import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';

import '../models/xmly_models.dart';
import 'xmly_client.dart';
import "../services/app_log.dart";

class HomeChannel {
  const HomeChannel({
    required this.pageId,
    required this.title,
    this.categoryId,
  });
  final int pageId;
  final int? categoryId;
  final String title;
}

class HomeTab {
  const HomeTab({required this.tabId, required this.title});
  final int tabId;
  final String title;
}

class HomeAlbumStats {
  const HomeAlbumStats({
    this.score,
    this.playCount,
    this.subscribeCount,
    this.finished = false,
  });
  final double? score;
  final int? playCount, subscribeCount;
  final bool finished;
}

class HomeSection {
  HomeSection({
    required this.title,
    required List<Album> albums,
    this.isRanking = false,
    this.moreCategoryId,
    Map<String, HomeAlbumStats> stats = const {},
  }) : albums = List.unmodifiable(albums),
       stats = Map.unmodifiable(stats) {
    AppLog.instance.trace("lib/api/xmly_experience.dart::HomeSection.new");
  }
  final String title;
  final List<Album> albums;
  final bool isRanking;
  final int? moreCategoryId;
  final Map<String, HomeAlbumStats> stats;
}

class HomeContent {
  HomeContent({
    required List<HomeSection> sections,
    List<HomeTab> tabs = const [],
  }) : sections = List.unmodifiable(sections),
       tabs = List.unmodifiable(tabs) {
    AppLog.instance.trace("lib/api/xmly_experience.dart::HomeContent.new");
  }
  final List<HomeSection> sections;
  final List<HomeTab> tabs;
}

class SubscriptionItem {
  const SubscriptionItem({
    required this.album,
    required this.latestTitle,
    required this.unreadCount,
    required this.updatedAt,
  });
  final Album album;
  final String latestTitle;
  final int unreadCount, updatedAt;
}

class SubscriptionPage {
  SubscriptionPage({
    required List<SubscriptionItem> items,
    required this.hasMore,
  }) : items = List.unmodifiable(items) {
    AppLog.instance.trace("lib/api/xmly_experience.dart::SubscriptionPage.new");
  }
  final List<SubscriptionItem> items;
  final bool hasMore;
}

class FavoritePage {
  FavoritePage({required List<Track> items, required this.hasMore})
    : items = List.unmodifiable(items) {
    AppLog.instance.trace("lib/api/xmly_experience.dart::FavoritePage.new");
  }
  final List<Track> items;
  final bool hasMore;
}

class UpdateItem {
  const UpdateItem({required this.track, required this.publishedAt});
  final Track track;
  final int publishedAt;
}

class UpdatePage {
  UpdatePage({
    required List<UpdateItem> items,
    required this.hasMore,
    required this.nextTimeline,
  }) : items = List.unmodifiable(items) {
    AppLog.instance.trace("lib/api/xmly_experience.dart::UpdatePage.new");
  }
  final List<UpdateItem> items;
  final bool hasMore;
  final int? nextTimeline;
}

class AlbumIntroductionData {
  const AlbumIntroductionData({
    required this.richText,
    required this.recommendations,
  });
  final String richText;
  final HomeSection recommendations;
}

/// Only the five most recent, bounded page summaries escape a membership scan.
/// HMAC key never leaves this object, so album markers cannot link scans.
class _SubscriptionPagination {
  _SubscriptionPagination()
    : _markers = Hmac(sha256, utf8.encode(const Uuid().v4())) {
    AppLog.instance.trace(
      'lib/api/xmly_experience.dart::_SubscriptionPagination.new',
    );
  }

  final Hmac _markers;
  final _recent = <Map<String, Object?>>[];

  void observe({
    required int page,
    required int pageSize,
    required Object? ret,
    required Map<String, dynamic> data,
    required int elapsedMs,
    required List<dynamic> rows,
    required Set<String> seen,
  }) {
    AppLog.instance.trace(
      'lib/api/xmly_experience.dart::_SubscriptionPagination.observe',
    );

    final unique = <String>{};
    final sequence = <String?>[];
    var invalidIds = 0, added = 0;
    for (final row in rows) {
      final value = row['albumId'];
      final text = value is String || value is int ? '$value' : '';
      final match = RegExp(r'^(?:xmly:)?([1-9][0-9]{0,18})$').firstMatch(text);
      if (match == null) {
        invalidIds++;
        sequence.add(null);
        continue;
      }
      final id = match[1]!;
      if (unique.add(id) && !seen.contains(id)) added++;
      sequence.add(
        _markers.convert(utf8.encode(id)).toString().substring(0, 16),
      );
    }
    _recent.add(
      Map.unmodifiable({
        'page': page,
        'pageSize': pageSize,
        'elapsedMs': elapsedMs,
        // XmlyClient.request only returns after checking HTTP status == 200.
        'httpStatus': 200,
        'ret': ret is int
            ? ret
            : ret is String
            ? int.tryParse(ret)
            : null,
        'hasMore': data['hasMore'] is bool ? data['hasMore'] : null,
        'responsePaging': {
          for (final key in const [
            'pageId',
            'pageSize',
            'size',
            'totalCount',
            'maxPageId',
            'nextPageId',
          ])
            if (data.containsKey(key)) key: XmlyExperience._integer(data[key]),
        },
        'resultCount': rows.length,
        'uniqueCount': unique.length,
        'duplicateCount': rows.length - invalidIds - unique.length,
        'invalidIdCount': invalidIds,
        'accumulatedBefore': seen.length,
        'newCount': added,
        'overlapCount': unique.length - added,
        'accumulatedAfter': seen.length + added,
        // The endpoint allows at most 50 rows; preserve their order for comparison.
        'albumMarkers': List<String?>.unmodifiable(sequence),
      }),
    );
    if (_recent.length > 5) _recent.removeAt(0);
  }

  XmlyException failure(String reason, String code, String message) {
    AppLog.instance.trace(
      'lib/api/xmly_experience.dart::_SubscriptionPagination.failure',
    );

    return XmlyException(
      code,
      message,
      diagnostics: Map.unmodifiable({
        'pagination': Map<String, Object?>.unmodifiable({
          'list': 'subscriptions',
          'reason': reason,
          'method': 'GET',
          'endpoint': '/fsubscribe-web/subscribe/comprehensive/rank',
          if (_recent.length > 2)
            'earlierPages': List.unmodifiable(_recent.take(_recent.length - 2)),
          if (_recent.length > 1) 'previousPage': _recent[_recent.length - 2],
          if (_recent.isNotEmpty) 'currentPage': _recent.last,
        }),
      }),
      fingerprint: List.unmodifiable([
        'xmplus',
        'subscription_pagination',
        reason,
      ]),
    );
  }
}

class _SubscriptionMembership {
  _SubscriptionMembership() {
    AppLog.instance.trace(
      'lib/api/xmly_experience.dart::_SubscriptionMembership.new',
    );
  }

  final ids = <String>{};
  final pagination = _SubscriptionPagination();
  int page = 1;
  bool complete = false;
  Future<void>? pending;
}

/// Lite client surfaces and explicit official subscription/favorite mutations.
/// No audio admission, billing, history writes, or credential-bearing caches.
class XmlyExperience {
  XmlyExperience(this.client) {
    AppLog.instance.trace("lib/api/xmly_experience.dart::XmlyExperience.new");
  }
  final XmlyClient client;
  static final _favoriteMembership = Expando<Future<Set<String>>>(
    'favoriteMembership',
  );
  static final _subscriptionMembership = Expando<_SubscriptionMembership>(
    'subscriptionMembership',
  );

  Future<AlbumIntroductionData> albumIntroduction(String albumId) async {
    AppLog.instance.trace(
      'lib/api/xmly_experience.dart::XmlyExperience.albumIntroduction',
    );
    final number = xmlyIdentifier(albumId);
    final response = await client.request(
      'GET',
      XmlyClient.mobile,
      '/fmobile-album/album/rec/detail/ts-$_stamp',
      query: {'albumId': number, 'supportWebp': 'true'},
      account: false,
    );
    final data = xmlyMap(response['data']);
    final detail = xmlyMap(data['detail']);
    final album = xmlyMap(data['album']);
    if (xmlyIdentifier('${album['albumId'] ?? ''}') != number ||
        (detail['albumId'] != null &&
            xmlyIdentifier('${detail['albumId']}') != number)) {
      throw const XmlyException('id_mismatch', '专辑简介与当前专辑不匹配');
    }
    // intro/shortIntro/shortIntroRich are server-truncated previews.
    final rich = detail['introRich'] ?? album['introRich'];
    if (rich is! String) {
      throw const XmlyException('invalid_introduction', '完整专辑简介格式无效，请重试');
    }
    final recommendations = <Album>[];
    final seen = <String>{number};
    for (final row in _list(data['recAlbums'], maximum: 100)) {
      final recommendation = Album.fromApi(xmlyMap(row));
      if (seen.add(recommendation.id)) recommendations.add(recommendation);
    }
    return AlbumIntroductionData(
      richText: rich,
      recommendations: HomeSection(
        title: _text(data['recAlbumsPanelTitle']).isEmpty
            ? '相关推荐'
            : _text(data['recAlbumsPanelTitle']),
        albums: recommendations,
      ),
    );
  }

  void invalidateLibrary() {
    AppLog.instance.trace(
      "lib/api/xmly_experience.dart::XmlyExperience.invalidateLibrary",
    );

    _favoriteMembership[client] = null;
    _subscriptionMembership[client] = null;
  }

  Future<Set<String>> _membership() async {
    AppLog.instance.trace(
      "lib/api/xmly_experience.dart::XmlyExperience._membership",
    );

    _requireAccount();
    final cache = _favoriteMembership;
    final pending = cache[client] ??= _loadMembership();
    try {
      final ids = await pending;
      _requireAccount();
      if (!identical(cache[client], pending)) return await _membership();
      return ids;
    } catch (_) {
      if (identical(cache[client], pending)) cache[client] = null;
      rethrow;
    }
  }

  Future<Set<String>> _loadMembership() async {
    AppLog.instance.trace(
      "lib/api/xmly_experience.dart::XmlyExperience._loadMembership",
    );

    final seen = <String>{};
    for (var page = 1; page <= 10000; page++) {
      final result = await _favorites(page: page);
      final ids = result.items.map((track) {
        AppLog.instance.trace(
          'lib/api/xmly_experience.dart::XmlyExperience._loadMembership.closure#1',
        );
        return track.id;
      });
      final more = result.hasMore;
      final before = seen.length;
      seen.addAll(ids);
      if ((ids.isNotEmpty || more) && seen.length == before) {
        throw const XmlyException('repeated_page', '列表分页未前进，请刷新后重试');
      }
      if (!more) return seen;
    }
    throw const XmlyException('page_limit', '列表超出读取范围，无法确认状态');
  }

  Future<void> _loadSubscriptionPage(_SubscriptionMembership membership) async {
    AppLog.instance.trace(
      'lib/api/xmly_experience.dart::XmlyExperience._loadSubscriptionPage',
    );

    if (membership.page > 10000) {
      throw membership.pagination.failure(
        'page_limit',
        'page_limit',
        '列表超出读取范围，无法确认状态',
      );
    }
    final result = await _subscriptions(
      page: membership.page,
      diagnostics: membership.pagination,
      seen: membership.ids,
    );
    final before = membership.ids.length;
    for (final item in result.items) {
      membership.ids.add(item.album.id);
    }
    if ((result.items.isNotEmpty || result.hasMore) &&
        membership.ids.length == before) {
      throw membership.pagination.failure(
        'no_progress',
        'repeated_page',
        '列表分页未前进，请刷新后重试',
      );
    }
    membership.complete = !result.hasMore;
    membership.page++;
  }

  static const _invalid = XmlyException('invalid_experience', '喜马拉雅返回的列表格式无效');
  String get _stamp {
    AppLog.instance.trace(
      "lib/api/xmly_experience.dart::XmlyExperience._stamp.get",
    );
    return '${DateTime.now().millisecondsSinceEpoch}';
  }

  static int? _integer(Object? value) {
    AppLog.instance.trace(
      "lib/api/xmly_experience.dart::XmlyExperience._integer",
    );

    if (value is String) {
      final parsed = int.tryParse(value);
      return parsed != null && parsed >= 0 ? parsed : null;
    }
    if (value is num &&
        value.isFinite &&
        value >= 0 &&
        value == value.truncateToDouble())
      return value.toInt();
    return null;
  }

  static String _text(Object? value) {
    AppLog.instance.trace("lib/api/xmly_experience.dart::XmlyExperience._text");
    return value is String ? value : '';
  }

  static List<dynamic> _list(Object? value, {int maximum = 500}) {
    AppLog.instance.trace("lib/api/xmly_experience.dart::XmlyExperience._list");

    if (value is! List ||
        value.length > maximum ||
        value.any((row) {
          AppLog.instance.trace(
            "lib/api/xmly_experience.dart::XmlyExperience._list.closure#1",
          );
          return row is! Map<String, dynamic>;
        }))
      throw _invalid;
    return value;
  }

  static bool _more(Map<String, dynamic> data) {
    AppLog.instance.trace("lib/api/xmly_experience.dart::XmlyExperience._more");

    if (data['hasMore'] is! bool) throw _invalid;
    return data['hasMore'] as bool;
  }

  static int _time(Object? value) {
    AppLog.instance.trace("lib/api/xmly_experience.dart::XmlyExperience._time");

    final time = _integer(value);
    if (time == null || time < 0 || time > 2115354119000) throw _invalid;
    return time;
  }

  static void _paging(int page, int size) {
    AppLog.instance.trace(
      "lib/api/xmly_experience.dart::XmlyExperience._paging",
    );

    if (page < 1 || page > 10000 || size < 1 || size > 50) {
      throw const XmlyException(
        'invalid_page',
        '页码范围为 1..10000，每页 1..50',
        definitive: true,
      );
    }
  }

  static Album _album(Map<String, dynamic> row) {
    AppLog.instance.trace(
      "lib/api/xmly_experience.dart::XmlyExperience._album",
    );
    return Album.fromApi({
      'albumId': row['albumId'],
      'title': row['albumTitle'],
      'intro': row['albumIntro'],
      'nickname': row['nickname'],
      'coverLarge': row['coverLarge'],
      'coverMiddle': row['coverMiddle'],
      'coverSmall': row['coverSmall'],
      'cover_url': row['albumCover'],
      'tracks': _integer(row['trackCount']) ?? 0,
    });
  }

  Future<Map<String, dynamic>> _get(
    String path,
    Map<String, dynamic> query, {
    bool account = true,
  }) async {
    AppLog.instance.trace("lib/api/xmly_experience.dart::XmlyExperience._get");

    final response = await client.request(
      'GET',
      XmlyClient.mobile,
      path,
      query: query,
      account: account,
    );
    if (response['data'] is! Map<String, dynamic>) throw _invalid;
    return response['data'] as Map<String, dynamic>;
  }

  void _requireAccount() {
    AppLog.instance.trace(
      "lib/api/xmly_experience.dart::XmlyExperience._requireAccount",
    );

    if (!client.accountAvailable)
      throw const XmlyException(
        'login_required',
        '登录后使用订阅、收藏和更新',
        definitive: true,
      );
  }

  Future<List<HomeChannel>> channels() async {
    AppLog.instance.trace(
      "lib/api/xmly_experience.dart::XmlyExperience.channels",
    );

    final data = await _get('/lite-mobile/index/v1/subPages/$_stamp', {
      'latestTheaterViewTimestamp': 0,
      'theaterDefaultMark': 0,
    });
    final result = <HomeChannel>[];
    final ids = <int>{};
    for (final raw in _list(data['subPages'], maximum: 100)) {
      final row = xmlyMap(raw);
      final id = _integer(row['pageId']);
      final title = _text(row['title']).trim();
      if (id == null || id <= 0 || title.isEmpty || !ids.add(id))
        throw _invalid;
      result.add(
        HomeChannel(
          pageId: id,
          title: title,
          categoryId: _integer(row['categoryId']),
        ),
      );
    }
    return List.unmodifiable(result);
  }

  Future<HomeContent> home(int pageId, {int? tabId}) async {
    AppLog.instance.trace("lib/api/xmly_experience.dart::XmlyExperience.home");

    if (pageId <= 0 ||
        pageId > 2147483647 ||
        (tabId != null && (tabId <= 0 || tabId > 2147483647))) {
      throw const XmlyException('invalid_page', '频道无效', definitive: true);
    }
    final data = await _get('/lite-mobile/index/v1/modules/$_stamp', {
      'pageId': pageId,
      if (tabId != null) 'tabId': tabId,
    });
    final sections = <HomeSection>[];
    final tabs = <HomeTab>[];
    final tabIds = <int>{};
    for (final raw in _list(xmlyMap(data['modules'])['list'], maximum: 100)) {
      final module = xmlyMap(raw);
      if (module['moduleCode'] == 'pageTab') {
        for (final rawTab in _list(module['list'], maximum: 100)) {
          final row = xmlyMap(rawTab);
          final id = _integer(row['tabId']);
          final title = _text(row['title']).trim();
          if (id == null || id <= 0 || title.isEmpty || !tabIds.add(id))
            throw _invalid;
          tabs.add(HomeTab(tabId: id, title: title));
        }
      } else if (module['moduleCode'] == 'rankingLists') {
        for (final rawRanking in _list(module['list'], maximum: 100)) {
          final ranking = xmlyMap(rawRanking);
          // Captured non-default tabs contain no albums and have no supported
          // endpoint in this surface. Never expose them as dead controls.
          if (ranking['isDefault'] != true) continue;
          final rows = _list(ranking['list']);
          if (rows.isNotEmpty)
            sections.add(
              _section(_text(ranking['rankingListName']), rows, ranking: true),
            );
        }
      } else if (module['moduleCode'] == 'feedStream') {
        final rows = <Map<String, dynamic>>[];
        for (final rawItem in _list(module['list'])) {
          final item = xmlyMap(rawItem);
          if (item['itemType'] != 'ALBUM') continue;
          if (item['item'] is! Map<String, dynamic>) throw _invalid;
          rows.add(item['item'] as Map<String, dynamic>);
        }
        if (rows.isNotEmpty)
          sections.add(
            _section(
              _text(module['title']),
              rows,
              moreCategoryId:
                  _integer(xmlyMap(data['page'])['categoryId']) ?? 0,
            ),
          );
      } else if (module['moduleCode'] == 'contentPool') {
        final rows = _list(module['list']);
        if (rows.isNotEmpty)
          sections.add(_section(_text(module['title']), rows));
      }
    }
    return HomeContent(sections: sections, tabs: tabs);
  }

  static HomeSection _section(
    String title,
    List<dynamic> rows, {
    bool ranking = false,
    int? moreCategoryId,
  }) {
    AppLog.instance.trace(
      "lib/api/xmly_experience.dart::XmlyExperience._section",
    );

    final albums = <Album>[];
    final stats = <String, HomeAlbumStats>{};
    final ids = <String>{};
    for (final raw in rows) {
      final row = xmlyMap(raw);
      final album = _album(row);
      if (!ids.add(album.id)) continue;
      albums.add(album);
      final score = double.tryParse('${row['albumScore']}');
      stats[album.id] = HomeAlbumStats(
        score: score != null && score.isFinite && score >= 0 && score <= 10
            ? score
            : null,
        playCount: _integer(row['playCount']),
        subscribeCount: _integer(row['subscribeCount']),
        finished: row['isFinished'] == true,
      );
    }
    return HomeSection(
      title: title.isEmpty ? (ranking ? '排行榜' : '推荐专辑') : title,
      albums: albums,
      isRanking: ranking,
      moreCategoryId: moreCategoryId,
      stats: stats,
    );
  }

  Future<SubscriptionPage> subscriptions({int page = 1, int pageSize = 30}) {
    AppLog.instance.trace(
      "lib/api/xmly_experience.dart::XmlyExperience.subscriptions",
    );

    if (page == 1) _subscriptionMembership[client] = null;
    return _subscriptions(page: page, pageSize: pageSize);
  }

  Future<SubscriptionPage> _subscriptions({
    int page = 1,
    int pageSize = 30,
    _SubscriptionPagination? diagnostics,
    Set<String> seen = const {},
  }) async {
    AppLog.instance.trace(
      "lib/api/xmly_experience.dart::XmlyExperience._subscriptions",
    );

    _requireAccount();
    _paging(page, pageSize);
    final elapsed = Stopwatch()..start();
    final response = await client.request(
      'GET',
      XmlyClient.mobile,
      '/fsubscribe-web/subscribe/comprehensive/rank/$_stamp',
      query: {'pageId': page, 'sign': 2, 'size': pageSize},
    );
    if (response['data'] is! Map<String, dynamic>) throw _invalid;
    final data = response['data'] as Map<String, dynamic>;
    final rows = _list(data['albumResults'], maximum: pageSize);
    final pages = diagnostics ?? _SubscriptionPagination();
    pages.observe(
      page: page,
      pageSize: pageSize,
      ret: response['ret'],
      data: data,
      elapsedMs: elapsed.elapsedMilliseconds,
      rows: rows,
      seen: seen,
    );
    final items = <SubscriptionItem>[];
    final ids = <String>{};
    for (final raw in rows) {
      final row = xmlyMap(raw);
      final album = _album(row);
      if (!ids.add(album.id)) {
        throw pages.failure('duplicate_ids', 'repeated_page', '订阅列表重复，请刷新后重试');
      }
      final unread = _integer(row['unreadNum']);
      if (unread == null || unread < 0) throw _invalid;
      items.add(
        SubscriptionItem(
          album: album,
          latestTitle: _text(row['trackTitle']),
          unreadCount: unread,
          updatedAt: _time(row['lastUpdateAt'] ?? 0),
        ),
      );
    }
    final more = _more(data);
    if (more && items.isEmpty) {
      throw pages.failure('empty_page', _invalid.code, _invalid.message);
    }
    return SubscriptionPage(items: items, hasMore: more);
  }

  Future<FavoritePage> favorites({int page = 1, int pageSize = 30}) {
    AppLog.instance.trace(
      "lib/api/xmly_experience.dart::XmlyExperience.favorites",
    );

    if (page == 1) _favoriteMembership[client] = null;
    return _favorites(page: page, pageSize: pageSize);
  }

  Future<FavoritePage> _favorites({int page = 1, int pageSize = 30}) async {
    AppLog.instance.trace(
      "lib/api/xmly_experience.dart::XmlyExperience._favorites",
    );

    _requireAccount();
    _paging(page, pageSize);
    final data = await _get('/lite-mobile/like/v1/user-likes', {
      'pageId': page,
      'pageSize': pageSize,
    });
    final maxPage = _integer(data['maxPageId']);
    // Lite returns zeroed pagination for an empty favorite library, including
    // pageId/pageSize, regardless of the requested first page.
    if (page == 1 &&
        _integer(data['pageId']) == 0 &&
        _integer(data['pageSize']) == 0 &&
        maxPage == 0 &&
        _integer(data['totalCount']) == 0 &&
        data['dataList'] is List &&
        (data['dataList'] as List).isEmpty) {
      return FavoritePage(items: const [], hasMore: false);
    }
    if (_integer(data['pageId']) != page ||
        _integer(data['pageSize']) != pageSize ||
        maxPage == null)
      throw _invalid;
    final items = <Track>[];
    final ids = <String>{};
    for (final raw in _list(data['dataList'], maximum: pageSize)) {
      final row = xmlyMap(raw);
      if (_integer(row['resourceType']) != 1) throw _invalid;
      final track = Track.fromApi({
        ...row,
        'isPaid': row['paid'],
        'isAuthorized': row['authorized'],
      });
      if (track.albumId.isEmpty) throw _invalid;
      if (!ids.add(track.id))
        throw const XmlyException('repeated_page', '收藏列表重复，请刷新后重试');
      items.add(track);
    }
    final more = page < maxPage;
    if ((more && items.isEmpty) || (items.isNotEmpty && page > maxPage))
      throw _invalid;
    return FavoritePage(items: items, hasMore: more);
  }

  Future<bool> isFavorite(String trackId) async {
    AppLog.instance.trace(
      "lib/api/xmly_experience.dart::XmlyExperience.isFavorite",
    );

    _requireAccount();
    final id = 'xmly:${xmlyIdentifier(trackId)}';
    return (await _membership()).contains(id);
  }

  Future<bool> isSubscribed(String albumId) async {
    AppLog.instance.trace(
      "lib/api/xmly_experience.dart::XmlyExperience.isSubscribed",
    );

    final id = xmlyIdentifier(albumId);
    while (true) {
      _requireAccount();
      final membership = _subscriptionMembership[client] ??=
          _SubscriptionMembership();
      if (membership.ids.contains(id)) return true;
      // A partial scan can confirm membership, never absence.
      if (membership.complete) return false;
      final pending = membership.pending ??= _loadSubscriptionPage(membership);
      try {
        await pending;
      } catch (_) {
        _requireAccount();
        if (identical(_subscriptionMembership[client], membership)) rethrow;
      } finally {
        if (identical(membership.pending, pending)) membership.pending = null;
      }
    }
  }

  static void _mutationSuccess(Map<String, dynamic> response) {
    AppLog.instance.trace(
      "lib/api/xmly_experience.dart::XmlyExperience._mutationSuccess",
    );

    // Mutations require explicit success, not merely an accepted response.
    if (_integer(response['ret']) != 0) throw _invalid;
  }

  Future<void> setLiked(Track track, {required bool liked}) async {
    AppLog.instance.trace(
      'lib/api/xmly_experience.dart::XmlyExperience.setLiked',
    );

    _requireAccount();
    final response = await client.request(
      'POST',
      XmlyClient.mobile,
      '/favourite-business/favorite/track',
      data: {
        'trackId': xmlyIdentifier(track.id),
        'playTime': '1',
        'favorite': '$liked',
      },
      form: true,
    );
    if (liked && _integer(response['ret']) == 111) return;
    _mutationSuccess(response);
  }

  Future<({int? likes, int? favorites})> trackCounts(String trackId) async {
    AppLog.instance.trace(
      'lib/api/xmly_experience.dart::XmlyExperience.trackCounts',
    );

    _requireAccount();
    final number = xmlyIdentifier(trackId);
    final response = await client.request(
      'GET',
      XmlyClient.mobile,
      '/fmobile-track/fmobile/track/playpage/$number/ts-$_stamp',
      query: {'device': 'android', 'trackId': number},
      signed: true,
    );
    if (_integer(response['ret']) != 0) throw _invalid;
    final info = xmlyMap(response['trackInfo']);
    if (xmlyIdentifier('${info['trackId'] ?? ''}') != number) {
      throw const XmlyException('id_mismatch', '返回的声音 ID 不匹配');
    }
    final likes = info['likes'];
    final favorites = info['likeCount'];
    return (
      likes: likes is int && likes >= 0 ? likes : null,
      favorites: favorites is int && favorites >= 0 ? favorites : null,
    );
  }

  Future<void> setFavorite(Track track, {required bool favorite}) async {
    AppLog.instance.trace(
      "lib/api/xmly_experience.dart::XmlyExperience.setFavorite",
    );

    _requireAccount();
    final trackId = xmlyIdentifier(track.id);
    var album = track.albumId;
    if (album.isEmpty) {
      final enriched = await client.track(trackId, force: true);
      if (enriched.number != trackId) {
        throw const XmlyException(
          'id_mismatch',
          '返回的声音 ID 不匹配',
          definitive: true,
        );
      }
      album = enriched.albumId;
      _requireAccount();
    }
    final albumId = xmlyIdentifier(album);
    try {
      final response = await client.request(
        'POST',
        XmlyClient.mobile,
        favorite ? '/lite-mobile/like/v1/like' : '/lite-mobile/like/v1/dislike',
        data: {'resourceId': trackId, 'albumId': albumId, 'resourceType': '1'},
        form: true,
      );
      _mutationSuccess(response);
    } finally {
      _favoriteMembership[client] = null;
    }
  }

  Future<void> setSubscribed(String albumId, {required bool subscribed}) async {
    AppLog.instance.trace(
      "lib/api/xmly_experience.dart::XmlyExperience.setSubscribed",
    );

    _requireAccount();
    final id = xmlyIdentifier(albumId);
    try {
      final response = await client.request(
        'POST',
        XmlyClient.mobile,
        subscribed
            ? '/subscribe/album-subscribe/and/ask-anchor-info'
            : '/subscribe/album/subscribe/delete',
        data: {'albumId': id},
        form: true,
      );
      _mutationSuccess(response);
    } finally {
      _subscriptionMembership[client] = null;
    }
  }

  Future<UpdatePage> updates({int? before, int pageSize = 30}) async {
    AppLog.instance.trace(
      "lib/api/xmly_experience.dart::XmlyExperience.updates",
    );

    _requireAccount();
    _paging(1, pageSize);
    if (before != null && (before <= 0 || before > 2115354119000))
      throw _invalid;
    final data = await _get('/track-feed/v1/track-feed/dynamic/ts-$_stamp', {
      'sign': 2,
      'size': pageSize,
      if (before != null) 'timeline': before,
    });
    final items = <UpdateItem>[];
    final ids = <String>{};
    int? cursor;
    for (final raw in _list(data['trackResults'], maximum: pageSize)) {
      final row = xmlyMap(raw);
      final track = Track.fromApi(row);
      if (!ids.add(track.id))
        throw const XmlyException('repeated_page', '更新列表重复，请刷新后重试');
      final timeline = _time(row['timeline']);
      if (cursor != null && timeline > cursor) throw _invalid;
      cursor = timeline;
      items.add(
        UpdateItem(
          track: track,
          publishedAt: _time(row['createdAt'] ?? timeline),
        ),
      );
    }
    final more = _more(data);
    // The live service may ignore timeline; do not present the repeated newest
    // page as older updates or claim that the complete feed was loaded.
    if (before != null && cursor != null && cursor >= before) {
      throw const XmlyException('repeated_page', '暂时无法读取更早的更新，已保留当前列表');
    }
    if (more && (cursor == null || cursor <= 0)) throw _invalid;
    return UpdatePage(items: items, hasMore: more, nextTimeline: cursor);
  }
}
