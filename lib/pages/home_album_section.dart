import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../api/xmly_experience.dart';
import '../models/xmly_models.dart';
import 'catalogue_page.dart';
import "../services/app_log.dart";

/// Uses the available width for albums while keeping each cover readable.
class HomeAlbumSection extends StatelessWidget {
  const HomeAlbumSection({
    required this.section,
    required this.onOpenAlbum,
    super.key,
  });

  final HomeSection section;
  final ValueChanged<Album>? onOpenAlbum;

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace(
      "lib/pages/home_album_section.dart::HomeAlbumSection.build",
    );

    final theme = Theme.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    final showCover = MediaQuery.sizeOf(context).width >= 320;
    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(top: 16, bottom: 8),
            child: Text(
              section.isRanking ? '排行榜 · ${section.title}' : section.title,
              style: theme.textTheme.titleLarge?.copyWith(
                fontSize: 22,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
        SliverLayoutBuilder(
          builder: (context, constraints) {
            AppLog.instance.trace(
              "lib/pages/home_album_section.dart::HomeAlbumSection.build.closure#1",
            );

            final width = constraints.crossAxisExtent;
            final gap = width >= 840 ? 12.0 : 10.0;
            final scale = math.max(1.0, scaler.scale(16) / 16);
            final minimumWidth = section.isRanking
                ? 280.0
                : width >= 720
                ? 180.0
                : width >= 480
                ? 148.0
                : 124.0;
            final availableColumns = math.max(
              1,
              ((width + gap) / (minimumWidth * scale + gap)).floor(),
            );
            final columns = section.isRanking
                ? math.min(3, availableColumns)
                : availableColumns;
            final cardWidth = (width - gap * (columns - 1)) / columns;
            final coverSize = section.isRanking
                ? (width * .05).clamp(56.0, 64.0)
                : cardWidth - 8;
            // Paragraph heights round up; reserve the same whole logical pixels.
            final titleHeight = (scaler.scale(16) * 1.4 * 2).ceilToDouble();
            final extent = section.isRanking
                ? math.max(
                    coverSize + 16,
                    titleHeight + (scaler.scale(12) * 1.4).ceilToDouble() + 20,
                  )
                : (showCover ? coverSize + 6 : 0) +
                      titleHeight +
                      (scaler.scale(14) * 1.4).ceilToDouble() +
                      (scaler.scale(12) * 1.4).ceilToDouble() +
                      16;
            return SliverGrid.builder(
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns,
                crossAxisSpacing: gap,
                mainAxisSpacing: 8,
                mainAxisExtent: extent,
              ),
              itemCount: section.albums.length,
              itemBuilder: (context, index) {
                AppLog.instance.trace(
                  "lib/pages/home_album_section.dart::HomeAlbumSection.build.closure#1.closure#1",
                );

                final album = section.albums[index];
                final stats = section.stats[album.id];
                return _HomeAlbumCard(
                  key: ValueKey(album.id),
                  album: album,
                  stats: stats,
                  rank: section.isRanking ? index + 1 : null,
                  coverSize: coverSize,
                  titleHeight: titleHeight,
                  showCover: showCover,
                  onTap: onOpenAlbum == null
                      ? null
                      : () {
                          AppLog.instance.trace(
                            "lib/pages/home_album_section.dart::HomeAlbumSection.build.closure#1.closure#1.closure#1",
                          );
                          onOpenAlbum!(album);
                        },
                );
              },
            );
          },
        ),
      ],
    );
  }
}

class _HomeAlbumCard extends StatelessWidget {
  const _HomeAlbumCard({
    required this.album,
    required this.stats,
    required this.rank,
    required this.coverSize,
    required this.titleHeight,
    required this.showCover,
    required this.onTap,
    super.key,
  });

  final Album album;
  final HomeAlbumStats? stats;
  final int? rank;
  final double coverSize, titleHeight;
  final bool showCover;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace(
      "lib/pages/home_album_section.dart::_HomeAlbumCard.build",
    );

    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final ranking = rank != null;
    final title = Text(
      album.title,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.titleMedium?.copyWith(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        height: 1.4,
      ),
    );
    final artist = Text(
      album.artist,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.bodyMedium?.copyWith(
        fontSize: ranking ? 12 : 14,
        height: 1.4,
        color: colors.onSurfaceVariant,
      ),
    );
    final details = [
      if (album.total > 0) '${album.total} 集',
      if (stats?.playCount != null)
        '${_count(stats!.playCount!)} 播放'
      else if (stats?.subscribeCount != null)
        '${_count(stats!.subscribeCount!)} 订阅',
      if (stats?.finished == true) '完结',
    ];
    return Tooltip(
      message: album.title,
      child: Material(
        color: ranking ? colors.surfaceContainerLow : Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          hoverColor: colors.primary.withValues(alpha: .045),
          focusColor: colors.primary.withValues(alpha: .09),
          highlightColor: colors.primary.withValues(alpha: .07),
          child: Padding(
            padding: EdgeInsets.all(ranking ? 8 : 4),
            child: ranking
                ? Row(
                    children: [
                      SizedBox(
                        width: MediaQuery.textScalerOf(context).scale(22) * 1.5,
                        child: Text(
                          '$rank'.padLeft(2, '0'),
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontSize: 22,
                            fontWeight: FontWeight.w600,
                            color: rank! <= 3
                                ? colors.primary
                                : colors.onSurfaceVariant.withValues(
                                    alpha: .65,
                                  ),
                          ),
                        ),
                      ),
                      if (showCover) ...[
                        CoverImage(uri: album.coverUrl, size: coverSize),
                        const SizedBox(width: 8),
                      ],
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            title,
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                Expanded(child: artist),
                                if (stats?.score != null) ...[
                                  const SizedBox(width: 8),
                                  _score(context),
                                ],
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (showCover) ...[
                        ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: CoverImage(
                            uri: album.coverUrl,
                            size: coverSize,
                          ),
                        ),
                        const SizedBox(height: 6),
                      ],
                      SizedBox(height: titleHeight, child: title),
                      const SizedBox(height: 4),
                      artist,
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              details.join(' · '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                height: 1.4,
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                          ),
                          if (stats?.score != null) ...[
                            const SizedBox(width: 8),
                            _score(context),
                          ],
                        ],
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }

  Widget _score(BuildContext context) {
    AppLog.instance.trace(
      "lib/pages/home_album_section.dart::_HomeAlbumCard._score",
    );
    return Semantics(
      label: '评分 ${stats!.score!.toStringAsFixed(1)} 分',
      child: ExcludeSemantics(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.star_rounded,
              size: 14,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(width: 3),
            Text(
              stats!.score!.toStringAsFixed(1),
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                height: 1.4,
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _count(int count) {
  AppLog.instance.trace("lib/pages/home_album_section.dart::_count");
  return count >= 100000000
      ? '${(count / 100000000).toStringAsFixed(1)}亿'
      : count >= 10000
      ? '${(count / 10000).toStringAsFixed(1)}万'
      : '$count';
}
