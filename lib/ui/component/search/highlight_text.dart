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
  BoxConstraints? _lastConstraints;

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
        final spans = document.buildAllSpans(context);

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

        return LayoutBuilder(
          builder: (context, constraints) {
            _lastConstraints = constraints;
            // 如果父组件给了无限高度（如 Column），必须给一个固定高度，
            // 否则 SingleChildScrollView 收不到有限约束，永远不会启用滚动。
            final hasInfiniteHeight = constraints.maxHeight == double.infinity;
            final maxScrollHeight = hasInfiniteHeight ? 300.0 : constraints.maxHeight;
            debugPrint('[HighlightTextWidget] constraints=$constraints, hasInfiniteHeight=$hasInfiniteHeight, maxScrollHeight=$maxScrollHeight');
            return ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxScrollHeight),
              child: SingleChildScrollView(
                controller: _scrollController,
                child: SizedBox(
                  // 强制固定宽度和 TextPainter 一致，避免布局不一致导致跳转位置错误
                  width: constraints.maxWidth,
                  child: SelectableText.rich(
                    TextSpan(children: spans),
                    showCursor: true,
                    // selectionColor: highlightSelectionColor(context),
                    contextMenuBuilder: widget.contextMenuBuilder,
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// 使用 TextPainter 计算匹配项的精确像素位置并滚动过去
  void _scrollToMatch(HighlightTextDocument document, int matchIndex) {
    debugPrint('[HighlightTextWidget] _scrollToMatch called, matchIndex=$matchIndex, matches=${document.matches.length}');
    if (matchIndex < 0 || matchIndex >= document.matches.length) {
      debugPrint('[HighlightTextWidget] matchIndex out of range');
      return;
    }

    final match = document.matches[matchIndex];
    final effectiveStyle = document.rootStyle?.merge(widget.style) ?? widget.style;

    // 优先使用 LayoutBuilder 给出的精确宽度；如果没有（理论上不会发生），回退到屏幕宽度
    final maxWidth = _lastConstraints?.maxWidth ?? MediaQuery.of(context).size.width;
    debugPrint('[HighlightTextWidget] maxWidth=$maxWidth, matchStart=${match.start}, matchEnd=${match.end}');

    final textPainter = TextPainter(
      text: TextSpan(text: document.text, style: effectiveStyle),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
    );

    textPainter.layout(maxWidth: maxWidth);
    debugPrint('[HighlightTextWidget] textPainter.size=${textPainter.size}, maxScrollExtent=${_scrollController.hasClients ? _scrollController.position.maxScrollExtent : -1}');

    // 使用 match.end 作为 extentOffset，避免空 selection 返回空列表
    final boxes = textPainter.getBoxesForSelection(
      TextSelection(baseOffset: match.start, extentOffset: match.end),
    );

    debugPrint('[HighlightTextWidget] boxes=${boxes.length}, hasClients=${_scrollController.hasClients}');

    if (boxes.isNotEmpty && _scrollController.hasClients) {
      final targetOffset = boxes.first.top;
      debugPrint('[HighlightTextWidget] jumping to $targetOffset');
      _scrollController.jumpTo(targetOffset);
    } else {
      // 备选方案：使用 getOffsetForCaret
      final caretOffset = textPainter.getOffsetForCaret(
        TextPosition(offset: match.start),
        Rect.zero,
      );
      debugPrint('[HighlightTextWidget] caretOffset=$caretOffset');
      if (caretOffset != Offset.zero && _scrollController.hasClients) {
        debugPrint('[HighlightTextWidget] jumping to caretOffset ${caretOffset.dy}');
        _scrollController.jumpTo(caretOffset.dy);
      } else {
        debugPrint('[HighlightTextWidget] skip scroll: boxes.isEmpty=${boxes.isEmpty}, hasClients=${_scrollController.hasClients}');
      }
    }
  }
}
