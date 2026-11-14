import '../models/xmly_models.dart';
import '../services/app_log.dart';
import 'xmly_client.dart';
import 'xmly_experience.dart';

class BrowseCategory {
  const BrowseCategory({required this.id, required this.title});
  final int id;
  final String title;
}

class BrowseAlbumPage {
  const BrowseAlbumPage({
    required this.section,
    required this.page,
    required this.total,
    required this.hasMore,
  });
  final HomeSection section;
  final int page, total;
  final bool hasMore;
}

class XmlyBrowse {
  const XmlyBrowse(this.client);
  final XmlyClient client;

  static const pageSize = 20;
  static const _invalid = XmlyException('invalid_browse', '专辑列表暂时不可用，请重试');

  Future<List<BrowseCategory>> categories() async {
    AppLog.instance.trace("lib/api/xmly_browse.dart::XmlyBrowse.categories");

    final response = await client.request(
      'GET',
      XmlyClient.searchOrigin,
      '/revision/category/v2/allCategory',
      account: false,
    );
    final rows = _rows(xmlyMap(response['data'])['categories']);
    final result = <BrowseCategory>[];
    final seen = <int>{};
    for (final row in rows) {
      if (row['isDisplay'] == false || (_integer(row['parentId']) ?? 0) != 0)
        continue;
      final id = _integer(row['id']);
      final title = _text(row['title']).trim();
      if (id == null || id <= 0 || title.isEmpty || !seen.add(id)) continue;
      result.add(BrowseCategory(id: id, title: title));
    }
    if (result.isEmpty) throw _invalid;
    return List.unmodifiable(result);
  }

  Future<BrowseAlbumPage> albums({
    int categoryId = 0,
    int sort = 1,
    int page = 1,
  }) async {
    AppLog.instance.trace("lib/api/xmly_browse.dart::XmlyBrowse.albums");

    if (categoryId < 0 ||
        categoryId > 2147483647 ||
        page < 1 ||
        page > 10000 ||
        !const {1, 2, 3}.contains(sort)) {
      throw const XmlyException('invalid_page', '分类或页码无效');
    }
    final response = await client.request(
      'GET',
      XmlyClient.searchOrigin,
      '/revision/category/v2/albums',
      query: {
        if (categoryId > 0) 'categoryId': categoryId,
        'pageNum': page,
        'pageSize': pageSize,
        'sort': sort,
      },
      account: false,
    );
    final data = xmlyMap(response['data']);
    final rows = _rows(data['albums'], maximum: pageSize);
    final total = _integer(data['total']);
    if (_integer(data['pageNum']) != page ||
        _integer(data['pageSize']) != pageSize ||
        total == null)
      throw _invalid;
    final albums = <Album>[];
    final stats = <String, HomeAlbumStats>{};
    final seen = <String>{};
    for (final row in rows) {
      if (row['isDeleted'] == true) continue;
      final id = xmlyIdentifier('${row['albumId'] ?? ''}');
      if (!seen.add(id)) continue;
      albums.add(
        Album.fromApi({
          'albumId': id,
          'title': _text(row['albumTitle']),
          'nickname': _text(row['albumUserNickName']),
          'intro': _text(row['intro']),
          'tracks': _integer(row['albumTrackCount']) ?? 0,
          'coverLarge': _cover(row['albumCoverPath']),
          'isPaid': row['isPaid'],
        }),
      );
      stats[id] = HomeAlbumStats(
        playCount: _integer(row['albumPlayCount']),
        finished: row['isFinished'] == 2,
      );
    }
    final hasMore = page * pageSize < total;
    if (rows.isEmpty && hasMore) throw _invalid;
    return BrowseAlbumPage(
      section: HomeSection(title: '专辑', albums: albums, stats: stats),
      page: page,
      total: total,
      hasMore: hasMore,
    );
  }

  static List<Map<String, dynamic>> _rows(Object? value, {int maximum = 500}) {
    AppLog.instance.trace("lib/api/xmly_browse.dart::XmlyBrowse._rows");

    if (value is! List || value.length > maximum) throw _invalid;
    final result = <Map<String, dynamic>>[];
    for (final row in value) {
      if (row is! Map<String, dynamic>) throw _invalid;
      result.add(row);
    }
    return result;
  }

  static int? _integer(Object? value) {
    AppLog.instance.trace("lib/api/xmly_browse.dart::XmlyBrowse._integer");

    if (value is int && value >= 0) return value;
    if (value is String) {
      final result = int.tryParse(value);
      if (result != null && result >= 0) return result;
    }
    return null;
  }

  static String _text(Object? value) {
    AppLog.instance.trace("lib/api/xmly_browse.dart::XmlyBrowse._text");
    return value is String ? value : '';
  }

  static String? _cover(Object? value) {
    AppLog.instance.trace("lib/api/xmly_browse.dart::XmlyBrowse._cover");

    if (value is! String || value.isEmpty) return null;
    if (value.startsWith('//')) return 'https:$value';
    if (value.startsWith('storages/') ||
        RegExp(r'^group\d+/').hasMatch(value)) {
      return 'https://imagev2.xmcdn.com/$value';
    }
    return value;
  }
}
