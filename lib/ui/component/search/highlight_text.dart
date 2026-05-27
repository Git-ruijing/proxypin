import 'package:flutter/material.dart';

import 'package:proxypin/ui/component/search/highlight_text_document.dart';
import 'package:proxypin/ui/component/search/search_controller.dart';

class HighlightTextWidget extends StatefulWidget {
  final String text;
  final TextStyle? style;
  final String? language;
  final EditableTextContextMenuBuilder? contextMenuBuilder;
  final SearchTextController searchController;

  const HighlightTextWidget({
    super.key,
    required this.text,
    this.style,
    this.language,
    this.contextMenuBuilder,
    required this.searchController,
  });

  @override
  State<HighlightTextWidget> createState() => _HighlightTextWidgetState();
}

class _HighlightTextWidgetState extends State<HighlightTextWidget> {
  final ScrollController _scrollController = ScrollController();
  int _lastScrolledMatchIndex = -1;
  List<GlobalKey> _matchKeys = [];

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.searchController,
      builder: (context, child) {
        final document = HighlightTextDocument.create(
          context,
          text: widget.text,
          style: widget.style,
          language: widget.language,
          searchController: widget.searchController,
        );
        // 为每个匹配项创建 GlobalKey，用于 Scrollable.ensureVisible 定位
        _matchKeys = List.generate(document.matches.length, (_) => GlobalKey());
        final spans = document.buildAllSpans(
          context,
          matchKeyBuilder: (index) => _matchKeys[index],
        );

        WidgetsBinding.instance.addPostFrameCallback((_) {
          widget.searchController.updateMatchCount(document.totalMatchCount);
        });

        // 触发搜索定位（仅在 currentMatchIndex 变化时）
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          final currentMatch = widget.searchController.currentMatchIndex.value;
          if (currentMatch != _lastScrolledMatchIndex && currentMatch >= 0) {
            _lastScrolledMatchIndex = currentMatch;
            _scrollToMatch(document, currentMatch);
          }
        });

        return SingleChildScrollView(
          controller: _scrollController,
          child: SelectableText.rich(
            TextSpan(children: spans),
            showCursor: true,
            contextMenuBuilder: widget.contextMenuBuilder,
          ),
        );
      },
    );
  }

  /// 使用 Scrollable.ensureVisible 滚动到匹配项位置
  void _scrollToMatch(HighlightTextDocument document, int matchIndex) {
    debugPrint('[HighlightTextWidget] _scrollToMatch called, matchIndex=$matchIndex, matches=${document.matches.length}');
    if (matchIndex < 0 || matchIndex >= document.matches.length) {
      debugPrint('[HighlightTextWidget] matchIndex out of range');
      return;
    }

    if (matchIndex >= _matchKeys.length) {
      debugPrint('[HighlightTextWidget] matchIndex out of _matchKeys range');
      return;
    }

    final key = _matchKeys[matchIndex];
    final ctx = key.currentContext;
    if (ctx != null) {
      debugPrint('[HighlightTextWidget] ensuring visible for match $matchIndex');
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 300),
        alignment: 0.5,
      );
    } else {
      debugPrint('[HighlightTextWidget] key.currentContext is null');
    }
  }
}
