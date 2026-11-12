import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart' show Factory;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import '../services/app_log.dart';
import '../services/webview_log.dart';

void _recordManuscriptError(
  String operation,
  Object error,
  StackTrace stack, {
  bool recoverable = false,
}) {
  AppLog.instance.trace(
    "lib/pages/manuscript_reader.dart::_recordManuscriptError",
  );

  final log = AppLog.instance;
  if (log.errorWasRecorded(error)) return;
  log.write(
    recoverable ? AppLogLevel.warning : AppLogLevel.error,
    'manuscript_reader',
    operation,
    error: error,
    stackTrace: stack,
    promptUser: !recoverable,
  );
}

/// Official publisher/AI manuscript HTML, including image-only manuscripts.
class ManuscriptReader extends StatefulWidget {
  const ManuscriptReader({
    required this.manuscript,
    this.showTitle = true,
    super.key,
  });
  final String manuscript;
  final bool showTitle;

  @override
  State<ManuscriptReader> createState() {
    AppLog.instance.trace(
      "lib/pages/manuscript_reader.dart::ManuscriptReader.createState",
    );
    return _ManuscriptReaderState();
  }
}

class _ManuscriptReaderState extends State<ManuscriptReader> {
  final _scroll = ScrollController();
  final _nonce = base64UrlEncode(
    (() {
      AppLog.instance.trace(
        "lib/pages/manuscript_reader.dart::_ManuscriptReaderState._nonce.closure#1",
      );

      final random = Random.secure();
      return List<int>.generate(24, (_) {
        AppLog.instance.trace(
          "lib/pages/manuscript_reader.dart::_ManuscriptReaderState._nonce.closure#1.closure#1",
        );
        return random.nextInt(256);
      });
    })(),
  );
  WebViewEnvironment? _environment;
  final _webLog = WebViewLog('manuscript');
  Directory? _profile;
  bool _ready = false;
  String? _error;
  int _attempt = 0;
  bool get _html {
    AppLog.instance.trace(
      "lib/pages/manuscript_reader.dart::_ManuscriptReaderState._html.get",
    );
    return widget.manuscript.contains('<') || widget.manuscript.contains('&');
  }

  String get _documentUrl {
    AppLog.instance.trace(
      "lib/pages/manuscript_reader.dart::_ManuscriptReaderState._documentUrl.get",
    );
    return Platform.isAndroid
        ? 'https://appassets.androidplatform.net/xmplus-manuscript/$_nonce/index.html'
        : 'about:blank';
  }

  @override
  void initState() {
    AppLog.instance.trace(
      "lib/pages/manuscript_reader.dart::_ManuscriptReaderState.initState",
    );

    super.initState();
    if (_html) unawaited(_prepare());
  }

  Future<void> _prepare() {
    AppLog.instance.trace(
      "lib/pages/manuscript_reader.dart::_ManuscriptReaderState._prepare",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/pages/manuscript_reader.dart::_ManuscriptReaderState._prepare.closure#1",
      );

      var unavailable = false;
      try {
        PlatformInAppWebViewController.debugLoggingSettings.enabled = false;
        if (Platform.isWindows) {
          final version = await WebViewEnvironment.getAvailableVersion();
          if (version == null || version.isEmpty) {
            unavailable = true;
            throw StateError('WebView2 unavailable');
          }
          final profile = _profile ??= await Directory.systemTemp.createTemp(
            'xmplus-manuscript-',
          );
          final environment = await WebViewEnvironment.create(
            settings: WebViewEnvironmentSettings(
              userDataFolder: profile.path,
              allowSingleSignOnUsingOSPrimaryAccount: false,
              language: 'zh-CN',
            ),
          );
          if (!mounted) {
            try {
              await environment.dispose();
            } catch (error, stack) {
              _recordManuscriptError(
                'Manuscript environment disposal failed',
                error,
                stack,
                recoverable: true,
              );
            }
            await _deleteProfile(profile);
            return;
          }
          _environment = environment;
        } else if (!Platform.isAndroid &&
            !Platform.isIOS &&
            !Platform.isMacOS) {
          unavailable = true;
          throw UnsupportedError('Native manuscript reader unavailable');
        }
        if (mounted)
          setState(() {
            AppLog.instance.trace(
              "lib/pages/manuscript_reader.dart::_ManuscriptReaderState._prepare.closure#1.closure#1",
            );
            _ready = true;
          });
      } catch (error, stack) {
        _recordManuscriptError(
          'Manuscript setup failed',
          error,
          stack,
          recoverable: unavailable,
        );
        _fail();
      }
    });
  }

  static Future<void> _deleteProfile(Directory profile) {
    AppLog.instance.trace(
      "lib/pages/manuscript_reader.dart::_ManuscriptReaderState._deleteProfile",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/pages/manuscript_reader.dart::_ManuscriptReaderState._deleteProfile.closure#1",
      );

      try {
        if (await profile.exists()) await profile.delete(recursive: true);
      } on FileSystemException catch (error, stack) {
        _recordManuscriptError(
          'Manuscript profile cleanup failed',
          error,
          stack,
          recoverable: true,
        );
        // WebView2 can retain its temporary isolated profile until shutdown.
      }
    });
  }

  @override
  void dispose() {
    AppLog.instance.trace(
      "lib/pages/manuscript_reader.dart::_ManuscriptReaderState.dispose",
    );

    _scroll.dispose();
    final environment = _environment, profile = _profile;
    unawaited(
      AppLog.instance.runWithErrorScope(() async {
        AppLog.instance.trace(
          "lib/pages/manuscript_reader.dart::_ManuscriptReaderState.dispose.closure#1",
        );

        try {
          await _webLog.dispose();
          await environment?.dispose();
        } catch (error, stack) {
          _recordManuscriptError(
            'Manuscript environment disposal failed',
            error,
            stack,
            recoverable: true,
          );
          // The native view may already have disposed the environment.
        }
        if (profile != null) await _deleteProfile(profile);
      }),
    );
    super.dispose();
  }

  void _fail() {
    AppLog.instance.trace(
      "lib/pages/manuscript_reader.dart::_ManuscriptReaderState._fail",
    );

    if (mounted)
      setState(() {
        AppLog.instance.trace(
          "lib/pages/manuscript_reader.dart::_ManuscriptReaderState._fail.closure#1",
        );
        _error = '文稿显示失败，请重试；HTML 文稿需要系统 WebView 运行时';
      });
  }

  bool _image(Uri uri) {
    AppLog.instance.trace(
      "lib/pages/manuscript_reader.dart::_ManuscriptReaderState._image",
    );
    return uri.scheme == 'https' &&
        uri.userInfo.isEmpty &&
        uri.port == 443 &&
        const ['xmcdn.com', 'ximalaya.com'].any((host) {
          AppLog.instance.trace(
            "lib/pages/manuscript_reader.dart::_ManuscriptReaderState._image.closure#1",
          );
          return uri.host == host || uri.host.endsWith('.$host');
        });
  }

  String _document() {
    AppLog.instance.trace(
      "lib/pages/manuscript_reader.dart::_ManuscriptReaderState._document",
    );

    final colors = Theme.of(context).colorScheme;
    String color(Color value) {
      AppLog.instance.trace(
        "lib/pages/manuscript_reader.dart::_ManuscriptReaderState._document.color",
      );
      return '#${value.toARGB32().toRadixString(16).substring(2)}';
    }

    final fontSize = MediaQuery.textScalerOf(context).scale(17);
    return '''<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'none'; style-src 'nonce-$_nonce'; img-src https://xmcdn.com https://*.xmcdn.com https://ximalaya.com https://*.ximalaya.com; connect-src 'none'; font-src 'none'; media-src 'none'; frame-src 'none'; object-src 'none'; base-uri https://www.ximalaya.com; form-action 'none'; sandbox">
<base href="https://www.ximalaya.com/">
<meta name="referrer" content="no-referrer">
<style nonce="$_nonce">html{color:${color(colors.onSurface)};background:${color(colors.surface)};font:${fontSize}px/1.8 sans-serif;overflow-wrap:anywhere}body{margin:0;padding:12px}img{max-width:100%;height:auto}pre{white-space:pre-wrap}a{color:inherit;pointer-events:none}table{max-width:100%;display:block;overflow:auto}</style>
</head><body>${widget.manuscript.replaceAll('\n', '<br>')}</body></html>''';
  }

  Future<void> _created(InAppWebViewController controller) {
    AppLog.instance.trace(
      "lib/pages/manuscript_reader.dart::_ManuscriptReaderState._created",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/pages/manuscript_reader.dart::_ManuscriptReaderState._created.closure#1",
      );

      try {
        if (Platform.isWindows) {
          await _webLog.denyDownloads(controller);
        }
        await _webLog.observe(controller);
        if (!mounted || _error != null) return;
        if (Platform.isAndroid) {
          await controller.loadUrl(
            urlRequest: URLRequest(url: WebUri(_documentUrl)),
          );
        } else {
          await controller.loadData(
            data: _document(),
            baseUrl: WebUri(_documentUrl),
          );
        }
      } catch (error, stack) {
        _recordManuscriptError(
          'Manuscript controller setup failed',
          error,
          stack,
        );
        _fail();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace(
      "lib/pages/manuscript_reader.dart::_ManuscriptReaderState.build",
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.showTitle)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text('文稿', style: Theme.of(context).textTheme.titleMedium),
          ),
        Expanded(
          child: !_html
              ? Scrollbar(
                  controller: _scroll,
                  child: SingleChildScrollView(
                    key: const ValueKey('manuscriptTextScroll'),
                    controller: _scroll,
                    padding: const EdgeInsets.all(12),
                    child: SelectableText(
                      widget.manuscript,
                      style: Theme.of(context).textTheme.bodyLarge
                          ?.copyWith(fontSize: 17, height: 1.9),
                    ),
                  ),
                )
              : _error != null
              ? Center(
                  child: SingleChildScrollView(
                    child: Column(
                      children: [
                        Text(
                          _error!,
                          key: const ValueKey('manuscriptRenderError'),
                        ),
                        TextButton(
                          onPressed: () {
                            AppLog.instance.trace(
                              "lib/pages/manuscript_reader.dart::_ManuscriptReaderState.build.closure#1",
                            );

                            setState(() {
                              AppLog.instance.trace(
                                "lib/pages/manuscript_reader.dart::_ManuscriptReaderState.build.closure#1.closure#1",
                              );

                              _error = null;
                              _attempt++;
                            });
                            if (!_ready) unawaited(_prepare());
                          },
                          child: const Text('重试显示文稿'),
                        ),
                      ],
                    ),
                  ),
                )
              : !_ready
              ? const Center(child: CircularProgressIndicator())
              : SentryMask(
                  InAppWebView(
                    key: ValueKey(_attempt),
                    webViewEnvironment: _environment,
                    gestureRecognizers: {
                      Factory<OneSequenceGestureRecognizer>(() {
                        AppLog.instance.trace(
                          "lib/pages/manuscript_reader.dart::_ManuscriptReaderState.build.closure#2",
                        );
                        return VerticalDragGestureRecognizer();
                      }),
                    },
                    initialSettings: InAppWebViewSettings(
                      incognito: true,
                      cacheEnabled: false,
                      javaScriptEnabled: false,
                      isInspectable: false,
                      disableContextMenu: true,
                      useShouldOverrideUrlLoading: true,
                      useShouldInterceptRequest: true,
                      supportMultipleWindows: false,
                      javaScriptCanOpenWindowsAutomatically: false,
                      allowFileAccess: false,
                      allowContentAccess: false,
                      allowFileAccessFromFileURLs: false,
                      allowUniversalAccessFromFileURLs: false,
                      thirdPartyCookiesEnabled: false,
                      geolocationEnabled: false,
                      saveFormData: false,
                      databaseEnabled: false,
                      domStorageEnabled: false,
                      mediaPlaybackRequiresUserGesture: true,
                      useOnDownloadStart: true,
                      mixedContentMode:
                          MixedContentMode.MIXED_CONTENT_NEVER_ALLOW,
                    ),
                    onWebViewCreated: _created,
                    shouldOverrideUrlLoading: (_, action) async {
                      AppLog.instance.trace(
                        "lib/pages/manuscript_reader.dart::_ManuscriptReaderState.build.closure#3",
                      );
                      return action.request.url?.toString() == _documentUrl &&
                              action.navigationType !=
                                  NavigationType.LINK_ACTIVATED
                          ? NavigationActionPolicy.ALLOW
                          : NavigationActionPolicy.CANCEL;
                    },
                    shouldInterceptRequest: (_, request) async {
                      AppLog.instance.trace(
                        "lib/pages/manuscript_reader.dart::_ManuscriptReaderState.build.closure#4",
                      );

                      _webLog.intercepted(request);
                      if (Platform.isAndroid &&
                          request.isForMainFrame == true &&
                          request.url.toString() == _documentUrl &&
                          mounted) {
                        return WebResourceResponse(
                          statusCode: 200,
                          reasonPhrase: 'OK',
                          contentType: 'text/html',
                          contentEncoding: 'utf-8',
                          headers: const {'Cache-Control': 'no-store'},
                          data: Uint8List.fromList(utf8.encode(_document())),
                        );
                      }
                      if ((Platform.isWindows ||
                              request.isForMainFrame != true) &&
                          _image(request.url.uriValue))
                        return null;
                      return WebResourceResponse(
                        statusCode: 403,
                        reasonPhrase: 'Forbidden',
                        contentType: 'text/plain',
                        headers: const {},
                        data: Uint8List(0),
                      );
                    },
                    onCreateWindow: (_, __) async {
                      AppLog.instance.trace(
                        "lib/pages/manuscript_reader.dart::_ManuscriptReaderState.build.closure#5",
                      );
                      return false;
                    },
                    onPermissionRequest: (_, request) async {
                      AppLog.instance.trace(
                        "lib/pages/manuscript_reader.dart::_ManuscriptReaderState.build.closure#6",
                      );
                      return PermissionResponse(
                        resources: request.resources,
                        action: PermissionResponseAction.DENY,
                      );
                    },
                    onDownloadStartRequest: (controller, _) {
                      AppLog.instance.trace(
                        "lib/pages/manuscript_reader.dart::_ManuscriptReaderState.build.closure#7",
                      );

                      unawaited(controller.stopLoading());
                      _fail();
                    },
                    onReceivedError: (_, request, error) {
                      AppLog.instance.trace(
                        "lib/pages/manuscript_reader.dart::_ManuscriptReaderState.build.closure#8",
                      );

                      _webLog.resourceError(request, error);
                      if (request.isForMainFrame == true) _fail();
                    },
                    onReceivedHttpError: (_, request, response) {
                      AppLog.instance.trace(
                        "lib/pages/manuscript_reader.dart::_ManuscriptReaderState.build.closure#9",
                      );

                      _webLog.httpError(request, response);
                      if (request.isForMainFrame == true) _fail();
                    },
                  ),
                ),
        ),
      ],
    );
  }
}
