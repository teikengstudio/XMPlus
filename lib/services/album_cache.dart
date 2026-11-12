import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:synchronized/synchronized.dart';
import 'package:uuid/uuid.dart';

import '../api/xmly_client.dart';
import '../models/xmly_models.dart';
import 'app_log.dart';
import 'http_log_attempt.dart';
import 'network_retry.dart';

/// Public catalogue observations only; never playback or download authority.
class CachedAlbum {
  CachedAlbum({
    required this.album,
    required List<Track> tracks,
    this.coverPath,
  }) : tracks = List.unmodifiable(tracks) {
    AppLog.instance.trace("lib/services/album_cache.dart::CachedAlbum.new");
  }

  final Album album;
  final List<Track> tracks;
  final String? coverPath;
}

class AlbumCache extends ChangeNotifier {
  AlbumCache(String directory)
    : directory = p.normalize(p.absolute(directory)) {
    AppLog.instance.trace("lib/services/album_cache.dart::AlbumCache.new");
  }

  static const _maxMetadataBytes = 8 * 1024 * 1024;
  static const _maxCoverBytes = 5 * 1024 * 1024;
  final String directory;
  final Lock _disk = Lock();
  final Map<String, CachedAlbum> _albums = {};
  final Map<String, int> _revisions = {};
  final Map<String, Future<void>> _refreshes = {};
  final Map<String, Uri?> _coverUrls = {};
  final Set<Future<void>> _pending = {};
  bool _loaded = false, _closing = false;
  Future<void>? _closeFuture;
  final _closed = Completer<void>();

  CachedAlbum? operator [](String albumId) {
    AppLog.instance.trace(
      "lib/services/album_cache.dart::AlbumCache.operator[]",
    );
    return _albums[xmlyIdentifier(albumId)];
  }

  Future<void> _track(Future<void> future) {
    AppLog.instance.trace("lib/services/album_cache.dart::AlbumCache._track");

    _pending.add(future);
    future.then<void>(
      (_) {
        AppLog.instance.trace(
          "lib/services/album_cache.dart::AlbumCache._track.closure#1",
        );

        _pending.remove(future);
      },
      onError: (Object error, StackTrace stack) {
        AppLog.instance.trace(
          "lib/services/album_cache.dart::AlbumCache._track.closure#2",
        );

        _pending.remove(future);
      },
    );
    return future;
  }

  void _checkOpen() {
    AppLog.instance.trace(
      "lib/services/album_cache.dart::AlbumCache._checkOpen",
    );

    if (_closing) throw StateError('Album cache is closed');
  }

  Future<void> load() {
    AppLog.instance.trace("lib/services/album_cache.dart::AlbumCache.load");

    _checkOpen();
    return _track(
      _disk.synchronized(() async {
        AppLog.instance.trace(
          "lib/services/album_cache.dart::AlbumCache.load.closure#1",
        );

        if (_loaded) return;
        // AppStorage owns the containing directory's exclusive lifetime lock.
        try {
          final root = await Directory(directory).create(recursive: true);
          if (await FileSystemEntity.type(root.path, followLinks: false) !=
              FileSystemEntityType.directory) {
            throw const FileSystemException('Invalid album cache directory');
          }
          await for (final entry in root.list(followLinks: false)) {
            if (entry is! Directory ||
                !RegExp(r'^[1-9][0-9]{0,18}$')
                    .hasMatch(p.basename(entry.path))) {
              continue;
            }
            final id = p.basename(entry.path);
            CachedAlbum? latest;
            var revision = 0;
            String? fallbackCover;
            for (var slot = 0; slot < 2; slot++) {
              try {
                final file = File(p.join(entry.path, 'index.$slot.json'));
                if (!await file.exists() ||
                    await file.length() > _maxMetadataBytes)
                  continue;
                final value = jsonDecode(await file.readAsString());
                if (value is! Map<String, dynamic> ||
                    value['version'] != 1 ||
                    value['revision'] is! int ||
                    (value['revision'] as int) < 1 ||
                    value['album'] is! Map<String, dynamic> ||
                    value['tracks'] is! List)
                  throw const FormatException();
                final album = _album(
                  Map<String, dynamic>.from(value['album'] as Map),
                );
                if (album.id != id) throw const FormatException();
                final tracks = <String, Track>{};
                for (final raw in value['tracks'] as List) {
                  if (raw is! Map<String, dynamic>)
                    throw const FormatException();
                  final track = _trackMetadata(raw, album);
                  if (tracks.containsKey(track.id))
                    throw const FormatException();
                  tracks[track.id] = track;
                }
                final cover = await _localCover(entry.path, value['cover']);
                fallbackCover ??= cover;
                final currentRevision = value['revision'] as int;
                if (currentRevision > revision) {
                  revision = currentRevision;
                  latest = CachedAlbum(
                    album: album,
                    tracks: _ordered(tracks.values),
                    coverPath: cover,
                  );
                }
              } on FileSystemException catch (error, stack) {
                AppLog.instance.write(
                  AppLogLevel.warning,
                  'album_cache',
                  'Album cache slot unavailable',
                  error: error,
                  stackTrace: stack,
                );
                continue;
              } on FormatException catch (error, stack) {
                AppLog.instance.write(
                  AppLogLevel.warning,
                  'album_cache',
                  'Album cache slot invalid',
                  error: error,
                  stackTrace: stack,
                );
                continue;
              } on XmlyException catch (error, stack) {
                AppLog.instance.write(
                  AppLogLevel.warning,
                  'album_cache',
                  'Album cache metadata invalid',
                  error: error,
                  stackTrace: stack,
                );
                continue;
              } on TypeError catch (error, stack) {
                AppLog.instance.write(
                  AppLogLevel.warning,
                  'album_cache',
                  'Album cache metadata invalid',
                  error: error,
                  stackTrace: stack,
                );
                continue;
              }
            }
            if (latest != null) {
              _albums[id] = CachedAlbum(
                album: latest.album,
                tracks: latest.tracks,
                coverPath: latest.coverPath ?? fallbackCover,
              );
              _revisions[id] = revision;
            }
          }
        } on FileSystemException catch (error, stack) {
          AppLog.instance.write(
            AppLogLevel.warning,
            'album_cache',
            'Album cache load failed',
            error: error,
            stackTrace: stack,
          );
          // Optional public cache cannot prevent the application from opening.
        }
        _loaded = true;
        if (_albums.isNotEmpty) notifyListeners();
      }),
    );
  }

  Future<void> remember(AlbumPage page) {
    AppLog.instance.trace("lib/services/album_cache.dart::AlbumCache.remember");

    _checkOpen();
    return _track(_remember(page));
  }

  Future<void> refresh(String albumId, XmlyClient client) {
    AppLog.instance.trace("lib/services/album_cache.dart::AlbumCache.refresh");

    _checkOpen();
    final id = xmlyIdentifier(albumId);
    final existing = _refreshes[id];
    if (existing != null) return existing;
    final future = _track(
      AppLog.instance.runWithErrorScope(() async {
        AppLog.instance.trace(
          "lib/services/album_cache.dart::AlbumCache.refresh.closure#1",
        );

        late final AlbumPage page;
        try {
          page = await client.album(id, ascending: true);
          if (page.album.id != id)
            throw const FormatException('Album mismatch');
        } catch (error, stack) {
          if (!AppLog.instance.errorWasRecorded(error)) {
            AppLog.instance.write(
              AppLogLevel.warning,
              'album_cache',
              'Album cache refresh failed',
              error: error,
              stackTrace: stack,
            );
          }
          rethrow;
        }
        await _remember(page);
      }),
    );
    _refreshes[id] = future;
    future.then<void>(
      (_) {
        AppLog.instance.trace(
          "lib/services/album_cache.dart::AlbumCache.refresh.closure#2",
        );

        _refreshes.remove(id);
      },
      onError: (Object error, StackTrace stack) {
        AppLog.instance.trace(
          "lib/services/album_cache.dart::AlbumCache.refresh.closure#3",
        );

        _refreshes.remove(id);
      },
    );
    return future;
  }

  Future<void> _remember(AlbumPage page) {
    AppLog.instance.trace(
      "lib/services/album_cache.dart::AlbumCache._remember",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/services/album_cache.dart::AlbumCache._remember.closure#1",
      );

      try {
        if (page.total < 0 ||
            page.album.total != page.total ||
            page.page < 1 ||
            page.pageSize < 1 ||
            page.pageSize > xmlyAlbumPageSize ||
            page.tracks.length > page.pageSize)
          throw const FormatException('Invalid album page');
        final album = _album(page.album.toJson());
        final observed = <Track>[
          for (final track in page.tracks)
            _trackMetadata(track.toJson(), album),
        ];
        var coverUri = page.album.coverUrl;
        for (final track in page.tracks) {
          coverUri ??= track.coverUrl;
          if (coverUri != null) break;
        }
        await _disk.synchronized(() async {
          AppLog.instance.trace(
            "lib/services/album_cache.dart::AlbumCache._remember.closure#1.closure#1",
          );

          final folder = await Directory(p.join(directory, album.id))
              .create(recursive: true);
          if (await FileSystemEntity.type(directory, followLinks: false) !=
                  FileSystemEntityType.directory ||
              await FileSystemEntity.type(folder.path, followLinks: false) !=
                  FileSystemEntityType.directory) {
            throw const FileSystemException('Invalid album cache directory');
          }
          final previous = _albums[album.id];
          final previousAlbum = previous?.album;
          final mergedAlbum = Album(
            id: album.id,
            title: album.title.isEmpty
                ? previousAlbum?.title ?? ''
                : album.title,
            artist: album.artist.isEmpty
                ? previousAlbum?.artist ?? ''
                : album.artist,
            intro: album.intro.isEmpty
                ? previousAlbum?.intro ?? ''
                : album.intro,
            coverUrl: album.coverUrl ?? previousAlbum?.coverUrl,
            total: album.total,
          );
          // A complete observation replaces the catalogue. Partial observations
          // replace only their known positions, in either display order; keep the
          // remaining cached pages, but retire positions beyond the new total.
          final complete = observed.length == page.total;
          final positions = observed
              .map((track) {
                AppLog.instance.trace(
                  "lib/services/album_cache.dart::AlbumCache._remember.closure#1.closure#1.closure#1",
                );
                return track.officialPosition;
              })
              .whereType<int>()
              .toSet();
          final tracks = <String, Track>{
            if (!complete)
              for (final track in previous?.tracks ?? const <Track>[])
                if (track.officialPosition == null ||
                    (track.officialPosition! <= page.total &&
                        !positions.contains(track.officialPosition)))
                  track.id: _trackMetadata(track.toJson(), mergedAlbum),
          };
          for (final track in observed) {
            final oldPosition = tracks[track.id]?.officialPosition;
            tracks[track.id] =
                track.officialPosition == null && oldPosition != null
                ? Track.fromJson({
                    ...track.toJson(),
                    'raw': {...track.raw, 'officialPosition': oldPosition},
                  })
                : track;
          }
          final next = CachedAlbum(
            album: mergedAlbum,
            tracks: _ordered(tracks.values),
            coverPath: previous?.coverPath,
          );
          await _saveAlbum(folder, next);
          _coverUrls[album.id] = coverUri;
        });
        if (coverUri != null && !_closing) {
          unawaited(_track(_rememberCover(album.id, coverUri)));
        }
      } catch (error, stack) {
        if (!AppLog.instance.errorWasRecorded(error)) {
          AppLog.instance.write(
            AppLogLevel.warning,
            'album_cache',
            'Album cache write failed',
            error: error,
            stackTrace: stack,
          );
        }
        rethrow;
      }
    });
  }

  Future<void> _rememberCover(String albumId, Uri uri) {
    AppLog.instance.trace(
      "lib/services/album_cache.dart::AlbumCache._rememberCover",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/services/album_cache.dart::AlbumCache._rememberCover.closure#1",
      );

      try {
        final bytes = await _fetchCover(uri);
        await _disk.synchronized(() async {
          AppLog.instance.trace(
            "lib/services/album_cache.dart::AlbumCache._rememberCover.closure#1.closure#1",
          );

          if (_closing || _coverUrls[albumId] != uri) return;
          final current = _albums[albumId];
          if (current == null) return;
          final folder = Directory(p.join(directory, albumId));
          if (await FileSystemEntity.type(directory, followLinks: false) !=
                  FileSystemEntityType.directory ||
              await FileSystemEntity.type(folder.path, followLinks: false) !=
                  FileSystemEntityType.directory) {
            throw const FileSystemException('Invalid album cache directory');
          }
          final digest = sha256.convert(bytes).toString();
          final target = File(p.join(folder.path, '$digest.cover'));
          if (await FileSystemEntity.type(target.path, followLinks: false) !=
                  FileSystemEntityType.file ||
              (await sha256.bind(target.openRead()).single).toString() !=
                  digest) {
            await _commit(target, bytes);
          }
          // Use the newest metadata; late artwork must not restore an old page.
          await _saveAlbum(
            folder,
            CachedAlbum(
              album: current.album,
              tracks: current.tracks,
              coverPath: target.path,
            ),
          );
        });
      } catch (error, stack) {
        if (!AppLog.instance.errorWasRecorded(error) && !_closing) {
          AppLog.instance.write(
            AppLogLevel.warning,
            'album_cache',
            'Album artwork cache failed',
            error: error,
            stackTrace: stack,
          );
        }
        // Optional artwork never replaces a usable catalogue or local cover.
      }
    });
  }

  // Called only while holding _disk, for metadata and artwork commits alike.
  Future<void> _saveAlbum(Directory folder, CachedAlbum next) async {
    AppLog.instance.trace(
      "lib/services/album_cache.dart::AlbumCache._saveAlbum",
    );

    final albumId = next.album.id;
    final revision = (_revisions[albumId] ?? 0) + 1;
    final coverPath = next.coverPath;
    final bytes = utf8.encode(
      jsonEncode({
        'version': 1,
        'revision': revision,
        'album': next.album.toJson(),
        'tracks': next.tracks.map((track) {
          AppLog.instance.trace(
            "lib/services/album_cache.dart::AlbumCache._saveAlbum.closure#1",
          );

          final value = track.toJson()..remove('is_authorized');
          return value;
        }).toList(),
        'cover': coverPath == null ? null : p.basename(coverPath),
      }),
    );
    if (bytes.length > _maxMetadataBytes)
      throw const FormatException('Album cache too large');
    // Two generations preserve the previous commit even on Windows.
    await _commit(
      File(p.join(folder.path, 'index.${revision % 2}.json')),
      bytes,
    );
    _albums[albumId] = next;
    _revisions[albumId] = revision;
    await _removeUnusedCovers(folder);
    notifyListeners();
  }

  static Album _album(Map<String, dynamic> value) {
    AppLog.instance.trace("lib/services/album_cache.dart::AlbumCache._album");

    for (final key in ['id', 'title', 'artist', 'intro']) {
      if (value[key] is! String)
        throw const FormatException('Invalid album metadata');
    }
    if (value['total'] is! int || (value['total'] as int) < 0)
      throw const FormatException('Invalid album total');
    return Album.fromJson({
      ...value,
      'cover_url': _publicCover(value['cover_url']),
      'raw': <String, dynamic>{},
    });
  }

  static Track _trackMetadata(Map<String, dynamic> value, Album album) {
    AppLog.instance.trace(
      "lib/services/album_cache.dart::AlbumCache._trackMetadata",
    );

    for (final key in ['id', 'title', 'artist', 'album', 'album_id', 'intro']) {
      if (value[key] is! String)
        throw const FormatException('Invalid track metadata');
    }
    final duration = value['duration'];
    if (value['album_id'] != album.id ||
        duration is! num ||
        !duration.isFinite ||
        duration < 0 ||
        (value['is_paid'] != null && value['is_paid'] is! bool))
      throw const FormatException('Invalid track metadata');
    for (final key in ['order_no', 'episode']) {
      if (value[key] != null &&
          (value[key] is! int || (value[key] as int) < 1)) {
        throw const FormatException('Invalid track order');
      }
    }
    if (value['raw'] is! Map)
      throw const FormatException('Invalid track metadata');
    final rawPosition = (value['raw'] as Map)['officialPosition'];
    if (rawPosition != null && (rawPosition is! int || rawPosition < 1)) {
      throw const FormatException('Invalid official position');
    }
    final position = xmlyPositive(xmlyMap(value['raw'])['officialPosition']);
    return Track.fromJson({
      ...value,
      'cover_url': _publicCover(value['cover_url']),
      'is_authorized': null,
      'raw': {
        if (position != null) 'officialPosition': position,
        if (album.total > 0) 'totalCount': album.total,
      },
    });
  }

  static String? _publicCover(Object? value) {
    AppLog.instance.trace(
      "lib/services/album_cache.dart::AlbumCache._publicCover",
    );

    if (value is! String || value.length > 16384) return null;
    final uri = Uri.tryParse(value);
    // Do not retain signed URLs or session parameters in public metadata.
    if (uri == null ||
        !const {'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.hasPort && uri.port != 80 && uri.port != 443))
      return null;
    return uri.toString();
  }

  static List<Track> _ordered(Iterable<Track> tracks) {
    AppLog.instance.trace("lib/services/album_cache.dart::AlbumCache._ordered");
    return tracks.toList()..sort((a, b) {
      AppLog.instance.trace(
        "lib/services/album_cache.dart::AlbumCache._ordered.closure#1",
      );

      final left = a.officialPosition ?? a.orderNo;
      final right = b.officialPosition ?? b.orderNo;
      if (left != right) {
        if (left == null) return 1;
        if (right == null) return -1;
        return left.compareTo(right);
      }
      final aId = a.number, bId = b.number;
      return aId.length == bId.length
          ? aId.compareTo(bId)
          : aId.length.compareTo(bId.length);
    });
  }

  static Future<void> _commit(File target, List<int> bytes) async {
    AppLog.instance.trace("lib/services/album_cache.dart::AlbumCache._commit");

    final temporary = File('${target.path}.${const Uuid().v4()}.tmp');
    try {
      await temporary.writeAsBytes(bytes, flush: true);
      if (await target.exists()) await target.delete();
      await temporary.rename(target.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  static Future<String?> _localCover(String directory, Object? name) async {
    AppLog.instance.trace(
      "lib/services/album_cache.dart::AlbumCache._localCover",
    );

    if (name == null) return null;
    if (name is! String || !RegExp(r'^[a-f0-9]{64}\.cover$').hasMatch(name))
      throw const FormatException('Invalid cover path');
    final file = File(p.join(directory, name));
    try {
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
              FileSystemEntityType.file ||
          await file.length() > _maxCoverBytes)
        return null;
      final bytes = await file.readAsBytes();
      if ('${sha256.convert(bytes)}.cover' != name) return null;
      await _validateImage(bytes);
      return file.path;
    } catch (error, stack) {
      AppLog.instance.write(
        AppLogLevel.warning,
        'album_cache',
        'Local album artwork unavailable',
        error: error,
        stackTrace: stack,
      );
      return null;
    }
  }

  static Future<void> _removeUnusedCovers(Directory folder) async {
    AppLog.instance.trace(
      "lib/services/album_cache.dart::AlbumCache._removeUnusedCovers",
    );

    try {
      final keep = <String>{};
      for (var slot = 0; slot < 2; slot++) {
        final index = File(p.join(folder.path, 'index.$slot.json'));
        if (!await index.exists()) continue;
        if (await index.length() > _maxMetadataBytes) return;
        final value = jsonDecode(await index.readAsString());
        if (value is! Map) return;
        if (value['cover'] is String) keep.add(value['cover'] as String);
      }
      await for (final file in folder.list(followLinks: false)) {
        if (file is File &&
            RegExp(r'^[a-f0-9]{64}\.cover$').hasMatch(p.basename(file.path)) &&
            !keep.contains(p.basename(file.path)))
          await file.delete();
      }
    } catch (error, stack) {
      AppLog.instance.write(
        AppLogLevel.warning,
        'album_cache',
        'Album artwork cleanup failed',
        error: error,
        stackTrace: stack,
      );
      // Cache cleanup is optional, and must not turn a commit into a failure.
    }
  }

  static Future<void> _validateImage(Uint8List bytes) async {
    AppLog.instance.trace(
      "lib/services/album_cache.dart::AlbumCache._validateImage",
    );

    final png =
        bytes.length >= 8 &&
        const [137, 80, 78, 71, 13, 10, 26, 10].asMap().entries.every((entry) {
          AppLog.instance.trace(
            "lib/services/album_cache.dart::AlbumCache._validateImage.closure#1",
          );
          return bytes[entry.key] == entry.value;
        });
    final jpeg =
        bytes.length >= 3 &&
        bytes[0] == 255 &&
        bytes[1] == 216 &&
        bytes[2] == 255;
    if (!png && !jpeg) throw const FormatException('Invalid cover image');
    final codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: 512,
      allowUpscaling: false,
    );
    try {
      final frame = await codec.getNextFrame();
      frame.image.dispose();
    } finally {
      codec.dispose();
    }
  }

  Future<Uint8List> _fetchCover(Uri initial) {
    AppLog.instance.trace(
      "lib/services/album_cache.dart::AlbumCache._fetchCover",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/services/album_cache.dart::AlbumCache._fetchCover.closure#1",
      );

      for (var attempt = 0; ; attempt++) {
        _checkOpen();
        // Isolated from XmlyClient: no cookies, identity or auth headers.
        final client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 10);
        client.findProxy = (_) {
          AppLog.instance.trace(
            "lib/services/album_cache.dart::AlbumCache._fetchCover.closure#1.closure#1",
          );
          return 'DIRECT';
        };
        client.connectionFactory = (uri, proxyHost, proxyPort) async {
          AppLog.instance.trace(
            "lib/services/album_cache.dart::AlbumCache._fetchCover.closure#1.closure#2",
          );

          final addresses = await _safeCoverUri(uri);
          return uri.scheme == 'https'
              ? SecureSocket.startConnect(addresses.first, uri.port)
              : Socket.startConnect(addresses.first, uri.port);
        };
        // Redirects share a 30-second budget; each retry gets a fresh budget.
        final deadline = DateTime.now().add(const Duration(seconds: 30));
        Future<T> wait<T>(Future<T> future) {
          AppLog.instance.trace(
            "lib/services/album_cache.dart::AlbumCache._fetchCover.closure#1.wait",
          );

          _checkOpen();
          final left = deadline.difference(DateTime.now());
          if (left <= Duration.zero) throw TimeoutException('Cover timeout');
          return Future.any<T>([
            future.timeout(left),
            _closed.future.then<T>((_) {
              AppLog.instance.trace(
                "lib/services/album_cache.dart::AlbumCache._fetchCover.closure#1.wait.closure#1",
              );
              return throw StateError('Album cache is closed');
            }),
          ]);
        }

        HttpLogAttempt? diagnostic;
        HttpClientResponse? response;
        var definitive = false;
        Duration? delay;
        try {
          var uri = initial;
          for (var redirects = 0; redirects <= 5; redirects++) {
            response = null;
            diagnostic = null;
            final bytes = BytesBuilder(copy: false);
            diagnostic =
                HttpLogAttempt(
                    account: '公共专辑封面（无账号）',
                    method: 'GET',
                    url: '$uri',
                  )
                  ..responseBytes = bytes.toBytes
                  ..responseIsBinary = true
                  ..started();
            await wait(_safeCoverUri(uri));
            response = null;
            final request = await wait(client.getUrl(uri));
            request.followRedirects = false;
            request.headers.forEach((name, values) {
              AppLog.instance.trace(
                "lib/services/album_cache.dart::AlbumCache._fetchCover.closure#1.closure#3",
              );

              diagnostic!.requestHeaders[name] = List<String>.of(values);
            });
            final current = await wait(request.close());
            response = current;
            diagnostic
              ..status = current.statusCode
              ..completeness = '响应体接收中；失败时保留全部已接收字节';
            current.headers.forEach((name, values) {
              AppLog.instance.trace(
                "lib/services/album_cache.dart::AlbumCache._fetchCover.closure#1.closure#4",
              );

              diagnostic!.responseHeaders[name] = List<String>.of(values);
            });
            final redirect = const {
              301,
              302,
              303,
              307,
              308,
            }.contains(current.statusCode);
            final location = current.headers.value(HttpHeaders.locationHeader);
            if (redirect && location != null && redirects < 5) {
              await current.listen((_) {
                AppLog.instance.trace(
                  "lib/services/album_cache.dart::AlbumCache._fetchCover.closure#1.closure#5",
                );
              }).cancel();
              diagnostic
                ..completeness = '未读取响应体：跟随重定向'
                ..responseByteCount = 0
                ..succeeded();
              uri = uri.resolve(location);
              continue;
            }
            if (current.contentLength > _maxCoverBytes) {
              definitive = true;
              diagnostic.completeness = '未读取响应体：Content-Length 超过 5 MiB 安全上限';
              throw const HttpException('Cover too large');
            }
            final iterator = StreamIterator(current);
            try {
              while (await wait(iterator.moveNext())) {
                final room = _maxCoverBytes - bytes.length;
                if (iterator.current.length > room) {
                  bytes.add(iterator.current.sublist(0, room));
                  definitive = true;
                  diagnostic.completeness = '响应体超过 5 MiB 安全上限；已捕获上限内全部字节';
                  throw const HttpException('Cover too large');
                }
                bytes.add(iterator.current);
              }
            } finally {
              await iterator.cancel();
            }
            diagnostic.completeness = '完整响应体';
            if (redirect || current.statusCode != 200) {
              definitive = redirect || !retryableStatus(current.statusCode);
              throw HttpException(
                'Invalid cover response: HTTP ${current.statusCode}',
              );
            }
            final image = bytes.toBytes();
            definitive = true;
            await wait(_validateImage(image));
            diagnostic
              ..responseByteCount = image.length
              ..succeeded();
            return image;
          }
          throw const FormatException('Cover redirect limit');
        } catch (error, stack) {
          if (_closing &&
              error is StateError &&
              error.message == 'Album cache is closed') {
            diagnostic?.cancelled(error);
          } else {
            if (retryableTransport(error))
              diagnostic?.transportError = '$error';
            await diagnostic?.fail(error, stack);
          }
          if (_closing ||
              definitive ||
              attempt == 4 ||
              error is FormatException ||
              error is TlsException ||
              !(retryableStatus(response?.statusCode) ||
                  retryableTransport(error)))
            rethrow;
          delay = retryDelay(
            attempt,
            response?.headers.value(HttpHeaders.retryAfterHeader),
          );
        } finally {
          client.close(force: true);
        }
        await waitToRetry(delay, closed: _closed.future);
      }
    });
  }

  // Same public-address and DNS-pinning policy as MediaProcessor cover fetches.
  static Future<List<InternetAddress>> _safeCoverUri(Uri uri) async {
    AppLog.instance.trace(
      "lib/services/album_cache.dart::AlbumCache._safeCoverUri",
    );

    if (!const {'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        (uri.hasPort && uri.port != 80 && uri.port != 443) ||
        uri.toString().length > 16384)
      throw const FormatException('Invalid cover URL');
    final addresses = await InternetAddress.lookup(uri.host)
        .timeout(const Duration(seconds: 10));
    if (addresses.isEmpty ||
        addresses.any((address) {
          AppLog.instance.trace(
            "lib/services/album_cache.dart::AlbumCache._safeCoverUri.closure#1",
          );

          final bytes = address.rawAddress;
          if (address.type == InternetAddressType.IPv4) {
            return bytes[0] == 0 ||
                bytes[0] == 10 ||
                bytes[0] == 127 ||
                bytes[0] >= 224 ||
                (bytes[0] == 169 && bytes[1] == 254) ||
                (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
                (bytes[0] == 192 &&
                    (bytes[1] == 168 ||
                        (bytes[1] == 0 && (bytes[2] == 0 || bytes[2] == 2)))) ||
                (bytes[0] == 198 &&
                    (bytes[1] == 18 ||
                        bytes[1] == 19 ||
                        (bytes[1] == 51 && bytes[2] == 100))) ||
                (bytes[0] == 203 && bytes[1] == 0 && bytes[2] == 113) ||
                (bytes[0] == 100 && bytes[1] >= 64 && bytes[1] <= 127);
          }
          return (bytes[0] & 0xe0) != 0x20;
        }))
      throw const FormatException('Non-public cover URL');
    return addresses;
  }

  Future<void> close() {
    AppLog.instance.trace("lib/services/album_cache.dart::AlbumCache.close");
    return _closeFuture ??= () async {
      AppLog.instance.trace(
        "lib/services/album_cache.dart::AlbumCache.close.closure#1",
      );

      _closing = true;
      _closed.complete();
      await Future.wait(
        _pending.toList().map((future) {
          AppLog.instance.trace(
            "lib/services/album_cache.dart::AlbumCache.close.closure#1.closure#1",
          );
          return future.then<void>(
            (_) {
              AppLog.instance.trace(
                "lib/services/album_cache.dart::AlbumCache.close.closure#1.closure#1.closure#1",
              );
            },
            onError: (Object error, StackTrace stack) {
              AppLog.instance.trace(
                "lib/services/album_cache.dart::AlbumCache.close.closure#1.closure#1.closure#2",
              );
            },
          );
        }),
      );
      dispose();
    }();
  }
}
