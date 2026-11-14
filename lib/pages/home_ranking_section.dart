import 'dart:async';

import 'package:flutter/material.dart';

import '../api/xmly_client.dart';
import '../api/xmly_experience.dart';
import '../api/xmly_ranking.dart';
import '../models/xmly_models.dart';
import '../services/app_log.dart';
import 'home_album_section.dart';
import 'home_section_page.dart';

class HomeRankingSection extends StatefulWidget {
  const HomeRankingSection({
    required this.client,
    required this.categoryId,
    required this.onOpenAlbum,
    super.key,
  });
  final XmlyClient client;
  final int categoryId;
  final ValueChanged<Album>? onOpenAlbum;
  @override
  State<HomeRankingSection> createState() {
    AppLog.instance.trace(
      "lib/pages/home_ranking_section.dart::HomeRankingSection.createState",
    );
    return _HomeRankingSectionState();
  }
}

class _HomeRankingSectionState extends State<HomeRankingSection> {
  Completer<void>? _cancel;
  HomeSection? _ranking;
  int _generation = 0;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    AppLog.instance.trace(
      "lib/pages/home_ranking_section.dart::_HomeRankingSectionState.initState",
    );

    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant HomeRankingSection oldWidget) {
    AppLog.instance.trace(
      "lib/pages/home_ranking_section.dart::_HomeRankingSectionState.didUpdateWidget",
    );

    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.client, widget.client) ||
        oldWidget.categoryId != widget.categoryId)
      _load();
  }

  Future<void> _load() async {
    AppLog.instance.trace(
      "lib/pages/home_ranking_section.dart::_HomeRankingSectionState._load",
    );

    _cancel?.complete();
    final cancel = _cancel = Completer<void>();
    final generation = ++_generation;
    final client = widget.client;
    final category = widget.categoryId;
    setState(() {
      AppLog.instance.trace(
        "lib/pages/home_ranking_section.dart::_HomeRankingSectionState._load.closure#1",
      );
      _busy = true;
      _error = null;
      _ranking = null;
    });
    try {
      final ranking = await client.withReadPolicy(
        () {
          AppLog.instance.trace(
            "lib/pages/home_ranking_section.dart::_HomeRankingSectionState._load.closure#2",
          );
          return XmlyRanking(client).hot(categoryId: category);
        },
        rateLimitRetries: 0,
        cancelled: cancel.future,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        AppLog.instance.trace(
          "lib/pages/home_ranking_section.dart::_HomeRankingSectionState._load.closure#3",
        );
        _ranking = ranking;
        _busy = false;
      });
    } catch (error, stack) {
      if (!mounted || generation != _generation) return;
      AppLog.instance.write(
        AppLogLevel.warning,
        'home_ranking',
        'Home ranking load failed',
        error: error,
        stackTrace: stack,
      );
      setState(() {
        AppLog.instance.trace(
          "lib/pages/home_ranking_section.dart::_HomeRankingSectionState._load.closure#4",
        );
        _error = '榜单暂时不可用';
        _busy = false;
      });
    }
  }

  void _openRanking() {
    AppLog.instance.trace(
      "lib/pages/home_ranking_section.dart::_HomeRankingSectionState._openRanking",
    );

    final ranking = _ranking;
    final openAlbum = widget.onOpenAlbum;
    if (ranking == null || openAlbum == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) {
          AppLog.instance.trace(
            "lib/pages/home_ranking_section.dart::_HomeRankingSectionState._openRanking.closure#1",
          );
          return HomeSectionPage(section: ranking, onOpenAlbum: openAlbum);
        },
      ),
    );
  }

  @override
  void dispose() {
    AppLog.instance.trace(
      "lib/pages/home_ranking_section.dart::_HomeRankingSectionState.dispose",
    );

    _generation++;
    _cancel?.complete();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace(
      "lib/pages/home_ranking_section.dart::_HomeRankingSectionState.build",
    );

    final ranking = _ranking;
    if (ranking != null && ranking.albums.isNotEmpty) {
      return HomeAlbumSection(
        section: HomeSection(
          title: ranking.title,
          albums: ranking.albums.take(9).toList(),
          isRanking: true,
          stats: ranking.stats,
        ),
        onOpenAlbum: widget.onOpenAlbum,
        onMore: widget.onOpenAlbum == null ? null : _openRanking,
        moreLabel: '完整榜单',
      );
    }
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 12,
          runSpacing: 8,
          children: [
            Text('排行榜', style: Theme.of(context).textTheme.titleLarge),
            if (_busy)
              const SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else if (_error != null) ...[
              Text(_error!, style: Theme.of(context).textTheme.bodySmall),
              TextButton(
                key: const ValueKey('homeRankingRetry'),
                onPressed: _load,
                child: const Text('重试'),
              ),
            ] else
              Text('暂无上榜专辑', style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}
