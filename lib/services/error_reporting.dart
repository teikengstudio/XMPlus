import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import 'app_log.dart';

// Deliberately excluded from method tracing: telemetry must not trace itself.
enum ErrorReportingStatus { unconfigured, initializing, active, failed }

abstract final class ErrorReporting {
  static final _status = ValueNotifier(ErrorReportingStatus.unconfigured);
  static ValueListenable<ErrorReportingStatus> get status => _status;
}

const _dsn = String.fromEnvironment('SENTRY_DSN');
const _environment = String.fromEnvironment(
  'SENTRY_ENVIRONMENT',
  defaultValue: kReleaseMode ? 'production' : 'development',
);
const _diagnosticBytes = 64 * 1024;
final _globalErrorKey = Object();
bool _insideTelemetry = false;
Future<void>? _initialization;

/// Call after binding and AppLog initialization, in the same zone as runApp.
/// The runner owns desktop initialization and runApp(SentryWidget(...)).
Future<void> initializeErrorReporting(Future<void> Function() appRunner) =>
    _initialization ??= _initialize(appRunner);

Future<void> _initialize(Future<void> Function() appRunner) async {
  final originalFlutterHandler = FlutterError.onError;
  final originalPlatformHandler = PlatformDispatcher.instance.onError;
  _installErrorHandlers();
  if (_dsn.trim().isEmpty) {
    ErrorReporting._status.value = ErrorReportingStatus.unconfigured;
    await _runApplication(appRunner);
    return;
  }

  ErrorReporting._status.value = ErrorReportingStatus.initializing;
  var runnerStarted = false;
  try {
    final package = await PackageInfo.fromPlatform();
    await SentryFlutter.init(
      (options) {
        options
          ..dsn = _dsn
          ..environment = _environment
          ..release = 'xmplus@${package.version}+${package.buildNumber}'
          ..dist = package.buildNumber
          ..sampleRate = 1.0
          ..sendDefaultPii = true
          ..captureFailedRequests = false
          ..captureNativeFailedRequests = false
          ..traceLifecycle = SentryTraceLifecycle.static
          ..tracesSampleRate = kReleaseMode ? 0.1 : 1.0
          ..maxBreadcrumbs = 100
          // SDK10 deduplicates by error.hashCode across invocations. Physical
          // attempts and AppLog invocation scopes already own deduplication.
          ..enableDeduplication = false
          ..reportSilentFlutterErrors = false
          ..attachScreenshot = false
          ..attachViewHierarchy = false
          ..beforeBreadcrumb = _beforeBreadcrumb
          ..beforeSend = _beforeSend
          ..beforeSendTransaction = _beforeSendTransaction
          ..beforeSendLog = _beforeSendLog;
        options.replay
          ..sessionSampleRate = Platform.isAndroid ? 0.1 : 0.0
          ..onErrorSampleRate = Platform.isAndroid ? 1.0 : 0.0;
        // Leave SDK default visual privacy masks unchanged.
        // Leave transport SDK-owned: on Windows it is still NoOpTransport
        // until SentryClient selects HTTP after this callback.
        // The SDK exports this diagnostic hook, but marks it internal.
        // SDK10 diagnostics are debug-only and isolate-local; they do not
        // confirm native delivery or report release-mode transport failures.
        // ignore: invalid_use_of_internal_member
        SentryInternalLogger.configure(
          isEnabled: true,
          minLevel: SentryLevel.warning,
          logOutput:
              ({
                required String name,
                required SentryLevel level,
                required String message,
                Object? error,
                StackTrace? stackTrace,
              }) {
                // Framework capture diagnostics repeat the exception being sent;
                // only operational failures belong in the local SDK warning stream.
                if (message == 'Uncaught Platform Error' ||
                    name == 'sentry_flutter' &&
                        Zone.current[_globalErrorKey] != null) {
                  return;
                }
                _localWarning(message, error: error, stackTrace: stackTrace);
              },
        );
      },
      appRunner: () async {
        runnerStarted = true;
        ErrorReporting._status.value = Sentry.isEnabled
            ? ErrorReportingStatus.active
            : ErrorReportingStatus.failed;
        AppLog.instance.sink = Sentry.isEnabled ? _record : null;
        // Chain outside the installed official integrations, not instead of
        // them. Their original Flutter/platform delegates remain intact.
        _installErrorHandlers();
        await _runApplication(appRunner);
      },
    );
  } catch (error, stackTrace) {
    if (runnerStarted) rethrow;
    AppLog.instance.sink = null;
    ErrorReporting._status.value = ErrorReportingStatus.failed;
    _localFatal('Sentry initialization failed', error, stackTrace);
    try {
      await Sentry.close();
    } catch (closeError, closeStack) {
      _localWarning(
        'Sentry shutdown failed',
        error: closeError,
        stackTrace: closeStack,
      );
    }
    // Failed integrations may have installed only some of their handlers.
    FlutterError.onError = originalFlutterHandler;
    PlatformDispatcher.instance.onError = originalPlatformHandler;
    _installErrorHandlers();
  }
  if (!runnerStarted) await _runApplication(appRunner);
}

Future<void> _runApplication(Future<void> Function() runner) async {
  ISentrySpan? transaction;
  try {
    if (ErrorReporting._status.value == ErrorReportingStatus.active) {
      transaction = Sentry.startTransaction(
        'application.startup',
        'app.startup',
      );
    }
  } catch (error, stackTrace) {
    _localWarning(
      'Sentry startup transaction could not start',
      error: error,
      stackTrace: stackTrace,
    );
  }
  try {
    await runner();
    if (transaction != null) transaction.status = const SpanStatus.ok();
  } catch (error, stackTrace) {
    if (transaction != null) {
      transaction.status = const SpanStatus.internalError();
    }
    // Main has no outer catch: the installed PlatformDispatcher integration
    // owns this unhandled occurrence. Do not manually capture it here as well.
    Error.throwWithStackTrace(error, stackTrace);
  } finally {
    // Finishing telemetry must not replace a real startup exception.
    try {
      await transaction?.finish();
    } catch (error, stackTrace) {
      _localWarning(
        'Sentry startup transaction failed',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }
}

void _installErrorHandlers() {
  final flutterDelegate = FlutterError.onError;
  final platformDelegate = PlatformDispatcher.instance.onError;
  FlutterError.onError = (details) {
    if (Zone.current[_globalErrorKey] != null) {
      flutterDelegate?.call(details);
      return;
    }
    final alreadyRecorded = AppLog.instance.errorWasRecorded(details.exception);
    final occurrence = _GlobalError(
      suppressCapture: details.silent || alreadyRecorded,
    );
    runZoned(() {
      if (!details.silent) AppLog.instance.requestUploadPrompt();
      if (!details.silent && !alreadyRecorded) {
        _localFatal(
          'Unhandled Flutter error',
          details.exception,
          details.stack,
        );
      }
      // SDK10 itself honors reportSilentFlutterErrors=false and still invokes
      // its saved framework delegate for silent details.
      flutterDelegate?.call(details);
    }, zoneValues: {_globalErrorKey: occurrence});
  };
  PlatformDispatcher.instance.onError = (error, stackTrace) {
    if (Zone.current[_globalErrorKey] != null) {
      return platformDelegate?.call(error, stackTrace) ?? false;
    }
    final recorded = AppLog.instance.errorWasRecorded(error);
    return runZoned(() {
      AppLog.instance.requestUploadPrompt();
      if (!recorded) _localFatal('Unhandled Dart error', error, stackTrace);
      return platformDelegate?.call(error, stackTrace) ?? false;
    }, zoneValues: {_globalErrorKey: _GlobalError(suppressCapture: recorded)});
  };
}

final class _GlobalError {
  _GlobalError({required this.suppressCapture});
  final bool suppressCapture;
  Map<String, Object?>? diagnostics;
}

void _localFatal(String message, Object error, StackTrace? stackTrace) {
  AppLog.instance.write(
    AppLogLevel.fatal,
    'runtime',
    message,
    error: error,
    stackTrace: stackTrace,
    promptUser: true,
  );
}

void _localWarning(String message, {Object? error, StackTrace? stackTrace}) {
  if (_insideTelemetry) return;
  // A synchronous SDK callback can run inside AppLog.write's reentry guard.
  // Write after that sink returns, without sending this warning back to SDK.
  scheduleMicrotask(() {
    if (_insideTelemetry) return;
    _insideTelemetry = true;
    try {
      AppLog.instance.write(
        AppLogLevel.warning,
        'sentry.internal',
        message,
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      _insideTelemetry = false;
    }
  });
}

Future<void> _record(AppLogRecord record) async {
  if (_insideTelemetry ||
      record.values['category'] == 'sentry.internal' ||
      record.values['category'] == 'method')
    return;
  try {
    final diagnostics = _diagnostics(record);
    if (record.level.index < AppLogLevel.error.index) {
      await Sentry.addBreadcrumb(
        Breadcrumb(
          message: record.values['message'] as String?,
          category: record.values['category'] as String?,
          level: _level(record.level),
          data: diagnostics,
          timestamp: DateTime.tryParse('${record.values['timestamp']}'),
        ),
      );
      return;
    }
    final attributes = <String, SentryAttribute>{
      for (final entry in diagnostics.entries)
        entry.key: _attribute(entry.value),
    };
    final message = record.values['message'] as String? ?? 'Application error';
    if (record.level == AppLogLevel.fatal) {
      Sentry.logger.fatal(message, attributes: attributes);
    } else {
      Sentry.logger.error(message, attributes: attributes);
    }
    final global = Zone.current[_globalErrorKey] as _GlobalError?;
    if (global != null) {
      global.diagnostics = diagnostics;
      return; // The official integration captures this occurrence once.
    }
    final error = record.error;
    final hint = Hint.withMap({'xmplus.diagnostics': diagnostics});
    if (error != null) {
      await Sentry.captureException(
        error,
        stackTrace: record.stackTrace,
        hint: hint,
        withScope: (scope) {
          scope.level = _level(record.level);
          scope.setContexts('xmplus', diagnostics);
          _setTags(scope, record);
        },
      );
    } else {
      // Some real platform failure notifications contain only a description.
      // Do not manufacture an Exception or a replacement stack for them.
      await Sentry.captureEvent(
        SentryEvent(
          message: SentryMessage(message),
          level: _level(record.level),
        ),
        hint: hint,
        withScope: (scope) {
          scope.setContexts('xmplus', diagnostics);
          _setTags(scope, record);
        },
      );
    }
  } catch (error, stackTrace) {
    _localWarning(
      'Sentry capture failed',
      error: error,
      stackTrace: stackTrace,
    );
  }
}

void _setTags(Scope scope, AppLogRecord record) {
  scope.setTag('platform', Platform.operatingSystem);
  final session = record.values['sessionId'];
  if (session != null) scope.setTag('sessionId', '$session');
  if (record.requestId != null) scope.setTag('requestId', record.requestId!);
  if (record.errorScopeId != null) {
    scope.setTag('errorScopeId', '${record.errorScopeId}');
  }
}

Map<String, Object?> _diagnostics(AppLogRecord record) {
  final data = record.values['data'];
  final fields = data is Map
      ? Map<String, Object?>.from(data)
      : const <String, Object?>{};
  return _bounded({
    // Insertion order determines priority under the shared 64 KiB budget.
    'sessionId': record.values['sessionId'],
    if (record.requestId != null) 'requestId': record.requestId,
    if (record.errorScopeId != null) 'errorScopeId': record.errorScopeId,
    for (final key in const ['method', 'url', 'status'])
      if (fields.containsKey(key)) key: fields[key],
    if (record.values['error'] != null) 'error': record.values['error'],
    if (record.values['stackTrace'] != null)
      'stackTrace': record.values['stackTrace'],
    'category': record.values['category'],
    'message': record.values['message'],
    for (final entry in fields.entries)
      if (!const ['method', 'url', 'status'].contains(entry.key))
        entry.key: entry.value,
  }, _diagnosticBytes * 3 ~/ 4);
}

SentryLevel _level(AppLogLevel level) => switch (level) {
  AppLogLevel.debug => SentryLevel.debug,
  AppLogLevel.info => SentryLevel.info,
  AppLogLevel.warning => SentryLevel.warning,
  AppLogLevel.error => SentryLevel.error,
  AppLogLevel.fatal => SentryLevel.fatal,
};

SentryAttribute _attribute(Object? value) => switch (value) {
  String value => SentryAttribute.string(value),
  bool value => SentryAttribute.bool(value),
  int value => SentryAttribute.int(value),
  double value => SentryAttribute.double(value),
  List value when value.every((item) => item is String) =>
    SentryAttribute.stringArray(value.cast<String>()),
  List value when value.every((item) => item is bool) =>
    SentryAttribute.boolArray(value.cast<bool>()),
  List value when value.every((item) => item is int) =>
    SentryAttribute.intArray(value.cast<int>()),
  List value when value.every((item) => item is double) =>
    SentryAttribute.doubleArray(value.cast<double>()),
  _ => SentryAttribute.string(jsonEncode(value)),
};

Breadcrumb? _beforeBreadcrumb(Breadcrumb? breadcrumb, Hint hint) {
  try {
    if (breadcrumb == null) return null;
    final json = _clean(breadcrumb.toJson());
    return Breadcrumb.fromJson(
      _bounded({
        'timestamp': json.remove('timestamp'),
        'level': json.remove('level'),
        ...json,
      }, 4096),
    );
  } catch (error, stackTrace) {
    _localWarning(
      'Dropped unsafe Sentry breadcrumb',
      error: error,
      stackTrace: stackTrace,
    );
    return null;
  }
}

SentryEvent? _beforeSend(SentryEvent event, Hint hint) {
  try {
    final global = Zone.current[_globalErrorKey] as _GlobalError?;
    if (global?.suppressCapture ?? false) return null;
    final details = hint.get(TypeCheckHint.syntheticException);
    if (details is FlutterErrorDetails && details.silent) return null;
    final diagnostics = global?.diagnostics ?? hint.get('xmplus.diagnostics');
    if (diagnostics != null) event.contexts['xmplus'] = diagnostics;
    event.tags = {
      ...?event.tags,
      'platform': Platform.operatingSystem,
      if (AppLog.instance.sessionId != null)
        'sessionId': AppLog.instance.sessionId!,
    };
    final json = _eventJson(event);
    final clean = SentryEvent.fromJson(json);
    // SDK10's thread parser reads frames from the thread rather than its
    // stacktrace member. Restore that member through the public stack parser.
    final threads = json['threads']?['values'] as List?;
    for (var i = 0; i < (threads?.length ?? 0); i++) {
      final stack = threads![i]['stacktrace'];
      if (stack is Map<String, dynamic>) {
        clean.threads![i].stacktrace = SentryStackTrace.fromJson(stack);
      }
    }
    return clean;
  } catch (error, stackTrace) {
    _localWarning(
      'Dropped unsafe Sentry event',
      error: error,
      stackTrace: stackTrace,
    );
    return null;
  }
}

SentryTransaction? _beforeSendTransaction(SentryTransaction event, Hint hint) {
  try {
    return _CleanTransaction(event, _eventJson(event));
  } catch (error, stackTrace) {
    _localWarning(
      'Dropped unsafe Sentry transaction',
      error: error,
      stackTrace: stackTrace,
    );
    return null;
  }
}

SentryLog? _beforeSendLog(SentryLog log, Hint hint) {
  try {
    final clean = _clean(log.toJson());
    final budget = _JsonBudget(_diagnosticBytes - 128);
    final payload = <String, dynamic>{};
    budget.put(payload, 'body', clean['body']);
    final attributes = <String, dynamic>{};
    budget.remaining -= 16; // attributes key, object and root delimiters
    for (final priority in const [true, false]) {
      for (final entry in (clean['attributes'] as Map).entries) {
        if (_JsonBudget._identifiers.contains(entry.key) != priority) continue;
        // Cookie-named attributes are replaced wholesale by the redactor.
        final value = entry.value is Map
            ? (entry.value as Map)['value']
            : entry.value;
        final attribute = _attribute(value);
        budget.put(attributes, '${entry.key}', attribute.toJson(), whole: true);
      }
    }
    log.body = payload['body'] as String;
    log.attributes = {
      for (final entry in attributes.entries)
        entry.key: _attribute((entry.value as Map)['value']),
      if (budget.omittedBytes > 0)
        'omittedBytes': SentryAttribute.int(budget.omittedBytes),
    };
    return log;
  } catch (error, stackTrace) {
    _localWarning(
      'Dropped unsafe Sentry log',
      error: error,
      stackTrace: stackTrace,
    );
    return null;
  }
}

Map<String, dynamic> _clean(Map<String, dynamic> json) {
  final clean = AppLog.redact(json) as Map;
  final result = Map<String, dynamic>.from(clean);
  // SentryRequest uses plural `cookies`, distinct from an ordinary business
  // field named cookies. It represents a Cookie header, so clean it explicitly.
  final request = result['request'];
  if (request is Map && request.containsKey('cookies')) {
    result['request'] = {...request, 'cookies': AppLog.cookieReplacement};
  }
  return result;
}

Map<String, dynamic> _eventJson(SentryEvent event) {
  final json = _clean(event.toJson());
  final contexts = Map<String, dynamic>.from(json['contexts'] as Map? ?? {});
  final trace = Map<String, dynamic>.from(
    contexts.remove('trace') as Map? ?? {},
  );
  final budget = _JsonBudget(_diagnosticBytes - 128);
  final cleanContexts = <String, dynamic>{};

  // Original exception/message/stack and trace protocol identity are core,
  // not optional diagnostics. Never generically clip or replace this evidence.
  const traceCore = {
    'trace_id',
    'span_id',
    'parent_span_id',
    'replay_id',
    'op',
    'status',
    'origin',
  };
  final cleanTrace = <String, dynamic>{
    for (final entry in trace.entries)
      if (traceCore.contains(entry.key)) entry.key: entry.value,
  };

  // Reserve request identity before bodies/contexts can consume the budget.
  final request = json.remove('request') as Map?;
  final cleanRequest = <String, dynamic>{};
  if (request != null) {
    for (final key in const ['method', 'url']) {
      if (request.containsKey(key)) {
        budget.put(cleanRequest, key, request[key], whole: true);
      }
    }
  }
  if (contexts.containsKey('xmplus')) {
    budget.put(cleanContexts, 'xmplus', contexts.remove('xmplus'));
  }
  if (request != null) {
    for (final entry in request.entries) {
      if (entry.key != 'method' && entry.key != 'url') {
        budget.put(cleanRequest, '${entry.key}', entry.value, whole: true);
      }
    }
    if (cleanRequest.isNotEmpty) json['request'] = cleanRequest;
  }
  for (final entry in trace.entries) {
    if (!traceCore.contains(entry.key)) {
      budget.put(cleanTrace, entry.key, entry.value, whole: true);
    }
  }
  if (cleanTrace.isNotEmpty) cleanContexts['trace'] = cleanTrace;
  for (final entry in contexts.entries) {
    // Typed SDK contexts (feedback/flags/etc.) must be complete or absent.
    budget.put(cleanContexts, entry.key, entry.value, whole: true);
  }
  for (final key in const [
    'extra',
    'spans',
    'user',
    'tags',
    'breadcrumbs',
    'measurements',
    'transaction_info',
  ]) {
    if (!json.containsKey(key)) continue;
    final value = json.remove(key);
    if (key == 'spans' || key == 'breadcrumbs') {
      // Retain each complete protocol item, never an ID/timestamp-less map.
      final items = <dynamic>[];
      budget.remaining -= 16;
      for (final item in value as List) {
        final fitted = budget.fit(item, whole: true);
        if (!identical(fitted, _omitted)) {
          items.add(fitted);
          budget.remaining--;
        }
      }
      if (items.isNotEmpty) json[key] = items;
    } else {
      budget.put(json, key, value, whole: key != 'extra');
    }
  }
  if (budget.omittedBytes > 0) {
    cleanContexts['xmplus_truncation'] = {'omittedBytes': budget.omittedBytes};
  }
  json['contexts'] = cleanContexts;
  return json;
}

// SDK10 has no SentryTransaction.fromJson; finished spans have no setters.
// Preserve the tracer, but serialize only the cleaned, budgeted protocol map.
final class _CleanTransaction extends SentryTransaction {
  _CleanTransaction(SentryTransaction original, this._json)
    : super(
        // ignore: invalid_use_of_internal_member
        original.tracer,
        eventId: original.eventId,
        timestamp: original.timestamp,
      );
  final Map<String, dynamic> _json;
  @override
  Map<String, dynamic> toJson() => _json;
}

Map<String, dynamic> _bounded(
  Map<String, Object?> values, [
  int limit = _diagnosticBytes,
]) {
  final budget = _JsonBudget(limit - 64);
  final result = budget.fit(values) as Map<String, dynamic>;
  if (budget.omittedBytes > 0) {
    result['omittedBytes'] =
        budget.omittedBytes + (result['omittedBytes'] as int? ?? 0);
  }
  return result;
}

const _omitted = Object();

final class _JsonBudget {
  _JsonBudget(this.remaining);
  int remaining;
  int omittedBytes = 0;

  static const _identifiers = {
    'sessionId',
    'requestId',
    'errorScopeId',
    'method',
    'url',
    'status',
    'timestamp',
    'start_timestamp',
    'trace_id',
    'span_id',
    'parent_span_id',
    'replay_id',
    'op',
    'level',
  };

  void put(
    Map<String, dynamic> target,
    String key,
    Object? value, {
    bool whole = false,
  }) {
    final overhead = utf8.encode(jsonEncode(key)).length + 2;
    if (remaining < overhead + 4) {
      omittedBytes += utf8.encode(jsonEncode({key: value})).length;
      return;
    }
    remaining -= overhead;
    final fitted = fit(value, whole: whole || _identifiers.contains(key));
    if (identical(fitted, _omitted)) {
      remaining += overhead;
    } else {
      target[key] = fitted;
    }
  }

  Object? fit(Object? value, {bool whole = false}) {
    if (whole) {
      final bytes = utf8.encode(jsonEncode(value)).length;
      if (bytes <= remaining) {
        remaining -= bytes;
        return value;
      }
      omittedBytes += bytes;
      return _omitted;
    }
    if (value is Map) {
      final result = <String, dynamic>{};
      remaining -= 2;
      for (final priority in const [true, false]) {
        for (final entry in value.entries) {
          if (_identifiers.contains(entry.key) != priority) continue;
          put(result, '${entry.key}', entry.value);
        }
      }
      return result;
    }
    if (value is List) {
      final result = <Object?>[];
      remaining -= 2;
      for (final item in value) {
        if (remaining < 8) {
          omittedBytes += utf8.encode(jsonEncode(item)).length;
          continue;
        }
        remaining--;
        final fitted = fit(item);
        if (!identical(fitted, _omitted)) result.add(fitted);
      }
      return result;
    }
    final bytes = utf8.encode(jsonEncode(value)).length;
    // A giant diagnostic string cannot starve other fields.
    final allowed = remaining.clamp(0, _diagnosticBytes ~/ 4);
    if (bytes <= allowed) {
      remaining -= bytes;
      return value;
    }
    if (value is! String || allowed < 2) {
      omittedBytes += bytes;
      return _omitted;
    }
    var low = 0;
    var high = value.length.clamp(0, allowed);
    while (low < high) {
      final middle = (low + high + 1) ~/ 2;
      if (utf8.encode(jsonEncode(value.substring(0, middle))).length <=
          allowed) {
        low = middle;
      } else {
        high = middle - 1;
      }
    }
    // Never cut a UTF-16 surrogate pair or its corresponding UTF-8 character.
    if (low > 0 &&
        low < value.length &&
        value.codeUnitAt(low - 1) >= 0xd800 &&
        value.codeUnitAt(low - 1) <= 0xdbff) {
      low--;
    }
    final clipped = value.substring(0, low);
    final keptBytes = utf8.encode(jsonEncode(clipped)).length;
    omittedBytes += bytes - keptBytes;
    remaining -= keptBytes;
    return clipped;
  }
}
