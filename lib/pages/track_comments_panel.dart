import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../api/xmly_client.dart';
import '../api/xmly_comments.dart';
import '../models/xmly_models.dart';
import '../services/app_log.dart';
import '../services/app_runtime.dart';
import 'comment_text.dart';

void _recordCommentsError(
  String operation,
  Object error,
  StackTrace stack, {
  bool recoverable = false,
}) {
  AppLog.instance.trace(
    "lib/pages/track_comments_panel.dart::_recordCommentsError",
  );

  final log = AppLog.instance;
  if (log.errorWasRecorded(error)) return;
  final expected =
      error is XmlyException &&
      const {
        'client_closed',
        'request_cancelled',
        'cancelled',
        'download_stopped',
        'stopped',
        'closed',
        'login_required',
        'login_expired',
        'auth_required',
        'account_changed',
        'account_mismatch',
        'missing_account',
        'confirmation_required',
        'confirmation_changed',
        'insufficient_quota',
        'usage_uncertain',
        'rate_limited',
        'queue_full',
        'catalogue_limit',
      }.contains(error.code);
  log.write(
    recoverable || expected ? AppLogLevel.warning : AppLogLevel.error,
    'track_comments_panel',
    operation,
    error: error,
    stackTrace: stack,
    promptUser: !recoverable && !expected,
  );
}

class TrackCommentsPanel extends StatefulWidget {
  const TrackCommentsPanel({
    required this.runtime,
    required this.track,
    this.onClose,
    super.key,
  });

  final AppRuntime runtime;
  final Track track;
  final VoidCallback? onClose;

  @override
  State<TrackCommentsPanel> createState() {
    AppLog.instance.trace(
      "lib/pages/track_comments_panel.dart::TrackCommentsPanel.createState",
    );
    return _TrackCommentsPanelState();
  }
}

class _TrackCommentsPanelState extends State<TrackCommentsPanel> {
  final _scroll = ScrollController();
  late _CommentFeed _feed;
  String? _expandedComment;

  @override
  void initState() {
    AppLog.instance.trace(
      "lib/pages/track_comments_panel.dart::_TrackCommentsPanelState.initState",
    );

    super.initState();
    _scroll.addListener(_loadNearEnd);
    _openFeed();
  }

  void _openFeed() {
    AppLog.instance.trace(
      "lib/pages/track_comments_panel.dart::_TrackCommentsPanelState._openFeed",
    );

    _feed = _CommentFeed(widget.runtime.anonymous, widget.track.id)
      ..addListener(_feedChanged);
    unawaited(_feed.load(reset: true));
  }

  void _feedChanged() {
    AppLog.instance.trace(
      "lib/pages/track_comments_panel.dart::_TrackCommentsPanelState._feedChanged",
    );

    if (!mounted) return;
    setState(() {
      AppLog.instance.trace(
        "lib/pages/track_comments_panel.dart::_TrackCommentsPanelState._feedChanged.closure#1",
      );
    });
    if (!_feed.busy) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        AppLog.instance.trace(
          "lib/pages/track_comments_panel.dart::_TrackCommentsPanelState._feedChanged.closure#2",
        );

        if (mounted) _loadNearEnd();
      });
    }
  }

  void _loadNearEnd() {
    AppLog.instance.trace(
      "lib/pages/track_comments_panel.dart::_TrackCommentsPanelState._loadNearEnd",
    );

    if (_scroll.hasClients &&
        _scroll.position.extentAfter < 240 &&
        _feed.hasMore &&
        _feed.error == null &&
        _feed.page < 250) {
      unawaited(_feed.load());
    }
  }

  Future<void> _refresh() async {
    AppLog.instance.trace(
      "lib/pages/track_comments_panel.dart::_TrackCommentsPanelState._refresh",
    );

    if (_feed.busy) return;
    setState(() {
      AppLog.instance.trace(
        "lib/pages/track_comments_panel.dart::_TrackCommentsPanelState._refresh.closure#1",
      );
      _expandedComment = null;
    });
    final feed = _feed;
    await feed.load(reset: true);
    if (mounted &&
        identical(feed, _feed) &&
        feed.error == null &&
        _scroll.hasClients) {
      _scroll.jumpTo(0);
    }
  }

  @override
  void didUpdateWidget(covariant TrackCommentsPanel oldWidget) {
    AppLog.instance.trace(
      "lib/pages/track_comments_panel.dart::_TrackCommentsPanelState.didUpdateWidget",
    );

    super.didUpdateWidget(oldWidget);
    if (oldWidget.runtime != widget.runtime ||
        oldWidget.track.id != widget.track.id) {
      _feed.dispose();
      _expandedComment = null;
      if (_scroll.hasClients) _scroll.jumpTo(0);
      _openFeed();
    }
  }

  @override
  void dispose() {
    AppLog.instance.trace(
      "lib/pages/track_comments_panel.dart::_TrackCommentsPanelState.dispose",
    );

    _feed.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace(
      "lib/pages/track_comments_panel.dart::_TrackCommentsPanelState.build",
    );

    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text.rich(
                TextSpan(
                  text: _feed.page > 0 ? '共' : '评论',
                  children: [
                    if (_feed.page > 0)
                      TextSpan(
                        text: ' ${_feed.total} 条评论',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            IconButton(
              tooltip: '刷新评论',
              onPressed: _feed.busy ? null : _refresh,
              icon: const Icon(Icons.refresh_rounded, size: 20),
            ),
            if (widget.onClose != null)
              IconButton(
                tooltip: '收起评论',
                onPressed: widget.onClose,
                icon: const Icon(Icons.close_rounded, size: 20),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(
          child: Scrollbar(
            controller: _scroll,
            child: RefreshIndicator(
              onRefresh: _refresh,
              child: ListView.builder(
                key: const ValueKey('trackCommentsScroll'),
                controller: _scroll,
                primary: false,
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.only(bottom: 16),
                itemCount: _feed.comments.length + 1,
                itemBuilder: (context, index) {
                  AppLog.instance.trace(
                    "lib/pages/track_comments_panel.dart::_TrackCommentsPanelState.build.closure#1",
                  );

                  if (index == _feed.comments.length) {
                    return _FeedFooter(feed: _feed, emptyLabel: '还没有评论');
                  }
                  final comment = _feed.comments[index];
                  final expanded = _expandedComment == comment.id;
                  return Padding(
                    key: ValueKey((widget.track.id, comment.id)),
                    padding: const EdgeInsets.fromLTRB(4, 16, 12, 20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _CommentContent(
                          comment: comment,
                          action: comment.replyCount == 0
                              ? null
                              : TextButton.icon(
                                  key: ValueKey('commentReplies:${comment.id}'),
                                  style: TextButton.styleFrom(
                                    foregroundColor:
                                        theme.colorScheme.onSurfaceVariant,
                                    textStyle: theme.textTheme.bodySmall,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                    ),
                                    minimumSize: const Size(0, 36),
                                  ),
                                  onPressed: () {
                                    AppLog.instance.trace(
                                      "lib/pages/track_comments_panel.dart::_TrackCommentsPanelState.build.closure#1.closure#1",
                                    );
                                    setState(() {
                                      AppLog.instance.trace(
                                        "lib/pages/track_comments_panel.dart::_TrackCommentsPanelState.build.closure#1.closure#1.closure#1",
                                      );

                                      _expandedComment = expanded
                                          ? null
                                          : comment.id;
                                    });
                                  },
                                  icon: Icon(
                                    expanded
                                        ? Icons.expand_less
                                        : Icons.expand_more,
                                    size: 18,
                                  ),
                                  label: Text(
                                    expanded
                                        ? '收起回复'
                                        : '${comment.replyCount} 条回复',
                                  ),
                                ),
                        ),
                        AnimatedSize(
                          duration: MediaQuery.disableAnimationsOf(context)
                              ? Duration.zero
                              : const Duration(milliseconds: 200),
                          curve: Curves.easeInOutCubic,
                          alignment: Alignment.topCenter,
                          child: expanded
                              ? _InlineReplies(
                                  key: ValueKey((widget.track.id, comment.id)),
                                  client: widget.runtime.anonymous,
                                  trackId: widget.track.id,
                                  commentId: comment.id,
                                )
                              : const SizedBox(width: double.infinity),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _CommentContent extends StatelessWidget {
  const _CommentContent({required this.comment, this.action});
  final TrackComment comment;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace(
      "lib/pages/track_comments_panel.dart::_CommentContent.build",
    );

    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          comment.author.isEmpty ? '听友' : comment.author,
          style: theme.textTheme.titleSmall?.copyWith(
            color: theme.colorScheme.primary,
          ),
        ),
        if (comment.parentAuthor.isNotEmpty)
          Text('回复 ${comment.parentAuthor}', style: theme.textTheme.bodySmall),
        const SizedBox(height: 8),
        CommentText(
          comment.content,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontSize: 15,
            height: 1.65,
          ),
        ),
        const SizedBox(height: 8),
        DefaultTextStyle(
          style: theme.textTheme.bodySmall!.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  comment.createdAt,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 16),
              Semantics(
                label: '${comment.likes} 个赞',
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.thumb_up_outlined,
                      size: 14,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 5),
                    Text('${comment.likes}'),
                  ],
                ),
              ),
              if (action != null) ...[const SizedBox(width: 12), action!],
            ],
          ),
        ),
      ],
    );
  }
}

class _InlineReplies extends StatefulWidget {
  const _InlineReplies({
    required this.client,
    required this.trackId,
    required this.commentId,
    super.key,
  });
  final XmlyClient client;
  final String trackId, commentId;

  @override
  State<_InlineReplies> createState() {
    AppLog.instance.trace(
      "lib/pages/track_comments_panel.dart::_InlineReplies.createState",
    );
    return _InlineRepliesState();
  }
}

class _InlineRepliesState extends State<_InlineReplies>
    with AutomaticKeepAliveClientMixin {
  late final _CommentFeed _feed;
  int _visibleCount = 3;

  @override
  bool get wantKeepAlive {
    AppLog.instance.trace(
      "lib/pages/track_comments_panel.dart::_InlineRepliesState.wantKeepAlive.get",
    );
    return true;
  }

  @override
  void initState() {
    AppLog.instance.trace(
      "lib/pages/track_comments_panel.dart::_InlineRepliesState.initState",
    );

    super.initState();
    _feed = _CommentFeed(
      widget.client,
      widget.trackId,
      commentId: widget.commentId,
    );
    unawaited(_feed.load(reset: true));
  }

  @override
  void dispose() {
    AppLog.instance.trace(
      "lib/pages/track_comments_panel.dart::_InlineRepliesState.dispose",
    );

    _feed.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace(
      "lib/pages/track_comments_panel.dart::_InlineRepliesState.build",
    );

    super.build(context);
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
      ),
      child: ListenableBuilder(
        listenable: _feed,
        builder: (context, _) {
          AppLog.instance.trace(
            "lib/pages/track_comments_panel.dart::_InlineRepliesState.build.closure#1",
          );
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final comment in _feed.comments.take(_visibleCount))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: _CommentContent(comment: comment),
                ),
              if (_visibleCount < _feed.comments.length)
                TextButton(
                  onPressed: () {
                    AppLog.instance.trace(
                      "lib/pages/track_comments_panel.dart::_InlineRepliesState.build.closure#1.closure#1",
                    );
                    setState(() {
                      AppLog.instance.trace(
                        "lib/pages/track_comments_panel.dart::_InlineRepliesState.build.closure#1.closure#1.closure#1",
                      );

                      _visibleCount = math.min(
                        _visibleCount + 10,
                        _feed.comments.length,
                      );
                    });
                  },
                  child: const Text('展开更多回复'),
                )
              else
                _FeedFooter(
                  feed: _feed,
                  emptyLabel: '还没有回复',
                  onMore: () async {
                    AppLog.instance.trace(
                      "lib/pages/track_comments_panel.dart::_InlineRepliesState.build.closure#1.closure#2",
                    );

                    await _feed.load();
                    if (mounted)
                      setState(() {
                        AppLog.instance.trace(
                          "lib/pages/track_comments_panel.dart::_InlineRepliesState.build.closure#1.closure#2.closure#1",
                        );
                        _visibleCount += 10;
                      });
                  },
                ),
            ],
          );
        },
      ),
    );
  }
}

class _FeedFooter extends StatelessWidget {
  const _FeedFooter({
    required this.feed,
    required this.emptyLabel,
    this.onMore,
  });
  final _CommentFeed feed;
  final String emptyLabel;
  final VoidCallback? onMore;

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace(
      "lib/pages/track_comments_panel.dart::_FeedFooter.build",
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Center(
        child: feed.busy
            ? const SizedBox.square(
                dimension: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : feed.error != null
            ? Column(
                children: [
                  Text(
                    feed.error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                  TextButton(
                    onPressed: () {
                      AppLog.instance.trace(
                        "lib/pages/track_comments_panel.dart::_FeedFooter.build.closure#1",
                      );
                      feed.load(reset: feed.retryReset);
                    },
                    child: const Text('重试'),
                  ),
                ],
              )
            : feed.comments.isEmpty
            ? Text(emptyLabel)
            : feed.hasMore
            ? TextButton(
                onPressed: feed.page >= 250
                    ? null
                    : onMore ??
                          () {
                            AppLog.instance.trace(
                              "lib/pages/track_comments_panel.dart::_FeedFooter.build.closure#2",
                            );
                            feed.load();
                          },
                child: Text(feed.page >= 250 ? '已加载 5000 条，请刷新查看' : '加载更多'),
              )
            : Text(
                '已显示全部',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
      ),
    );
  }
}

class _CommentFeed extends ChangeNotifier {
  _CommentFeed(this.client, this.trackId, {this.commentId}) {
    AppLog.instance.trace(
      "lib/pages/track_comments_panel.dart::_CommentFeed.new",
    );
  }
  final XmlyClient client;
  final String trackId;
  final String? commentId;
  List<TrackComment> comments = [];
  int page = 0, total = 0, _request = 0;
  bool busy = false, hasMore = false, retryReset = true, _disposed = false;
  String? error;

  Future<void> load({bool reset = false}) {
    AppLog.instance.trace(
      "lib/pages/track_comments_panel.dart::_CommentFeed.load",
    );

    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/pages/track_comments_panel.dart::_CommentFeed.load.closure#1",
      );

      if (_disposed || busy || (!reset && page >= 250)) return;
      final request = ++_request;
      final nextPage = reset ? 1 : page + 1;
      busy = true;
      retryReset = reset;
      error = null;
      notifyListeners();
      try {
        final result = await XmlyComments(client)
            .load(trackId, page: nextPage, commentId: commentId);
        if (_disposed || request != _request) return;
        final known = reset
            ? <String>{}
            : comments.map((row) {
                AppLog.instance.trace(
                  "lib/pages/track_comments_panel.dart::_CommentFeed.load.closure#1.closure#1",
                );
                return row.id;
              }).toSet();
        final added = result.comments.where((row) {
          AppLog.instance.trace(
            "lib/pages/track_comments_panel.dart::_CommentFeed.load.closure#1.closure#2",
          );
          return known.add(row.id);
        }).toList();
        if (result.hasMore && added.isEmpty) {
          throw const XmlyException('repeated_comments', '评论分页没有前进，请刷新后重试');
        }
        comments = [if (!reset) ...comments, ...added];
        page = nextPage;
        total = result.total;
        hasMore = result.hasMore;
      } catch (failure, stack) {
        _recordCommentsError('Comments load failed', failure, stack);
        if (!_disposed && request == _request) {
          error = failure is XmlyException ? failure.message : '评论加载失败，请重试';
        }
      } finally {
        if (!_disposed && request == _request) {
          busy = false;
          notifyListeners();
        }
      }
    });
  }

  @override
  void dispose() {
    AppLog.instance.trace(
      "lib/pages/track_comments_panel.dart::_CommentFeed.dispose",
    );

    _disposed = true;
    _request++;
    super.dispose();
  }
}
