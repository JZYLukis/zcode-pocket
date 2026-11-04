import 'package:flutter/material.dart' hide Text;
import '../core/localized_text.dart';
import 'package:flutter/services.dart';

import '../core/code_highlight.dart';
import '../core/payload_guard.dart';
import '../core/theme.dart';
import '../state/app_state_scope.dart';

/// diff 查看器（2.3，波次 3b）：conversationFileChangesV4 文件清单 +
/// 按目录分组 + 逐文件 hunk 着色 + git-checkpoint 单文件回滚
/// （fileRewindPreview 预检 → applyFileRewind）。
///
/// 语法高亮（2026-10-23 清偿 ADR 0011 P1 欠账）：官方 diff 全表面带
/// shiki 高亮（diff-viewer.tsx:99/previewPanePatchFallbackContent.tsx:
/// 50-58/EditInlineDiffContent.tsx:68-80），文字色=语法 token 色、增删
/// 由行底 tint+行首竖条表达——我们用 code_highlight（github 双主题同源）
/// 对位；当时"需语法库依赖"的缓办理由已不成立。
class DiffViewerPage extends StatefulWidget {
  final String sessionId;
  final Map<String, dynamic>? rowTarget; // {rowId, entityId?}（turnHeader 行）

  /// 进入时预展开的文件（对抗审查 3a-6：点文件行应落在该文件而非整轮列表）。
  final String? initialPath;

  const DiffViewerPage({
    super.key,
    required this.sessionId,
    this.rowTarget,
    this.initialPath,
  });

  @override
  State<DiffViewerPage> createState() => _DiffViewerPageState();
}

class _DiffViewerPageState extends State<DiffViewerPage> {
  Map<String, dynamic>? _data;
  String? _error;
  bool _loading = true;
  String? _openPath;

  @override
  void initState() {
    super.initState();
    // 对抗审查 3a-6：点文件行进入即预展开该文件（官方 openDiff 单文件
    // 语义的手机化）。
    _openPath = widget.initialPath;
    // AppStateScope.of 不能在 initState 同步调用（阶段 1 根因陷阱）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  Future<void> _load() async {
    final app = AppStateScope.of(context);
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await app.fileChanges(
        widget.sessionId,
        target: widget.rowTarget ?? const {},
      );
      if (mounted) {
        setState(() {
          _data = res is Map ? res.cast<String, dynamic>() : {};
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _loading = false;
        });
      }
    }
  }

  List<Map<String, dynamic>> get _items =>
      listOf(_data?['items'])
          ?.whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList() ??
      const [];

  /// 按目录分组（文件树的第一层呈现：目录 → 文件列表）。
  Map<String, List<Map<String, dynamic>>> get _byDir {
    final out = <String, List<Map<String, dynamic>>>{};
    for (final item in _items) {
      final path = '${item['path']}';
      final slash = path.lastIndexOf('/');
      final dir = slash <= 0 ? '/' : path.substring(0, slash);
      out.putIfAbsent(dir, () => []).add(item);
    }
    return out;
  }

  /// 目录级增删合计（Paseo 参考 2026-10-23）：哪层改动最大一眼可读。
  ({int add, int del}) _dirTotals(List<Map<String, dynamic>> items) {
    var add = 0;
    var del = 0;
    for (final item in items) {
      add += intOrZero(item['additions']);
      del += intOrZero(item['deletions']);
    }
    return (add: add, del: del);
  }

  Widget _dirHeader(String dir, ({int add, int del}) totals) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 12, 4, 6),
    child: Row(
      children: [
        Expanded(
          child: Text(
            dir,
            translate: false,
            style: TextStyle(
              fontSize: AppType.uiXs,
              color: context.colors.foregroundSubtlest,
              fontFamily: 'monospace',
            ),
          ),
        ),
        Text(
          '+${totals.add}/-${totals.del}',
          style: TextStyle(
            fontSize: AppType.uiXs,
            color: context.colors.foregroundSubtlest,
            fontFamily: 'monospace',
          ),
        ),
      ],
    ),
  );

  Future<void> _rewind(Map<String, dynamic> item) async {
    final app = AppStateScope.of(context);
    final path = '${item['path']}';
    // 先取预检：协议语义=整轮工作区文件撤销（applyFileRewind 不截断聊天
    // 历史，safeFiles 逐文件 restore/delete）——盲审 #4 抓出旧文案
    // "不影响其他文件"与协议不符，改为诚实表述。
    Map<String, dynamic>? preview;
    try {
      final res = await app.fileRewindPreview(
        widget.sessionId,
        target: widget.rowTarget ?? const {},
      );
      preview = res is Map ? res.cast<String, dynamic>() : null;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('回滚预检失败：$e')));
      }
      return;
    }
    final canApply = preview?['canApply'] == true;
    if (!canApply) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('当前不支持回滚（部分文件已越过安全边界）')));
      }
      return;
    }
    final safeCount = listOf(preview?['safeFiles'])?.length ?? 0;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('回滚本轮文件修改？'),
        content: Text(
          '将把本轮对 $safeCount 个文件的修改恢复到本轮开始前'
          '（含「$path」；撤销按文件逐个进行，越过安全边界的文件会被跳过）。'
          '聊天记录不受影响。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: context.colors.warning),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('回滚'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await app.applyFileRewind(
        widget.sessionId,
        target: widget.rowTarget ?? const {},
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('已回滚本轮安全文件'),
            duration: const Duration(seconds: 2),
          ),
        );
        _load();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('回滚失败：$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('文件变更', style: TextStyle(fontSize: AppType.uiLg)),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: context.colors.border),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
          : _error != null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '加载失败：$_error',
                    style: TextStyle(
                      fontSize: AppType.uiCaption,
                      color: context.colors.destructive,
                    ),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton(onPressed: _load, child: const Text('重试')),
                ],
              ),
            )
          : _buildBody(),
    );
  }

  Widget _buildBody() {
    final files = intOrZero(_data?['files']);
    final add = intOrZero(_data?['additions']);
    final del = intOrZero(_data?['deletions']);
    final state = '${_data?['state'] ?? 'active'}';
    if (files == 0) {
      return Center(
        child: Text(
          '本回合没有文件变更',
          style: TextStyle(
            fontSize: AppType.uiCaption,
            color: context.colors.foregroundSubtle,
          ),
        ),
      );
    }
    return ListView(
      key: const ValueKey('diff-list'),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: context.colors.card,
            borderRadius: BorderRadius.circular(AppRadius.card),
            border: Border.all(color: context.colors.border),
          ),
          child: Row(
            children: [
              Icon(
                Icons.difference_outlined,
                size: 18,
                color: context.colors.foregroundSubtle,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '$files 个文件  ',
                  style: const TextStyle(fontSize: AppType.uiBase),
                ),
              ),
              Text(
                '+$add ',
                style: TextStyle(
                  fontSize: AppType.uiBase,
                  color: context.colors.diffAdded,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                '-$del',
                style: TextStyle(
                  fontSize: AppType.uiBase,
                  color: context.colors.diffRemoved,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (state == 'reverted') ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: context.colors.warning.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                  ),
                  child: Text(
                    '已回滚',
                    style: TextStyle(
                      fontSize: AppType.uiXs,
                      color: context.colors.warning,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        for (final entry in _byDir.entries) ...[
          _dirHeader(entry.key, _dirTotals(entry.value)),
          for (final item in entry.value)
            _FileCard(
              item: item,
              expanded: _openPath == '${item['path']}',
              onTap: () => setState(
                () => _openPath = _openPath == '${item['path']}'
                    ? null
                    : '${item['path']}',
              ),
              onRewind: () => _rewind(item),
            ),
        ],
      ],
    );
  }
}

class _FileCard extends StatelessWidget {
  final Map<String, dynamic> item;
  final bool expanded;
  final VoidCallback onTap;
  final VoidCallback onRewind;

  const _FileCard({
    required this.item,
    required this.expanded,
    required this.onTap,
    required this.onRewind,
  });

  @override
  Widget build(BuildContext context) {
    final path = '${item['path']}';
    final name = path.split('/').last;
    final add = intOrZero(item['additions']);
    final del = intOrZero(item['deletions']);
    final patches =
        listOf(item['patches'])
            ?.whereType<Map>()
            .map((e) => e.cast<String, dynamic>())
            .toList() ??
        const [];
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: context.colors.card,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: context.colors.border),
      ),
      child: Column(
        children: [
          InkWell(
            key: ValueKey('diff-file-$path'),
            borderRadius: BorderRadius.circular(AppRadius.sm),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Row(
                children: [
                  Icon(
                    expanded ? Icons.expand_less : Icons.chevron_right,
                    size: 16,
                    color: context.colors.foregroundSubtlest,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      name,
                      translate: false,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: AppType.uiCaption,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                  Text(
                    '+$add/-$del',
                    style: TextStyle(
                      fontSize: AppType.uiXs,
                      color: context.colors.foregroundSubtlest,
                    ),
                  ),
                  const SizedBox(width: 6),
                  InkWell(
                    onTap: onRewind,
                    borderRadius: BorderRadius.circular(6),
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Icon(
                        Icons.history,
                        size: 15,
                        color: context.colors.warning,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (expanded)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: context.colors.surface,
                borderRadius: BorderRadius.vertical(
                  bottom: Radius.circular(AppRadius.sm),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 每文件按语言整体着色（懒展开单文件，LRU 缓存兜住）；
                  // hunk 逐个 tokenize（跨 hunk 内容本就断开）。
                  for (final patch in patches)
                    ..._patchLines(
                      context,
                      patch,
                      languageForFilePath(path),
                    ),
                  if (patches.isEmpty)
                    Text(
                      '（本文件无文本 hunk）',
                      style: TextStyle(
                        fontSize: AppType.uiXs,
                        color: context.colors.foregroundSubtlest,
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  List<Widget> _patchLines(
    BuildContext context,
    Map<String, dynamic> patch,
    String? language,
  ) {
    final lines =
        (listOf(patch['lines']) ?? []).whereType<String>().toList();
    // 总开关关闭时降 null 回落纯色呈现（对抗审查 B3：与内联 diff/
    // 预览/消息代码块同受一个开关，不自相矛盾）。裸树容错默认开。
    final scope = context.getInheritedWidgetOfExactType<AppStateScope>();
    final highlightOn =
        scope?.notifier?.uiPrefs.codeHighlightEnabled ?? true;
    final views = highlightDiffLines(
      lines,
      highlightOn ? language : null,
      brightness: Theme.of(context).brightness,
    );
    return [
      for (var i = 0; i < views.length; i++)
        _DiffLine(view: views[i]),
    ];
  }
}

class _DiffLine extends StatelessWidget {
  final DiffLineView view;
  const _DiffLine({required this.view});

  @override
  Widget build(BuildContext context) {
    if (view.kind == DiffLineKind.hunk) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Text(
          view.text,
          style: TextStyle(
            fontSize: AppType.uiXs,
            fontFamily: 'monospace',
            height: 1.4,
            color: context.colors.foregroundSubtlest,
          ),
        ),
      );
    }
    final diffColor = view.kind == DiffLineKind.add
        ? context.colors.diffAdded
        : view.kind == DiffLineKind.del
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
        // 行首 3px 竖条（官方 lightweight-diff-preview.ts:73-111 的
        // inset boxShadow 同款）——行底 tint 很淡，竖条是增删的主锚点。
        border: diffColor == null
            ? null
            : Border(left: BorderSide(width: 3, color: diffColor)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      // 长行软换行（对抗审查 A-1：此前 maxLines:1 截断使长代码行尾部
      // 永久不可见；与内联 diff 同步改软换行）。
      child: view.spans != null
          ? Text.rich(TextSpan(children: view.spans, style: base))
          : Text(
              // 语言未知/解析失败回落：纯色文字（旧呈现，marker 已剥）。
              view.text,
              style: base.copyWith(
                color: diffColor ?? context.colors.foregroundSubtle,
              ),
            ),
    );
  }
}
