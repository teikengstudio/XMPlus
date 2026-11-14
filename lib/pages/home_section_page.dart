import 'package:flutter/material.dart';

import '../api/xmly_experience.dart';
import '../common/widgets/app_header.dart';
import '../common/widgets/app_scrollbar.dart';
import '../models/xmly_models.dart';
import '../services/app_log.dart';
import 'home_album_section.dart';

/// Keeps the same ordered snapshot as the preview until the homepage refreshes.
class HomeSectionPage extends StatefulWidget {
  const HomeSectionPage({
    required this.section,
    required this.onOpenAlbum,
    super.key,
  });
  final HomeSection section;
  final ValueChanged<Album> onOpenAlbum;
  @override
  State<HomeSectionPage> createState() {
    AppLog.instance.trace(
      "lib/pages/home_section_page.dart::HomeSectionPage.createState",
    );
    return _HomeSectionPageState();
  }
}

class _HomeSectionPageState extends State<HomeSectionPage> {
  final _scroll = ScrollController();
  @override
  void dispose() {
    AppLog.instance.trace(
      "lib/pages/home_section_page.dart::_HomeSectionPageState.dispose",
    );
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    AppLog.instance.trace(
      "lib/pages/home_section_page.dart::_HomeSectionPageState.build",
    );

    final section = widget.section;
    return Scaffold(
      appBar: AppHeader(title: Text(section.title)),
      body: AppScrollbar(
        controller: _scroll,
        child: CustomScrollView(
          controller: _scroll,
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Text(
                  '${section.albums.length} 部',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              sliver: HomeAlbumSection(
                section: section,
                showTitle: false,
                onOpenAlbum: widget.onOpenAlbum,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
