import 'package:flutter/material.dart';

import '../api/xmly_comments.dart';
import '../common/widgets/local_panel.dart';
import '../models/xmly_models.dart';
import '../services/app_log.dart';
import '../services/app_runtime.dart';

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

Future<void> showTrackComments(
  BuildContext context,
  AppRuntime runtime,
  Track track, {
  TrackComment? parent,
}) {
  AppLog.instance.trace(
    "lib/pages/track_comments_panel.dart::showTrackComments",
  );
  return showLocalPanel<void>(
    context: context,
    title: parent == null ? '单集评论' : '评论回复',
    builder: (_) {
      AppLog.instance.trace(
        "lib/pages/track_comments_panel.dart::showTrackComments.closure#1",
      );
      return TrackCommentsPanel(runtime: runtime, track: track, parent: parent);
    },
  );
}

class TrackCommentsPanel extends StatefulWidget {
  const TrackCommentsPanel({
    required this.runtime,
    required this.track,
    this.parent,
    super.key,
  });

  final AppRuntime runtime;
  final Track track;
  final TrackComment? parent;

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
  List<TrackComment> _comments = [];
  int _page = 0, _total = 0, _request = 0;
  bool _busy = false, _hasMore = false;
  bool _retryReset = true;
  String? _error;

  @override
  void initState() {
    AppLog.instance.trace(
      "lib/pages/track_comments_panel.dart::_TrackCommentsPanelState.initState",
    );

    super.initState();
    _load(reset: true);
  }

  @override
  void didUpdateWidget(covariant TrackCommentsPanel oldWidget) {
    AppLog.instance.trace(
      "lib/pages/track_comments_panel.dart::_TrackCommentsPanelState.didUpdateWidget",
    );

    super.didUpdateWidget(oldWidget);
    if (oldWidget.runtime != widget.runtime ||
        oldWidget.track.id != widget.track.id ||
        oldWidget.parent?.id != widget.parent?.id) {
      _request++;
      _comments = [];
      _page = _total = 0;
      _busy = _hasMore = false;
      _load(reset: true);
    }
  }

  @override
  void dispose() {
    AppLog.instance.trace(
      "lib/pages/track_comments_panel.dart::_TrackCommentsPanelState.dispose",
    );

    _request++;
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load({bool reset = false}) {
    AppLog.instance.trace(
      "lib/pages/track_comments_panel.dart::_TrackCommentsPanelState._load",
    );
    return AppLog.instance.runWithErrorScope(() async {
      AppLog.instance.trace(
        "lib/pages/track_comments_panel.dart::_TrackCommentsPanelState._load.closure#1",
      );

      if (_busy) return;
      final request = ++_request;
      final page = reset ? 1 : _page + 1;
      setState(() {
        AppLog.instance.trace(
          "lib/pages/track_comments_panel.dart::_TrackCommentsPanelState._load.closure#1.closure#1",
        );

        _busy = true;
        _retryReset = reset;
        _error = null;
      });
      try {
        final result = await XmlyComments(widget.runtime.anonymous)
            .load(widget.track.id, page: page, commentId: widget.parent?.id);
        if (!mounted || request != _request) return;
        final known = reset
            ? <String>{}
            : _comments.map((row) {
                AppLog.instance.trace(
                  "lib/pages/track_comments_panel.dart::_TrackCommentsPanelState._load.closure#1.closure#2",
                );
                return row.id;
              }).toSet();
        final added = result.comments.where((row) {
          AppLog.instance.trace(
            "lib/pages/track_comments_panel.dart::_TrackCommentsPanelState._load.closure#1.closure#3",
          );
          return known.add(row.id);
        }).toList();
        if (result.hasMore && added.isEmpty) {
          throw const XmlyException('repeated_comments', '评论分页没有前进，请刷新后重试');
        }
        setState(() {
          AppLog.instance.trace(
            "lib/pages/track_comments_panel.dart::_TrackCommentsPanelState._load.closure#1.closure#4",
          );

          _comments = [if (!reset) ..._comments, ...added];
          _page = page;
          _total = result.total;
          _hasMore = result.hasMore;
        });
        if (reset && _scroll.hasClients) _scroll.jumpTo(0);
      } catch (error, stack) {
        _recordCommentsError('Comments load failed', error, stack);
        if (mounted && request == _request) {
          setState(() {
            AppLog.instance.trace(
              "lib/pages/track_comments_panel.dart::_TrackCommentsPanelState._load.closure#1.closure#5",
            );
            _error = error is XmlyException ? error.message : '评论加载失败，请重试';
          });
        }
      } finally {
        if (mounted && request == _request)
          setState(() {
            AppLog.instance.trace(
              "lib/pages/track_comments_panel.dart::_TrackCommentsPanelState._load.closure#1.closure#6",
            );
            _busy = false;
          });
      }
    });
  }

  Widget _comment(TrackComment comment, {bool parent = false}) {
    AppLog.instance.trace(
      "lib/pages/track_comments_panel.dart::_TrackCommentsPanelState._comment",
    );
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              comment.author.isEmpty ? '听友' : comment.author,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            if (comment.parentAuthor.isNotEmpty)
              Text('回复 ${comment.parentAuthor}'),
            const SizedBox(height: 8),
            SelectableText(comment.content),
            const SizedBox(height: 8),
            Wrap(
              spacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (comment.createdAt.isNotEmpty) Text(comment.createdAt),
                Text('${comment.likes} 赞'),
                if (!parent && widget.parent == null && comment.replyCount > 0)
                  TextButton(
                    onPressed: () {
                      AppLog.instance.trace(
                        "lib/pages/track_comments_panel.dart::_TrackCommentsPanelState._comment.closure#1",
                      );
                      showTrackComments(
                        context,
                        widget.runtime,
                        widget.track,
                        parent: comment,
                      );
                    },
                    child: Text('查看回复（${comment.replyCount}）'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace(
      "lib/pages/track_comments_panel.dart::_TrackCommentsPanelState.build",
    );
    return Scrollbar(
      controller: _scroll,
      child: RefreshIndicator(
        onRefresh: () {
          AppLog.instance.trace(
            "lib/pages/track_comments_panel.dart::_TrackCommentsPanelState.build.closure#1",
          );
          return _load(reset: true);
        },
        child: ListView.builder(
          controller: _scroll,
          physics: const AlwaysScrollableScrollPhysics(),
          itemCount: _comments.length + 2,
          itemBuilder: (context, index) {
            AppLog.instance.trace(
              "lib/pages/track_comments_panel.dart::_TrackCommentsPanelState.build.closure#2",
            );

            if (index == 0) {
              return Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      widget.track.title.isEmpty
                          ? widget.track.id
                          : widget.track.title,
                    ),
                    Wrap(
                      alignment: WrapAlignment.spaceBetween,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        if (_page > 0)
                          Text(
                            '$_total 条${widget.parent == null ? "评论" : "回复"}',
                          ),
                        TextButton.icon(
                          onPressed: _busy
                              ? null
                              : () {
                                  AppLog.instance.trace(
                                    "lib/pages/track_comments_panel.dart::_TrackCommentsPanelState.build.closure#2.closure#1",
                                  );
                                  _load(reset: true);
                                },
                          icon: const Icon(Icons.refresh),
                          label: const Text('刷新'),
                        ),
                      ],
                    ),
                    if (widget.parent case final parent?)
                      _comment(parent, parent: true),
                  ],
                ),
              );
            }
            if (index <= _comments.length)
              return _comment(_comments[index - 1]);
            return Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  if (_busy) const CircularProgressIndicator(),
                  if (_error != null) ...[
                    Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () {
                              AppLog.instance.trace(
                                "lib/pages/track_comments_panel.dart::_TrackCommentsPanelState.build.closure#2.closure#2",
                              );
                              _load(reset: _retryReset);
                            },
                      child: const Text('重试'),
                    ),
                  ] else if (!_busy && _comments.isEmpty)
                    Text(widget.parent == null ? '暂无评论' : '暂无回复')
                  else if (!_busy && _hasMore)
                    TextButton(
                      onPressed: _page >= 250
                          ? null
                          : () {
                              AppLog.instance.trace(
                                "lib/pages/track_comments_panel.dart::_TrackCommentsPanelState.build.closure#2.closure#3",
                              );
                              _load();
                            },
                      child: Text(_page >= 250 ? '已加载 5000 条，请刷新查看' : '加载更多'),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
