import '../models/xmly_models.dart';
import '../services/app_log.dart';
import 'xmly_client.dart';

class AnchorProfile {
  const AnchorProfile({
    required this.uid,
    required this.nickname,
    this.avatar,
    this.background,
    this.intro = '',
    this.verification = '',
    this.verified = false,
    this.level,
    this.location = '',
    this.fans,
    this.following,
    this.albums,
    this.tracks,
  });

  final String uid, nickname, intro, location, verification;
  final bool verified;
  final int? level;
  final Uri? avatar, background;
  final int? fans, following, albums, tracks;
}

class AnchorAlbum {
  const AnchorAlbum({required this.album, this.playCount});
  final Album album;
  final int? playCount;
}

class AnchorContentPage<T> {
  AnchorContentPage({
    required List<T> items,
    required this.page,
    required this.hasMore,
    this.total,
  }) : items = List.unmodifiable(items) {
    AppLog.instance.trace("lib/api/xmly_anchor.dart::AnchorContentPage.new");
  }

  final List<T> items;
  final int page;
  final bool hasMore;
  final int? total;
}

/// Public creator endpoints deliberately use no account cookies.
class XmlyAnchor {
  XmlyAnchor(this.client) {
    AppLog.instance.trace("lib/api/xmly_anchor.dart::XmlyAnchor.new");
  }

  final XmlyClient client;
  static const pageSize = 20;
  static const _invalid = XmlyException('invalid_anchor', '主播资料暂时无法读取，请重试');

  static String _text(Object? value) {
    AppLog.instance.trace("lib/api/xmly_anchor.dart::XmlyAnchor._text");

    return value is String ? value.trim() : '';
  }

  static int? _count(Object? value) {
    AppLog.instance.trace("lib/api/xmly_anchor.dart::XmlyAnchor._count");

    if (value is String) value = int.tryParse(value);
    if (value is int && value >= 0) return value;
    return null;
  }

  static Uri? _image(Object? value) {
    AppLog.instance.trace("lib/api/xmly_anchor.dart::XmlyAnchor._image");

    final text = _text(value);
    if (text.isEmpty ||
        text.length > 16384 ||
        RegExp(r'[\x00-\x20]').hasMatch(text)) {
      return null;
    }
    final uri = Uri.tryParse(text.startsWith('//') ? 'https:$text' : text);
    if (uri == null ||
        !const ['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      return null;
    }
    return uri.scheme == 'http' &&
            (uri.host == 'xmcdn.com' || uri.host.endsWith('.xmcdn.com'))
        ? uri.replace(scheme: 'https')
        : uri;
  }

  Future<Map<String, dynamic>> _get(
    String path,
    Map<String, dynamic> query,
  ) async {
    AppLog.instance.trace("lib/api/xmly_anchor.dart::XmlyAnchor._get");

    final response = await client.request(
      'GET',
      XmlyClient.searchOrigin,
      path,
      query: query,
      account: false,
    );
    if (response['data'] is! Map<String, dynamic>) throw _invalid;
    return response['data'] as Map<String, dynamic>;
  }

  Future<String> albumAnchor(String albumId) async {
    AppLog.instance.trace("lib/api/xmly_anchor.dart::XmlyAnchor.albumAnchor");

    final id = xmlyIdentifier(albumId);
    final data = await _get('/revision/album/v1/simple', {'albumId': id});
    if ('${data['albumId']}' != id) throw _invalid;
    final main = xmlyMap(data['albumPageMainInfo']);
    final uid = xmlyPositive(main['anchorUid']);
    if (uid == null) throw _invalid;
    return '$uid';
  }

  Future<String> trackAnchor(String trackId) async {
    AppLog.instance.trace("lib/api/xmly_anchor.dart::XmlyAnchor.trackAnchor");

    final id = xmlyIdentifier(trackId);
    final data = await _get('/revision/track/simple', {'trackId': id});
    final track = xmlyMap(data['trackInfo']);
    if ('${track['trackId']}' != id) throw _invalid;
    final uid = xmlyPositive(track['anchorUid']);
    if (uid == null) throw _invalid;
    return '$uid';
  }

  Future<AnchorProfile> profile(String uid) async {
    AppLog.instance.trace("lib/api/xmly_anchor.dart::XmlyAnchor.profile");

    final id = xmlyIdentifier(uid);
    final data = await _get('/revision/user/basic', {'uid': id});
    if ('${data['uid']}' != id) throw _invalid;
    final nickname = _text(data['nickName']);
    if (nickname.isEmpty) throw _invalid;
    final location = <String>{_text(data['province']), _text(data['city'])}
      ..remove('');
    return AnchorProfile(
      uid: id,
      nickname: nickname,
      avatar: _image(data['cover']),
      background: _image(data['background']),
      intro: _text(
        data['description'] ?? data['personalSignature'] ?? data['intro'],
      ),
      verification: _text(data['personalDescription']),
      verified: (_count(data['logoType']) ?? 0) > 0,
      level: xmlyPositive(data['mvpGrade']),
      location: location.join(' · '),
      fans: _count(data['fansCount']),
      following: _count(data['followingCount']),
      albums: _count(data['albumsCount']),
      tracks: _count(data['tracksCount']),
    );
  }

  Future<AnchorContentPage<AnchorAlbum>> albums(
    String uid, {
    int page = 1,
  }) async {
    AppLog.instance.trace("lib/api/xmly_anchor.dart::XmlyAnchor.albums");

    return _content<AnchorAlbum>(uid, page, '/revision/user/pub', 'albumList', (
      row,
    ) {
      AppLog.instance.trace(
        "lib/api/xmly_anchor.dart::XmlyAnchor.albums.closure#1",
      );

      return AnchorAlbum(
        album: Album.fromApi({
          ...row,
          'albumId': row['id'],
          'nickname': row['anchorNickName'],
          'cover_url': row['coverPath'],
          'intro': row['description'],
          'tracks': _count(row['trackCount']) ?? 0,
        }),
        playCount: _count(row['playCount']),
      );
    });
  }

  Future<AnchorContentPage<Track>> tracks(String uid, {int page = 1}) async {
    AppLog.instance.trace("lib/api/xmly_anchor.dart::XmlyAnchor.tracks");

    return _content<Track>(uid, page, '/revision/user/track', 'trackList', (
      row,
    ) {
      AppLog.instance.trace(
        "lib/api/xmly_anchor.dart::XmlyAnchor.tracks.closure#1",
      );

      return Track.fromApi({
        ...row,
        'cover_url': row['coverPath'],
        'duration': _count(row['length']) ?? 0,
      });
    });
  }

  Future<AnchorContentPage<AnchorProfile>> following(
    String uid, {
    int page = 1,
  }) async {
    AppLog.instance.trace("lib/api/xmly_anchor.dart::XmlyAnchor.following");

    return _content<AnchorProfile>(
      uid,
      page,
      '/revision/user/following',
      'followingsPageInfo',
      (row) {
        AppLog.instance.trace(
          "lib/api/xmly_anchor.dart::XmlyAnchor.following.closure#1",
        );

        final id = xmlyPositive(row['uid']);
        final nickname = _text(row['anchorNickName']);
        if (id == null || nickname.isEmpty) throw _invalid;
        return AnchorProfile(
          uid: '$id',
          nickname: nickname,
          avatar: _image(row['coverPath']),
          intro: _text(row['description']),
          verification: _text(row['ptitle']),
          verified: (_count(row['logoType']) ?? 0) > 0,
          fans: _count(row['followerCount']),
          following: _count(row['followingCount']),
          albums: _count(row['albumCount']),
          tracks: _count(row['trackCount']),
        );
      },
      requestedSize: 10,
      filters: const {'keyWord': ''},
    );
  }

  Future<AnchorContentPage<T>> _content<T>(
    String uid,
    int page,
    String path,
    String key,
    T Function(Map<String, dynamic>) decode, {
    int requestedSize = pageSize,
    Map<String, dynamic> filters = const {},
  }) async {
    AppLog.instance.trace("lib/api/xmly_anchor.dart::XmlyAnchor._content");

    if (page < 1 || page > 10000) {
      throw const XmlyException('invalid_page', '无法继续翻页，请刷新后重试');
    }
    final data = await _get(path, {
      ...filters,
      'uid': xmlyIdentifier(uid),
      'page': page,
      'pageSize': requestedSize,
    });
    final returnedPage = _count(data['page']);
    if (returnedPage != null && returnedPage != page) {
      throw const XmlyException('repeated_page', '列表分页未前进，请刷新后重试');
    }
    final rows = data[key];
    if (rows is! List || rows.length > 100) throw _invalid;
    final items = <T>[];
    for (final row in rows) {
      if (row is! Map<String, dynamic>) throw _invalid;
      items.add(decode(row));
    }
    var total = _count(data['filterTotalCount']) ?? _count(data['totalCount']);
    final maximum = _count(data['maxCount']);
    if (maximum != null && (total == null || maximum < total)) total = maximum;
    final size = _count(data['pageSize']);
    final effectiveSize = size != null && size > 0 ? size : requestedSize;
    return AnchorContentPage(
      items: items,
      page: page,
      total: total,
      hasMore: total != null
          ? page * effectiveSize < total
          : items.length >= effectiveSize,
    );
  }
}
