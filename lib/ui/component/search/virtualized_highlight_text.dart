import 'dart:math';

import 'package:flutter/material.dart';
import 'package:proxypin/network/util/logger.dart';
import 'package:proxypin/ui/component/search/highlight_text_document.dart';
import 'package:proxypin/ui/component/search/search_controller.dart';
import 'package:proxypin/ui/component/utils.dart';
import 'package:proxypin/utils/platform.dart';
import 'package:scrollable_positioned_list_nic/scrollable_positioned_list_nic.dart';

class VirtualizedHighlightText extends StatefulWidget {
  final String text;
  final String? language;
  final TextStyle? style;
  final EditableTextContextMenuBuilder? contextMenuBuilder;
  final SearchTextController searchController;
  final ScrollController? scrollController;
  final double? height;
  final int chunkLines;

  const VirtualizedHighlightText({
    super.key,
    required this.text,
    this.language,
    this.style,
    this.contextMenuBuilder,
    required this.searchController,
    this.scrollController,
    this.height,
    this.chunkLines = 80,
  });

  @override
  State<VirtualizedHighlightText> createState() => _VirtualizedHighlightTextState();
}

class _VirtualizedHighlightTextState extends State<VirtualizedHighlightText> {
  final ItemScrollController itemScrollController = ItemScrollController();
  ScrollController? trackingScrollController;
  int _lastScrolledMatchIndex = -1;

  // 超长单行文本（SingleChildScrollView 分支）使用的滚动控制器
  ScrollController? _singleLineScrollController;
  BoxConstraints? _singleLineConstraints;

  // 缓存机制，避免重复计算
  HighlightTextDocument? _cachedDocument;
  String? _cachedText;
  SearchSettings? _cachedSearchSettings;
  late final Map<int, List<InlineSpan>> _chunkSpanCache;
  late List<HighlightDocumentChunk> chunks;

  @override
  void initState() {
    super.initState();
    _chunkSpanCache = {};
    // 初始化chunks为空列表，避免late未初始化错误
    chunks = [];
  }

  @override
  void dispose() {
    trackingScrollController?.dispose();
    _singleLineScrollController?.dispose();
    _chunkSpanCache.clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final viewHeight = widget.height ?? max(240, MediaQuery.sizeOf(context).height - 220);
    // 方案一：超长单行文本，使用官方 SelectableText（完美支持滚动和搜索）
    final bool isExtraLongSingleLine = !widget.text.contains('\n') && widget.text.length > 3000;

    if (isExtraLongSingleLine) {
      _singleLineScrollController ??= ScrollController();
      return AnimatedBuilder(
        animation: widget.searchController,
        builder: (context, child) {
          // 重新构建高亮文本
          final document = HighlightTextDocument.create(
            context,
            text: widget.text,
            language: widget.language,
            style: widget.style,
            searchController: widget.searchController,
          );
          widget.searchController.updateMatchCount(document.totalMatchCount);

          // 触发搜索定位（仅在 currentMatchIndex 变化时）
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            final currentMatch = widget.searchController.currentMatchIndex.value;
            if (currentMatch != _lastScrolledMatchIndex && currentMatch >= 0) {
              _lastScrolledMatchIndex = currentMatch;
              _scrollSingleLineToMatch(document, currentMatch);
            }
          });

          return SizedBox(
            height: viewHeight,
            child: LayoutBuilder(
              builder: (context, constraints) {
                _singleLineConstraints = constraints;
                return SingleChildScrollView(
                  controller: _singleLineScrollController,
                  child: SelectableText.rich(
                    TextSpan(children: document.buildSpansForAll(context)),
                    style: widget.style,
                  ),
                );
              },
            ),
          );
        },
      );
    }

    return AnimatedBuilder(
      animation: widget.searchController,
      builder: (context, child) {
        // 只在文本或搜索参数（模式、大小写敏感性、正则表达式）变化时重新创建document
        // 不在currentMatchIndex变化时重新创建，以避免频繁rebuild
        final newSearchSettings = SearchSettings(
          isCaseSensitive: widget.searchController.value.isCaseSensitive,
          isRegExp: widget.searchController.value.isRegExp,
          pattern: widget.searchController.value.pattern,
          currentMatchIndex: 0, // 忽略currentMatchIndex用于比较
        );

        final shouldRebuildDocument =
          _cachedText != widget.text ||
          _cachedSearchSettings != newSearchSettings;

        if (shouldRebuildDocument) {
            // ===== 添加这段预处理 =====
          String processedText = widget.text;
          // 如果文本是超长单行（无换行且长度>4000），每2000字符插入换行
          if (!widget.text.contains('\n') && widget.text.length > 4000) {
            final buffer = StringBuffer();
            const int wrapAt = 2000;
            for (var i = 0; i < widget.text.length; i += wrapAt) {
              final end = (i + wrapAt) < widget.text.length ? i + wrapAt : widget.text.length;
              buffer.write(widget.text.substring(i, end));
              buffer.write('\n -BBA1- \n');  // 物理插入换行符
            }
            processedText = buffer.toString();
          }
          _cachedDocument = HighlightTextDocument.create(
            context,
            text: widget.text,
            language: widget.language,
            style: widget.style,
            searchController: widget.searchController,
          );
          _cachedText = widget.text;
          _cachedSearchSettings = newSearchSettings;
          // 清除旧的块缓存
          _chunkSpanCache.clear();
          // 重新分块
          chunks = _buildChunks(_cachedDocument!, widget.chunkLines);
        }

        _updateSearchState(_cachedDocument!);

        return _buildList(viewHeight, chunks, (index) {
          final chunk = chunks[index];
          final chunkSpans = _chunkSpanCache.putIfAbsent(
            index,
            () => _buildSpansForChunk(context, _cachedDocument!, chunk),
          );
          return Text.rich(TextSpan(children: chunkSpans));
        });
      },
    );
  }

  Widget _buildList<T>(double viewHeight, List<T> items, Widget Function(int) itemBuilder) {
    // 根据文本块大小动态调整缓存范围，避免过度缓存导致的内存和CPU消耗
    // 缓存范围应该是视口高度的2-3倍
    final estimatedItemHeight = 24.0; // 粗略估计单行高度（monospace）
    final itemsInView = max(3, (viewHeight / estimatedItemHeight).ceil());
    final minCacheExtent = estimatedItemHeight * itemsInView * 2;

    return SizedBox(
      width: double.infinity,
      height: viewHeight,
      child: SelectionArea(
        child: ScrollablePositionedList.builder(
          key: const ValueKey('virtualized-highlight-text'),
          physics: Platforms.isDesktop() ? null : const BouncingScrollPhysics(),
          scrollController: Platforms.isDesktop() ? null : _trackingScroll(),
          itemScrollController: itemScrollController,
          minCacheExtent: minCacheExtent,
          itemCount: items.length,
          itemBuilder: (context, index) {
                // 1. 安全探测：直接从上层组件实例 widget 中寻找潜在的 document 对象
            // 如果 widget 内部没有直接声明名为 document 的变量，Dart 会回退检查当前 State 里的字段
            dynamic doc;
            try {
              // 尝试反射获取，如果失败则尝试 ProxyPin 常规命名 widget.textDocument
              doc = (widget as dynamic).document ?? (widget as dynamic).textDocument;
            } catch (_) {}

            // 【核心安全拦截】：如果成功获取到了 doc 实例，且判定为单行超长文本
            if (doc != null && doc.lines.length == 1 && doc.text.length > 1000) {
              const int charsPerChunk = 1500; // 虚拟块步长
              int startOffset = index * charsPerChunk;
              int endOffset = startOffset + charsPerChunk;
              if (endOffset > doc.text.length) {
                endOffset = doc.text.length;
              }

              // 筛选出落在这个 1500 字虚拟组件块内部的搜索匹配项
              final currentChunkMatches = doc.matches
                  .where((m) => m.start >= startOffset && m.end <= endOffset)
                  .toList();
              final chunkText = doc.text.substring(startOffset, endOffset);

              return Container(
                key: ValueKey('virtualized-code-chunk-$index'),
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 8),
                child: Text.rich(
                  TextSpan(
                    // 【修复报错 2】：严格对齐 6 个参数的输入，不多传不少传
                    children: _buildSpansForSubText(
                      context,
                      chunkText,
                      startOffset,
                      currentChunkMatches,
                      doc.rootStyle,
                      doc.currentMatchIndex,
                    ),
                  ),
                  softWrap: true, // 保持安卓端的原生自动折行
                ),
              );
            }

            // -----------------------------------------------------------------------
            // 正常的多行文本逻辑（保持原样不变）：
            // 如果是正常代码或多行日志，或者上面动态探测失败，直接复用原项目原本的闭包渲染
            // -----------------------------------------------------------------------
            return Container(
              key: ValueKey('virtualized-code-chunk-$index'),
              child: itemBuilder(index),
            );
          },
        ),
      ),
    );
  }

  void _updateSearchState(HighlightTextDocument document) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // 使用缓存的文档，确保使用最新的数据
      final cachedDoc = _cachedDocument;
      if (cachedDoc == null) return;

      widget.searchController.updateMatchCount(cachedDoc.totalMatchCount);
      final currentMatch = widget.searchController.currentMatchIndex.value;
      if (currentMatch != _lastScrolledMatchIndex && currentMatch >= 0) {
        _lastScrolledMatchIndex = currentMatch;
        _scrollToCurrentMatch(cachedDoc);
      }
    });
  }

  Future<void> _scrollToCurrentMatch(HighlightTextDocument document) async {
    // 1. 边界检查
    if (document.totalMatchCount == 0 || chunks.isEmpty) {
      return;
    }

    final matchIndex = widget.searchController.currentMatchIndex.value;

    // 3. 以下为原有逻辑（针对多行文本），完全保持不变
    final lineIndex = document.lineIndexForMatch(matchIndex);
    if (lineIndex == null || lineIndex < 0) {
      return;
    }

    int chunkIndex = -1;
    if (document.lines.length == 1) {
      // 根据我们自定义的 charsPerVirtualLine(500) 和 charsPerChunk(1500) 换算所属虚拟块
      // 500字一行，1500字一嘴，相当于每 3 逻辑行构成一个真正的虚拟 Widget Chunk
      chunkIndex = (lineIndex / 3).floor();
    } else {
      for (var i = 0; i < chunks.length; i++) {
        final chunk = chunks[i];
        if (lineIndex >= chunk.startLineIndex && lineIndex < chunk.endLineIndex) {
          chunkIndex = i;
          break;
        }
      }
    }

    if (chunkIndex == -1) {
      chunkIndex = (chunks.length - 1).clamp(0, chunks.length - 1);
    }

    if (!itemScrollController.isAttached) {
      return;
    }

    try {
      await itemScrollController.scrollTo(
        index: chunkIndex,
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
        alignment: 0.45,
      );
    } catch (e) {
      logger.w('VirtualizedHighlightText scroll failed: $e');
    }
  }

  /// 针对超长单行文本（SingleChildScrollView 分支）的搜索定位
  ///
  /// 通过 TextPainter 计算匹配项在软换行后的精确像素位置，
  /// 然后让 _singleLineScrollController 滚动到对应位置。
  void _scrollSingleLineToMatch(HighlightTextDocument document, int matchIndex) {
    if (matchIndex < 0 || matchIndex >= document.matches.length) return;

    final match = document.matches[matchIndex];
    final effectiveStyle = document.rootStyle?.merge(widget.style) ?? widget.style;

    // 用与 SelectableText.rich 完全相同的样式进行布局计算
    final textPainter = TextPainter(
      text: TextSpan(text: document.text, style: effectiveStyle),
      textDirection: TextDirection.ltr,
    );

    final maxWidth = _singleLineConstraints?.maxWidth ?? MediaQuery.of(context).size.width;
    textPainter.layout(maxWidth: maxWidth);

    // 获取匹配项起始位置在软换行后的边界框
    final boxes = textPainter.getBoxesForSelection(
      TextSelection(baseOffset: match.start, extentOffset: match.start),
    );

    if (boxes.isNotEmpty && _singleLineScrollController?.hasClients == true) {
      _singleLineScrollController!.jumpTo(boxes.first.top);
    }
  }

  ScrollController _trackingScroll() {
    if (trackingScrollController != null) {
      return trackingScrollController!;
    }

    trackingScrollController = trackingScroll(widget.scrollController) ?? TrackingScrollController();
    return trackingScrollController!;
  }

  /// 将行分组为块，每块包含指定数量的行
  List<HighlightDocumentChunk> _buildChunks(HighlightTextDocument document, int chunkLines) {
    final chunks = <HighlightDocumentChunk>[];
    final allLines = document.lines;

      // 【核心修复】：如果是大单行文本
    if (document.lines.length == 1 && document.text.length > 1000) {
      const int charsPerChunk = 1500; // 每1500个字符强行作为一个独立的组件块
      final int chunkCount = (document.text.length / charsPerChunk).ceil();

      for (var i = 0; i < chunkCount; i++) {
        chunks.add(HighlightDocumentChunk(
          startLineIndex: i, // 借用这两个属性，记录当前虚拟块的序号
          endLineIndex: i + 1,
        ));
      }
      return chunks;
    }

    for (var i = 0; i < allLines.length; i += chunkLines) {
      final endIndex = min(i + chunkLines, allLines.length);
      chunks.add(HighlightDocumentChunk(
        startLineIndex: i,
        endLineIndex: endIndex,
      ));
    }

    return chunks.isEmpty ? [HighlightDocumentChunk(startLineIndex: 0, endLineIndex: 0)] : chunks;
  }

  /// 为指定块构建 InlineSpan 列表
  List<InlineSpan> _buildSpansForChunk(
    BuildContext context,
    HighlightTextDocument document,
    HighlightDocumentChunk chunk,
  ) {
    final spans = <InlineSpan>[];

    for (var i = chunk.startLineIndex; i < chunk.endLineIndex; i++) {
      if (i >= document.lines.length) break;

      spans.addAll(document.buildSpansForLine(context, i));

      // 在行之间添加换行符
      if (i < chunk.endLineIndex - 1) {
        spans.add(TextSpan(text: '\n', style: document.rootStyle));
      }
    }

    return spans;
  }
  // ==================== 确保此函数严格接收 6 个参数 ====================
  List<InlineSpan> _buildSpansForSubText(
    BuildContext context,
    String chunkText,
    int chunkStart,
    List<dynamic> chunkMatches,
    TextStyle? rootStyle,
    int currentMatchIndex,
  ) {
    final spans = <InlineSpan>[];
    final colorScheme = ColorScheme.of(context);
    var localStart = 0;

    for (final match in chunkMatches) {
      // 转换为当前 1500 字片段内的相对局部坐标
      final relStart = match.start - chunkStart;
      final relEnd = match.end - chunkStart;

      // 添加匹配项前面的普通文本
      if (relStart > localStart) {
        spans.add(TextSpan(text: chunkText.substring(localStart, relStart), style: rootStyle));
      }

      // 添加高亮搜索项文本
      final isCurrentMatch = match.index == currentMatchIndex;
      spans.add(TextSpan(
        text: chunkText.substring(relStart, relEnd),
        style: (rootStyle ?? const TextStyle()).copyWith(
          backgroundColor: isCurrentMatch ? colorScheme.primary : colorScheme.inversePrimary,
          color: isCurrentMatch ? colorScheme.onPrimary : (rootStyle?.color ?? Colors.black),
        ),
      ));
      localStart = relEnd;
    }

    // 添加剩下的尾部普通文本
    if (localStart < chunkText.length) {
      spans.add(TextSpan(text: chunkText.substring(localStart), style: rootStyle));
    }
    return spans;
  }
}

/// 文本块的定义，用于虚拟化渲染
class HighlightDocumentChunk {
  final int startLineIndex;
  final int endLineIndex;

  HighlightDocumentChunk({
    required this.startLineIndex,
    required this.endLineIndex,
  });

  int get lineCount => endLineIndex - startLineIndex;
}
