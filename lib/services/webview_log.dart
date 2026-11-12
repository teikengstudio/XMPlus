import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:uuid/uuid.dart';

import 'app_log.dart';

/// Observes only data exposed by the WebView SDK; never changes requests.
class WebViewLog {
  WebViewLog(this.page) {
    AppLog.instance.trace("lib/services/webview_log.dart::WebViewLog.new");
  }

  final String page;
  final String _id = const Uuid().v4();
  final _requests = <String, _ObservedRequest>{};
  final _listeners = <String>[];
  InAppWebViewController? _controller;
  Future<void>? _connecting;
  bool _disposed = false, _observing = false;
  int _sequence = 0;

  bool get _debug {
    AppLog.instance.trace(
      "lib/services/webview_log.dart::WebViewLog._debug.get",
    );
    return AppLog.instance.level == AppLogLevel.debug;
  }

  Future<void> observe(InAppWebViewController controller) async {
    AppLog.instance.trace("lib/services/webview_log.dart::WebViewLog.observe");

    if (!Platform.isWindows || _disposed) return;
    _connecting = _observe(controller);
    await _connecting;
  }

  Future<void> _observe(InAppWebViewController controller) async {
    AppLog.instance.trace("lib/services/webview_log.dart::WebViewLog._observe");

    await _detach();
    if (_disposed) return;
    _controller = controller;
    try {
      for (final name in const [
        'Network.requestWillBeSent',
        'Network.responseReceived',
        'Network.loadingFailed',
        'Network.loadingFinished',
      ]) {
        await controller.addDevToolsProtocolEventListener(
          eventName: name,
          callback: (data) {
            AppLog.instance.trace(
              "lib/services/webview_log.dart::WebViewLog._observe.closure#1",
            );

            if (_disposed) return;
            try {
              _event(name, data);
            } catch (error, stack) {
              _warning('WebView network event unavailable', error, stack);
            }
          },
        );
        _listeners.add(name);
        if (_disposed) return;
      }
      await controller.callDevToolsProtocolMethod(methodName: 'Network.enable');
      _observing = !_disposed;
    } catch (error, stack) {
      _warning('WebView network observation unavailable', error, stack);
      await _detach();
    }
  }

  Future<void> _detach() async {
    AppLog.instance.trace("lib/services/webview_log.dart::WebViewLog._detach");

    _observing = false;
    final controller = _controller;
    if (controller != null) {
      for (final name in _listeners) {
        try {
          await controller.removeDevToolsProtocolEventListener(eventName: name);
        } catch (error, stack) {
          _warning('WebView network listener removal failed', error, stack);
        }
      }
    }
    _listeners.clear();
    _requests.clear();
    _controller = null;
  }

  Future<void> dispose() async {
    AppLog.instance.trace("lib/services/webview_log.dart::WebViewLog.dispose");

    _disposed = true;
    await _connecting;
    await _detach();
  }

  void _warning(String message, Object error, StackTrace stack) {
    AppLog.instance.trace("lib/services/webview_log.dart::WebViewLog._warning");

    AppLog.instance.write(
      AppLogLevel.warning,
      'webview',
      message,
      data: {'page': page},
      error: error,
      stackTrace: stack,
    );
  }

  void _event(String name, dynamic data) {
    AppLog.instance.trace("lib/services/webview_log.dart::WebViewLog._event");

    if (data is! Map || data['requestId'] is! String) {
      throw const FormatException('WebView CDP requestId unavailable');
    }
    final cdpId = data['requestId'] as String;
    var request = _requests[cdpId];
    switch (name) {
      case 'Network.requestWillBeSent':
        final redirect = data['redirectResponse'];
        if (redirect is Map) _response(cdpId, request, redirect);
        final details = data['request'];
        if (details is! Map) {
          throw const FormatException('WebView CDP request unavailable');
        }
        request = _ObservedRequest('$_id-${++_sequence}', details);
        _requests[cdpId] = request;
        if (_debug) {
          AppLog.instance.write(
            AppLogLevel.debug,
            'webview',
            'Request started',
            requestId: request.id,
            data: {'page': page, 'cdpRequestId': cdpId, 'request': details},
          );
        }
        break;
      case 'Network.responseReceived':
        final response = data['response'];
        if (response is! Map) {
          throw const FormatException('WebView CDP response unavailable');
        }
        _response(cdpId, request, response);
        break;
      case 'Network.loadingFailed':
        if (data['canceled'] == true) {
          if (_debug) {
            AppLog.instance.write(
              AppLogLevel.debug,
              'webview',
              'Request cancelled',
              requestId: request?.id,
              data: {'page': page, 'cdpRequestId': cdpId, 'event': data},
            );
          }
        } else {
          _failure(cdpId, request, data);
        }
        _requests.remove(cdpId);
        break;
      case 'Network.loadingFinished':
        if (_debug) {
          AppLog.instance.write(
            AppLogLevel.debug,
            'webview',
            'Response completed',
            requestId: request?.id,
            data: {
              'page': page,
              'cdpRequestId': cdpId,
              'encodedByteCount': data['encodedDataLength'],
            },
          );
        }
        _requests.remove(cdpId);
        break;
    }
  }

  void _response(String cdpId, _ObservedRequest? request, Map response) {
    AppLog.instance.trace(
      "lib/services/webview_log.dart::WebViewLog._response",
    );

    request?.response = response;
    if (_debug) {
      AppLog.instance.write(
        AppLogLevel.debug,
        'webview',
        'Response received',
        requestId: request?.id,
        data: {'page': page, 'cdpRequestId': cdpId, 'response': response},
      );
    }
    final status = response['status'];
    if (status is num && status >= 400) _failure(cdpId, request, response);
  }

  void _failure(String cdpId, _ObservedRequest? request, Map event) {
    AppLog.instance.trace("lib/services/webview_log.dart::WebViewLog._failure");

    if (request?.failed == true) return;
    if (request != null) request.failed = true;
    AppLog.instance.write(
      AppLogLevel.error,
      'webview',
      'Request failed',
      requestId: request?.id,
      data: {
        'page': page,
        'cdpRequestId': cdpId,
        'request': request?.details,
        'response': request?.response,
        'event': event,
        // CDP exposes error data, not the original native exception/stack.
        'stackSource': 'Dart observation callback',
      },
      error: event,
      stackTrace: StackTrace.current,
      networkError: true,
      promptUser: true,
    );
  }

  Map<String, Object?> _requestData(WebResourceRequest request) {
    AppLog.instance.trace(
      "lib/services/webview_log.dart::WebViewLog._requestData",
    );
    return {
      'page': page,
      'method': request.method,
      'url': request.url.toString(),
      'headers': request.headers,
      'isForMainFrame': request.isForMainFrame,
    };
  }

  void intercepted(WebResourceRequest request) {
    AppLog.instance.trace(
      "lib/services/webview_log.dart::WebViewLog.intercepted",
    );

    if (!_debug || _disposed || (Platform.isWindows && _observing)) return;
    AppLog.instance.write(
      AppLogLevel.debug,
      'webview',
      'Resource request observed',
      data: _requestData(request),
    );
  }

  void loaded(LoadedResource resource) {
    AppLog.instance.trace("lib/services/webview_log.dart::WebViewLog.loaded");

    if (!_debug || _disposed) return;
    AppLog.instance.write(
      AppLogLevel.debug,
      'webview',
      'Resource loaded',
      data: {
        'page': page,
        'url': resource.url?.toString(),
        'initiatorType': resource.initiatorType,
        'startTime': resource.startTime,
        'duration': resource.duration,
      },
    );
  }

  void resourceError(WebResourceRequest request, WebResourceError error) {
    AppLog.instance.trace(
      "lib/services/webview_log.dart::WebViewLog.resourceError",
    );

    if (_disposed || (Platform.isWindows && _observing)) return;
    final cancelled =
        error.type == WebResourceErrorType.CANCELLED ||
        error.type == WebResourceErrorType.USER_CANCELLED_AUTHENTICATION;
    if (cancelled && !_debug) return;
    AppLog.instance.write(
      cancelled ? AppLogLevel.debug : AppLogLevel.error,
      'webview',
      cancelled ? 'Resource request cancelled' : 'Resource request failed',
      data: {
        ..._requestData(request),
        'type': error.type.toNativeValue(),
        'description': error.description,
        'stackSource': 'Dart observation callback',
      },
      error: cancelled ? null : error,
      stackTrace: cancelled ? null : StackTrace.current,
      networkError: !cancelled,
      promptUser: !cancelled,
    );
  }

  void httpError(WebResourceRequest request, WebResourceResponse response) {
    AppLog.instance.trace(
      "lib/services/webview_log.dart::WebViewLog.httpError",
    );

    if (_disposed || (Platform.isWindows && _observing)) return;
    AppLog.instance.write(
      AppLogLevel.error,
      'webview',
      'Resource HTTP error',
      data: {
        ..._requestData(request),
        'status': response.statusCode,
        'reason': response.reasonPhrase,
        'responseHeaders': response.headers,
        'contentType': response.contentType,
        'visibleByteCount': response.data?.length,
        'stackSource': 'Dart observation callback',
      },
      error: response,
      stackTrace: StackTrace.current,
      networkError: true,
      promptUser: true,
    );
  }

  Future<void> denyDownloads(InAppWebViewController controller) async {
    AppLog.instance.trace(
      "lib/services/webview_log.dart::WebViewLog.denyDownloads",
    );

    final channel =
        'com.pichillilorenzo/flutter_inappwebview_${controller.getViewId()}';
    const method = 'xmplusDenyDownloads';
    const arguments = <String, dynamic>{};
    if (_debug) {
      AppLog.instance.write(
        AppLogLevel.debug,
        'platform',
        'MethodChannel call',
        data: {'channel': channel, 'method': method, 'arguments': arguments},
      );
    }
    try {
      final installed = await MethodChannel(channel)
          .invokeMethod<bool>(method, arguments);
      if (_debug) {
        AppLog.instance.write(
          AppLogLevel.debug,
          'platform',
          'MethodChannel result',
          data: {'channel': channel, 'method': method, 'result': installed},
        );
      }
      if (installed != true) {
        throw StateError('Native download guard unavailable');
      }
    } catch (error, stack) {
      AppLog.instance.write(
        AppLogLevel.error,
        'platform',
        'MethodChannel failed',
        data: {'channel': channel, 'method': method, 'arguments': arguments},
        error: error,
        stackTrace: stack,
      );
      rethrow;
    }
  }
}

class _ObservedRequest {
  _ObservedRequest(this.id, this.details) {
    AppLog.instance.trace(
      "lib/services/webview_log.dart::_ObservedRequest.new",
    );
  }

  final String id;
  final Map details;
  Map? response;
  bool failed = false;
}
