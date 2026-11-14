import '../models/xmly_models.dart';
import '../services/app_log.dart';
import 'xmly_client.dart';
import 'xmly_experience.dart';

/// The website returns one complete, bounded chart, not a pageable album feed.
class XmlyRanking {
  const XmlyRanking(this.client);
  final XmlyClient client;

  static const _invalid = XmlyException('invalid_ranking', '榜单暂时不可用，请重试');

  Future<HomeSection> hot({int categoryId = 0}) async {
    AppLog.instance.trace('lib/api/xmly_ranking.dart::XmlyRanking.hot');
    if (categoryId < 0 || categoryId > 2147483647) throw _invalid;
    final clusters = await client.request(
      'GET',
      XmlyClient.searchOrigin,
      '/revision/rank/v3/cluster',
      account: false,
    );
    final groups = _rows(xmlyMap(clusters['data'])['clusterType']);
    final group = groups.where((row) {
      AppLog.instance.trace(
        "lib/api/xmly_ranking.dart::XmlyRanking.hot.closure#1",
      );

      return row['rankClusterTypeCode'] == 'hot' &&
          _integer(row['rankType']) == 2;
    }).firstOrNull;
    if (group == null) throw _invalid;
    final typeId = _integer(group['rankClusterTypeId']);
    final categories = _rows(group['rankClusterCategories']);
    final selected =
        categories.where((row) {
          AppLog.instance.trace(
            "lib/api/xmly_ranking.dart::XmlyRanking.hot.closure#2",
          );

          return _integer(row['categoryId']) == categoryId;
        }).firstOrNull ??
        categories.where((row) {
          AppLog.instance.trace(
            "lib/api/xmly_ranking.dart::XmlyRanking.hot.closure#3",
          );

          return _integer(row['categoryId']) == 0;
        }).firstOrNull;
    if (selected == null || typeId == null || typeId <= 0) throw _invalid;
    final clusterId = _integer(selected['rankClusterId']);
    final rankId = _integer(selected['rankId']);
    if (clusterId == null || clusterId <= 0 || rankId == null || rankId <= 0)
      throw _invalid;
    final response = await client.request(
      'GET',
      XmlyClient.searchOrigin,
      '/revision/rank/v3/element',
      query: {'typeId': typeId, 'clusterId': clusterId},
      account: false,
    );
    final data = xmlyMap(response['data']);
    if (_integer(data['typeId']) != typeId ||
        _integer(data['clusterId']) != clusterId)
      throw _invalid;
    final rank = _rows(data['rankList']).where((row) {
      AppLog.instance.trace(
        "lib/api/xmly_ranking.dart::XmlyRanking.hot.closure#4",
      );

      return _integer(row['rankId']) == rankId;
    }).firstOrNull;
    if (rank == null) throw _invalid;
    final title = _text(rank['title']).trim();
    final rows = _rows(rank['albums']);
    final count = _integer(rank['count']);
    // A smaller response is not a complete chart. Never invent extra pages or
    // silently label a truncated preview as the full ranking.
    if (title.isEmpty || count != rows.length) throw _invalid;
    final albums = <Album>[];
    final stats = <String, HomeAlbumStats>{};
    final seen = <String>{};
    for (final row in rows) {
      final id = xmlyIdentifier('${row['id'] ?? ''}');
      if (!seen.add(id)) throw _invalid;
      albums.add(
        Album.fromApi({
          'albumId': id,
          'title': _text(row['albumTitle']),
          'nickname': _text(row['anchorName']),
          'intro': _text(row['description']),
          'tracks': _integer(row['trackCount']) ?? 0,
          'coverLarge': _cover(row['cover']),
          'isPaid': row['isPaid'],
        }),
      );
      stats[id] = HomeAlbumStats(playCount: _integer(row['playCount']));
    }
    return HomeSection(
      title: _integer(selected['categoryId']) == 0 && title == '热播榜'
          ? '全站热播榜'
          : title,
      albums: albums,
      isRanking: true,
      stats: stats,
    );
  }

  static List<Map<String, dynamic>> _rows(Object? value) {
    AppLog.instance.trace('lib/api/xmly_ranking.dart::XmlyRanking._rows');
    if (value is! List || value.length > 500) throw _invalid;
    final result = <Map<String, dynamic>>[];
    for (final row in value) {
      if (row is! Map<String, dynamic>) throw _invalid;
      result.add(row);
    }
    return result;
  }

  static int? _integer(Object? value) {
    AppLog.instance.trace('lib/api/xmly_ranking.dart::XmlyRanking._integer');
    if (value is int && value >= 0) return value;
    if (value is String) {
      final number = int.tryParse(value);
      if (number != null && number >= 0) return number;
    }
    return null;
  }

  static String _text(Object? value) {
    AppLog.instance.trace('lib/api/xmly_ranking.dart::XmlyRanking._text');
    return value is String ? value : '';
  }

  static String? _cover(Object? value) {
    AppLog.instance.trace('lib/api/xmly_ranking.dart::XmlyRanking._cover');
    if (value is! String || value.isEmpty) return null;
    if (value.startsWith('//')) return 'https:$value';
    if (value.startsWith('storages/') || RegExp(r'^group\d+/').hasMatch(value))
      return 'https://imagev2.xmcdn.com/$value';
    return value;
  }
}
