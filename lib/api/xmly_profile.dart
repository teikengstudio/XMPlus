import '../models/xmly_models.dart';
import '../services/app_log.dart';
import 'xmly_client.dart';

class PublicProfile {
  const PublicProfile({required this.uid, this.nickname, this.avatarUrl});

  final String uid;
  final String? nickname;
  final Uri? avatarUrl;
}

class XmlyProfile {
  XmlyProfile(this.client) {
    AppLog.instance.trace('lib/api/xmly_profile.dart::XmlyProfile.new');
  }

  final XmlyClient client;

  static Uri? _avatar(Map<String, dynamic> response) {
    AppLog.instance.trace('lib/api/xmly_profile.dart::XmlyProfile._avatar');
    for (final key in [
      'mobileMiddleLogo',
      'mobileSmallLogo',
      'mobileLargeLogo',
    ]) {
      final value = response[key];
      if (value is! String ||
          value.length > 16384 ||
          RegExp(r'[\x00-\x20]').hasMatch(value)) {
        continue;
      }
      final uri = Uri.tryParse(value.startsWith('//') ? 'https:$value' : value);
      if (uri != null &&
          (uri.scheme == 'http' || uri.scheme == 'https') &&
          uri.host.isNotEmpty &&
          uri.userInfo.isEmpty) {
        return uri;
      }
    }
    return null;
  }

  Future<PublicProfile> load(String uid) async {
    AppLog.instance.trace('lib/api/xmly_profile.dart::XmlyProfile.load');
    if (!RegExp(r'^[1-9][0-9]{0,19}$').hasMatch(uid)) {
      throw const XmlyException('invalid_id', '账号 UID 必须是正整数');
    }
    final response = await client.request(
      'GET',
      XmlyClient.mobile,
      '/fmobile-user/homePage/ts-${DateTime.now().millisecondsSinceEpoch}',
      query: {'device': 'android', 'uid': uid},
    );
    if ((response['ret'] != 0 && response['ret'] != '0') ||
        '${response['uid']}' != uid) {
      throw const XmlyException('invalid_profile', '公开账号资料格式或 UID 不匹配');
    }
    final nickname = response['nickname'];
    return PublicProfile(
      uid: uid,
      nickname: nickname is String && nickname.trim().isNotEmpty
          ? nickname.trim()
          : null,
      avatarUrl: _avatar(response),
    );
  }
}
