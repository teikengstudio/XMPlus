import '../models/xmly_models.dart';
import 'xmly_client.dart';
import '../services/app_log.dart';

class TrackComment {
  const TrackComment({
    required this.id,
    required this.author,
    required this.content,
    required this.createdAt,
    required this.likes,
    required this.replyCount,
    this.parentAuthor = '',
    this.uid = '',
    this.avatarUrl,
    this.liked = false,
  });

  final String id, author, content, createdAt, parentAuthor, uid;
  final Uri? avatarUrl;
  final int likes, replyCount;
  final bool liked;

  TrackComment withLike(bool value) {
    AppLog.instance.trace('lib/api/xmly_comments.dart::TrackComment.withLike');
    return TrackComment(
      id: id,
      author: author,
      content: content,
      createdAt: createdAt,
      likes:
          (likes +
                  (value == liked
                      ? 0
                      : value
                      ? 1
                      : -1))
              .clamp(0, 0x7fffffff),
      replyCount: replyCount,
      parentAuthor: parentAuthor,
      uid: uid,
      avatarUrl: avatarUrl,
      liked: value,
    );
  }
}

class TrackCommentPage {
  TrackCommentPage({
    required List<TrackComment> comments,
    required this.total,
    required this.hasMore,
  }) : comments = List.unmodifiable(comments) {
    AppLog.instance.trace('lib/api/xmly_comments.dart::TrackCommentPage.new');
  }
  final List<TrackComment> comments;
  final int total;
  final bool hasMore;
}

class XmlyComments {
  XmlyComments(this.client) {
    AppLog.instance.trace('lib/api/xmly_comments.dart::XmlyComments.new');
  }
  final XmlyClient client;
  static const _invalid = XmlyException('invalid_comments', '评论列表格式无效，请重试');

  static int _count(Object? value) {
    AppLog.instance.trace('lib/api/xmly_comments.dart::XmlyComments._count');
    if (value is! int || value < 0) throw _invalid;
    return value;
  }

  static String _text(Object? value) {
    AppLog.instance.trace('lib/api/xmly_comments.dart::XmlyComments._text');
    return value is String ? value : '';
  }

  static Uri? _avatar(Object? value) {
    AppLog.instance.trace('lib/api/xmly_comments.dart::XmlyComments._avatar');
    if (value is! String || value.length > 16384) return null;
    final uri = Uri.tryParse(value);
    if (uri == null ||
        !['https', 'http'].contains(uri.scheme) ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        !(uri.host == 'xmcdn.com' || uri.host.endsWith('.xmcdn.com')) ||
        uri.hasPort)
      return null;
    return uri.replace(scheme: 'https');
  }

  static String _createdAt(Object? value) {
    AppLog.instance.trace(
      'lib/api/xmly_comments.dart::XmlyComments._createdAt',
    );
    if (value is! int) return _text(value);
    if (value < 0 || value > 8640000000000000) throw _invalid;
    final date = DateTime.fromMillisecondsSinceEpoch(value).toLocal();
    String two(int part) {
      AppLog.instance.trace(
        'lib/api/xmly_comments.dart::XmlyComments._createdAt.two',
      );
      return '$part'.padLeft(2, '0');
    }

    return '${date.year}-${two(date.month)}-${two(date.day)} ${two(date.hour)}:${two(date.minute)}';
  }

  Future<TrackCommentPage> load(
    String trackId, {
    int page = 1,
    String? commentId,
  }) async {
    AppLog.instance.trace('lib/api/xmly_comments.dart::XmlyComments.load');
    if (page < 1 || page > 250) {
      throw const XmlyException('comment_limit', '最多读取 5000 条评论，请刷新后查看');
    }
    final replies = commentId != null;
    final number = xmlyIdentifier(trackId);
    final response = await client.request(
      'GET',
      replies ? XmlyClient.searchOrigin : XmlyClient.mobile,
      replies
          ? '/revision/comment/queryReplies'
          : '/comment-mobile/v1/track/comment/${DateTime.now().millisecondsSinceEpoch}',
      query: replies
          ? {
              'trackId': number,
              'commentId': xmlyIdentifier(commentId),
              'page': page,
              'pageSize': 20,
            }
          : {
              'trackId': number,
              'pageId': page,
              'pageSize': 20,
              'hotPageId': 1,
              'hotPageSize': 0,
              'order': 0,
              'showVersion': 1,
              'source': 2,
            },
      // Only the official mobile endpoint may receive this client's credentials.
      account: !replies && client.accountAvailable,
    );
    final data = xmlyMap(replies ? response['data'] : response['comment']);
    if (_count(data[replies ? 'currentPage' : 'pageId']) != page)
      throw _invalid;
    final total = _count(data[replies ? 'totalComment' : 'totalCount']);
    final pages = _count(data[replies ? 'totalPage' : 'maxPageId']);
    final raw = data[replies ? 'replies' : 'list'];
    if (raw is! List || raw.length > 20) throw _invalid;
    final comments = <TrackComment>[];
    final ids = <String>{};
    for (final value in raw) {
      final row = xmlyMap(value);
      final id = xmlyIdentifier('${row['id'] ?? ''}');
      if (!ids.add(id) ||
          row['content'] is! String ||
          (row['trackId'] != null &&
              xmlyIdentifier('${row['trackId']}') != number))
        throw _invalid;
      final uid = row['uid'] == null ? '' : xmlyIdentifier('${row['uid']}');
      comments.add(
        TrackComment(
          id: id,
          uid: uid,
          author: _text(row['nickname']),
          content: row['content'] as String,
          createdAt: _createdAt(row[replies ? 'createAt' : 'createdAt']),
          likes: _count(row['likes'] ?? 0),
          replyCount: _count(row['replyCount'] ?? 0),
          parentAuthor: _text(row['parentNickname']),
          avatarUrl: _avatar(row['smallHeader']),
          liked: row['liked'] == true || row['likeStatus'] == 1,
        ),
      );
    }
    return TrackCommentPage(
      comments: comments,
      total: total,
      hasMore: page < pages,
    );
  }

  Future<void> create(String trackId, String content) async {
    AppLog.instance.trace('lib/api/xmly_comments.dart::XmlyComments.create');
    final context = client.context();
    if (content.trim().isEmpty) {
      throw const XmlyException('empty_comment', '请输入评论内容', definitive: true);
    }
    // The captured create token is the normal login token after its UID prefix.
    await client.request(
      'POST',
      XmlyClient.mobile,
      '/comment-mobile/v1/create',
      data: {
        'uid': context['uid'],
        'token': context['token'],
        'setTop': 'false',
        'topExpireTime': '0',
        'trackId': xmlyIdentifier(trackId),
        'startTime': '0',
        'synchaos': '0',
        'endTime': '0',
        'content': content.trim(),
      },
      form: true,
    );
  }

  String _requireUid() {
    AppLog.instance.trace(
      'lib/api/xmly_comments.dart::XmlyComments._requireUid',
    );
    return client.context()['uid']!;
  }

  Future<void> setLiked(
    String trackId,
    TrackComment comment, {
    required bool liked,
  }) async {
    AppLog.instance.trace('lib/api/xmly_comments.dart::XmlyComments.setLiked');
    final uid = _requireUid();
    await client.request(
      'POST',
      XmlyClient.mobile,
      '/comment-mobile/like',
      data: {
        'uid': uid,
        'islike': '$liked',
        'trackId': xmlyIdentifier(trackId),
        'commentId': xmlyIdentifier(comment.id),
        'device': 'android',
      },
      form: true,
    );
  }

  Future<void> delete(String trackId, TrackComment comment) async {
    AppLog.instance.trace('lib/api/xmly_comments.dart::XmlyComments.delete');
    if (comment.uid.isEmpty || comment.uid != _requireUid()) {
      throw const XmlyException(
        'permission_denied',
        '只能删除当前账号自己的评论',
        definitive: true,
      );
    }
    await client.request(
      'POST',
      XmlyClient.mobile,
      '/mobile/comment/delete/${DateTime.now().millisecondsSinceEpoch}',
      data: {
        'trackId': xmlyIdentifier(trackId),
        'commentId': xmlyIdentifier(comment.id),
        'device': 'android',
      },
      form: true,
    );
  }
}
