import 'package:flutter/material.dart';

import '../api/xmly_client.dart';
import '../api/xmly_experience.dart';
import '../models/xmly_models.dart';
import 'manuscript_reader.dart';
import 'home_album_section.dart';
import '../common/widgets/local_panel.dart';
import "../services/app_log.dart";

/// Compact metadata preview; the reader fetches the dedicated complete detail.
class AlbumIntroduction extends StatelessWidget {
  const AlbumIntroduction({
    required this.text,
    required this.client,
    required this.albumId,
    required this.onOpenAlbum,
    super.key,
  });

  final String text;
  final XmlyClient client;
  final String albumId;
  final ValueChanged<Album> onOpenAlbum;

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace(
      "lib/pages/album_introduction.dart::AlbumIntroduction.build",
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (text.trim().isNotEmpty)
          Text(text, maxLines: 3, overflow: TextOverflow.ellipsis),
        TextButton.icon(
          onPressed: () {
            AppLog.instance.trace(
              'lib/pages/album_introduction.dart::AlbumIntroduction.build.closure#1',
            );
            showLocalPanel<void>(
              context: context,
              title: '专辑简介',
              width: 640,
              builder: (context) {
                AppLog.instance.trace(
                  'lib/pages/album_introduction.dart::AlbumIntroduction.build.closure#1.closure#1',
                );
                return _CompleteIntroduction(
                  client: client,
                  albumId: albumId,
                  onOpenAlbum: (album) {
                    AppLog.instance.trace(
                      "lib/pages/album_introduction.dart::AlbumIntroduction.build.closure#1.closure#1.closure#1",
                    );

                    Navigator.of(context).pop();
                    onOpenAlbum(album);
                  },
                );
              },
            );
          },
          icon: const Icon(Icons.notes_rounded, size: 18),
          label: const Text('查看完整简介'),
        ),
      ],
    );
  }
}

class _CompleteIntroduction extends StatefulWidget {
  const _CompleteIntroduction({
    required this.client,
    required this.albumId,
    required this.onOpenAlbum,
  });
  final XmlyClient client;
  final String albumId;
  final ValueChanged<Album> onOpenAlbum;

  @override
  State<_CompleteIntroduction> createState() {
    AppLog.instance.trace(
      'lib/pages/album_introduction.dart::_CompleteIntroduction.createState',
    );
    return _CompleteIntroductionState();
  }
}

class _CompleteIntroductionState extends State<_CompleteIntroduction> {
  AlbumIntroductionData? _content;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    AppLog.instance.trace(
      'lib/pages/album_introduction.dart::_CompleteIntroductionState.initState',
    );
    super.initState();
    _load();
  }

  Future<void> _load() async {
    AppLog.instance.trace(
      'lib/pages/album_introduction.dart::_CompleteIntroductionState._load',
    );
    if (_busy) return;
    setState(() {
      AppLog.instance.trace(
        "lib/pages/album_introduction.dart::_CompleteIntroductionState._load.closure#1",
      );

      _busy = true;
      _error = null;
    });
    try {
      final content = await XmlyExperience(widget.client)
          .albumIntroduction(widget.albumId);
      if (mounted)
        setState(() {
          AppLog.instance.trace(
            "lib/pages/album_introduction.dart::_CompleteIntroductionState._load.closure#2",
          );

          _content = content;
        });
    } catch (error, stack) {
      final log = AppLog.instance;
      if (!log.errorWasRecorded(error)) {
        log.write(
          AppLogLevel.error,
          'album_introduction',
          'Loading full album introduction failed',
          error: error,
          stackTrace: stack,
          promptUser: true,
        );
      }
      if (mounted)
        setState(() {
          AppLog.instance.trace(
            "lib/pages/album_introduction.dart::_CompleteIntroductionState._load.closure#3",
          );

          _error = error is XmlyException ? error.message : '完整简介加载失败，请重试';
        });
    } finally {
      if (mounted)
        setState(() {
          AppLog.instance.trace(
            "lib/pages/album_introduction.dart::_CompleteIntroductionState._load.closure#4",
          );

          _busy = false;
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace(
      'lib/pages/album_introduction.dart::_CompleteIntroductionState.build',
    );
    if (_busy) return const Center(child: CircularProgressIndicator());
    if (_error != null)
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!),
            TextButton(onPressed: _load, child: const Text('重试')),
          ],
        ),
      );
    final content = _content;
    if (content == null) return const SizedBox.shrink();
    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          const TabBar(
            tabs: [
              Tab(text: '完整简介'),
              Tab(text: '相关推荐'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                content.richText.trim().isEmpty
                    ? const Center(child: Text('暂无专辑简介'))
                    : ManuscriptReader(
                        manuscript: content.richText,
                        showTitle: false,
                      ),
                content.recommendations.albums.isEmpty
                    ? const Center(child: Text('暂无相关推荐'))
                    : CustomScrollView(
                        slivers: [
                          SliverPadding(
                            padding: const EdgeInsets.all(12),
                            sliver: HomeAlbumSection(
                              section: content.recommendations,
                              onOpenAlbum: widget.onOpenAlbum,
                            ),
                          ),
                        ],
                      ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
