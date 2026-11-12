import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../api/xmly_client.dart';
import '../api/xmly_comments.dart';
import '../models/xmly_models.dart';
import '../common/widgets/logged_network_image.dart';
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
        'empty_comment',
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
  final _compose = TextEditingController();
  bool _sending = false;
  String? _composeError;
  late _CommentFeed _feed;
  String? _expandedComment;

  @override
  void initState() {
    AppLog.instance.trace(
      "lib/pages/track_comments_panel.dart::_TrackCommentsPanelState.initState",
    );

    super.initState();
    _scroll.addListener(_loadNearEnd);
    widget.runtime.addListener(_accountChanged);
    _openFeed();
  }

  void _openFeed() {
    AppLog.instance.trace(
      "lib/pages/track_comments_panel.dart::_TrackCommentsPanelState._openFeed",
    );

    _feed = _CommentFeed(widget.runtime.client, widget.track.id)
      ..addListener(_feedChanged);
    unawaited(_feed.load(reset: true));
  }

  void _accountChanged() {
    AppLog.instance.trace(
      'lib/pages/track_comments_panel.dart::_TrackCommentsPanelState._accountChanged',
    );
    if (identical(_feed.client, widget.runtime.client)) return;
    _feed.dispose();
    _expandedComment = null;
    _openFeed();
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

  Future<void> _send() async {
    AppLog.instance.trace(
      'lib/pages/track_comments_panel.dart::_TrackCommentsPanelState._send',
    );
    if (_sending) return;
    final client = widget.runtime.client, trackId = widget.track.id;
    final content = _compose.text;
    setState(() {
      AppLog.instance.trace(
        "lib/pages/track_comments_panel.dart::_TrackCommentsPanelState._send.closure#1",
      );

      _sending = true;
      _composeError = null;
    });
    try {
      if (widget.runtime.accounts.admissionPaused) {
        throw const XmlyException('account_changed', '账号正在切换，请稍后重试');
      }
      await XmlyComments(client).create(trackId, content);
      if (!mounted ||
          widget.track.id != trackId ||
          !identical(client, widget.runtime.client))
        return;
      _compose.clear();
      FocusScope.of(context).unfocus();
      await _refresh();
    } catch (error, stack) {
      _recordCommentsError('Creating comment failed', error, stack);
      if (mounted &&
          widget.track.id == trackId &&
          identical(client, widget.runtime.client)) {
        setState(() {
          AppLog.instance.trace(
            "lib/pages/track_comments_panel.dart::_TrackCommentsPanelState._send.closure#2",
          );

          _composeError = error is XmlyException ? error.message : '评论发送失败，请重试';
        });
      }
    } finally {
      if (mounted)
        setState(() {
          AppLog.instance.trace(
            "lib/pages/track_comments_panel.dart::_TrackCommentsPanelState._send.closure#3",
          );

          _sending = false;
        });
    }
  }

  @override
  void didUpdateWidget(covariant TrackCommentsPanel oldWidget) {
    AppLog.instance.trace(
      "lib/pages/track_comments_panel.dart::_TrackCommentsPanelState.didUpdateWidget",
    );

    super.didUpdateWidget(oldWidget);
    if (oldWidget.runtime != widget.runtime) {
      oldWidget.runtime.removeListener(_accountChanged);
      widget.runtime.addListener(_accountChanged);
    }
    if (oldWidget.runtime != widget.runtime ||
        oldWidget.track.id != widget.track.id) {
      _feed.dispose();
      _expandedComment = null;
      _compose.clear();
      _composeError = null;
      if (_scroll.hasClients) _scroll.jumpTo(0);
      _openFeed();
    }
  }

  @override
  void dispose() {
    AppLog.instance.trace(
      "lib/pages/track_comments_panel.dart::_TrackCommentsPanelState.dispose",
    );

    widget.runtime.removeListener(_accountChanged);
    _feed.dispose();
    _scroll.dispose();
    _compose.dispose();
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
                    padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (index > 0)
                          Divider(
                            height: 1,
                            thickness: .5,
                            color: theme.colorScheme.outlineVariant,
                          ),
                        _CommentContent(
                          comment: comment,
                          runtime: widget.runtime,
                          trackId: widget.track.id,
                          onChanged: () {
                            AppLog.instance.trace(
                              "lib/pages/track_comments_panel.dart::_TrackCommentsPanelState.build.closure#1.closure#1",
                            );
                            return _feed.load(reset: true);
                          },
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
                                    minimumSize: const Size(48, 48),
                                  ),
                                  onPressed: () {
                                    AppLog.instance.trace(
                                      "lib/pages/track_comments_panel.dart::_TrackCommentsPanelState.build.closure#1.closure#2",
                                    );
                                    setState(() {
                                      AppLog.instance.trace(
                                        "lib/pages/track_comments_panel.dart::_TrackCommentsPanelState.build.closure#1.closure#2.closure#1",
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
                                  runtime: widget.runtime,
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
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _compose,
                      enabled: !_sending,
                      minLines: 1,
                      maxLines: 4,
                      textInputAction: TextInputAction.newline,
                      decoration: InputDecoration(
                        hintText: widget.runtime.client.accountAvailable
                            ? '写评论…'
                            : '登录后可发表评论',
                        isDense: true,
                        border: const OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    tooltip: '发送评论',
                    onPressed: _sending ? null : _send,
                    constraints: const BoxConstraints(
                      minWidth: 48,
                      minHeight: 48,
                    ),
                    icon: _sending
                        ? const SizedBox.square(
                            dimension: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.send_outlined),
                  ),
                ],
              ),
              if (_composeError != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    _composeError!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _CommentContent extends StatefulWidget {
  const _CommentContent({
    super.key,
    required this.comment,
    required this.runtime,
    required this.trackId,
    required this.onChanged,
    this.action,
  });
  final TrackComment comment;
  final AppRuntime runtime;
  final String trackId;
  final Future<void> Function() onChanged;
  final Widget? action;

  @override
  State<_CommentContent> createState() {
    AppLog.instance.trace(
      'lib/pages/track_comments_panel.dart::_CommentContent.createState',
    );
    return _CommentContentState();
  }
}

class _CommentContentState extends State<_CommentContent> {
  bool _busy = false;
  TrackComment? _updated;
  String? _error;

  @override
  void didUpdateWidget(covariant _CommentContent oldWidget) {
    AppLog.instance.trace(
      'lib/pages/track_comments_panel.dart::_CommentContentState.didUpdateWidget',
    );
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.comment, widget.comment)) _updated = null;
  }

  Future<void> _mutate({bool delete = false}) async {
    AppLog.instance.trace(
      'lib/pages/track_comments_panel.dart::_CommentContentState._mutate',
    );
    if (_busy) return;
    final runtime = widget.runtime, client = widget.runtime.client;
    final comment = _updated ?? widget.comment;
    setState(() {
      AppLog.instance.trace(
        "lib/pages/track_comments_panel.dart::_CommentContentState._mutate.closure#1",
      );

      _error = null;
      _busy = true;
    });
    try {
      if (runtime.accounts.admissionPaused) {
        throw const XmlyException('account_changed', '账号正在切换，请稍后重试');
      }
      if (!client.accountAvailable) {
        throw const XmlyException('login_required', '请先登录账号后再操作评论');
      }
      if (delete) {
        if (comment.uid != client.credentials?.uid) {
          throw const XmlyException('permission_denied', '只能删除自己的评论');
        }
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) {
            AppLog.instance.trace(
              "lib/pages/track_comments_panel.dart::_CommentContentState._mutate.closure#2",
            );
            return AlertDialog(
              title: const Text('删除评论？'),
              content: const Text('删除后无法恢复。'),
              actions: [
                TextButton(
                  onPressed: () {
                    AppLog.instance.trace(
                      "lib/pages/track_comments_panel.dart::_CommentContentState._mutate.closure#2.closure#1",
                    );
                    Navigator.pop(context, false);
                  },
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () {
                    AppLog.instance.trace(
                      "lib/pages/track_comments_panel.dart::_CommentContentState._mutate.closure#2.closure#2",
                    );
                    Navigator.pop(context, true);
                  },
                  child: const Text('删除'),
                ),
              ],
            );
          },
        );
        if (confirmed != true || !mounted) return;
      }
      if (!identical(client, runtime.client) ||
          runtime.accounts.admissionPaused) {
        throw const XmlyException('account_changed', '账号已切换，请重新操作');
      }
      final api = XmlyComments(client);
      if (delete) {
        await api.delete(widget.trackId, comment);
      } else {
        await api.setLiked(widget.trackId, comment, liked: !comment.liked);
        if (mounted)
          setState(() {
            AppLog.instance.trace(
              "lib/pages/track_comments_panel.dart::_CommentContentState._mutate.closure#3",
            );

            _updated = comment.withLike(!comment.liked);
          });
      }
      if (mounted && identical(client, runtime.client))
        await widget.onChanged();
    } catch (error, stack) {
      _recordCommentsError('Comment mutation failed', error, stack);
      if (mounted)
        setState(() {
          AppLog.instance.trace(
            "lib/pages/track_comments_panel.dart::_CommentContentState._mutate.closure#4",
          );

          _error = error is XmlyException ? error.message : '评论操作失败，请重试';
        });
    } finally {
      if (mounted)
        setState(() {
          AppLog.instance.trace(
            "lib/pages/track_comments_panel.dart::_CommentContentState._mutate.closure#5",
          );

          _busy = false;
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace(
      'lib/pages/track_comments_panel.dart::_CommentContentState.build',
    );
    final theme = Theme.of(context), comment = _updated ?? widget.comment;
    final own =
        comment.uid.isNotEmpty &&
        comment.uid == widget.runtime.client.credentials?.uid;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: ClipOval(
            child: SizedBox.square(
              dimension: 32,
              child: comment.avatarUrl == null
                  ? const Icon(Icons.account_circle_outlined, size: 32)
                  : Image(
                      image: LoggedNetworkImage(comment.avatarUrl.toString()),
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stack) {
                        AppLog.instance.trace(
                          "lib/pages/track_comments_panel.dart::_CommentContentState.build.closure#1",
                        );
                        return const Icon(
                          Icons.account_circle_outlined,
                          size: 32,
                        );
                      },
                    ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(
                            comment.author.isEmpty ? '听友' : comment.author,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall?.copyWith(
                              color: theme.colorScheme.primary,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            comment.createdAt,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Semantics(
                    label:
                        '${comment.liked ? '取消点赞' : '点赞'}，${comment.likes} 个赞',
                    selected: comment.liked,
                    child: TextButton.icon(
                      style: TextButton.styleFrom(
                        minimumSize: const Size(48, 48),
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        foregroundColor: comment.liked
                            ? theme.colorScheme.primary
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                      onPressed: _busy
                          ? null
                          : () {
                              AppLog.instance.trace(
                                "lib/pages/track_comments_panel.dart::_CommentContentState.build.closure#2",
                              );
                              _mutate();
                            },
                      icon: _busy
                          ? const SizedBox.square(
                              dimension: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Icon(
                              comment.liked
                                  ? Icons.thumb_up
                                  : Icons.thumb_up_outlined,
                              size: 18,
                            ),
                      label: Text('${comment.likes}'),
                    ),
                  ),
                ],
              ),
              if (comment.parentAuthor.isNotEmpty)
                Text(
                  '回复 ${comment.parentAuthor}',
                  style: theme.textTheme.bodySmall,
                ),
              CommentText(
                comment.content,
                style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
              ),
              if (widget.action != null || own)
                Row(
                  children: [
                    if (widget.action != null) widget.action!,
                    if (own)
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () {
                                AppLog.instance.trace(
                                  "lib/pages/track_comments_panel.dart::_CommentContentState.build.closure#3",
                                );
                                _mutate(delete: true);
                              },
                        style: TextButton.styleFrom(
                          minimumSize: const Size(48, 48),
                        ),
                        child: const Text('删除'),
                      ),
                  ],
                ),
              if (_error != null)
                Text(
                  _error!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _InlineReplies extends StatefulWidget {
  const _InlineReplies({
    required this.runtime,
    required this.trackId,
    required this.commentId,
    super.key,
  });
  final AppRuntime runtime;
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
      widget.runtime.client,
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(48, 8, 8, 4),
      child: ListenableBuilder(
        listenable: _feed,
        builder: (context, _) {
          AppLog.instance.trace(
            "lib/pages/track_comments_panel.dart::_InlineRepliesState.build.closure#1",
          );
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (index, comment)
                  in _feed.comments.take(_visibleCount).indexed) ...[
                if (index > 0)
                  Divider(
                    height: 1,
                    thickness: .5,
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: _CommentContent(
                    key: ValueKey(comment.id),
                    comment: comment,
                    runtime: widget.runtime,
                    trackId: widget.trackId,
                    onChanged: () {
                      AppLog.instance.trace(
                        "lib/pages/track_comments_panel.dart::_InlineRepliesState.build.closure#1.closure#1",
                      );
                      return _feed.load(reset: true);
                    },
                  ),
                ),
              ],
              if (_visibleCount < _feed.comments.length)
                TextButton(
                  onPressed: () {
                    AppLog.instance.trace(
                      "lib/pages/track_comments_panel.dart::_InlineRepliesState.build.closure#1.closure#2",
                    );
                    setState(() {
                      AppLog.instance.trace(
                        "lib/pages/track_comments_panel.dart::_InlineRepliesState.build.closure#1.closure#2.closure#1",
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
                      "lib/pages/track_comments_panel.dart::_InlineRepliesState.build.closure#1.closure#3",
                    );

                    await _feed.load();
                    if (mounted)
                      setState(() {
                        AppLog.instance.trace(
                          "lib/pages/track_comments_panel.dart::_InlineRepliesState.build.closure#1.closure#3.closure#1",
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
  bool _resetPending = false;
  String? error;

  Future<void> load({bool reset = false}) {
    AppLog.instance.trace(
      "lib/pages/track_comments_panel.dart::_CommentFeed.load",
    );

    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/pages/track_comments_panel.dart::_CommentFeed.load.closure#1",
      );

      if (_disposed || (!reset && page >= 250)) return;
      if (busy) {
        _resetPending = _resetPending || reset;
        return;
      }
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
          if (_resetPending) {
            _resetPending = false;
            unawaited(load(reset: true));
          }
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
