// SPDX-License-Identifier: GPL-3.0-only
// Environment/inline bridge structure adapted from PiliPlus
// lib/pages/login/geetest/geetest_webview_dialog.dart, commit
// d9e9626f1a3f89cd9ca85e18f61aaba02634e12a. Official GeeTest v4 only.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path/path.dart' as p;
import 'package:sentry_flutter/sentry_flutter.dart';

import '../services/app_log.dart';
import '../services/webview_log.dart';

void _recordGeetestError(
  String operation,
  Object error,
  StackTrace stack, {
  bool recoverable = false,
}) {
  AppLog.instance.trace("lib/pages/geetest_dialog.dart::_recordGeetestError");

  final log = AppLog.instance;
  if (log.errorWasRecorded(error)) return;
  final expected = error is FormatException;
  log.write(
    recoverable || expected ? AppLogLevel.warning : AppLogLevel.error,
    'geetest_dialog',
    operation,
    error: error,
    stackTrace: stack,
    promptUser: !recoverable && !expected,
  );
}

/// A new private profile per challenge; never receives application credentials.
class GeetestDialog extends StatefulWidget {
  const GeetestDialog({
    required this.captchaId,
    required this.dataDirectory,
    super.key,
  });

  final String captchaId;
  final String dataDirectory;

  static Future<Map<String, dynamic>?> show(
    BuildContext context, {
    required String captchaId,
    required String dataDirectory,
  }) {
    AppLog.instance.trace("lib/pages/geetest_dialog.dart::GeetestDialog.show");
    return showDialog<Map<String, dynamic>>(
      context: context,
      barrierDismissible: false,
      routeSettings: const RouteSettings(name: '/dialog/geetest'),
      builder: (_) {
        AppLog.instance.trace(
          "lib/pages/geetest_dialog.dart::GeetestDialog.show.closure#1",
        );
        return GeetestDialog(
          captchaId: captchaId,
          dataDirectory: dataDirectory,
        );
      },
    );
  }

  @override
  State<GeetestDialog> createState() {
    AppLog.instance.trace(
      "lib/pages/geetest_dialog.dart::GeetestDialog.createState",
    );
    return _GeetestDialogState();
  }
}

class _GeetestDialogState extends State<GeetestDialog> {
  static const _installer =
      'https://developer.microsoft.com/microsoft-edge/webview2/';
  final _nonce = _newNonce();
  late final String _documentUrl = Platform.isAndroid
      ? 'https://appassets.androidplatform.net/xmplus-captcha/$_nonce/index.html'
      : 'about:blank';
  WebViewEnvironment? _environment;
  final _webLog = WebViewLog('geetest');
  Directory? _profile;
  Timer? _timeout;
  bool _ready = false, _accepting = false, _finished = false;
  String? _error;
  bool _runtimeMissing = false;
  String _stage = '运行时检测';

  static String _newNonce() {
    AppLog.instance.trace(
      "lib/pages/geetest_dialog.dart::_GeetestDialogState._newNonce",
    );

    final random = Random.secure();
    return base64UrlEncode(
      List<int>.generate(32, (_) {
        AppLog.instance.trace(
          "lib/pages/geetest_dialog.dart::_GeetestDialogState._newNonce.closure#1",
        );
        return random.nextInt(256);
      }),
    );
  }

  void _invalidate() {
    AppLog.instance.trace(
      "lib/pages/geetest_dialog.dart::_GeetestDialogState._invalidate",
    );

    _finished = true;
    _accepting = false;
    _timeout?.cancel();
  }

  @override
  void initState() {
    AppLog.instance.trace(
      "lib/pages/geetest_dialog.dart::_GeetestDialogState.initState",
    );

    super.initState();
    _prepare();
  }

  Future<void> _prepare() {
    AppLog.instance.trace(
      "lib/pages/geetest_dialog.dart::_GeetestDialogState._prepare",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/pages/geetest_dialog.dart::_GeetestDialogState._prepare.closure#1",
      );

      try {
        if (!RegExp(r'^[a-fA-F0-9]{32}$').hasMatch(widget.captchaId)) {
          throw const FormatException();
        }
        // Plugin debug output can include challenge responses and request URLs.
        PlatformInAppWebViewController.debugLoggingSettings.enabled = false;
        if (Platform.isWindows) {
          final version = await WebViewEnvironment.getAvailableVersion();
          if (!mounted || _finished) return;
          if (version == null || version.isEmpty) {
            _runtimeMissing = true;
            _fail('未检测到 WebView2 运行时。可安装微软官方运行时后重试，或返回 Cookie 登录。');
            return;
          }
          _stage = '验证资料目录';
          final base = await Directory(p.join(widget.dataDirectory, 'captcha'))
              .create(recursive: true);
          final profile = await base.createTemp('session-');
          _profile = profile;
          if (!mounted || _finished) {
            await _deleteProfile(profile);
            return;
          }
          _stage = 'WebView2 环境创建';
          final environment = await WebViewEnvironment.create(
            settings: WebViewEnvironmentSettings(
              userDataFolder: profile.path,
              allowSingleSignOnUsingOSPrimaryAccount: false,
              language: 'zh-CN',
            ),
          );
          if (!mounted || _finished) {
            try {
              await environment.dispose();
            } catch (error, stack) {
              _recordGeetestError(
                'Captcha environment disposal failed',
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
          _fail('此平台暂不能显示安全验证，请返回导入登录信息。');
          return;
        }
        if (!mounted || _finished) return;
        setState(() {
          AppLog.instance.trace(
            "lib/pages/geetest_dialog.dart::_GeetestDialogState._prepare.closure#1.closure#1",
          );
          _ready = true;
        });
        _timeout = Timer(const Duration(seconds: 45), () {
          AppLog.instance.trace(
            "lib/pages/geetest_dialog.dart::_GeetestDialogState._prepare.closure#1.closure#2",
          );
          _fail('安全验证加载超时，请关闭后重试，或使用登录信息导入。');
        });
      } catch (error, stack) {
        _recordGeetestError('Captcha setup failed', error, stack);
        _failStage(error);
        final profile = _profile;
        if (profile != null && (!mounted || _finished)) {
          await _deleteProfile(profile);
        }
      }
    });
  }

  void _fail(String message) {
    AppLog.instance.trace(
      "lib/pages/geetest_dialog.dart::_GeetestDialogState._fail",
    );

    _accepting = false;
    _timeout?.cancel();
    if (mounted && !_finished)
      setState(() {
        AppLog.instance.trace(
          "lib/pages/geetest_dialog.dart::_GeetestDialogState._fail.closure#1",
        );
        _error = message;
      });
  }

  void _failStage(Object error) {
    AppLog.instance.trace(
      "lib/pages/geetest_dialog.dart::_GeetestDialogState._failStage",
    );

    final code =
        error is PlatformException &&
            RegExp(r'^-?[0-9]{1,12}$').hasMatch(error.code)
        ? '（错误码 ${error.code}）'
        : '';
    _fail('$_stage失败$code。请关闭后重试，或返回 Cookie 登录。');
  }

  static Future<void> _deleteProfile(Directory profile) {
    AppLog.instance.trace(
      "lib/pages/geetest_dialog.dart::_GeetestDialogState._deleteProfile",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/pages/geetest_dialog.dart::_GeetestDialogState._deleteProfile.closure#1",
      );

      // WebView2 may still hold the directory briefly; it contains only this
      // challenge's isolated private profile, never an account credential store.
      try {
        if (await profile.exists()) await profile.delete(recursive: true);
      } on FileSystemException catch (error, stack) {
        _recordGeetestError(
          'Captcha profile cleanup failed',
          error,
          stack,
          recoverable: true,
        );
        /* The runtime still owns its temporary profile. */
      }
    });
  }

  @override
  void dispose() {
    AppLog.instance.trace(
      "lib/pages/geetest_dialog.dart::_GeetestDialogState.dispose",
    );

    _invalidate();
    final environment = _environment, profile = _profile;
    unawaited(
      AppLog.instance.runWithErrorScope(() async {
        AppLog.instance.trace(
          "lib/pages/geetest_dialog.dart::_GeetestDialogState.dispose.closure#1",
        );

        try {
          await _webLog.dispose();
          await environment?.dispose();
        } catch (error, stack) {
          _recordGeetestError(
            'Captcha environment disposal failed',
            error,
            stack,
            recoverable: true,
          );
          /* Already disposed. */
        }
        if (profile != null) await _deleteProfile(profile);
      }),
    );
    super.dispose();
  }

  bool _allowedResource(Uri uri) {
    AppLog.instance.trace(
      "lib/pages/geetest_dialog.dart::_GeetestDialogState._allowedResource",
    );
    return uri.scheme == 'https' &&
        uri.userInfo.isEmpty &&
        uri.port == 443 &&
        ['geetest.com', 'geevisit.com', 'gsensebot.com'].any((host) {
          AppLog.instance.trace(
            "lib/pages/geetest_dialog.dart::_GeetestDialogState._allowedResource.closure#1",
          );
          return uri.host == host || uri.host.endsWith('.$host');
        });
  }

  Map<String, dynamic>? _parseGeetestResult(Object? raw) {
    AppLog.instance.trace(
      "lib/pages/geetest_dialog.dart::_GeetestDialogState._parseGeetestResult",
    );

    const fields = [
      'captcha_id',
      'lot_number',
      'pass_token',
      'gen_time',
      'captcha_output',
    ];
    if (raw is! Map ||
        raw.length != fields.length ||
        fields.any((key) {
          AppLog.instance.trace(
            "lib/pages/geetest_dialog.dart::_GeetestDialogState._parseGeetestResult.closure#1",
          );
          return raw[key] is! String ||
              !RegExp(r'^[\x21-\x7e]{1,8192}$').hasMatch(raw[key] as String);
        }) ||
        raw['captcha_id'] != widget.captchaId) {
      return null;
    }
    return {for (final key in fields) key: raw[key]};
  }

  String _html() {
    AppLog.instance.trace(
      "lib/pages/geetest_dialog.dart::_GeetestDialogState._html",
    );

    final id = jsonEncode(widget.captchaId);
    return '''<!doctype html><html><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="referrer" content="no-referrer">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline' https://*.geetest.com https://*.geevisit.com https://*.gsensebot.com; connect-src https://*.geetest.com https://*.geevisit.com https://*.gsensebot.com; img-src data: blob: https://*.geetest.com https://*.geevisit.com https://*.gsensebot.com; style-src 'unsafe-inline' https://*.geetest.com; font-src data: https://*.geetest.com; frame-src https://*.geetest.com https://*.geevisit.com https://*.gsensebot.com; object-src 'none'; base-uri 'none'; form-action 'none'">
<title>XMPlus 安全验证</title>
<style>body{font:16px sans-serif;text-align:center;padding:20px}button{font:inherit;padding:12px}</style>
</head><body><p id="status">正在加载安全验证…</p><button id="verify" hidden>开始验证</button>
<script>
(() => {
  const nonce=${jsonEncode(_nonce)};
  const emit=(kind,value)=>{if(window===window.top) window.flutter_inappwebview.callHandler('xmlyCaptcha',nonce,kind,value);};
  const fail=()=>{document.getElementById('status').textContent='安全验证加载失败，请关闭后重试';emit('error',null);};
  const start=()=>{
    if(typeof initGeetest4!=='function'){fail();return;}
    initGeetest4({captchaId:$id,product:'bind',language:'zho',protocol:'https://',onError:fail,offlineCb:fail},captcha=>{
      captcha.onReady(()=>{
        document.getElementById('status').textContent='请完成安全验证';
        const button=document.getElementById('verify');button.hidden=false;
        button.onclick=()=>captcha.showCaptcha();emit('ready',null);
        captcha.showCaptcha();
      }).onSuccess(()=>{
        const v=captcha.getValidate();
        if(!v){fail();return;}
        const out={captcha_id:$id};
        ['lot_number','pass_token','gen_time','captcha_output'].forEach(k=>out[k]=v[k]);
        emit('success',out);
      }).onError(fail).onClose(()=>emit('close',null));
    });
  };
  const load=()=>{const script=document.createElement('script');script.src='https://static.geetest.com/v4/gt4.js';script.onload=start;script.onerror=fail;document.head.appendChild(script);};
  if(window.flutter_inappwebview?.callHandler){load();}
  else{window.addEventListener('flutterInAppWebViewPlatformReady',load,{once:true});}
})();
</script></body></html>''';
  }

  Future<void> _created(InAppWebViewController controller) {
    AppLog.instance.trace(
      "lib/pages/geetest_dialog.dart::_GeetestDialogState._created",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/pages/geetest_dialog.dart::_GeetestDialogState._created.closure#1",
      );

      try {
        if (Platform.isWindows) {
          _stage = '下载安全策略初始化';
          await _webLog.denyDownloads(controller);
        }
        await _webLog.observe(controller);
        if (!mounted || _finished || _error != null) return;
        controller.addJavaScriptHandler(
          handlerName: 'xmlyCaptcha',
          callback: (args) async {
            AppLog.instance.trace(
              "lib/pages/geetest_dialog.dart::_GeetestDialogState._created.closure#1.closure#1",
            );

            if (!_accepting ||
                !mounted ||
                _finished ||
                args.length != 3 ||
                args[0] != _nonce ||
                (await controller.getUrl())?.toString() != _documentUrl)
              return null;
            if (!mounted || !_accepting || _finished) return null;
            switch (args[1]) {
              case 'ready':
                _timeout?.cancel();
                break;
              case 'success':
                final result = _parseGeetestResult(args[2]);
                if (result == null) {
                  _fail('安全验证结果无效，请关闭后重新验证。');
                  return null;
                }
                _finished = true;
                _accepting = false;
                Navigator.of(context).pop(result);
                break;
              case 'error':
                _fail('安全验证未完成，请关闭后重试，或使用登录信息导入。');
                break;
              case 'close':
                _finished = true;
                _accepting = false;
                Navigator.of(context).pop();
                break;
            }
            return null;
          },
        );
        _accepting = true;
        _stage = '验证页面加载';
        if (Platform.isAndroid) {
          await controller.loadUrl(
            urlRequest: URLRequest(url: WebUri(_documentUrl)),
          );
        } else {
          await controller.loadData(
            data: _html(),
            baseUrl: WebUri(_documentUrl),
          );
        }
      } catch (error, stack) {
        _recordGeetestError('Captcha controller setup failed', error, stack);
        _failStage(error);
      }
    });
  }

  Future<void> _openInstaller() {
    AppLog.instance.trace(
      "lib/pages/geetest_dialog.dart::_GeetestDialogState._openInstaller",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/pages/geetest_dialog.dart::_GeetestDialogState._openInstaller.closure#1",
      );

      try {
        await InAppBrowser.openWithSystemBrowser(url: WebUri(_installer));
      } catch (error, stack) {
        _recordGeetestError(
          'Browser launch failed',
          error,
          stack,
          recoverable: true,
        );
        _fail('无法打开浏览器。请访问 $_installer 安装官方运行时，或返回导入登录信息。');
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace(
      "lib/pages/geetest_dialog.dart::_GeetestDialogState.build",
    );
    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        AppLog.instance.trace(
          "lib/pages/geetest_dialog.dart::_GeetestDialogState.build.closure#1",
        );

        if (didPop) _invalidate();
      },
      child: AlertDialog(
        insetPadding: const EdgeInsets.all(12),
        contentPadding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        title: const Text('安全验证', maxLines: 1, overflow: TextOverflow.ellipsis),
        content: SizedBox(
          width: 440,
          height: min(440.0, MediaQuery.sizeOf(context).height * 0.6),
          child: _error != null
              ? SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_error!),
                      if (Platform.isWindows && _runtimeMissing) ...[
                        const SizedBox(height: 16),
                        TextButton.icon(
                          onPressed: _openInstaller,
                          icon: const Icon(Icons.open_in_new),
                          label: const Text('微软 WebView2 下载页'),
                        ),
                      ],
                      const SizedBox(height: 16),
                      const Text('关闭此窗口后，仍可选择“导入登录信息”。'),
                    ],
                  ),
                )
              : !_ready
              ? const Center(child: CircularProgressIndicator())
              : SentryMask(
                  InAppWebView(
                    webViewEnvironment: _environment,
                    initialSettings: InAppWebViewSettings(
                      incognito: true,
                      javaScriptEnabled: true,
                      isInspectable: false,
                      disableContextMenu: true,
                      useShouldOverrideUrlLoading: true,
                      useShouldInterceptRequest: true,
                      useOnLoadResource: Platform.isAndroid,
                      supportMultipleWindows: false,
                      javaScriptCanOpenWindowsAutomatically: false,
                      allowFileAccess: false,
                      allowContentAccess: false,
                      allowFileAccessFromFileURLs: false,
                      allowUniversalAccessFromFileURLs: false,
                      thirdPartyCookiesEnabled: false,
                      geolocationEnabled: false,
                      saveFormData: false,
                      mediaPlaybackRequiresUserGesture: true,
                      useOnDownloadStart: true,
                    ),
                    onWebViewCreated: _created,
                    shouldOverrideUrlLoading: (_, action) async {
                      AppLog.instance.trace(
                        "lib/pages/geetest_dialog.dart::_GeetestDialogState.build.closure#2",
                      );

                      if (!action.isForMainFrame) {
                        return NavigationActionPolicy.ALLOW;
                      }
                      final url = action.request.url?.toString();
                      return url == 'about:blank' ||
                              (Platform.isAndroid &&
                                  _accepting &&
                                  !_finished &&
                                  _error == null &&
                                  url == _documentUrl)
                          ? NavigationActionPolicy.ALLOW
                          : NavigationActionPolicy.CANCEL;
                    },
                    shouldInterceptRequest: (_, request) async {
                      AppLog.instance.trace(
                        "lib/pages/geetest_dialog.dart::_GeetestDialogState.build.closure#3",
                      );

                      _webLog.intercepted(request);
                      // This challenge's main document is local, never fetched remotely.
                      if (Platform.isAndroid &&
                          request.isForMainFrame == true &&
                          mounted &&
                          _accepting &&
                          !_finished &&
                          _error == null &&
                          request.url.toString() == _documentUrl) {
                        return WebResourceResponse(
                          statusCode: 200,
                          reasonPhrase: 'OK',
                          contentType: 'text/html',
                          contentEncoding: 'utf-8',
                          headers: const {'Cache-Control': 'no-store'},
                          data: Uint8List.fromList(utf8.encode(_html())),
                        );
                      }
                      // Windows reports every resource as a main-frame request;
                      // top-level navigation is guarded separately above.
                      if ((Platform.isWindows ||
                              request.isForMainFrame != true) &&
                          _allowedResource(request.url.uriValue))
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
                        "lib/pages/geetest_dialog.dart::_GeetestDialogState.build.closure#4",
                      );
                      return false;
                    },
                    onPermissionRequest: (_, request) async {
                      AppLog.instance.trace(
                        "lib/pages/geetest_dialog.dart::_GeetestDialogState.build.closure#5",
                      );
                      return PermissionResponse(
                        resources: request.resources,
                        action: PermissionResponseAction.DENY,
                      );
                    },
                    onDownloadStartRequest: (controller, _) {
                      AppLog.instance.trace(
                        "lib/pages/geetest_dialog.dart::_GeetestDialogState.build.closure#6",
                      );

                      unawaited(controller.stopLoading());
                      _fail('安全验证不允许下载文件。');
                    },
                    onLoadResource: (_, resource) {
                      AppLog.instance.trace(
                        "lib/pages/geetest_dialog.dart::_GeetestDialogState.build.closure#7",
                      );
                      _webLog.loaded(resource);
                    },
                    onReceivedError: (_, request, error) {
                      AppLog.instance.trace(
                        "lib/pages/geetest_dialog.dart::_GeetestDialogState.build.closure#8",
                      );

                      _webLog.resourceError(request, error);
                      if (request.isForMainFrame == true)
                        _fail('安全验证加载失败，请关闭后重试。');
                    },
                    onReceivedHttpError: (controller, request, response) {
                      AppLog.instance.trace(
                        "lib/pages/geetest_dialog.dart::_GeetestDialogState.build.closure#9",
                      );

                      _webLog.httpError(request, response);
                      if (request.isForMainFrame == true) {
                        unawaited(controller.stopLoading());
                        _fail('安全验证页面加载失败，请关闭后重试。');
                      }
                    },
                  ),
                ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              AppLog.instance.trace(
                "lib/pages/geetest_dialog.dart::_GeetestDialogState.build.closure#10",
              );

              _invalidate();
              Navigator.of(context).pop();
            },
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }
}
