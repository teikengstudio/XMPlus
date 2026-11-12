import 'dart:convert';

import 'package:uuid/uuid.dart';

import 'app_log.dart';

/// One observation per actual HTTP attempt, including redirects and retries.
class HttpLogAttempt {
  HttpLogAttempt({
    required this.account,
    required this.method,
    required this.url,
  }) {
    AppLog.instance.trace(
      "lib/services/http_log_attempt.dart::HttpLogAttempt.new",
    );
  }

  final DateTime timestamp = DateTime.now().toUtc();
  final String requestId = const Uuid().v4();
  final String account, method;
  final Stopwatch _elapsed = Stopwatch()..start();
  String url;
  String requestHeaderAvailability =
      '完整的 HTTP 库请求头；底层连接自动生成的头（如 Host / Connection）可能不向调用方暴露';
  Map<String, dynamic> requestHeaders = {};
  String requestBody = '(无请求体)';
  String Function()? requestBodyCapture;
  int? status;
  String? transportError;
  Map<String, dynamic> responseHeaders = {};
  List<int> Function()? responseBytes;
  String completeness = '未接收到响应体';
  bool responseIsBinary = false;
  int? responseByteCount;
  bool _started = false,
      _responded = false,
      _failed = false,
      _cancelled = false;

  void started() {
    AppLog.instance.trace(
      "lib/services/http_log_attempt.dart::HttpLogAttempt.started",
    );

    if (_started || _cancelled) return;
    _started = true;
    if (AppLog.instance.level != AppLogLevel.debug) return;
    AppLog.instance.write(
      AppLogLevel.debug,
      'network',
      'HTTP request',
      requestId: requestId,
      data: _requestData(),
    );
  }

  void succeeded() {
    AppLog.instance.trace(
      "lib/services/http_log_attempt.dart::HttpLogAttempt.succeeded",
    );

    if (_responded || _cancelled) return;
    _responded = true;
    if (AppLog.instance.level != AppLogLevel.debug) return;
    AppLog.instance.write(
      AppLogLevel.debug,
      'network',
      'HTTP response',
      requestId: requestId,
      data: _responseData(captureBinary: false),
    );
  }

  Future<void> fail(
    Object error,
    StackTrace stackTrace, {
    bool promptUser = true,
  }) {
    AppLog.instance.trace(
      "lib/services/http_log_attempt.dart::HttpLogAttempt.fail",
    );

    if (_failed || _cancelled) return Future<void>.value();
    _failed = true;
    if (status != null) succeeded();
    AppLog.instance.write(
      AppLogLevel.error,
      'network',
      'HTTP request failed',
      requestId: requestId,
      data: _responseData(captureBinary: true),
      error: error,
      stackTrace: stackTrace,
      networkError: true,
      promptUser: promptUser,
    );
    return AppLog.instance.flush();
  }

  void cancelled([Object? reason]) {
    AppLog.instance.trace(
      "lib/services/http_log_attempt.dart::HttpLogAttempt.cancelled",
    );

    if (_cancelled || _failed) return;
    _cancelled = true;
    if (AppLog.instance.level != AppLogLevel.debug) return;
    AppLog.instance.write(
      AppLogLevel.debug,
      'network',
      'HTTP request cancelled',
      requestId: requestId,
      data: {
        ..._requestData(),
        'elapsedMs': _elapsed.elapsedMilliseconds,
        if (reason != null) 'reason': '$reason',
      },
    );
  }

  Map<String, Object?> _requestData() {
    AppLog.instance.trace(
      "lib/services/http_log_attempt.dart::HttpLogAttempt._requestData",
    );

    var body = requestBody;
    Object? captureError;
    try {
      body = requestBodyCapture?.call() ?? body;
    } catch (error) {
      captureError = '$error';
    }
    return {
      'timestamp': timestamp.toIso8601String(),
      'account': account,
      'method': method,
      'url': url,
      'requestHeaderAvailability': requestHeaderAvailability,
      'requestHeaders': requestHeaders,
      'requestBody': body,
      if (captureError != null) 'requestBodyCaptureError': captureError,
    };
  }

  Map<String, Object?> _responseData({required bool captureBinary}) {
    AppLog.instance.trace(
      "lib/services/http_log_attempt.dart::HttpLogAttempt._responseData",
    );

    final data = <String, Object?>{
      ..._requestData(),
      'status': status,
      'responseHeaders': responseHeaders,
      'elapsedMs': _elapsed.elapsedMilliseconds,
      'completeness': completeness,
      'responseIsBinary': responseIsBinary,
      if (transportError != null) 'transportError': transportError,
    };
    if (responseIsBinary) {
      data['responseByteCount'] = responseByteCount;
      // Media success must not materialize the captured failure fragment.
      if (!captureBinary) return data;
    }
    try {
      final bytes = responseBytes?.call() ?? const <int>[];
      data['capturedResponseBytes'] = bytes.length;
      try {
        data['responseBody'] = utf8.decode(bytes, allowMalformed: false);
      } on FormatException {
        data['responseBodyBase64'] = base64Encode(bytes);
      }
    } catch (error) {
      data['captureError'] = '$error';
    }
    return data;
  }
}
