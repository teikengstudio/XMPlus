import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../api/xmly_client.dart';
import '../api/xmly_comments.dart';
import '../models/xmly_models.dart';
import '../common/widgets/app_scrollbar.dart';
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
  // Switching away and back can reuse the same client while a send is pending.
  int _sendRequest = 0;
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
    _sendRequest++;
    _sending = false;
    _composeError = null;
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
    final request = ++_sendRequest;
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
          request != _sendRequest ||
          widget.track.id != trackId ||
          !identical(client, widget.runtime.client))
        return;
      _compose.clear();
      FocusScope.of(context).unfocus();
      await _refresh();
    } catch (error, stack) {
      _recordCommentsError('Creating comment failed', error, stack);
      if (mounted &&
          request == _sendRequest &&
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
      if (mounted && request == _sendRequest)
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
      _sendRequest++;
      _sending = false;
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

    return LayoutBuilder(builder: _buildPanel);
  }

  Widget _buildPanel(BuildContext context, BoxConstraints constraints) {
    AppLog.instance.trace(
      'lib/pages/track_comments_panel.dart::_TrackCommentsPanelState._buildPanel',
    );

    final theme = Theme.of(context);
    final inset = constraints.maxWidth < 600 ? 16.0 : 24.0;
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 880),
        child: Padding(
          padding: EdgeInsets.fromLTRB(inset, 12, inset, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _feed.page > 0 ? '${_feed.total} 条评论' : '评论',
                      style: theme.textTheme.titleSmall?.copyWith(
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
                child: AppScrollbar(
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
                          "lib/pages/track_comments_panel.dart::_TrackCommentsPanelState._buildPanel.closure#1",
                        );

                        if (index == _feed.comments.length) {
                          return _FeedFooter(feed: _feed, emptyLabel: '还没有评论');
                        }
                        final comment = _feed.comments[index];
                        final expanded = _expandedComment == comment.id;
                        return Padding(
                          key: ValueKey((widget.track.id, comment.id)),
                          padding: const EdgeInsets.only(bottom: 16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (index > 0) ...[
                                Divider(
                                  height: 1,
                                  thickness: .5,
                                  indent: 52,
                                  color: theme.colorScheme.outlineVariant
                                      .withValues(alpha: .5),
                                ),
                                const SizedBox(height: 16),
                              ],
                              _CommentContent(
                                key: ObjectKey(_feed),
                                comment: comment,
                                runtime: widget.runtime,
                                trackId: widget.track.id,
                                onLiked: _feed.setLiked,
                                onChanged: () {
                                  AppLog.instance.trace(
                                    "lib/pages/track_comments_panel.dart::_TrackCommentsPanelState._buildPanel.closure#1.closure#1",
                                  );
                                  return _feed.load(reset: true);
                                },
                                action: comment.replyCount == 0
                                    ? null
                                    : TextButton.icon(
                                        key: ValueKey(
                                          'commentReplies:${comment.id}',
                                        ),
                                        style: TextButton.styleFrom(
                                          foregroundColor: theme
                                              .colorScheme
                                              .onSurfaceVariant,
                                          textStyle: theme.textTheme.bodySmall,
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                          ),
                                          minimumSize: const Size(48, 48),
                                        ),
                                        onPressed: () {
                                          AppLog.instance.trace(
                                            "lib/pages/track_comments_panel.dart::_TrackCommentsPanelState._buildPanel.closure#1.closure#2",
                                          );
                                          setState(() {
                                            AppLog.instance.trace(
                                              "lib/pages/track_comments_panel.dart::_TrackCommentsPanelState._buildPanel.closure#1.closure#2.closure#1",
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
                                duration:
                                    MediaQuery.disableAnimationsOf(context)
                                    ? Duration.zero
                                    : const Duration(milliseconds: 200),
                                curve: Curves.easeInOutCubic,
                                alignment: Alignment.topCenter,
                                child: expanded
                                    ? _InlineReplies(
                                        key: ValueKey((
                                          widget.track.id,
                                          comment.id,
                                        )),
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
              DecoratedBox(
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface,
                  border: Border(
                    top: BorderSide(
                      color: theme.colorScheme.outlineVariant.withValues(
                        alpha: .5,
                      ),
                      width: .5,
                    ),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
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
                              style: theme.textTheme.bodyMedium?.copyWith(
                                height: 1.5,
                              ),
                              textInputAction: TextInputAction.newline,
                              decoration: InputDecoration(
                                hintText: widget.runtime.client.accountAvailable
                                    ? '写评论…'
                                    : '登录后可发表评论',
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 14,
                                ),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(16),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          IconButton.filledTonal(
                            tooltip: '发送评论',
                            onPressed: _sending ? null : _send,
                            constraints: const BoxConstraints(
                              minWidth: 48,
                              minHeight: 48,
                            ),
                            style: IconButton.styleFrom(
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                            ),
                            icon: _sending
                                ? const SizedBox.square(
                                    dimension: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
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
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CommentContent extends StatefulWidget {
  const _CommentContent({
    super.key,
    required this.comment,
    required this.runtime,
    required this.trackId,
    required this.onLiked,
    required this.onChanged,
    this.action,
    this.compact = false,
  });
  final TrackComment comment;
  final AppRuntime runtime;
  final String trackId;
  final void Function(String commentId, bool liked) onLiked;
  final Future<void> Function() onChanged;
  final Widget? action;
  final bool compact;

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
  String? _error;

  Future<void> _mutate({bool delete = false}) async {
    AppLog.instance.trace(
      'lib/pages/track_comments_panel.dart::_CommentContentState._mutate',
    );
    if (_busy) return;
    final runtime = widget.runtime, client = widget.runtime.client;
    final comment = widget.comment;
    final onLiked = widget.onLiked;
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
        if (mounted && identical(client, runtime.client))
          await widget.onChanged();
      } else {
        await api.setLiked(widget.trackId, comment, liked: !comment.liked);
        // The feed owns the result even if this row scrolled out of view.
        if (identical(client, runtime.client))
          onLiked(comment.id, !comment.liked);
      }
    } catch (error, stack) {
      _recordCommentsError('Comment mutation failed', error, stack);
      if (mounted)
        setState(() {
          AppLog.instance.trace(
            "lib/pages/track_comments_panel.dart::_CommentContentState._mutate.closure#3",
          );

          _error = error is XmlyException ? error.message : '评论操作失败，请重试';
        });
    } finally {
      if (mounted)
        setState(() {
          AppLog.instance.trace(
            "lib/pages/track_comments_panel.dart::_CommentContentState._mutate.closure#4",
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
    final theme = Theme.of(context), comment = widget.comment;
    final own =
        comment.uid.isNotEmpty &&
        comment.uid == widget.runtime.client.credentials?.uid;
    final avatarSize = widget.compact ? 32.0 : 40.0;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: ClipOval(
            child: SizedBox.square(
              dimension: avatarSize,
              child: comment.avatarUrl == null
                  ? Icon(Icons.account_circle_outlined, size: avatarSize)
                  : Image(
                      image: LoggedNetworkImage(comment.avatarUrl.toString()),
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stack) {
                        AppLog.instance.trace(
                          "lib/pages/track_comments_panel.dart::_CommentContentState.build.closure#1",
                        );
                        return Icon(
                          Icons.account_circle_outlined,
                          size: avatarSize,
                        );
                      },
                    ),
            ),
          ),
        ),
        SizedBox(width: widget.compact ? 10 : 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          comment.author.isEmpty ? '听友' : comment.author,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall?.copyWith(
                            color: theme.colorScheme.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (comment.createdAt.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(
                            comment.createdAt,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                              fontWeight: FontWeight.normal,
                              height: 1.4,
                            ),
                          ),
                        ],
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
              const SizedBox(height: 8),
              if (comment.parentAuthor.isNotEmpty) ...[
                Text(
                  '回复 ${comment.parentAuthor}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 4),
              ],
              CommentText(
                comment.content,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontSize: widget.compact ? 14 : 15,
                  height: 1.65,
                ),
              ),
              if (widget.action != null || own)
                Wrap(
                  spacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
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
      padding: const EdgeInsets.fromLTRB(24, 8, 0, 4),
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
                    indent: 42,
                    color: Theme.of(context).colorScheme.outlineVariant
                        .withValues(alpha: .5),
                  ),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: _CommentContent(
                    key: ValueKey(comment.id),
                    comment: comment,
                    runtime: widget.runtime,
                    trackId: widget.trackId,
                    compact: true,
                    onLiked: _feed.setLiked,
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
  Completer<void>? _pendingRefresh;
  final _likesDuringLoad = <String, bool>{};
  String? error;

  void setLiked(String id, bool liked) {
    AppLog.instance.trace(
      'lib/pages/track_comments_panel.dart::_CommentFeed.setLiked',
    );
    if (_disposed) return;
    if (busy) _likesDuringLoad[id] = liked;
    for (var index = 0; index < comments.length; index++) {
      final comment = comments[index];
      if (comment.id != id) continue;
      // A refresh may have replaced the row while the like was pending.
      comments[index] = comment.withLike(liked);
      notifyListeners();
      return;
    }
  }

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
        if (reset) {
          await (_pendingRefresh ??= Completer<void>()).future;
        }
        return;
      }
      final request = ++_request;
      final nextPage = reset ? 1 : page + 1;
      _likesDuringLoad.clear();
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
        // A response can predate likes that completed while it was loading.
        for (var index = 0; index < added.length; index++) {
          final liked = _likesDuringLoad[added[index].id];
          if (liked != null) added[index] = added[index].withLike(liked);
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
          _likesDuringLoad.clear();
          busy = false;
          final pending = _pendingRefresh;
          _pendingRefresh = null;
          if (pending == null) {
            notifyListeners();
          } else {
            try {
              await load(reset: true);
            } finally {
              pending.complete();
            }
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
    _likesDuringLoad.clear();
    _pendingRefresh?.complete();
    _pendingRefresh = null;
    super.dispose();
  }
}
