import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/xmly_client.dart';
import '../api/xmly_profile.dart';
import '../api/xmly_login.dart';
import '../common/widgets/adaptive_text.dart';
import '../common/widgets/confirmation_dialog.dart';
import '../common/widgets/logged_network_image.dart';
import '../api/xmly_rewards.dart';
import '../models/xmly_models.dart';
import '../services/account_service.dart';
import '../services/app_log.dart';
import '../storage/app_storage.dart';
import 'geetest_dialog.dart';

// Errors at this surface are deliberately mapped by code, never interpolated
// from raw inputs, transport exceptions, or upstream response messages.
String _accountError(Object error) {
  AppLog.instance.trace("lib/pages/account_page.dart::_accountError");

  final code = error is XmlyException
      ? error.code
      : error is AccountException
      ? error.code
      : '';
  if (code == 'rate_limited' || code == 'sms_cooldown') {
    final retry = error is XmlyException ? error.retryAfter : null;
    return retry != null && retry.inSeconds > 0
        ? '请求过于频繁，请在 ${retry.inSeconds} 秒后重试。'
        : '请求过于频繁，请稍后重试。';
  }
  return switch (code) {
    'invalid_credentials' => '登录信息格式不正确，请检查令牌和原设备 ID。',
    'login_expired' ||
    'login_required' ||
    'auth_required' => '登录信息无效或已过期，请重新登录。',
    'invalid_mobile' => '请输入有效手机号（6–18 位数字，可含国际区号 +）。',
    'invalid_code' => '短信验证码须为 4–8 位数字。',
    'sms_verify_rejected' => '验证码未通过，请检查后重试；最多尝试 5 次。',
    'sms_send_rejected' => '短信发送未成功，请在官方 App 检查后再试。',
    'quick_login_rejected' => '登录未成功，请重新进行短信验证。',
    'invalid_captcha' || 'captcha_reused' => '安全验证无效或已使用，请重新验证。',
    'challenge_expired' || 'challenge_invalid' => '短信验证已过期或失效，请重新发送。',
    'network' || 'network_error' || 'http_error' => '连接失败或超时，请检查网络。短信不会自动重发。',
    'uncertain' => '请求结果未知，请先在官方 App 核对，不要重复领取。',
    'reward_rejected' => '领取未成功，请在官方 App 检查。',
    'reward_paused' => '领取已暂停，请先在官方 App 核对，再选择恢复领取。',
    'unsettled' || 'usage_uncertain' => '听时暂时无法确认，正在自动核对，请稍后再试。',
    'integration_required' => '暂时无法安全切换账号，原账号已保留。',
    'credential_write_failed' => '安全凭据保存失败，原账号已保留。',
    'credential_mismatch' => '请导入该账号的 Cookie，并保留原设备 ID；其他账号不能恢复此记录。',
    'credential_read_failed' ||
    'credential_missing' ||
    'credential_invalid' => '无法读取登录信息，请重新导入原账号。',
    'paused' => '账号正在切换，请稍后重试。',
    _ => '操作未完成，原资料已保留。请检查网络或稍后重试。',
  };
}

void _recordAccountError(Object error, StackTrace stack) {
  AppLog.instance.trace("lib/pages/account_page.dart::_recordAccountError");

  final code = error is XmlyException
      ? error.code
      : error is AccountException
      ? error.code
      : null;
  if ((error is StorageException &&
          const {'too_large', 'secret_in_state'}.contains(error.code)) ||
      const {
        'invalid_credentials',
        'invalid_mobile',
        'invalid_code',
        'invalid_captcha',
        'captcha_reused',
        'challenge_expired',
        'challenge_invalid',
        'sms_cooldown',
        'not_loaded',
        'quota_invalid',
        'archive_invalid',
        'sms_verify_rejected',
        'sms_send_rejected',
        'quick_login_rejected',
        'login_expired',
        'login_required',
        'auth_required',
        'rate_limited',
        'uncertain',
        'reward_rejected',
        'reward_paused',
        'unsettled',
        'usage_uncertain',
        'credential_mismatch',
        'credential_missing',
        'missing',
        'paused',
        'closed',
        'request_cancelled',
        'client_closed',
      }.contains(code) ||
      AppLog.instance.errorWasRecorded(error))
    return;
  AppLog.instance.write(
    AppLogLevel.error,
    'account',
    'Account action failed',
    error: error,
    stackTrace: stack,
    promptUser: true,
  );
}

Future<bool> _confirm(
  BuildContext context,
  String title,
  String message, {
  String action = '确认',
}) {
  AppLog.instance.trace("lib/pages/account_page.dart::_confirm");
  return showConfirmationDialog(
    context,
    Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
    content: SingleChildScrollView(child: Text(message)),
    confirmLabel: action,
  );
}

class AccountPage extends StatefulWidget {
  const AccountPage({
    required this.storage,
    required this.accounts,
    this.onChanged,
    this.updates,
    super.key,
  });

  final AppStorage storage;
  final AccountService accounts;
  final VoidCallback? onChanged;
  final Listenable? updates;

  @override
  State<AccountPage> createState() {
    AppLog.instance.trace(
      "lib/pages/account_page.dart::AccountPage.createState",
    );
    return _AccountPageState();
  }
}

class _AccountPageState extends State<AccountPage> {
  XmlyLogin get _login {
    AppLog.instance.trace(
      "lib/pages/account_page.dart::_AccountPageState._login.get",
    );
    return widget.accounts.smsLogin;
  }

  bool _busy = false;
  String? _error;
  late String _viewKey;
  final _profiles = <String, PublicProfile>{};
  final _profileClients = <String, XmlyClient>{};
  final _profileRequests = <String, XmlyClient>{};

  bool get _autoClaim {
    AppLog.instance.trace(
      "lib/pages/account_page.dart::_AccountPageState._autoClaim.get",
    );
    return (widget.storage.state['settings'] as Map)['autoClaim'] == true;
  }

  String _accountViewKey() {
    AppLog.instance.trace(
      "lib/pages/account_page.dart::_AccountPageState._accountViewKey",
    );

    final records = widget.storage.state['accounts'] as Map;
    return jsonEncode([
      widget.accounts.primaryAccountId,
      widget.accounts.activeClient?.identity,
      widget.accounts.accountIds,
      _autoClaim,
      for (final identity in widget.accounts.accountIds)
        [
          identity,
          if (records[identity] case final Map record)
            for (final field in ['uid', 'deviceHint', 'rewardPaused', 'quota'])
              record[field],
        ],
    ]);
  }

  @override
  void initState() {
    AppLog.instance.trace(
      "lib/pages/account_page.dart::_AccountPageState.initState",
    );

    super.initState();
    _viewKey = _accountViewKey();
    widget.updates?.addListener(_changed);
    _refreshProfiles();
  }

  @override
  void didUpdateWidget(covariant AccountPage oldWidget) {
    AppLog.instance.trace(
      "lib/pages/account_page.dart::_AccountPageState.didUpdateWidget",
    );

    super.didUpdateWidget(oldWidget);
    if (oldWidget.updates != widget.updates) {
      oldWidget.updates?.removeListener(_changed);
      widget.updates?.addListener(_changed);
    }
    if (oldWidget.accounts != widget.accounts ||
        oldWidget.storage != widget.storage) {
      _profiles.clear();
      _profileClients.clear();
      _profileRequests.clear();
    }
    _refreshProfiles();
    _viewKey = _accountViewKey();
  }

  void _changed() {
    AppLog.instance.trace(
      "lib/pages/account_page.dart::_AccountPageState._changed",
    );

    if (!mounted) return;
    _refreshProfiles();
    final key = _accountViewKey();
    if (key != _viewKey)
      setState(() {
        AppLog.instance.trace(
          "lib/pages/account_page.dart::_AccountPageState._changed.closure#1",
        );
        _viewKey = key;
      });
  }

  void _refreshProfiles({String? identity}) {
    AppLog.instance.trace(
      'lib/pages/account_page.dart::_AccountPageState._refreshProfiles',
    );
    if (!mounted) return;
    final accounts = widget.accounts;
    final ids = accounts.accountIds;
    final visibleIds = {...ids, ...accounts.missingCredentialAccountIds};
    _profiles.removeWhere((id, _) {
      AppLog.instance.trace(
        'lib/pages/account_page.dart::_AccountPageState._refreshProfiles.closure#1',
      );
      return !visibleIds.contains(id);
    });
    _profileClients.removeWhere((id, _) {
      AppLog.instance.trace(
        'lib/pages/account_page.dart::_AccountPageState._refreshProfiles.closure#2',
      );
      return !ids.contains(id);
    });
    _profileRequests.removeWhere((id, _) {
      AppLog.instance.trace(
        'lib/pages/account_page.dart::_AccountPageState._refreshProfiles.closure#3',
      );
      return !ids.contains(id);
    });
    final records = widget.storage.state['accounts'] as Map;
    for (final id in ids) {
      final record = records[id];
      final uid = record is Map ? record['uid'] : null;
      if (uid is! String) continue;
      final client = accounts.clientFor(id);
      if (identical(_profileClients[id], client) &&
          (id != identity || identical(_profileRequests[id], client))) {
        continue;
      }
      _profileClients[id] = client;
      _profileRequests[id] = client;
      unawaited(_loadProfile(id, uid, client, accounts));
    }
  }

  Future<void> _loadProfile(
    String identity,
    String uid,
    XmlyClient client,
    AccountService accounts,
  ) async {
    AppLog.instance.trace(
      'lib/pages/account_page.dart::_AccountPageState._loadProfile',
    );
    try {
      final profile = await XmlyProfile(client).load(uid);
      if (!mounted ||
          widget.accounts != accounts ||
          !identical(_profileRequests[identity], client)) {
        return;
      }
      final record = (widget.storage.state['accounts'] as Map)[identity];
      if (record is! Map || record['uid'] != profile.uid) return;
      setState(() {
        AppLog.instance.trace(
          'lib/pages/account_page.dart::_AccountPageState._loadProfile.closure#1',
        );
        final previous = _profiles[identity];
        _profiles[identity] = PublicProfile(
          uid: profile.uid,
          nickname: profile.nickname ?? previous?.nickname,
          avatarUrl: profile.avatarUrl ?? previous?.avatarUrl,
        );
      });
    } catch (error, stack) {
      if (!AppLog.instance.errorWasRecorded(error)) {
        AppLog.instance.write(
          AppLogLevel.warning,
          'account',
          'Optional public account profile unavailable',
          data: {'uid': uid},
          error: error,
          stackTrace: stack,
          promptUser: false,
        );
      }
    } finally {
      if (identical(_profileRequests[identity], client)) {
        _profileRequests.remove(identity);
      }
    }
  }

  @override
  void dispose() {
    AppLog.instance.trace(
      "lib/pages/account_page.dart::_AccountPageState.dispose",
    );

    widget.updates?.removeListener(_changed);
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) {
    AppLog.instance.trace(
      "lib/pages/account_page.dart::_AccountPageState._run",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/pages/account_page.dart::_AccountPageState._run.closure#1",
      );

      if (_busy) return;
      setState(() {
        AppLog.instance.trace(
          "lib/pages/account_page.dart::_AccountPageState._run.closure#1.closure#1",
        );

        _busy = true;
        _error = null;
      });
      try {
        await action();
        _refreshProfiles();
        widget.onChanged?.call();
      } catch (error, stack) {
        _recordAccountError(error, stack);
        if (mounted)
          setState(() {
            AppLog.instance.trace(
              "lib/pages/account_page.dart::_AccountPageState._run.closure#1.closure#2",
            );
            _error = _accountError(error);
          });
      } finally {
        if (mounted)
          setState(() {
            AppLog.instance.trace(
              "lib/pages/account_page.dart::_AccountPageState._run.closure#1.closure#3",
            );
            _busy = false;
          });
      }
    });
  }

  Future<void> _openImport({String? recoveryIdentity}) async {
    AppLog.instance.trace(
      "lib/pages/account_page.dart::_AccountPageState._openImport",
    );

    final onChanged = widget.onChanged;
    final changed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) {
        AppLog.instance.trace(
          "lib/pages/account_page.dart::_AccountPageState._openImport.closure#1",
        );
        return _CredentialDialog(
          accounts: widget.accounts,
          recoveryIdentity: recoveryIdentity,
        );
      },
    );
    if (changed != true) return;
    onChanged?.call();
    if (mounted) {
      _refreshProfiles();
      setState(() {
        AppLog.instance.trace(
          "lib/pages/account_page.dart::_AccountPageState._openImport.closure#2",
        );
        _error = null;
      });
    }
  }

  Future<void> _openSms() async {
    AppLog.instance.trace(
      "lib/pages/account_page.dart::_AccountPageState._openSms",
    );

    final onChanged = widget.onChanged;
    final changed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) {
        AppLog.instance.trace(
          "lib/pages/account_page.dart::_AccountPageState._openSms.closure#1",
        );
        return _SmsLoginDialog(
          accounts: widget.accounts,
          dataDirectory: widget.storage.directory,
          login: _login,
        );
      },
    );
    if (changed != true) return;
    onChanged?.call();
    if (mounted) {
      _refreshProfiles();
      setState(() {
        AppLog.instance.trace(
          "lib/pages/account_page.dart::_AccountPageState._openSms.closure#2",
        );
        _error = null;
      });
    }
  }

  Future<void> _storeQuota(String identity, Quota quota) {
    AppLog.instance.trace(
      "lib/pages/account_page.dart::_AccountPageState._storeQuota",
    );
    return widget.storage.transaction((state) {
      AppLog.instance.trace(
        "lib/pages/account_page.dart::_AccountPageState._storeQuota.closure#1",
      );

      final record = (state['accounts'] as Map)[identity];
      if (record is Map && record['credentialRef'] is String)
        record['quota'] = quota.toJson();
    });
  }

  Future<void> _quota(String identity) {
    AppLog.instance.trace(
      "lib/pages/account_page.dart::_AccountPageState._quota",
    );
    return _run(() async {
      AppLog.instance.trace(
        "lib/pages/account_page.dart::_AccountPageState._quota.closure#1",
      );

      final quota = await widget.accounts.runWithAccount(identity, (client) {
        AppLog.instance.trace(
          "lib/pages/account_page.dart::_AccountPageState._quota.closure#1.closure#1",
        );
        return client.queryQuota();
      });
      await _storeQuota(identity, quota);
      _refreshProfiles(identity: identity);
    });
  }

  Future<void> _claim(String identity, String uid) async {
    AppLog.instance.trace(
      "lib/pages/account_page.dart::_AccountPageState._claim",
    );

    if (!await _confirm(
          context,
          '领取听时',
          '为账号 $uid 发送一次领取请求？领取结果以官方 App 为准。',
          action: '领取一次',
        ) ||
        !mounted)
      return;
    await _run(() async {
      AppLog.instance.trace(
        "lib/pages/account_page.dart::_AccountPageState._claim.closure#1",
      );

      try {
        final quota = await widget.accounts.runWithAccount(identity, (
          client,
        ) async {
          AppLog.instance.trace(
            "lib/pages/account_page.dart::_AccountPageState._claim.closure#1.closure#1",
          );

          final record = (widget.storage.state['accounts'] as Map)[identity];
          if (record is Map && record['rewardPaused'] == true) {
            throw const AccountException('reward_paused', '领取已暂停');
          }
          // Manual issuance is a single request, not the automatic refill loop.
          await XmlyRewards(client).claim({});
          return client.queryQuota();
        });
        await _storeQuota(identity, quota);
      } catch (error, stack) {
        _recordAccountError(error, stack);
        await widget.storage.transaction((state) {
          AppLog.instance.trace(
            "lib/pages/account_page.dart::_AccountPageState._claim.closure#1.closure#2",
          );

          final record = (state['accounts'] as Map)[identity];
          if (record is Map) record['rewardPaused'] = true;
        });
        rethrow;
      }
    });
  }

  Future<void> _resumeRewards(String identity, String uid) async {
    AppLog.instance.trace(
      "lib/pages/account_page.dart::_AccountPageState._resumeRewards",
    );

    if (!await _confirm(
          context,
          '恢复领取',
          '请先在官方 App 核对账号 $uid 上一次领取的结果。确认已核对，并允许之后重新领取？',
          action: '已核对，恢复',
        ) ||
        !mounted)
      return;
    await _run(() {
      AppLog.instance.trace(
        "lib/pages/account_page.dart::_AccountPageState._resumeRewards.closure#1",
      );
      return widget.storage.transaction((state) {
        AppLog.instance.trace(
          "lib/pages/account_page.dart::_AccountPageState._resumeRewards.closure#1.closure#1",
        );

        final record = (state['accounts'] as Map)[identity];
        if (record is Map) record['rewardPaused'] = false;
      });
    });
  }

  Future<void> _toggleAuto(bool value) async {
    AppLog.instance.trace(
      "lib/pages/account_page.dart::_AccountPageState._toggleAuto",
    );

    if (value &&
        (!await _confirm(
              context,
              '开启自动领取',
              '对所有已登录账号生效：可用听时不足 2 小时时尝试领取至 4 小时。请求失败会暂停该账号的自动领取，需人工核对后恢复。',
              action: '开启',
            ) ||
            !mounted))
      return;
    await _run(() {
      AppLog.instance.trace(
        "lib/pages/account_page.dart::_AccountPageState._toggleAuto.closure#1",
      );
      return widget.storage.transaction((state) {
        AppLog.instance.trace(
          "lib/pages/account_page.dart::_AccountPageState._toggleAuto.closure#1.closure#1",
        );

        (state['settings'] as Map)['autoClaim'] = value;
      });
    });
  }

  Future<void> _remove(String identity, String uid) async {
    AppLog.instance.trace(
      "lib/pages/account_page.dart::_AccountPageState._remove",
    );

    if (!await _confirm(
          context,
          '移除此账号',
          '移除账号 $uid 的登录信息？已有扣时记录会保留。移除主账号时会优先选取剩余可用账号作为主账号。',
          action: '移除',
        ) ||
        !mounted)
      return;
    await _run(() {
      AppLog.instance.trace(
        "lib/pages/account_page.dart::_AccountPageState._remove.closure#1",
      );
      return widget.accounts.remove(identity);
    });
  }

  Widget _account(String identity, Map record) {
    AppLog.instance.trace(
      "lib/pages/account_page.dart::_AccountPageState._account",
    );

    final uid =
        record['uid'] is String &&
            RegExp(r'^[0-9]{1,20}$').hasMatch(record['uid'])
        ? record['uid'] as String
        : '未知';
    final rawHint = record['deviceHint'];
    final hint =
        rawHint is String &&
            RegExp(r'^(?:\*{4}|…[A-Za-z0-9_.:\-]{4})$').hasMatch(rawHint)
        ? rawHint
        : '****';
    final primary = widget.accounts.primaryAccountId == identity;
    final missing = widget.accounts.missingCredentialAccountIds.contains(
      identity,
    );
    final active = widget.accounts.activeClient?.identity == identity;
    final paused = record['rewardPaused'] == true;
    final quota = record['quota'];
    Quota? verified;
    try {
      if (quota is Map)
        verified = Quota.fromJson(Map<String, dynamic>.from(quota));
    } catch (error, stack) {
      AppLog.instance.write(
        AppLogLevel.warning,
        'account',
        'Stored quota unavailable',
        error: error,
        stackTrace: stack,
        promptUser: false,
      );
    }
    final remaining = verified?.remainingSeconds;
    final checked = verified?.checkedAt.toLocal();
    final avatar = _profiles[identity]?.avatarUrl;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: ClipOval(
                    child: SizedBox.square(
                      dimension: 40,
                      child: avatar == null
                          ? const Icon(Icons.account_circle_outlined, size: 40)
                          : Image(
                              image: LoggedNetworkImage(avatar.toString()),
                              fit: BoxFit.cover,
                              errorBuilder: (context, error, stack) {
                                AppLog.instance.trace(
                                  'lib/pages/account_page.dart::_AccountPageState._account.closure#1',
                                );
                                return const Icon(
                                  Icons.account_circle_outlined,
                                  size: 40,
                                );
                              },
                            ),
                    ),
                  ),
                ),
                Expanded(
                  child: AdaptiveText(
                    '账号 $uid',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (primary)
                  const Padding(
                    padding: EdgeInsets.only(left: 8),
                    child: Chip(label: Text('主账号')),
                  ),
                if (active && !primary)
                  const Padding(
                    padding: EdgeInsets.only(left: 8),
                    child: Chip(label: Text('当前使用')),
                  ),
              ],
            ),
            AdaptiveText('设备 $hint'),
            const SizedBox(height: 8),
            if (missing) ...[
              const Text('安全凭据缺失，可重新导入原账号或移除登录记录。已有资料、下载和扣时记录均已保留。'),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: _busy
                        ? null
                        : () {
                            AppLog.instance.trace(
                              "lib/pages/account_page.dart::_AccountPageState._account.closure#2",
                            );
                            _openImport(recoveryIdentity: identity);
                          },
                    icon: const Icon(Icons.key),
                    label: const Text('恢复此账号登录'),
                  ),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () {
                            AppLog.instance.trace(
                              "lib/pages/account_page.dart::_AccountPageState._account.closure#3",
                            );
                            _remove(identity, uid);
                          },
                    child: const Text('移除'),
                  ),
                ],
              ),
            ] else ...[
              Text(
                remaining == null
                    ? '可用听时：未核验'
                    : '可用听时：${remaining ~/ 3600} 小时 ${(remaining % 3600) ~/ 60} 分 ${remaining % 60} 秒',
              ),
              if (checked != null)
                AdaptiveText(
                  '核验于 ${checked.toString().split('.').first}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              if (paused)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text('领取已暂停，请先在官方 App 核对上一次结果。'),
                ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: _busy
                        ? null
                        : () {
                            AppLog.instance.trace(
                              "lib/pages/account_page.dart::_AccountPageState._account.closure#4",
                            );
                            _openImport(recoveryIdentity: identity);
                          },
                    icon: const Icon(Icons.key),
                    label: const Text('更新登录'),
                  ),
                  if (!primary || !active)
                    OutlinedButton(
                      onPressed: _busy
                          ? null
                          : () {
                              AppLog.instance.trace(
                                "lib/pages/account_page.dart::_AccountPageState._account.closure#5",
                              );
                              _run(() {
                                AppLog.instance.trace(
                                  "lib/pages/account_page.dart::_AccountPageState._account.closure#5.closure#1",
                                );
                                return widget.accounts.setPrimary(identity);
                              });
                            },
                      child: Text(primary ? '切回主账号' : '设为主账号'),
                    ),
                  OutlinedButton(
                    onPressed: _busy
                        ? null
                        : () {
                            AppLog.instance.trace(
                              "lib/pages/account_page.dart::_AccountPageState._account.closure#6",
                            );
                            _quota(identity);
                          },
                    child: const Text('查询听时'),
                  ),
                  OutlinedButton(
                    onPressed: _busy || paused
                        ? null
                        : () {
                            AppLog.instance.trace(
                              "lib/pages/account_page.dart::_AccountPageState._account.closure#7",
                            );
                            _claim(identity, uid);
                          },
                    child: const Text('领取一次'),
                  ),
                  if (paused)
                    OutlinedButton(
                      onPressed: _busy
                          ? null
                          : () {
                              AppLog.instance.trace(
                                "lib/pages/account_page.dart::_AccountPageState._account.closure#8",
                              );
                              _resumeRewards(identity, uid);
                            },
                      child: const Text('核对后恢复自动领取'),
                    ),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () {
                            AppLog.instance.trace(
                              "lib/pages/account_page.dart::_AccountPageState._account.closure#9",
                            );
                            _remove(identity, uid);
                          },
                    child: const Text('移除'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace(
      "lib/pages/account_page.dart::_AccountPageState.build",
    );

    _viewKey = _accountViewKey();
    final records = widget.storage.state['accounts'] as Map;
    final ids = [
      ...widget.accounts.accountIds,
      ...widget.accounts.missingCredentialAccountIds,
    ];
    return PopScope(
      canPop: !_busy,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: EdgeInsets.all(
              MediaQuery.sizeOf(context).width < 320 ? 8 : 16,
            ),
            children: [
              AdaptiveText('账号', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 16),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  FilledButton.icon(
                    onPressed: _busy ? null : _openImport,
                    icon: const Icon(Icons.key),
                    label: const Text('Cookie 登录'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _openSms,
                    icon: const Icon(Icons.sms_outlined),
                    label: const Text('短信登录'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              const Text('主账号用于默认请求。'),
              if (_busy)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: LinearProgressIndicator(),
                ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              if (ids.isEmpty)
                const Card(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('还没有登录账号。'),
                  ),
                ),
              for (final id in ids)
                if (records[id] is Map) _account(id, records[id] as Map),
              const SizedBox(height: 16),
              Card(
                child: SwitchListTile(
                  title: const Text('自动领取听时'),
                  subtitle: const Text('不足 2 小时补充至 4 小时，对所有账号生效。'),
                  value: _autoClaim,
                  onChanged: _busy ? null : _toggleAuto,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CredentialDialog extends StatefulWidget {
  const _CredentialDialog({required this.accounts, this.recoveryIdentity});
  final AccountService accounts;
  final String? recoveryIdentity;
  @override
  State<_CredentialDialog> createState() {
    AppLog.instance.trace(
      "lib/pages/account_page.dart::_CredentialDialog.createState",
    );
    return _CredentialDialogState();
  }
}

class _CredentialDialogState extends State<_CredentialDialog> {
  final _cookie = TextEditingController();
  bool _primary = true, _busy = false;
  String? _error;
  bool _switchBlocked = false;

  @override
  void dispose() {
    AppLog.instance.trace(
      "lib/pages/account_page.dart::_CredentialDialogState.dispose",
    );

    _cookie.clear();
    _cookie.dispose();
    super.dispose();
  }

  Future<void> _save() {
    AppLog.instance.trace(
      "lib/pages/account_page.dart::_CredentialDialogState._save",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/pages/account_page.dart::_CredentialDialogState._save.closure#1",
      );

      if (_busy) return;
      setState(() {
        AppLog.instance.trace(
          "lib/pages/account_page.dart::_CredentialDialogState._save.closure#1.closure#1",
        );

        _busy = true;
        _error = null;
        _switchBlocked = false;
      });
      try {
        final candidate = Credentials.parse(_cookie.text);
        await widget.accounts.commit(
          candidate,
          makePrimary: _primary,
          recoveryIdentity: widget.recoveryIdentity,
        );
        if (mounted) Navigator.pop(context, true);
      } catch (error, stack) {
        _recordAccountError(error, stack);
        if (mounted)
          setState(() {
            AppLog.instance.trace(
              "lib/pages/account_page.dart::_CredentialDialogState._save.closure#1.closure#2",
            );
            _error = _accountError(error);
            _switchBlocked =
                error is AccountException && error.code == 'unsettled' ||
                error is XmlyException && error.code == 'usage_uncertain';
          });
      } finally {
        if (mounted)
          setState(() {
            AppLog.instance.trace(
              "lib/pages/account_page.dart::_CredentialDialogState._save.closure#1.closure#3",
            );
            _busy = false;
          });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace(
      "lib/pages/account_page.dart::_CredentialDialogState.build",
    );
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        title: Text(
          widget.recoveryIdentity == null ? 'Cookie 登录' : '恢复原账号登录',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: _cookie,
                  enabled: !_busy,
                  minLines: 4,
                  maxLines: 8,
                  keyboardType: TextInputType.multiline,
                  autocorrect: false,
                  enableSuggestions: false,
                  smartDashesType: SmartDashesType.disabled,
                  smartQuotesType: SmartQuotesType.disabled,
                  enableIMEPersonalizedLearning: false,
                  inputFormatters: [LengthLimitingTextInputFormatter(65536)],
                  decoration: const InputDecoration(
                    labelText: 'Cookie',
                    hintText: '1&_token=UID&令牌; 1&_device=android&设备ID&3.4.10;',
                    helperText: '可粘贴多行 Cookie 或请求头，自动提取登录字段',
                    hintMaxLines: 2,
                    helperMaxLines: 3,
                    border: OutlineInputBorder(),
                  ),
                ),
                if (widget.recoveryIdentity != null)
                  const Padding(
                    padding: EdgeInsets.only(top: 12),
                    child: Text('使用原账号和原设备 ID。恢复后保留主账号选择；结果未知的扣时仍需核对。'),
                  )
                else
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('设为主账号'),
                    value: _primary,
                    onChanged: _busy
                        ? null
                        : (value) {
                            AppLog.instance.trace(
                              "lib/pages/account_page.dart::_CredentialDialogState.build.closure#1",
                            );
                            setState(() {
                              AppLog.instance.trace(
                                "lib/pages/account_page.dart::_CredentialDialogState.build.closure#1.closure#1",
                              );
                              _primary = value!;
                            });
                          },
                  ),
                if (_error != null)
                  Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                if (_switchBlocked && widget.recoveryIdentity == null)
                  const Text('仅添加新账号时，可取消勾选“设为主账号”后重试。'),
                if (_busy) const LinearProgressIndicator(),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: _busy
                ? null
                : () {
                    AppLog.instance.trace(
                      "lib/pages/account_page.dart::_CredentialDialogState.build.closure#2",
                    );
                    Navigator.pop(context);
                  },
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: _busy ? null : _save,
            child: const Text('核验并保存'),
          ),
        ],
      ),
    );
  }
}

class _SmsLoginDialog extends StatefulWidget {
  const _SmsLoginDialog({
    required this.accounts,
    required this.dataDirectory,
    required this.login,
  });
  final AccountService accounts;
  final String dataDirectory;
  final XmlyLogin login;
  @override
  State<_SmsLoginDialog> createState() {
    AppLog.instance.trace(
      "lib/pages/account_page.dart::_SmsLoginDialog.createState",
    );
    return _SmsLoginDialogState();
  }
}

class _SmsLoginDialogState extends State<_SmsLoginDialog> {
  XmlyLogin get _login {
    AppLog.instance.trace(
      "lib/pages/account_page.dart::_SmsLoginDialogState._login.get",
    );
    return widget.login;
  }

  final _phone = TextEditingController(), _code = TextEditingController();
  final _watch = Stopwatch()..start();
  Timer? _timer;
  Duration _expiresAt = Duration.zero;
  String? _challenge, _error;
  Credentials? _candidate;
  bool _busy = false, _committing = false, _primary = true, _cancelled = false;
  bool _switchBlocked = false;

  int get _cooldown {
    AppLog.instance.trace(
      "lib/pages/account_page.dart::_SmsLoginDialogState._cooldown.get",
    );
    return _login.smsCooldownSeconds(_phone.text.trim());
  }

  void _invalidate() {
    AppLog.instance.trace(
      "lib/pages/account_page.dart::_SmsLoginDialogState._invalidate",
    );

    _cancelled = true;
    _login.clear();
    _challenge = null;
    _candidate = null;
    _phone.clear();
    _code.clear();
  }

  @override
  void initState() {
    AppLog.instance.trace(
      "lib/pages/account_page.dart::_SmsLoginDialogState.initState",
    );

    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      AppLog.instance.trace(
        "lib/pages/account_page.dart::_SmsLoginDialogState.initState.closure#1",
      );

      if (!mounted || _candidate != null) return;
      if (_challenge != null && _watch.elapsed >= _expiresAt && !_committing) {
        _login.clear();
        _challenge = null;
        _code.clear();
        _error = '短信验证已过期，请重新发送。';
      }
      setState(() {
        AppLog.instance.trace(
          "lib/pages/account_page.dart::_SmsLoginDialogState.initState.closure#1.closure#1",
        );
      });
    });
  }

  @override
  void dispose() {
    AppLog.instance.trace(
      "lib/pages/account_page.dart::_SmsLoginDialogState.dispose",
    );

    _timer?.cancel();
    _login.clear();
    _watch.stop();
    _challenge = null;
    _candidate = null;
    _phone.clear();
    _code.clear();
    _phone.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _send() {
    AppLog.instance.trace(
      "lib/pages/account_page.dart::_SmsLoginDialogState._send",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/pages/account_page.dart::_SmsLoginDialogState._send.closure#1",
      );

      if (_busy || _cancelled || _candidate != null || _cooldown > 0) return;
      final mobile = _phone.text.trim();
      if (!RegExp(r'^\+?[0-9]{6,18}$').hasMatch(mobile)) {
        setState(() {
          AppLog.instance.trace(
            "lib/pages/account_page.dart::_SmsLoginDialogState._send.closure#1.closure#1",
          );
          _error = '请输入有效手机号（6–18 位数字，可含国际区号 +）。';
        });
        return;
      }
      setState(() {
        AppLog.instance.trace(
          "lib/pages/account_page.dart::_SmsLoginDialogState._send.closure#1.closure#2",
        );

        _busy = true;
        _error = null;
      });
      try {
        final geetest = await GeetestDialog.show(
          context,
          captchaId: _login.config()['captcha_id'] as String,
          dataDirectory: widget.dataDirectory,
        );
        if (!mounted || _cancelled || geetest == null) return;
        if (!await _confirm(
              context,
              '发送短信',
              '向尾号 ${mobile.substring(mobile.length - 4)} 的手机号发送登录验证码？180 秒内不可重发。',
              action: '发送短信',
            ) ||
            !mounted ||
            _cancelled)
          return;
        // Keep the current code usable until the replacement send is confirmed.
        _login.clear();
        _challenge = null;
        _code.clear();
        final response = await _login.sendSms(mobile, geetest);
        if (!mounted || _cancelled) return;
        _challenge = response['challenge_id'] as String;
        _expiresAt = _watch.elapsed + const Duration(seconds: 600);
      } catch (error, stack) {
        _recordAccountError(error, stack);
        if (mounted)
          setState(() {
            AppLog.instance.trace(
              "lib/pages/account_page.dart::_SmsLoginDialogState._send.closure#1.closure#3",
            );
            _error = _accountError(error);
          });
      } finally {
        if (mounted)
          setState(() {
            AppLog.instance.trace(
              "lib/pages/account_page.dart::_SmsLoginDialogState._send.closure#1.closure#4",
            );
            _busy = false;
          });
      }
    });
  }

  Future<void> _verify() {
    AppLog.instance.trace(
      "lib/pages/account_page.dart::_SmsLoginDialogState._verify",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/pages/account_page.dart::_SmsLoginDialogState._verify.closure#1",
      );

      final challenge = _challenge;
      if (_busy || _cancelled || (_candidate == null && challenge == null))
        return;
      setState(() {
        AppLog.instance.trace(
          "lib/pages/account_page.dart::_SmsLoginDialogState._verify.closure#1.closure#1",
        );

        _busy = true;
        _error = null;
        _switchBlocked = false;
      });
      try {
        var candidate = _candidate;
        if (candidate == null) {
          candidate = await _login.verifySms(challenge!, _code.text.trim());
          if (!mounted || _cancelled) return;
          _candidate = candidate;
          _code.clear();
          _phone.clear();
          _challenge = null;
        }
        setState(() {
          AppLog.instance.trace(
            "lib/pages/account_page.dart::_SmsLoginDialogState._verify.closure#1.closure#2",
          );
          _committing = true;
        });
        await widget.accounts.commit(candidate, makePrimary: _primary);
        _candidate = null;
        if (mounted) Navigator.pop(context, true);
      } catch (error, stack) {
        _recordAccountError(error, stack);
        if (mounted)
          setState(() {
            AppLog.instance.trace(
              "lib/pages/account_page.dart::_SmsLoginDialogState._verify.closure#1.closure#3",
            );

            _error = _accountError(error);
            _switchBlocked =
                error is AccountException && error.code == 'unsettled' ||
                error is XmlyException && error.code == 'usage_uncertain';
            if (error is XmlyException &&
                [
                  'challenge_invalid',
                  'challenge_expired',
                ].contains(error.code)) {
              _challenge = null;
              _code.clear();
            }
          });
      } finally {
        if (mounted)
          setState(() {
            AppLog.instance.trace(
              "lib/pages/account_page.dart::_SmsLoginDialogState._verify.closure#1.closure#4",
            );

            _busy = false;
            _committing = false;
          });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace(
      "lib/pages/account_page.dart::_SmsLoginDialogState.build",
    );
    return PopScope(
      canPop: !_committing,
      onPopInvokedWithResult: (didPop, _) {
        AppLog.instance.trace(
          "lib/pages/account_page.dart::_SmsLoginDialogState.build.closure#1",
        );

        if (didPop) _invalidate();
      },
      child: AlertDialog(
        title: const Text('短信登录', maxLines: 1, overflow: TextOverflow.ellipsis),
        content: SizedBox(
          width: 440,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('先完成安全验证，再由你确认发送短信。登录后仍需核验极速版可用听时；失败不替换原账号。'),
                const SizedBox(height: 16),
                if (_candidate != null)
                  const Text('短信验证已完成，可直接重试登录，无需重新发送短信。')
                else ...[
                  TextField(
                    controller: _phone,
                    enabled: !_busy && _challenge == null,
                    onChanged: (_) {
                      AppLog.instance.trace(
                        "lib/pages/account_page.dart::_SmsLoginDialogState.build.closure#2",
                      );
                      setState(() {
                        AppLog.instance.trace(
                          "lib/pages/account_page.dart::_SmsLoginDialogState.build.closure#2.closure#1",
                        );
                      });
                    },
                    autocorrect: false,
                    enableSuggestions: false,
                    enableIMEPersonalizedLearning: false,
                    keyboardType: TextInputType.phone,
                    inputFormatters: [LengthLimitingTextInputFormatter(19)],
                    decoration: const InputDecoration(
                      labelText: '手机号',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton(
                    onPressed: _busy || _cooldown > 0 ? null : _send,
                    child: Text(
                      _cooldown > 0 ? '$_cooldown 秒后可重发' : '安全验证并发送短信',
                    ),
                  ),
                ],
                if (_challenge != null) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: _code,
                    enabled: !_busy,
                    autocorrect: false,
                    enableSuggestions: false,
                    enableIMEPersonalizedLearning: false,
                    keyboardType: TextInputType.number,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(8),
                    ],
                    decoration: const InputDecoration(
                      labelText: '短信验证码',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text('验证码 10 分钟内有效，最多尝试 5 次。'),
                ],
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('设为主账号'),
                  value: _primary,
                  onChanged: _busy
                      ? null
                      : (value) {
                          AppLog.instance.trace(
                            "lib/pages/account_page.dart::_SmsLoginDialogState.build.closure#3",
                          );
                          setState(() {
                            AppLog.instance.trace(
                              "lib/pages/account_page.dart::_SmsLoginDialogState.build.closure#3.closure#1",
                            );
                            _primary = value!;
                          });
                        },
                ),
                if (_error != null)
                  Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                if (_switchBlocked)
                  const Text('仅添加新账号时，可取消勾选“设为主账号”后重试，无需重新发送短信。'),
                if (_busy) const LinearProgressIndicator(),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: _committing
                ? null
                : () {
                    AppLog.instance.trace(
                      "lib/pages/account_page.dart::_SmsLoginDialogState.build.closure#4",
                    );

                    _invalidate();
                    Navigator.pop(context);
                  },
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: _busy || (_challenge == null && _candidate == null)
                ? null
                : _verify,
            child: const Text('验证并登录'),
          ),
        ],
      ),
    );
  }
}
