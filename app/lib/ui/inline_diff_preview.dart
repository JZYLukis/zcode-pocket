import 'package:flutter/material.dart' hide Text;
import '../core/localized_text.dart';

import '../core/code_highlight.dart';
import '../core/theme.dart';
import '../state/app_state_scope.dart';

/// 会话内联 diff 预览（编辑/写入工具行展开区首块，官方
/// EditInlineDiffContent 对位）。2026-10-23 Paseo 参考批从
/// conversation_page 抽出公开（独立可测）；同批 DiffViewer 语法高亮
/// 清偿 ADR 0011 P1 欠账时一并对齐官方：文字色=语法 token 色（官方
/// EditInlineDiffContent.tsx:68-80 内联 diff 同样带 shiki 高亮），
/// 增删由行底 tint+行首竖条表达，marker 不作为代码内容显示。
///
/// 18077 验收#6（优化意见 A）：[collapsible]=true 时大 diff 折叠——
/// 超过 [kInlineDiffCollapseLines] 行默认截断+「显示全部」展开（审批
/// 卡场景滚动百行 diff 的替代）。默认 false=旧全量滚动行为（工具行
/// 展开区不变）。
const int kInlineDiffCollapseLines = 24;

class InlineDiffPreview extends StatefulWidget {
  final Map<String, dynamic> display;
  final bool collapsible;

  const InlineDiffPreview({
    super.key,
    required this.display,
    this.collapsible = false,
  });

  @override
  State<InlineDiffPreview> createState() => _InlineDiffPreviewState();
}

class _InlineDiffPreviewState extends State<InlineDiffPreview> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final hunks = widget.display['structuredPatch'];
    // 语言按文件路径推（协议 file_diff display 带 filePath，
    // toolDisplay.ts:27）。总开关关闭时降 null 回落纯色（对抗审查 B3：
    // 同一展开区里预览变纯色而内联 diff 仍彩色=自相矛盾）。裸树容错：
    // 本组件公开承诺可独立挂树（无 AppStateScope 时默认开）。
    final scope = context.getInheritedWidgetOfExactType<AppStateScope>();
    final highlightOn =
        scope?.notifier?.uiPrefs.codeHighlightEnabled ?? true;
    final language = highlightOn
        ? languageForFilePath('${widget.display['filePath'] ?? ''}')
        : null;
    final brightness = Theme.of(context).brightness;
    if (hunks is! List) return const SizedBox.shrink();
    final hunkLines = <List<DiffLineView>>[];
    for (final h in hunks.whereType<Map>()) {
      final ls = h['lines'];
      if (ls is List && ls.isNotEmpty) {
        hunkLines.add(
          highlightDiffLines(
            ls.whereType<String>().toList(),
            language,
            brightness: brightness,
          ),
        );
      }
    }
    if (hunkLines.isEmpty) return const SizedBox.shrink();
    final totalLines = hunkLines.fold<int>(
      0,
      (sum, views) => sum + views.length,
    );
    final shouldCollapse =
        widget.collapsible && !_expanded && totalLines > kInlineDiffCollapseLines;
    var emitted = 0;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 200),
        child: SingleChildScrollView(
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: context.colors.surface,
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final views in hunkLines)
                  for (final v in views)
                    if (!shouldCollapse ||
                        emitted++ < kInlineDiffCollapseLines)
                      _line(context, v),
                if (shouldCollapse)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        key: const ValueKey('inline-diff-expand-all'),
                        onPressed: () => setState(() => _expanded = true),
                        icon: const Icon(Icons.unfold_more, size: 14),
                        label: Text('显示全部 $totalLines 行'),
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          minimumSize: const Size(0, 36),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _line(BuildContext context, DiffLineView v) {
    if (v.kind == DiffLineKind.hunk) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Text(
          v.text,
          translate: false,
          style: TextStyle(
            fontSize: AppType.uiXs,
            fontFamily: 'monospace',
            height: 1.4,
            color: context.colors.foregroundSubtlest,
          ),
        ),
      );
    }
    final diffColor = v.kind == DiffLineKind.add
        ? context.colors.diffAdded
        : v.kind == DiffLineKind.del
        ? context.colors.diffRemoved
        : null;
    final base = TextStyle(
      fontSize: AppType.uiXs,
      fontFamily: 'monospace',
      height: 1.4,
    );
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: diffColor?.withValues(alpha: AppAlpha.faint),
        border: diffColor == null
            ? null
            : Border(left: BorderSide(width: 3, color: diffColor)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      // 长行软换行（对抗审查 A-1：此前 maxLines:1+ellipsis 使 80+ 字符
      // 的代码行尾部永久不可见且无任何表面能看整行——软换行是官方
      // wrapLongLines 模式的手机化，窄屏优先可读性）。
      child: v.spans != null
          ? Text.rich(TextSpan(children: v.spans, style: base), translate: false)
          : Text(
              v.text,
              translate: false,
              style: base.copyWith(
                color: diffColor ?? context.colors.foregroundSubtlest,
              ),
            ),
    );
  }
}
