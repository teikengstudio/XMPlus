import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:synchronized/synchronized.dart';

import '../api/xmly_client.dart';
import '../models/xmly_models.dart';
import 'app_log.dart';
import 'file_paths.dart';
import 'network_retry.dart';
import 'http_log_attempt.dart';

/// The sole upstream byte producer for one account/track/task directory.
/// URLs and caller identity headers never enter the on-disk index.
class AudioCache {
  static const blockSize = 1024 * 1024;
  static final _openDirectories = <String>{};
  final String directory;
  ResolvedAudio _audio;
  final Future<ResolvedAudio> Function(bool Function() isActive)? _refresh;
  final Future<void> Function()? _checkpoint;
  final void Function(int, int?, double)? _onProgress;
  final int? _rateLimitRetries;
  final Duration _minimumRateLimitDelay;
  final _blocks = <int, String>{};
  final _waiting = <int, Completer<void>>{};
  final _priority = LinkedHashSet<int>();
  final Lock _disk = Lock();
  Completer<void> _changed = Completer<void>();
  HttpClient? _client;
  Future<void>? _running;
  Completer<void>? _interruptedWait;
  int _producerEpoch = 0;
  Object? _failure;
  StackTrace? _failureStack;
  bool _closed = false, _paused = false, _background = false;
  bool _validated = false, _ranges = true;
  int _refreshAttempts = 0;
  int? _length;
  int _generation = 0, _revision = 0;
  int? _partialBlock;
  int _partialBytes = 0;
  String? _etag, _modified;
  String? get _rangeValidator {
    AppLog.instance.trace(
      "lib/services/audio_cache.dart::AudioCache._rangeValidator.get",
    );
    final etag = _etag;
    // A modification date must not override an explicitly weak entity tag.
    if (etag != null) return etag.startsWith('W/') ? null : etag;
    return _modified;
  }

  String _format = '';
  final Stopwatch _speedClock = Stopwatch()..start();
  int _speedBytes = 0;
  HttpLogAttempt? _diagnostic;

  AudioCache._(
    this.directory,
    this._audio,
    this._refresh,
    this._checkpoint,
    this._onProgress,
    this._rateLimitRetries,
    this._minimumRateLimitDelay,
  ) {
    AppLog.instance.trace("lib/services/audio_cache.dart::AudioCache._");
  }

  static Future<AudioCache> open({
    required String directory,
    required ResolvedAudio audio,
    Future<ResolvedAudio> Function(bool Function() isActive)? refresh,
    Future<void> Function()? checkpoint,
    void Function(int received, int? total, double rate)? onProgress,
    int? rateLimitRetries,
    Duration minimumRateLimitDelay = Duration.zero,
  }) {
    AppLog.instance.trace("lib/services/audio_cache.dart::AudioCache.open");
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/services/audio_cache.dart::AudioCache.open.closure#1",
      );

      if ((rateLimitRetries != null &&
              (rateLimitRetries < 0 || rateLimitRetries > 1000)) ||
          minimumRateLimitDelay.isNegative) {
        throw const XmlyException('invalid_retry', '限流重试设置无效');
      }
      final path = absoluteFilePath(directory);
      if (!_openDirectories.add(
        Platform.isWindows ? path.toLowerCase() : path,
      )) {
        throw const XmlyException('cache_in_use', '此缓存正在使用');
      }
      final cache = AudioCache._(
        path,
        audio,
        refresh,
        checkpoint,
        onProgress,
        rateLimitRetries,
        minimumRateLimitDelay,
      );
      try {
        cache._validateUri(audio.uri);
        await Directory(path).create(recursive: true);
        await cache._load();
        return cache;
      } catch (error, stack) {
        if (!AppLog.instance.errorWasRecorded(error)) {
          AppLog.instance.write(
            AppLogLevel.error,
            'audio_cache',
            'Audio cache open failed',
            error: error,
            stackTrace: stack,
            promptUser: true,
          );
        }
        _openDirectories.remove(Platform.isWindows ? path.toLowerCase() : path);
        rethrow;
      }
    });
  }

  String get accountIdentity {
    AppLog.instance.trace(
      "lib/services/audio_cache.dart::AudioCache.accountIdentity.get",
    );
    return _audio.accountIdentity;
  }

  int? get length {
    AppLog.instance.trace(
      "lib/services/audio_cache.dart::AudioCache.length.get",
    );
    return _length;
  }

  bool get supportsRanges {
    AppLog.instance.trace(
      "lib/services/audio_cache.dart::AudioCache.supportsRanges.get",
    );
    return _ranges;
  }

  String get sourceFormat {
    AppLog.instance.trace(
      "lib/services/audio_cache.dart::AudioCache.sourceFormat.get",
    );
    return _format;
  }

  int get generation {
    AppLog.instance.trace(
      "lib/services/audio_cache.dart::AudioCache.generation.get",
    );
    return _generation;
  }

  void updateAuthorization(ResolvedAudio audio) {
    AppLog.instance.trace(
      "lib/services/audio_cache.dart::AudioCache.updateAuthorization",
    );

    if (_running != null)
      throw const XmlyException('cache_in_use', '请先暂停原媒体请求');
    if (audio.accountIdentity != _audio.accountIdentity ||
        audio.track.id != _audio.track.id) {
      throw const XmlyException('cache_identity', '音频授权与缓存身份不符');
    }
    _validateUri(audio.uri);
    _audio = audio;
    // A resumed authorization can name a different version of the same track.
    // Complete caches are already coherent and require no further transport.
    if (!complete) _validated = false;
    _refreshAttempts = 0;
  }

  int get downloadedBytes {
    AppLog.instance.trace(
      "lib/services/audio_cache.dart::AudioCache.downloadedBytes.get",
    );
    return _blocks.keys.fold(0, (sum, index) {
          AppLog.instance.trace(
            "lib/services/audio_cache.dart::AudioCache.downloadedBytes.get.closure#1",
          );
          return sum + _blockLength(index);
        }) +
        _partialBytes;
  }

  bool get complete {
    AppLog.instance.trace(
      "lib/services/audio_cache.dart::AudioCache.complete.get",
    );
    return _validated &&
        _length != null &&
        _blocks.length == (_length! - 1) ~/ blockSize + 1;
  }

  File _block(int index) {
    AppLog.instance.trace("lib/services/audio_cache.dart::AudioCache._block");
    return File(p.join(directory, '$index.block'));
  }

  File _part(int index) {
    AppLog.instance.trace("lib/services/audio_cache.dart::AudioCache._part");
    return File(p.join(directory, '$index.part'));
  }

  int _blockLength(int index) {
    AppLog.instance.trace(
      "lib/services/audio_cache.dart::AudioCache._blockLength",
    );
    return _length == null
        ? blockSize
        : min(blockSize, _length! - index * blockSize);
  }

  Uri _validateUri(Uri uri) {
    AppLog.instance.trace(
      "lib/services/audio_cache.dart::AudioCache._validateUri",
    );
    return XmlyClient.mediaUri(uri.toString());
  }

  Future<void> _load() async {
    AppLog.instance.trace("lib/services/audio_cache.dart::AudioCache._load");

    Map<String, dynamic>? latest;
    for (var slot = 0; slot < 2; slot++) {
      final file = File(p.join(directory, 'index.$slot.json'));
      if (!await file.exists()) continue;
      try {
        if (await file.length() > 8 * 1024 * 1024) continue;
        final value = jsonDecode(await file.readAsString());
        if (value is! Map<String, dynamic> ||
            value['version'] != 1 ||
            value['revision'] is! int)
          continue;
        if (latest == null ||
            (value['revision'] as int) > (latest['revision'] as int))
          latest = value;
      } on FormatException catch (error, stack) {
        AppLog.instance.write(
          AppLogLevel.warning,
          'audio_cache',
          'Audio cache index unavailable',
          error: error,
          stackTrace: stack,
        );
        continue;
      }
    }
    if (latest == null) return;
    if (latest['account'] != _audio.accountIdentity ||
        latest['track'] != _audio.track.id ||
        latest['directory'] != directory) {
      throw const XmlyException('cache_identity', '缓存不属于当前账号或任务');
    }
    _revision = latest['revision'] as int;
    final size = latest['length'];
    if (size != null && (size is! int || size <= 0)) return;
    _length = size as int?;
    _etag = latest['etag'] is String ? latest['etag'] as String : null;
    _modified = latest['modified'] is String
        ? latest['modified'] as String
        : null;
    _ranges = latest['ranges'] == true;
    _format = latest['format'] is String ? latest['format'] as String : '';
    if (!_ranges || _length == null || latest['blocks'] is! Map) return;
    for (final entry in (latest['blocks'] as Map).entries) {
      final index = int.tryParse(entry.key.toString());
      if (index == null ||
          index < 0 ||
          index * blockSize >= _length! ||
          entry.value is! String)
        continue;
      final file = _block(index);
      if (await file.exists() &&
          await file.length() == _blockLength(index) &&
          (await sha256.bind(file.openRead()).single).toString() ==
              entry.value) {
        _blocks[index] = entry.value as String;
      }
    }
    // A resumed cache is not readable until a new upstream response verifies it.
  }

  Future<void> _save({int? index, String? digest}) async {
    AppLog.instance.trace("lib/services/audio_cache.dart::AudioCache._save");

    final revision = _revision + 1;
    final target = File(p.join(directory, 'index.${revision % 2}.json'));
    final temporary = File('${target.path}.tmp');
    await temporary.writeAsString(
      jsonEncode({
        'version': 1,
        'revision': revision,
        'account': _audio.accountIdentity,
        'track': _audio.track.id,
        'directory': directory,
        'length': _length,
        'etag': _etag,
        'modified': _modified,
        'ranges': _ranges,
        'format': _format,
        'blocks': {
          for (final entry in _blocks.entries) '${entry.key}': entry.value,
          if (index != null) '$index': digest,
        },
      }),
      flush: true,
    );
    // Two generations preserve the last committed index even on Windows, where
    // rename cannot replace a file. An interrupted inactive-slot write is ignored.
    if (await target.exists()) await target.delete();
    await temporary.rename(target.path);
    _revision = revision;
  }

  void _signal() {
    AppLog.instance.trace("lib/services/audio_cache.dart::AudioCache._signal");

    final old = _changed;
    _changed = Completer<void>();
    old.complete();
  }

  void _checkState() {
    AppLog.instance.trace(
      "lib/services/audio_cache.dart::AudioCache._checkState",
    );

    if (_closed) throw const XmlyException('cache_closed', '缓存已关闭');
    if (_paused) throw const XmlyException('cache_paused', '下载已暂停');
    if (_failure != null) Error.throwWithStackTrace(_failure!, _failureStack!);
  }

  void _checkProducer(int epoch) {
    AppLog.instance.trace(
      "lib/services/audio_cache.dart::AudioCache._checkProducer",
    );

    _checkState();
    if (epoch != _producerEpoch)
      throw const XmlyException('cache_source_changed', '音频来源已变化');
  }

  Future<T> _whileActive<T>(int epoch, Future<T> Function() operation) async {
    AppLog.instance.trace(
      "lib/services/audio_cache.dart::AudioCache._whileActive",
    );

    _checkProducer(epoch);
    final interrupted = Completer<void>();
    _interruptedWait = interrupted;
    try {
      // A per-wait completer releases its listener after this wait. Future.any
      // also observes late operation errors after pause has won the race.
      final result = await Future.any<T>([
        Future<T>.sync(operation),
        interrupted.future.then<T>((_) {
          AppLog.instance.trace(
            "lib/services/audio_cache.dart::AudioCache._whileActive.closure#1",
          );

          _checkProducer(epoch);
          throw const XmlyException('cache_source_changed', '音频来源已变化');
        }),
      ]);
      _checkProducer(epoch);
      return result;
    } finally {
      if (identical(_interruptedWait, interrupted)) _interruptedWait = null;
    }
  }

  void _resume() {
    AppLog.instance.trace("lib/services/audio_cache.dart::AudioCache._resume");

    if (_closed) throw const XmlyException('cache_closed', '缓存已关闭');
    if (_running == null) {
      if (!_ranges && !complete) _validated = false;
      _paused = false;
      _failure = null;
      _failureStack = null;
    }
  }

  Future<void> _need(int index) {
    AppLog.instance.trace("lib/services/audio_cache.dart::AudioCache._need");

    if (_validated && _blocks.containsKey(index)) return Future<void>.value();
    final waiter = _waiting.putIfAbsent(index, () {
      AppLog.instance.trace(
        "lib/services/audio_cache.dart::AudioCache._need.closure#1",
      );
      return Completer<void>();
    });
    _priority.add(index);
    _kick();
    return waiter.future;
  }

  void _kick() {
    AppLog.instance.trace("lib/services/audio_cache.dart::AudioCache._kick");

    if (_running != null || _closed || _paused || _failure != null || complete)
      return;
    _running = _produce(++_producerEpoch);
  }

  Future<void> _produce(int epoch) {
    AppLog.instance.trace("lib/services/audio_cache.dart::AudioCache._produce");
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/services/audio_cache.dart::AudioCache._produce.closure#1",
      );

      try {
        while (!_closed && !_paused) {
          if (_checkpoint != null) await _whileActive(epoch, _checkpoint);
          int? next;
          if (!_validated) {
            next = 0;
          } else {
            _priority.removeWhere((index) {
              AppLog.instance.trace(
                "lib/services/audio_cache.dart::AudioCache._produce.closure#1.closure#1",
              );
              return _blocks.containsKey(index) ||
                  (_length != null && index * blockSize >= _length!);
            });
            if (_priority.isNotEmpty) next = _priority.first;
            if (next == null && _background && !complete) {
              next = 0;
              while (_blocks.containsKey(next)) {
                next = next! + 1;
              }
            }
          }
          if (next == null) break;
          try {
            final before = downloadedBytes;
            await _fetchWithRetry(next, epoch);
            // Verification of an already cached prefix is not forward progress:
            // repeatedly authorizing only that prefix must still hit the limit.
            if (downloadedBytes > before) _refreshAttempts = 0;
          } on XmlyException catch (error) {
            if (error.code != 'media_unauthorized') rethrow;
            await _refreshAuthorization(epoch);
            continue;
          }
          for (final index in _waiting.keys.toList()) {
            if (_validated &&
                (_blocks.containsKey(index) ||
                    (_length != null && index * blockSize >= _length!))) {
              _waiting.remove(index)!.complete();
            }
          }
          _signal();
        }
      } catch (error, stack) {
        final expected =
            _closed ||
            _paused ||
            (error is XmlyException &&
                const {
                  'cache_closed',
                  'cache_paused',
                  'cache_source_changed',
                  'client_closed',
                  'request_cancelled',
                  'login_required',
                  'login_expired',
                  'permission_denied',
                  'insufficient_quota',
                  'preview_only',
                  'media_unauthorized',
                  'rate_limited',
                }.contains(error.code));
        if (!expected) {
          if (!AppLog.instance.errorWasRecorded(error)) {
            AppLog.instance.write(
              AppLogLevel.error,
              'audio_cache',
              'Audio cache production failed',
              error: error,
              stackTrace: stack,
              promptUser: true,
            );
          } else {
            AppLog.instance.requestUploadPrompt();
          }
        }
        _client?.close(force: true);
        _client = null;
        _failure = _closed
            ? const XmlyException('cache_closed', '缓存已关闭')
            : _paused
            ? const XmlyException('cache_paused', '下载已暂停')
            : error;
        AppLog.instance.linkError(_failure!, error);
        _failureStack = stack;
        for (final waiter in _waiting.values) {
          waiter.completeError(_failure!, stack);
        }
        _waiting.clear();
        _priority.clear();
      } finally {
        _running = null;
        _signal();
      }
    });
  }

  Future<void> _refreshAuthorization(int epoch) async {
    AppLog.instance.trace(
      "lib/services/audio_cache.dart::AudioCache._refreshAuthorization",
    );

    final generation = _generation;
    bool isActive() {
      AppLog.instance.trace(
        "lib/services/audio_cache.dart::AudioCache._refreshAuthorization.isActive",
      );
      return !_closed &&
          !_paused &&
          epoch == _producerEpoch &&
          generation == _generation;
    }

    while (true) {
      _checkProducer(epoch);
      if (_refresh == null || _refreshAttempts >= 3) {
        throw const XmlyException('media_unauthorized', '音频授权仍然失效，自动重新获取次数已用尽');
      }
      // Bound consecutive renewals that fail to produce new cached bytes.
      _refreshAttempts++;
      late ResolvedAudio audio;
      try {
        // API requests own their network retries; do not wrap this in the CDN
        // transport retry loop and multiply retries for a failed resolution.
        audio = await _whileActive(epoch, () {
          AppLog.instance.trace(
            "lib/services/audio_cache.dart::AudioCache._refreshAuthorization.closure#1",
          );
          return _refresh(isActive);
        });
      } on XmlyException catch (error) {
        if (error.code != 'media_unauthorized') rethrow;
        continue;
      }
      if (!isActive())
        throw const XmlyException('cache_source_changed', '音频来源已变化');
      if (audio.accountIdentity != _audio.accountIdentity ||
          audio.track.id != _audio.track.id) {
        throw const XmlyException('cache_identity', '重新授权的账号或声音不一致');
      }
      _validateUri(audio.uri);
      _audio = audio;
      // Keep validators and hashes, but verify block zero before reusing bytes
      // from a different URL. The producer then resumes missing blocks.
      _validated = false;
      return;
    }
  }

  Future<T> _transport<T>(Future<T> Function() operation) async {
    AppLog.instance.trace(
      "lib/services/audio_cache.dart::AudioCache._transport",
    );

    try {
      return await operation();
    } on SocketException catch (error, stack) {
      final failure = _AudioTransportFailure(error, stack);
      AppLog.instance.linkError(failure, error);
      throw failure;
    } on TimeoutException catch (error, stack) {
      final failure = _AudioTransportFailure(error, stack);
      AppLog.instance.linkError(failure, error);
      throw failure;
    } on HttpException catch (error, stack) {
      final message = error.message.toLowerCase();
      if (!message.startsWith('connection closed') &&
          !message.contains('connection reset by peer'))
        rethrow;
      final failure = _AudioTransportFailure(error, stack);
      AppLog.instance.linkError(failure, error);
      throw failure;
    }
  }

  Future<void> _fetchWithRetry(
    int index,
    int epoch, {
    bool verifyOnly = false,
  }) async {
    AppLog.instance.trace(
      "lib/services/audio_cache.dart::AudioCache._fetchWithRetry",
    );

    var rateRetries = 0, transportRetries = 0;
    for (var attempt = 0; ; attempt++) {
      final previousDiagnostic = _diagnostic;
      _diagnostic = null;
      try {
        await _fetch(
          index,
          epoch,
          resumeSequential: attempt > 0,
          verifyOnly: verifyOnly,
        );
        _diagnostic?.succeeded();
        _diagnostic?.responseBytes = null;
        return;
      } catch (error, stack) {
        if (_paused || _closed || epoch != _producerEpoch) {
          _diagnostic?.cancelled(error);
        } else if (error is FileSystemException) {
          if (!AppLog.instance.errorWasRecorded(error)) {
            AppLog.instance.write(
              AppLogLevel.error,
              'audio_cache',
              'Audio cache write failed',
              error: error,
              stackTrace: stack,
              promptUser: true,
            );
          }
        } else {
          await _diagnostic?.fail(
            error is _AudioTransportFailure ? error.error : error,
            error is _AudioTransportFailure ? error.stack : stack,
            promptUser:
                !(error is XmlyException &&
                    const {
                      'media_unauthorized',
                      'rate_limited',
                    }.contains(error.code)),
          );
        }
        final rateLimited =
            error is XmlyException && error.code == 'rate_limited';
        if (error is! _AudioTransportFailure && !rateLimited) rethrow;
        _client?.close(force: true);
        _client = null;
        _checkProducer(epoch);
        final exhausted = _rateLimitRetries == null
            ? attempt >= 4
            : rateLimited
            ? rateRetries++ >= _rateLimitRetries
            : transportRetries++ >= 4;
        if (exhausted) {
          if (error is _AudioTransportFailure)
            Error.throwWithStackTrace(error.error, error.stack);
          Error.throwWithStackTrace(error, stack);
        }
        final backoff = Duration(
          seconds:
              1 <<
              (_rateLimitRetries == null
                  ? min(attempt, 4)
                  : max(0, min(transportRetries - 1, 4))),
        );
        final retryAfter = rateLimited
            ? error.retryAfter
            : error is _AudioTransportFailure
            ? error.retryAfter
            : null;
        var delay = retryAfter != null && retryAfter > backoff
            ? retryAfter
            : backoff;
        if (rateLimited && _minimumRateLimitDelay > delay) {
          delay = _minimumRateLimitDelay;
        }
        final ready = Completer<void>();
        final timer = Timer(delay, ready.complete);
        try {
          await _whileActive(epoch, () {
            AppLog.instance.trace(
              "lib/services/audio_cache.dart::AudioCache._fetchWithRetry.closure#1",
            );
            return ready.future;
          });
        } finally {
          // Losing the active-wait race must also release its timer; otherwise
          // a long Retry-After keeps the isolate alive after pause or close.
          timer.cancel();
        }
      } finally {
        _diagnostic?.responseBytes = null;
        _diagnostic = previousDiagnostic;
      }
    }
  }

  Stream<List<int>> _responseBytes(
    HttpClientResponse response,
    int epoch,
  ) async* {
    AppLog.instance.trace(
      "lib/services/audio_cache.dart::AudioCache._responseBytes",
    );

    final diagnostic = _diagnostic;
    final iterator = StreamIterator(
      response.timeout(const Duration(seconds: 25)),
    );
    try {
      while (await _whileActive(epoch, () {
        AppLog.instance.trace(
          "lib/services/audio_cache.dart::AudioCache._responseBytes.closure#1",
        );
        return _transport(iterator.moveNext);
      })) {
        if (diagnostic != null) {
          diagnostic.responseByteCount =
              (diagnostic.responseByteCount ?? 0) + iterator.current.length;
        }
        yield iterator.current;
      }
      diagnostic?.completeness = '完整（已接收音频响应体）';
    } finally {
      await iterator.cancel();
    }
  }

  Future<void> _discard(HttpClientResponse response) {
    AppLog.instance.trace("lib/services/audio_cache.dart::AudioCache._discard");
    return response.listen(null).cancel();
  }

  Future<void> _captureFailureResponse(HttpClientResponse response) async {
    AppLog.instance.trace(
      "lib/services/audio_cache.dart::AudioCache._captureFailureResponse",
    );

    final diagnostic = _diagnostic!;
    const limit = 2 * 1024 * 1024;
    final bytes = BytesBuilder(copy: false);
    diagnostic.responseBytes = bytes.toBytes;
    diagnostic.completeness = '响应体未接收完整（接收中或传输中断）';
    try {
      await for (final chunk in _responseBytes(response, _producerEpoch)) {
        final remaining = limit - bytes.length;
        if (chunk.length > remaining) {
          if (remaining > 0) bytes.add(chunk.sublist(0, remaining));
          diagnostic.completeness = '错误响应体已截断：诊断上限 $limit 字节';
          break;
        }
        bytes.add(chunk);
      }
      if (!diagnostic.completeness.contains('截断')) {
        diagnostic.completeness =
            response.contentLength >= 0 &&
                response.contentLength != bytes.length
            ? '响应体不完整：声明 ${response.contentLength} 字节，收到 ${bytes.length} 字节'
            : '完整（HTTP 响应体）';
      }
    } catch (transportError, transportStack) {
      diagnostic.transportError = '$transportError';
      if (_paused || _closed) {
        diagnostic.cancelled(transportError);
      } else {
        await diagnostic.fail(
          transportError is _AudioTransportFailure
              ? transportError.error
              : transportError,
          transportError is _AudioTransportFailure
              ? transportError.stack
              : transportStack,
        );
      }
    }
  }

  // Reuse bytes already written to the cache; do not buffer whole successful audio.
  List<int> _diagnosticPrefix(
    int length, {
    List<int> prefix = const [],
    List<int> chunk = const [],
  }) {
    AppLog.instance.trace(
      "lib/services/audio_cache.dart::AudioCache._diagnosticPrefix",
    );

    const limit = 2 * 1024 * 1024;
    length = min(length, limit);
    final bytes = BytesBuilder(copy: false);
    var offset = 0;
    while (offset < length) {
      final index = offset ~/ blockSize;
      final file = _blocks.containsKey(index) ? _block(index) : _part(index);
      final handle = file.openSync();
      try {
        final chunk = handle.readSync(min(blockSize, length - offset));
        if (chunk.length != min(blockSize, length - offset)) {
          throw const FileSystemException('已接收音频缓存不完整');
        }
        bytes.add(chunk);
        offset += chunk.length;
      } finally {
        handle.closeSync();
      }
    }
    for (final part in [prefix, chunk]) {
      final count = min(part.length, limit - bytes.length);
      if (count > 0) {
        bytes.add(count == part.length ? part : part.sublist(0, count));
      }
    }
    return bytes.takeBytes();
  }

  Future<({HttpClientResponse response, Uri finalUri})> _request(
    int start,
    int end,
    int epoch,
  ) async {
    AppLog.instance.trace("lib/services/audio_cache.dart::AudioCache._request");

    var uri = _audio.uri;
    for (var redirects = 0; ; redirects++) {
      final diagnostic = HttpLogAttempt(
        account: _audio.accountIdentity,
        method: 'GET',
        url: uri.toString(),
      );
      diagnostic.responseIsBinary = true;
      final validator = _validated && _blocks.isNotEmpty
          ? _rangeValidator
          : null;
      diagnostic.requestHeaders = {
        HttpHeaders.userAgentHeader: 'XMPlus/1.0',
        HttpHeaders.acceptHeader: 'audio/*, application/octet-stream',
        HttpHeaders.acceptEncodingHeader: 'identity',
        HttpHeaders.rangeHeader: 'bytes=$start-$end',
        if (validator != null) HttpHeaders.ifRangeHeader: validator,
      };
      _diagnostic = diagnostic;
      diagnostic.started();
      try {
        uri = _validateUri(uri);
      } on XmlyException {
        _audio.invalidateCachedUri();
        rethrow;
      }
      _checkProducer(epoch);
      _client ??= HttpClient()
        ..connectionTimeout = const Duration(seconds: 10)
        ..autoUncompress = false;
      final request = await _whileActive(epoch, () {
        AppLog.instance.trace(
          "lib/services/audio_cache.dart::AudioCache._request.closure#1",
        );
        return _transport(() {
          AppLog.instance.trace(
            "lib/services/audio_cache.dart::AudioCache._request.closure#1.closure#1",
          );
          return _client!.getUrl(uri).timeout(const Duration(seconds: 25));
        });
      });
      request.followRedirects = false;
      // Deliberately ignore ResolvedAudio.headers. API cookies, x-tk and all other
      // identity headers must never reach either a CDN or its redirect target.
      request.headers.set(HttpHeaders.userAgentHeader, 'XMPlus/1.0');
      request.headers.set(
        HttpHeaders.acceptHeader,
        'audio/*, application/octet-stream',
      );
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-$end');
      if (validator != null)
        request.headers.set(HttpHeaders.ifRangeHeader, validator);
      request.headers.forEach((name, values) {
        AppLog.instance.trace(
          "lib/services/audio_cache.dart::AudioCache._request.closure#2",
        );

        diagnostic.requestHeaders[name] = List<String>.of(values);
      });
      final response = await _whileActive(epoch, () {
        AppLog.instance.trace(
          "lib/services/audio_cache.dart::AudioCache._request.closure#3",
        );
        return _transport(() {
          AppLog.instance.trace(
            "lib/services/audio_cache.dart::AudioCache._request.closure#3.closure#1",
          );
          return request.close().timeout(const Duration(seconds: 25));
        });
      });
      diagnostic.status = response.statusCode;
      diagnostic.responseByteCount = 0;
      response.headers.forEach((name, values) {
        AppLog.instance.trace(
          "lib/services/audio_cache.dart::AudioCache._request.closure#4",
        );

        diagnostic.responseHeaders[name] = List<String>.of(values);
      });
      diagnostic.completeness = '响应体未接收完整（接收中或传输中断）';
      if (![200, 206, 301, 302, 303, 307, 308].contains(response.statusCode)) {
        await _captureFailureResponse(response);
      }
      if (retryableStatus(response.statusCode) && response.statusCode != 429) {
        throw _AudioTransportFailure(
          HttpException('HTTP ${response.statusCode}', uri: uri),
          StackTrace.current,
          retryAfter: serverRetryAfter(
            response.headers.value(HttpHeaders.retryAfterHeader),
          ),
        );
      }
      if ([301, 302, 303, 307, 308].contains(response.statusCode)) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        if (location != null && location.isNotEmpty && redirects < 5) {
          try {
            final target = _validateUri(uri.resolve(location));
            await _discard(response);
            diagnostic.completeness = '重定向响应体未读取';
            diagnostic.succeeded();
            uri = target;
            continue;
          } catch (_) {
            await _captureFailureResponse(response);
            // Keep redirect validation/transport failures on this request.
            _audio.invalidateCachedUri();
            rethrow;
          }
        }
        await _captureFailureResponse(response);
        _audio.invalidateCachedUri();
        throw const XmlyException('invalid_media', '音频重定向过多或无效');
      }
      if (response.statusCode == 401 || response.statusCode == 403) {
        _audio.invalidateCachedUri();
        _validated = false;
        throw const XmlyException('media_unauthorized', '音频授权已失效');
      }
      if (response.statusCode == 429) {
        final header = response.headers.value(HttpHeaders.retryAfterHeader);
        final wait = serverRetryAfter(header) ?? const Duration(minutes: 5);
        throw XmlyException('rate_limited', '音频请求过于频繁，请稍后重试', retryAfter: wait);
      }
      return (response: response, finalUri: uri);
    }
  }

  bool _acceptableType(HttpClientResponse response) {
    AppLog.instance.trace(
      "lib/services/audio_cache.dart::AudioCache._acceptableType",
    );

    final type = response.headers.contentType?.mimeType.toLowerCase() ?? '';
    return type.startsWith('audio/') ||
        type.startsWith('video/') ||
        type == 'application/octet-stream' ||
        type == 'binary/octet-stream' ||
        type == 'application/ogg' ||
        type.isEmpty;
  }

  static String _sniff(List<int> bytes) {
    AppLog.instance.trace("lib/services/audio_cache.dart::AudioCache._sniff");

    bool text(int offset, String value) {
      AppLog.instance.trace(
        "lib/services/audio_cache.dart::AudioCache._sniff.text",
      );
      return bytes.length >= offset + value.length &&
          List.generate(value.length, (i) {
            AppLog.instance.trace(
              "lib/services/audio_cache.dart::AudioCache._sniff.text.closure#1",
            );
            return bytes[offset + i] == value.codeUnitAt(i);
          }).every((v) {
            AppLog.instance.trace(
              "lib/services/audio_cache.dart::AudioCache._sniff.text.closure#2",
            );
            return v;
          });
    }

    if (text(0, 'ID3')) return 'mp3';
    if (text(0, 'fLaC')) return 'flac';
    if (text(0, 'OggS')) return 'ogg';
    if (text(0, 'RIFF') && text(8, 'WAVE')) return 'wav';
    if (text(4, 'ftyp')) return 'm4a';
    if (bytes.length >= 4 &&
        bytes[0] == 0xff &&
        (bytes[1] & 0xe0) == 0xe0 &&
        (bytes[1] & 0x06) != 0 &&
        (bytes[2] & 0xf0) != 0xf0 &&
        (bytes[2] & 0xf0) != 0 &&
        (bytes[2] & 0x0c) != 0x0c)
      return 'mp3';
    if (bytes.length >= 4 &&
        bytes[0] == 0xff &&
        (bytes[1] & 0xf6) == 0xf0 &&
        (bytes[2] & 0x3c) != 0x3c)
      return 'aac';
    throw const XmlyException('invalid_media', '响应不是可识别的音频，未保存错误页面');
  }

  Future<void> _reset() {
    AppLog.instance.trace("lib/services/audio_cache.dart::AudioCache._reset");
    return _disk.synchronized(() async {
      AppLog.instance.trace(
        "lib/services/audio_cache.dart::AudioCache._reset.closure#1",
      );

      // Commit the empty index before removing old blocks. Orphans are never read.
      _generation++;
      _blocks.clear();
      _partialBlock = null;
      _partialBytes = 0;
      _validated = false;
      await _save();
      await for (final entry in Directory(directory).list(followLinks: false)) {
        if (entry is File &&
            RegExp(r'^[0-9]+\.(?:block|part)$')
                .hasMatch(p.basename(entry.path))) {
          await entry.delete();
        }
      }
      _signal();
    });
  }

  Future<bool> _metadata(
    HttpClientResponse response,
    int? size,
    bool ranges, {
    bool resumeSequential = false,
  }) async {
    AppLog.instance.trace(
      "lib/services/audio_cache.dart::AudioCache._metadata",
    );

    final etag = response.headers.value(HttpHeaders.etagHeader);
    final modified = response.headers.value(HttpHeaders.lastModifiedHeader);
    final hadBytes = _blocks.isNotEmpty || _partialBytes > 0;
    final changed =
        hadBytes &&
        (_length != size ||
            _etag != etag ||
            _modified != modified ||
            _ranges != ranges ||
            (!ranges && !resumeSequential));
    if (changed) await _reset();
    _length = size;
    _etag = etag;
    _modified = modified;
    _ranges = ranges;
    return changed;
  }

  Future<void> _fetch(
    int index,
    int epoch, {
    bool resumeSequential = false,
    bool verifyOnly = false,
  }) async {
    AppLog.instance.trace("lib/services/audio_cache.dart::AudioCache._fetch");

    final start = index * blockSize;
    final requestedEnd = !_validated || _length == null
        ? start + blockSize - 1
        : min(start + blockSize, _length!) - 1;
    final result = await _request(start, requestedEnd, epoch);
    final response = result.response;
    if (verifyOnly && response.statusCode != HttpStatus.partialContent) {
      await _discard(response);
      await _reset();
      throw const XmlyException('cache_source_changed', '音频来源已变化');
    }
    if (response.statusCode == 416) {
      final match = RegExp(r'^bytes \*/([0-9]+)$').firstMatch(
        response.headers.value(HttpHeaders.contentRangeHeader) ?? '',
      );
      if (complete && match != null && int.tryParse(match[1]!) == _length) {
        await _diagnostic?.fail(
          HttpException('HTTP ${response.statusCode}', uri: result.finalUri),
          StackTrace.current,
        );
        return;
      }
      _audio.invalidateCachedUri();
      final size = match == null ? null : int.tryParse(match[1]!);
      if (size != null && size > 0 && size != _length) {
        await _reset();
        _length = size;
        await _save();
      }
      throw const XmlyException('cache_range', '服务器拒绝音频范围，缓存尚未完整');
    }
    if (![200, 206].contains(response.statusCode) ||
        !_acceptableType(response) ||
        (response.headers.value(HttpHeaders.contentEncodingHeader) ??
                'identity') !=
            'identity') {
      _audio.invalidateCachedUri();
      if ([200, 206].contains(response.statusCode)) {
        await _captureFailureResponse(response);
      }
      throw const XmlyException('invalid_media', '服务器未返回有效音频');
    }
    if (response.statusCode == 200) {
      final changed = await _metadata(
        response,
        response.contentLength < 0 ? null : response.contentLength,
        false,
        resumeSequential: resumeSequential,
      );
      final resumeBytes = resumeSequential && !changed ? downloadedBytes : 0;
      if (resumeBytes == 0 && (_blocks.isNotEmpty || _partialBytes > 0)) {
        await _reset();
      }
      await _sequential(response, result.finalUri, epoch, resumeBytes);
      return;
    }
    final match = RegExp(
      r'^bytes ([0-9]+)-([0-9]+)/([0-9]+)$',
    ).firstMatch(response.headers.value(HttpHeaders.contentRangeHeader) ?? '');
    final first = match == null ? null : int.tryParse(match[1]!);
    final last = match == null ? null : int.tryParse(match[2]!);
    final total = match == null ? null : int.tryParse(match[3]!);
    if (first != start ||
        last == null ||
        total == null ||
        total <= 0 ||
        last < start ||
        last != min(requestedEnd, total - 1) ||
        (response.contentLength >= 0 &&
            response.contentLength != last - start + 1)) {
      _audio.invalidateCachedUri();
      await _captureFailureResponse(response);
      throw const XmlyException('cache_range', '服务器返回的音频范围不一致');
    }
    final changed = await _metadata(response, total, true);
    if (verifyOnly && changed) {
      await _discard(response);
      throw const XmlyException('cache_source_changed', '音频来源已变化');
    }
    if (changed &&
        (index != 0 || last != min(start + blockSize - 1, total - 1))) {
      await _discard(response);
      return;
    }
    final bytes = BytesBuilder(copy: false);
    _diagnostic?.responseBytes = bytes.toBytes;
    try {
      await for (final chunk in _responseBytes(response, epoch)) {
        _diagnostic?.responseBytes = () {
          AppLog.instance.trace(
            "lib/services/audio_cache.dart::AudioCache._fetch.closure#1",
          );
          return _diagnosticPrefix(0, prefix: bytes.toBytes(), chunk: chunk);
        };
        _checkState();
        if (_checkpoint != null) await _whileActive(epoch, _checkpoint);
        if (bytes.length + chunk.length > last - start + 1)
          throw const XmlyException('cache_range', '音频块长度不一致');
        bytes.add(chunk);
        _diagnostic?.responseBytes = bytes.toBytes;
      }
      if (bytes.length != last - start + 1) {
        _diagnostic?.completeness =
            '响应体不完整：范围声明 ${last - start + 1} 字节，收到 ${bytes.length} 字节';
        throw const XmlyException('cache_range', '音频块未接收完整');
      }
      final data = bytes.takeBytes();
      _diagnostic?.responseBytes = () {
        AppLog.instance.trace(
          "lib/services/audio_cache.dart::AudioCache._fetch.closure#2",
        );
        return data;
      };
      if (verifyOnly) {
        if (_blocks[index] != sha256.convert(data).toString()) {
          await _reset();
          throw const XmlyException('cache_source_changed', '音频来源已变化');
        }
        return;
      }
      if (index == 0) {
        _format = _sniff(data);
        final oldHash = _blocks[0];
        if (oldHash != null && oldHash != sha256.convert(data).toString())
          await _reset();
        // Without a strong validator, verify every retained block before
        // releasing readers. Matching block zero alone cannot prove that a
        // previously cached later range still belongs to the same audio.
        if (!_validated && _rangeValidator == null) {
          final retained = _blocks.keys.where((index) {
            AppLog.instance.trace(
              "lib/services/audio_cache.dart::AudioCache._fetch.closure#3",
            );
            return index != 0;
          }).toList();
          _diagnostic?.succeeded();
          try {
            for (final retainedIndex in retained) {
              await _fetchWithRetry(retainedIndex, epoch, verifyOnly: true);
            }
          } catch (_) {
            // The nested attempt already recorded its own upstream failure.
            _diagnostic = null;
            rethrow;
          }
        }
        _validated = true;
      }
      _checkProducer(epoch);
      _audio.rememberFinalUri(result.finalUri);
      await _commitBlock(index, data);
    } on XmlyException catch (error) {
      if (error.code == 'invalid_media' || error.code == 'cache_range')
        _audio.invalidateCachedUri();
      rethrow;
    } finally {
      _signal();
    }
  }

  Future<void> _commitBlock(int index, List<int> bytes) {
    AppLog.instance.trace(
      "lib/services/audio_cache.dart::AudioCache._commitBlock",
    );
    return _disk.synchronized(() async {
      AppLog.instance.trace(
        "lib/services/audio_cache.dart::AudioCache._commitBlock.closure#1",
      );

      final temporary = _part(index);
      await temporary.writeAsBytes(bytes, flush: true);
      final target = _block(index);
      if (await target.exists()) await target.delete();
      await temporary.rename(target.path);
      final digest = sha256.convert(bytes).toString();
      await _save(index: index, digest: digest);
      _blocks[index] = digest;
      _progress(bytes.length);
      _signal();
    });
  }

  Future<void> _sequential(
    HttpClientResponse response,
    Uri finalUri,
    int epoch,
    int resumeBytes,
  ) async {
    AppLog.instance.trace(
      "lib/services/audio_cache.dart::AudioCache._sequential",
    );

    var offset = 0;
    RandomAccessFile? writer;
    final prefix = BytesBuilder(copy: false);
    var sniffed = false;
    Future<void> writeChunk(List<int> bytes) async {
      AppLog.instance.trace(
        "lib/services/audio_cache.dart::AudioCache._sequential.writeChunk",
      );

      var position = 0;
      while (position < bytes.length) {
        _checkProducer(epoch);
        final index = offset ~/ blockSize;
        if (offset < resumeBytes) {
          // A non-range server must replay its prefix. Compare every cached
          // byte before appending, even when it supplies no version validator.
          final count = min(
            bytes.length - position,
            min(resumeBytes - offset, blockSize - offset % blockSize),
          );
          final file = _blocks.containsKey(index)
              ? _block(index)
              : _part(index);
          final handle = await file.open();
          late List<int> cached;
          try {
            await handle.setPosition(offset % blockSize);
            cached = await handle.read(count);
          } finally {
            await handle.close();
          }
          var matches = cached.length == count;
          for (var i = 0; matches && i < count; i++) {
            matches = cached[i] == bytes[position + i];
          }
          _checkProducer(epoch);
          if (!matches) {
            await _reset();
            throw const XmlyException('cache_source_changed', '音频来源已变化');
          }
          offset += count;
          position += count;
          continue;
        }
        writer ??= await _part(index).open(
          mode: offset % blockSize == 0 ? FileMode.write : FileMode.append,
        );
        final count = min(
          bytes.length - position,
          blockSize - offset % blockSize,
        );
        await writer!.writeFrom(bytes, position, position + count);
        await writer!.flush();
        offset += count;
        position += count;
        _partialBlock = index;
        _partialBytes = offset % blockSize == 0
            ? blockSize
            : offset % blockSize;
        if (_partialBytes == blockSize) {
          await writer!.close();
          writer = null;
          await _finishSequentialBlock(index);
        }
        _progress(count);
        _signal();
      }
    }

    try {
      await for (final chunk in _responseBytes(response, epoch)) {
        final receivedOffset = offset;
        _diagnostic?.responseBytes = () {
          AppLog.instance.trace(
            "lib/services/audio_cache.dart::AudioCache._sequential.closure#1",
          );
          return _diagnosticPrefix(
            receivedOffset,
            prefix: prefix.toBytes(),
            chunk: chunk,
          );
        };
        _checkState();
        if (_checkpoint != null) await _whileActive(epoch, _checkpoint);
        if (_length != null &&
            offset + prefix.length + chunk.length > _length!) {
          throw const XmlyException('cache_range', '音频流超过声明长度');
        }
        if (!sniffed) {
          prefix.add(chunk);
          _diagnostic?.responseBytes = prefix.toBytes;
          if (prefix.length < 12) continue;
          final initial = prefix.takeBytes();
          _diagnostic?.responseBytes = () {
            AppLog.instance.trace(
              "lib/services/audio_cache.dart::AudioCache._sequential.closure#2",
            );
            return _diagnosticPrefix(0, prefix: initial);
          };
          _format = _sniff(initial);
          _validated = true;
          sniffed = true;
          _checkProducer(epoch);
          _audio.rememberFinalUri(finalUri);
          await writeChunk(initial);
        } else {
          await writeChunk(chunk);
        }
        final received = offset;
        _diagnostic?.responseBytes = () {
          AppLog.instance.trace(
            "lib/services/audio_cache.dart::AudioCache._sequential.closure#3",
          );
          return _diagnosticPrefix(received);
        };
      }
      if (!sniffed) {
        final initial = prefix.takeBytes();
        _diagnostic?.responseBytes = () {
          AppLog.instance.trace(
            "lib/services/audio_cache.dart::AudioCache._sequential.closure#4",
          );
          return _diagnosticPrefix(0, prefix: initial);
        };
        _format = _sniff(initial);
        _validated = true;
        _checkProducer(epoch);
        _audio.rememberFinalUri(finalUri);
        await writeChunk(initial);
      }
      if (_length != null && offset != _length)
        throw const XmlyException('cache_range', '音频流未接收完整');
      if (offset <= 0) throw const XmlyException('invalid_media', '音频为空');
      _length = offset;
      if (writer != null) {
        await writer!.close();
        writer = null;
        await _finishSequentialBlock((offset - 1) ~/ blockSize);
      }
      await _save();
    } on XmlyException catch (error) {
      if (error.code == 'invalid_media' || error.code == 'cache_range')
        _audio.invalidateCachedUri();
      rethrow;
    } finally {
      await writer?.close();
      _signal();
    }
  }

  Future<void> _finishSequentialBlock(int index) {
    AppLog.instance.trace(
      "lib/services/audio_cache.dart::AudioCache._finishSequentialBlock",
    );
    return _disk.synchronized(() async {
      AppLog.instance.trace(
        "lib/services/audio_cache.dart::AudioCache._finishSequentialBlock.closure#1",
      );

      final temporary = _part(index);
      final digest = (await sha256.bind(temporary.openRead()).single)
          .toString();
      final target = _block(index);
      if (await target.exists()) await target.delete();
      await temporary.rename(target.path);
      await _save(index: index, digest: digest);
      _blocks[index] = digest;
      _partialBlock = null;
      _partialBytes = 0;
    });
  }

  void _progress(int count) {
    AppLog.instance.trace(
      "lib/services/audio_cache.dart::AudioCache._progress",
    );

    _speedBytes += count;
    final seconds = _speedClock.elapsedMicroseconds / 1000000;
    _onProgress?.call(
      downloadedBytes,
      _length,
      seconds > 0 ? _speedBytes / seconds : 0,
    );
  }

  Future<void> ensureComplete() {
    AppLog.instance.trace(
      "lib/services/audio_cache.dart::AudioCache.ensureComplete",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/services/audio_cache.dart::AudioCache.ensureComplete.closure#1",
      );

      _resume();
      _background = true;
      _kick();
      while (!complete) {
        final changed = _changed.future;
        _checkState();
        await changed;
      }
      await _running;
      _checkState();
    });
  }

  Future<List<int>> read(int start, int endExclusive) {
    AppLog.instance.trace("lib/services/audio_cache.dart::AudioCache.read");
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/services/audio_cache.dart::AudioCache.read.closure#1",
      );

      final bytes = BytesBuilder(copy: false);
      await for (final chunk in stream(start, endExclusive)) {
        bytes.add(chunk);
      }
      return bytes.takeBytes();
    });
  }

  Stream<List<int>> stream(int start, [int? endExclusive]) {
    AppLog.instance.trace("lib/services/audio_cache.dart::AudioCache.stream");

    final output = StreamController<List<int>>();
    final cancelled = Completer<void>();
    StreamSubscription<List<int>>? subscription;
    output.onListen = () {
      AppLog.instance.trace(
        "lib/services/audio_cache.dart::AudioCache.stream.closure#1",
      );

      subscription = _readStream(
        start,
        endExclusive,
        cancelled,
      ).listen(output.add, onError: output.addError, onDone: output.close);
    };
    output.onPause = () {
      AppLog.instance.trace(
        "lib/services/audio_cache.dart::AudioCache.stream.closure#2",
      );
      subscription?.pause();
    };
    output.onResume = () {
      AppLog.instance.trace(
        "lib/services/audio_cache.dart::AudioCache.stream.closure#3",
      );
      subscription?.resume();
    };
    output.onCancel = () async {
      AppLog.instance.trace(
        "lib/services/audio_cache.dart::AudioCache.stream.closure#4",
      );

      if (!cancelled.isCompleted) cancelled.complete();
      await subscription?.cancel();
    };
    return output.stream;
  }

  Stream<List<int>> _readStream(
    int start,
    int? endExclusive,
    Completer<void> cancelled,
  ) async* {
    AppLog.instance.trace(
      "lib/services/audio_cache.dart::AudioCache._readStream",
    );

    if (start < 0 || (endExclusive != null && endExclusive < start))
      throw RangeError('Invalid audio range');
    // Only the download owner may explicitly resume production after a pause.
    if (!_paused || _closed) _resume();
    var initialGeneration = _generation;
    var offset = start;
    while (!cancelled.isCompleted &&
        (endExclusive == null || offset < endExclusive)) {
      final changed = _changed.future;
      if (!_paused || _closed) _checkState();
      if (_generation != initialGeneration) {
        if (offset != start)
          throw const XmlyException('cache_source_changed', '音频来源已变化，请重新打开');
        initialGeneration = _generation;
      }
      if (_validated && _length != null && offset >= _length!) {
        if (endExclusive != null && endExclusive > _length!)
          throw RangeError('Audio range exceeds length');
        break;
      }
      final index = offset ~/ blockSize;
      if (!_paused && (!_validated || !_blocks.containsKey(index)))
        _need(index).ignore();
      int available = 0;
      File? file;
      if (_validated && _blocks.containsKey(index)) {
        available = _blockLength(index);
        file = _block(index);
      } else if (_validated && _partialBlock == index) {
        available = _partialBytes;
        file = _part(index);
      }
      final within = offset % blockSize;
      if (file == null || available <= within) {
        _checkState();
        await Future.any([changed, cancelled.future]);
        continue;
      }
      final count = min(
        available - within,
        min(
          64 * 1024,
          endExclusive == null ? 64 * 1024 : endExclusive - offset,
        ),
      );
      final data = await _disk.synchronized(() async {
        AppLog.instance.trace(
          "lib/services/audio_cache.dart::AudioCache._readStream.closure#1",
        );

        // Windows cannot rename a partial block while a reader holds its handle.
        RandomAccessFile handle;
        try {
          handle = await file!.open();
        } on FileSystemException catch (error, stack) {
          if (_blocks.containsKey(index) || _partialBlock == index) {
            AppLog.instance.write(
              AppLogLevel.warning,
              'audio_cache',
              'Audio cache read retrying committed block',
              error: error,
              stackTrace: stack,
            );
            handle = await _block(index).open();
          } else {
            rethrow;
          }
        }
        try {
          await handle.setPosition(within);
          return await handle.read(count);
        } finally {
          await handle.close();
        }
      });
      if (_generation != initialGeneration) {
        if (offset == start) continue;
        throw const XmlyException('cache_source_changed', '音频来源已变化，请重新打开');
      }
      if (data.length != count)
        throw const XmlyException('cache_range', '缓存块不完整');
      offset += data.length;
      yield data;
    }
  }

  Future<String> assemble(String outputPath) {
    AppLog.instance.trace("lib/services/audio_cache.dart::AudioCache.assemble");
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/services/audio_cache.dart::AudioCache.assemble.closure#1",
      );

      await ensureComplete();
      final generation = _generation;
      final output = File(outputPath);
      await output.create(exclusive: true);
      final handle = await output.open(mode: FileMode.writeOnly);
      try {
        await for (final chunk in stream(0, _length)) {
          if (_generation != generation)
            throw const XmlyException('cache_source_changed', '音频来源已变化');
          await handle.writeFrom(chunk);
        }
        await handle.flush();
      } finally {
        await handle.close();
      }
      return output.path;
    });
  }

  Future<void> pause() async {
    AppLog.instance.trace("lib/services/audio_cache.dart::AudioCache.pause");

    _paused = true;
    _background = false;
    _producerEpoch++;
    final interrupted = _interruptedWait;
    if (interrupted != null && !interrupted.isCompleted) interrupted.complete();
    _client?.close(force: true);
    _client = null;
    _signal();
    await _running;
  }

  Future<void> close() async {
    AppLog.instance.trace("lib/services/audio_cache.dart::AudioCache.close");

    if (_closed) return;
    _closed = true;
    await pause();
    _openDirectories.remove(
      Platform.isWindows ? directory.toLowerCase() : directory,
    );
  }

  Future<void> deleteRegenerable() async {
    AppLog.instance.trace(
      "lib/services/audio_cache.dart::AudioCache.deleteRegenerable",
    );

    await close();
    await Directory(directory).delete(recursive: true);
  }
}

class _AudioTransportFailure {
  final Object error;
  final StackTrace stack;
  final Duration? retryAfter;
  const _AudioTransportFailure(this.error, this.stack, {this.retryAfter});
}

/// Loopback-only, capability-token HTTP facade. No URL ever exposes a disk path.
class AudioProxy {
  final HttpServer _server;
  final String _token;
  final _mounts = <String, AudioCache>{};
  final _keys = <AudioCache, String>{};
  final _random = Random.secure();
  bool _closed = false;
  AudioProxy._(this._server, this._token) {
    AppLog.instance.trace("lib/services/audio_cache.dart::AudioProxy._");
  }

  static Future<AudioProxy> start() async {
    AppLog.instance.trace("lib/services/audio_cache.dart::AudioProxy.start");

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final random = Random.secure();
    final token = base64UrlEncode(
      List<int>.generate(32, (_) {
        AppLog.instance.trace(
          "lib/services/audio_cache.dart::AudioProxy.start.closure#1",
        );
        return random.nextInt(256);
      }),
    ).replaceAll('=', '');
    final proxy = AudioProxy._(server, token);
    server.listen((request) {
      AppLog.instance.trace(
        "lib/services/audio_cache.dart::AudioProxy.start.closure#2",
      );

      unawaited(proxy._serve(request));
    });
    return proxy;
  }

  Uri mount(AudioCache cache) {
    AppLog.instance.trace("lib/services/audio_cache.dart::AudioProxy.mount");

    final key = _keys.putIfAbsent(cache, () {
      AppLog.instance.trace(
        "lib/services/audio_cache.dart::AudioProxy.mount.closure#1",
      );
      return base64UrlEncode(
        List<int>.generate(24, (_) {
          AppLog.instance.trace(
            "lib/services/audio_cache.dart::AudioProxy.mount.closure#1.closure#1",
          );
          return _random.nextInt(256);
        }),
      ).replaceAll('=', '');
    });
    _mounts[key] = cache;
    return Uri(
      scheme: 'http',
      host: '127.0.0.1',
      port: _server.port,
      path: '/$_token/$key',
    );
  }

  Future<void> unmount(AudioCache cache) async {
    AppLog.instance.trace("lib/services/audio_cache.dart::AudioProxy.unmount");

    final key = _keys.remove(cache);
    if (key != null) _mounts.remove(key);
  }

  Future<void> _serve(HttpRequest request) {
    AppLog.instance.trace("lib/services/audio_cache.dart::AudioProxy._serve");
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/services/audio_cache.dart::AudioProxy._serve.closure#1",
      );

      final response = request.response;
      final diagnostic =
          HttpLogAttempt(
              account: 'local AudioProxy',
              method: request.method,
              url: request.requestedUri.toString(),
            )
            ..requestHeaderAvailability = '本机 AudioProxy 入站请求头'
            ..responseIsBinary = true
            ..responseByteCount = 0;
      request.headers.forEach((name, values) {
        AppLog.instance.trace(
          "lib/services/audio_cache.dart::AudioProxy._serve.closure#1.closure#1",
        );

        diagnostic.requestHeaders[name] = List<String>.of(values);
      });
      diagnostic.started();
      Object? failure;
      StackTrace? failureStack;
      AudioCache? source;
      try {
        final segments = request.uri.pathSegments;
        final cache =
            segments.length == 2 &&
                segments[0] == _token &&
                !request.uri.hasQuery
            ? _mounts[segments[1]]
            : null;
        source = cache;
        if (cache == null || request.headers.value('origin') != null) {
          response.statusCode = HttpStatus.notFound;
          await response.close();
          return;
        }
        if (request.method != 'GET' && request.method != 'HEAD') {
          response.statusCode = HttpStatus.methodNotAllowed;
          response.headers.set(HttpHeaders.allowHeader, 'HEAD, GET');
          await response.close();
          return;
        }
        // First bytes both validate audio and establish any upstream range metadata.
        final firstByte = StreamIterator(cache.stream(0, 1));
        try {
          final available = await Future.any<bool>([
            firstByte.moveNext(),
            response.done.then((_) {
              AppLog.instance.trace(
                "lib/services/audio_cache.dart::AudioProxy._serve.closure#1.closure#2",
              );
              return false;
            }),
          ]);
          if (!available) {
            diagnostic.cancelled('Local reader disconnected');
            return;
          }
        } finally {
          await firstByte.cancel();
        }
        final size = cache.length;
        final range = request.headers.value(HttpHeaders.rangeHeader);
        var start = 0;
        int? end = size;
        if (range != null) {
          final match = RegExp(r'^bytes=([0-9]*)-([0-9]*)$').firstMatch(range);
          if (match == null || (match[1]!.isEmpty && match[2]!.isEmpty)) {
            await _rangeError(response, size);
            return;
          }
          final first = match[1]!.isEmpty ? null : int.tryParse(match[1]!);
          final last = match[2]!.isEmpty ? null : int.tryParse(match[2]!);
          if ((match[1]!.isNotEmpty && first == null) ||
              (match[2]!.isNotEmpty && last == null) ||
              (first != null && last != null && last < first) ||
              (first == null && (last == null || last <= 0)) ||
              (size != null && first != null && first >= size)) {
            await _rangeError(response, size);
            return;
          }
          if (size == null) {
            // Unknown-length audio ignores valid Range and sends the complete
            // representation as chunked 200, rather than inventing a range end.
            start = 0;
            end = null;
          } else {
            start = first ?? max(0, size - last!);
            end = first == null || last == null
                ? size
                : min(last, size - 1) + 1;
            response.statusCode = HttpStatus.partialContent;
            response.headers.set(
              HttpHeaders.contentRangeHeader,
              'bytes $start-${end - 1}/$size',
            );
          }
        }
        response.headers.set(
          HttpHeaders.contentTypeHeader,
          switch (cache.sourceFormat) {
            'mp3' => 'audio/mpeg',
            'm4a' => 'audio/mp4',
            'flac' => 'audio/flac',
            'ogg' => 'audio/ogg',
            'wav' => 'audio/wav',
            'aac' => 'audio/aac',
            _ => 'application/octet-stream',
          },
        );
        response.headers.set(
          HttpHeaders.acceptRangesHeader,
          size != null ? 'bytes' : 'none',
        );
        response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
        response.headers.set('X-Content-Type-Options', 'nosniff');
        if (end != null) response.contentLength = end - start;
        if (request.method == 'HEAD') {
          await response.close();
          return;
        }
        response.bufferOutput = false;
        await _pipe(response, cache.stream(start, end), diagnostic);
        await response.close();
      } catch (error, stack) {
        if (_closed ||
            source?._paused == true ||
            source?._closed == true ||
            (error is XmlyException &&
                (error.code == 'cache_paused' ||
                    error.code == 'cache_closed'))) {
          diagnostic.cancelled(error);
        } else {
          failure = error;
          failureStack = stack;
        }
        try {
          response.statusCode = HttpStatus.badGateway;
          response.contentLength = 0;
          await response.close();
        } catch (cleanupError, cleanupStack) {
          AppLog.instance.write(
            AppLogLevel.warning,
            'audio_proxy',
            'Audio proxy response cleanup failed',
            error: cleanupError,
            stackTrace: cleanupStack,
          );
          try {
            // Once headers are sent, neither statusCode nor detachSocket is
            // legal. A deadline aborts this response's connection even then.
            response.deadline = Duration.zero;
            await response.done;
          } catch (cleanupError, cleanupStack) {
            AppLog.instance.write(
              AppLogLevel.warning,
              'audio_proxy',
              'Audio proxy connection cleanup failed',
              error: cleanupError,
              stackTrace: cleanupStack,
            );
            /* Aborted or already disconnected. */
          }
        }
      } finally {
        diagnostic.status = response.statusCode;
        response.headers.forEach((name, values) {
          AppLog.instance.trace(
            "lib/services/audio_cache.dart::AudioProxy._serve.closure#1.closure#3",
          );

          diagnostic.responseHeaders[name] = List<String>.of(values);
        });
        if (failure != null && !AppLog.instance.errorWasRecorded(failure)) {
          await diagnostic.fail(failure, failureStack!);
        } else {
          diagnostic.completeness = '本机 AudioProxy 响应已结束';
          diagnostic.succeeded();
        }
      }
    });
  }

  Future<void> _pipe(
    HttpResponse response,
    Stream<List<int>> bytes,
    HttpLogAttempt diagnostic,
  ) async {
    AppLog.instance.trace("lib/services/audio_cache.dart::AudioProxy._pipe");

    final done = Completer<void>();
    late StreamSubscription<List<int>> subscription;
    void finish([Object? error, StackTrace? stack]) {
      AppLog.instance.trace(
        "lib/services/audio_cache.dart::AudioProxy._pipe.finish",
      );

      if (done.isCompleted) return;
      if (error == null) {
        done.complete();
      } else {
        done.completeError(error, stack);
      }
    }

    subscription = bytes.listen(
      (chunk) {
        AppLog.instance.trace(
          "lib/services/audio_cache.dart::AudioProxy._pipe.closure#1",
        );

        subscription.pause();
        try {
          response.add(chunk);
          diagnostic.responseByteCount =
              (diagnostic.responseByteCount ?? 0) + chunk.length;
          response.flush().then(
            (_) {
              AppLog.instance.trace(
                "lib/services/audio_cache.dart::AudioProxy._pipe.closure#1.closure#1",
              );

              if (!done.isCompleted) subscription.resume();
            },
            onError: (Object error, StackTrace stack) {
              AppLog.instance.trace(
                "lib/services/audio_cache.dart::AudioProxy._pipe.closure#1.closure#2",
              );

              finish(error, stack);
            },
          );
        } catch (error, stack) {
          finish(error, stack);
        }
      },
      onError: (Object error, StackTrace stack) {
        AppLog.instance.trace(
          "lib/services/audio_cache.dart::AudioProxy._pipe.closure#2",
        );

        finish(error, stack);
      },
      onDone: finish,
    );
    // Socket teardown stops this reader even while it is waiting for a missing
    // block; no cancellation reaches the cache's separately-owned producer.
    response.done.then(
      (_) {
        AppLog.instance.trace(
          "lib/services/audio_cache.dart::AudioProxy._pipe.closure#3",
        );

        if (!done.isCompleted) {
          diagnostic.cancelled('Local reader disconnected');
        }
        finish();
      },
      onError: (Object error, StackTrace stack) {
        AppLog.instance.trace(
          "lib/services/audio_cache.dart::AudioProxy._pipe.closure#4",
        );

        finish(error, stack);
      },
    );
    try {
      await done.future;
    } finally {
      await subscription.cancel();
    }
  }

  Future<void> _rangeError(HttpResponse response, int? size) async {
    AppLog.instance.trace(
      "lib/services/audio_cache.dart::AudioProxy._rangeError",
    );

    response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
    response.headers.set(
      HttpHeaders.contentRangeHeader,
      'bytes */${size ?? '*'}',
    );
    await response.close();
  }

  Future<void> close() async {
    AppLog.instance.trace("lib/services/audio_cache.dart::AudioProxy.close");

    _closed = true;
    _mounts.clear();
    _keys.clear();
    await _server.close(force: true);
  }
}
