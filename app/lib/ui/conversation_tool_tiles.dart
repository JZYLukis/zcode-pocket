import 'package:flutter/material.dart' hide Text;
import 'package:flutter/services.dart';

import '../core/code_highlight.dart';
import '../core/localized_text.dart';
import '../core/payload_guard.dart';
import '../core/theme.dart';
import '../state/app_state_scope.dart';
import 'conversation_message_cells.dart';
import 'inline_diff_preview.dart';
import 'markdown_view.dart';
import 'motion.dart';
import 'turn_model.dart';

class TodoTile extends StatefulWidget {
  const TodoTile({
    required this.row,
    required this.openByRow,
    required this.turnRunning,
  });

  final Map<String, dynamic> row;
  final Map<int, bool> openByRow;
  final bool turnRunning;

  /// 解析 todos：[{content,status}]，status ∈ pending/in_progress/completed。
  static List<({String title, String status})>? todosOf(
    Map<String, dynamic> row,
  ) {
    final args = toolInputArgs(row);
    final raw = args?['todos'];
    if (raw is! List || raw.isEmpty) return null;
    final out = <({String title, String status})>[];
    for (final e in raw) {
      if (e is! Map) continue;
      final title = '${e['content'] ?? ''}'.trim();
      if (title.isEmpty) continue;
      out.add((title: title, status: '${e['status'] ?? 'pending'}'));
    }
    return out.isEmpty ? null : out;
  }

  int get _rowId => intOf(row['rowId']) ?? -1;

  @override
  State<TodoTile> createState() => TodoTileState();
}

class TodoTileState extends State<TodoTile> {
  bool get _open => widget.openByRow[widget._rowId] ?? false;

  void _toggle() {
    setState(() => widget.openByRow[widget._rowId] = !_open);
  }

  @override
  Widget build(BuildContext context) {
    final todos = TodoTile.todosOf(widget.row)!;
    final completed = todos.where((t) => t.status == 'completed').length;
    final active =
        todos.where((t) => t.status == 'in_progress').firstOrNull ??
        todos.where((t) => t.status != 'completed').firstOrNull ??
        todos.last;
    final status = '${widget.row['status'] ?? ''}';
    final running =
        const [
          'running',
          'inputStreaming',
          'pending',
          'waiting',
        ].contains(status) ||
        widget.turnRunning;
    return InkWell(
      borderRadius: BorderRadius.circular(4),
      onTap: _toggle,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 5),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.checklist,
                  size: 15,
                  color: running
                      ? context.colors.running
                      : context.colors.foregroundSubtle,
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: running
                      ? ShimmerText(
                          text: tr('待办 · ') + active.title,
                          maxLines: 1,
                          style: TextStyle(
                            fontSize: AppType.uiBase,
                            fontWeight: FontWeight.w500,
                            color: context.colors.running,
                          ),
                        )
                      : Text(
                          tr('待办 · ') + active.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          translate: false,
                          style: TextStyle(
                            fontSize: AppType.uiBase,
                            fontWeight: FontWeight.w500,
                            color: context.colors.foregroundSubtle,
                          ),
                        ),
                ),
                const SizedBox(width: 6),
                Text(
                  '$completed/${todos.length}',
                  style: TextStyle(
                    fontSize: AppType.uiSm,
                    color: context.colors.foregroundSubtlest,
                  ),
                ),
                Icon(
                  _open ? Icons.expand_less : Icons.expand_more,
                  size: 16,
                  color: context.colors.foregroundSubtlest,
                ),
              ],
            ),
            if (_open)
              Padding(
                padding: const EdgeInsets.only(left: 22, top: 2, bottom: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final t in todos)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              t.status == 'completed'
                                  ? Icons.check_circle
                                  : t.status == 'in_progress'
                                  ? Icons.arrow_right
                                  : Icons.radio_button_unchecked,
                              size: 14,
                              color: t.status == 'completed'
                                  ? context.colors.success
                                  : t.status == 'in_progress'
                                  ? context.colors.foreground
                                  : context.colors.foregroundSubtlest,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                t.title,
                                translate: false,
                                style: TextStyle(
                                  fontSize: AppType.uiSm,
                                  color: t.status == 'completed'
                                      ? context.colors.foregroundSubtlest
                                      : context.colors.foreground,
                                  decoration: t.status == 'completed'
                                      ? TextDecoration.lineThrough
                                      : null,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}


class ToolCallTile extends StatefulWidget {
  final Map<String, dynamic> row;
  final Map<int, bool> openByRow;

  /// 所属回合是否仍在运行（#11 状态词兜底用）。
  final bool turnRunning;
  final int? searchTargetRowId;
  final GlobalKey? searchTargetKey;
  final int? searchStart;
  final String? searchSourceText;

  const ToolCallTile({
    required this.row,
    required this.openByRow,
    this.turnRunning = true,
    this.searchTargetRowId,
    this.searchTargetKey,
    this.searchStart,
    this.searchSourceText,
  });

  @override
  State<ToolCallTile> createState() => ToolCallTileState();
}

class ToolCallTileState extends State<ToolCallTile> {
  bool _localOpen = false;

  /// （2026-10-24 修复批）：toolPreview/_inputDiffCounts 记忆化——
  /// 流式期整页每帧重建，行未变化（identical：变更行走 row.upserted
  /// 新 map，未变行引用稳定）时重复解析是每帧 O(行数) 的纯浪费。
  Map<String, dynamic>? _memoRow;
  String _memoPreview = '';
  ({int a, int d})? _memoDiff;

  int? get _rowId => intOf(widget.row['rowId']);
  bool get _searchTarget =>
      _rowId != null && _rowId == widget.searchTargetRowId;

  bool get _open =>
      _searchTarget ||
      (_rowId == null
          ? _localOpen
          : toolOpenDecision(
              // V2 折叠策略①：失败/被拒自动展开（错误输出默认可见），
              // 手动记忆优先（用户点收后永久让位）。
              widget.openByRow[_rowId!],
              toolStatusLabel(
                '${widget.row['status'] ?? ''}',
                turnRunning: widget.turnRunning,
              ),
            ));

  void _toggle() {
    final id = _rowId;
    if (id == null) {
      // #9：无 rowId 的旧快照行用本地态兜底（重开页面回默认收起）。
      setState(() => _localOpen = !_localOpen);
      return;
    }
    setState(() => widget.openByRow[id] = !_open);
  }

  /// 读取类工具的文件预览语言：从 inputText 的 file_path/path 按扩展
  /// 名推（官方由服务端 inlinePreview.language 投影，手机行数据不带）。
  String? _filePreviewLanguage(Map<String, dynamic> row) {
    final name = '${row['toolName'] ?? row['name'] ?? ''}'.toLowerCase();
    if (name != 'read' && name != 'readfile' && name != 'read_file') {
      return null;
    }
    // 取值链统一走 toolInputArgs（
    // inputText 缺席而 input 已随 running upsert 到场时也能推断）。
    final decoded = toolInputArgs(row);
    if (decoded != null) {
      final p = decoded['file_path'] ?? decoded['path'] ?? decoded['filePath'];
      if (p is String && p.isNotEmpty) return languageForFilePath(p);
    }
    return null;
  }

  (Color, String) _statusStyle() {
    final label = toolStatusLabel(
      '${widget.row['status'] ?? ''}',
      turnRunning: widget.turnRunning,
    );
    final color = switch (label) {
      '执行中' => context.colors.running,
      '等待中' => context.colors.foregroundSubtle,
      '等待确认' => context.colors.interactionAskForeground,
      '执行失败' || '已拒绝' => context.colors.destructive,
      '已停止' => context.colors.warning,
      _ => context.colors.foregroundSubtlest,
    };
    return (color, label);
  }

  /// 输出可见文本取值链（-2/4-3/4-9，2026-10-22）：
  /// 失败优先 error.message（协议 status=error 必带，官方 toolError.ts
  /// 同序——此前全 app 零消费，失败自动展开可能展开个空白）→ 运行中
  /// 行字段 outputPreview（手机 replayable 档不流 output.text，
  /// core.ts:47-56）→ output.text → bash display.output（150KB 有界）。
  /// 全空返回 null（渲染层出「没有输出。」占位）。
  String? _visibleOutput(Map<String, dynamic> row, {required bool running}) {
    final err = row['error'];
    if (err is Map) {
      final m = '${err['message'] ?? ''}'.trim();
      if (m.isNotEmpty) return m;
    }
    if (running) {
      final pv = row['outputPreview'];
      if (pv is Map) {
        final t = '${pv['fullText'] ?? ''}'.trim();
        if (t.isNotEmpty) return t;
      }
    }
    final out = row['output'];
    if (out is Map) {
      final t = '${out['text'] ?? ''}'.trim();
      if (t.isNotEmpty) return t;
      final d = out['display'];
      if (d is Map && d['kind'] == 'bash_output') {
        final t2 = '${d['output'] ?? ''}'.trim();
        if (t2.isNotEmpty) return t2;
      }
    }
    return null;
  }

  /// Edit/Write 的 file_diff 展示载荷（协议 toolDisplay.ts:27：
  /// filePath/additions/deletions/structuredPatch）。批4 反馈②（2026-10-23）：
  /// 补 file_diffs 复数形态（官方 readFileDiffDisplays 同时支持两种，
  /// apply_patch 类多文件工具用复数）——手机端行级取合计。
  Map<String, dynamic>? _fileDiff(Map<String, dynamic> row) {
    final out = row['output'];
    final d = out is Map ? out['display'] : null;
    if (d is Map && d['kind'] == 'file_diff') {
      return d.cast<String, dynamic>();
    }
    if (d is Map && d['kind'] == 'file_diffs' && d['files'] is List) {
      var a = 0;
      var del = 0;
      for (final f in (d['files'] as List).whereType<Map>()) {
        a += intOrZero(f['additions']);
        del += intOrZero(f['deletions']);
      }
      return {'additions': a, 'deletions': del};
    }
    return null;
  }

  /// 流式期 ±N 先行值：edit 取 old/new 字符串行数、write 取 content 行
  /// 数；完成后以 output.display 权威值为准。
  /// 取值链对齐官方 toolCallRowAdapter.ts:36-54——优先结构化 input
  /// （进入 running 的 upsert 即携带），退 inputText 解析。档位天花板
  /// （2026-10-23 真机反馈"桌面实时跳、手机最后一次性跳出"的定性）：
  /// 官方桌面的打字期逐秒跳动是 continuous 档流式 inputText 增量
  /// （streaming-tool-input-preview.ts 半截 JSON 解析，节流 1s）；手机
  /// 被桌面端强制 replayable 档（webRemoteControlSharedHostAttachments
  /// :50 clientMode 硬编码），inputText 增量在服务端 flush 管线即被
  /// 过滤（profiles.ts:27-35），打字期数据不上手机——±N 最早只能出现
  /// 在"进入执行态"的 upsert 到达这一刻，客户端无解，非实现 bug。
  ({int a, int d}) _inputDiffCounts(Map<String, dynamic> row) {
    final name = '${row['toolName'] ?? row['name'] ?? ''}'.toLowerCase();
    final isEdit = name.contains('edit') || name.contains('apply_patch');
    final isWrite = name.contains('write') || name.contains('create');
    if (!isEdit && !isWrite) return (a: 0, d: 0);
    final decoded = toolInputArgs(row);
    if (decoded == null) return (a: 0, d: 0);
    int lines(dynamic v) =>
        v is String && v.isNotEmpty ? v.split('\n').length : 0;
    if (isEdit) {
      // 键位矩阵对齐官方 fileSummaryHeuristics.ts:181-201（old/new 各
      // 多形态：第三方工具用 before/after/old_content 等变体——此前
      // 只认 old_string/new_string 两形）。
      final oldS =
          decoded['old_string'] ??
          decoded['oldString'] ??
          decoded['oldText'] ??
          decoded['before'] ??
          decoded['old_content'] ??
          decoded['oldContent'];
      final newS =
          decoded['new_string'] ??
          decoded['newString'] ??
          decoded['newText'] ??
          decoded['after'] ??
          decoded['new_content'] ??
          decoded['newContent'];
      return (a: lines(newS), d: lines(oldS));
    }
    return (a: lines(decoded['content']), d: 0);
  }

  /// 摘要行 +N -M 行数 spans（官方隐藏规则：两者皆≤0 不显示）。
  List<InlineSpan> _diffCountSpans(Map<String, dynamic> row) {
    final fd = _fileDiff(row);
    var a = intOrZero(fd?['additions']);
    var d = intOrZero(fd?['deletions']);
    if (fd == null) {
      final input = identical(row, _memoRow) && _memoDiff != null
          ? _memoDiff!
          : _inputDiffCounts(row);
      a = input.a;
      d = input.d;
    }
    if (a <= 0 && d <= 0) return const [];
    return [
      TextSpan(
        text: '  +$a',
        style: TextStyle(
          color: context.colors.diffAdded,
          fontWeight: FontWeight.w600,
        ),
      ),
      TextSpan(
        text: ' -$d',
        style: TextStyle(
          color: context.colors.diffRemoved,
          fontWeight: FontWeight.w600,
        ),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final row = widget.row;
    final name = '${row['toolName'] ?? row['name'] ?? 'tool'}';
    // 优化批 #11：ExitPlanMode 专用计划卡（官方 switch-mode.tsx
    // SwitchModeToolCallBlock 对位）——此前按普通工具行渲染，摘要=
    // 计划前 72 字符、无卡片无全文页。计划正文三路全空（流式
    // inputText 未就绪/失败态）时回落通用工具行（官方同款兜底语义）。
    if ('${row['toolName'] ?? row['name'] ?? ''}' == 'ExitPlanMode') {
      final plan = extractPlanToolCallContent(row);
      if (plan != null) {
        return PlanModeCard(
          markdown: plan.markdown,
          planFilePath: plan.planFilePath,
        );
      }
    }
    final (color, statusLabel) = _statusStyle();
    // 记忆化：行引用未变直接复用上次解析结果（见字段声明注）。
    if (!identical(row, _memoRow)) {
      _memoRow = row;
      _memoDiff = _inputDiffCounts(row);
      _memoPreview = toolPreview(row);
    }
    final preview = _memoPreview;
    // 优化批 #5：消费协议 row.progress（官方 product-projection.ts
    // onToolCallProgress：MCP notifications/progress → progress
    // {fraction 0-1, total, message≤200, updatedAt}；终态由服务端清空、
    // Bash 的字节进度走 outputPreview 不进此字段——此前手机端零消费，
    // 运行中只有扫光。呈现对位官方 ToolCallProgressIndicator：有
    // fraction=determinate 细条，缺席（仅 message/total 到场）=
    // indeterminate 细条，message 尾随。
    final progress = row['progress'];
    final progressMap = progress is Map ? progress : null;
    final progressFraction = numOf(progressMap?['fraction'])?.toDouble();
    final progressMessage = '${progressMap?['message'] ?? ''}'.trim();
    final visibleOutput = _visibleOutput(row, running: statusLabel == '执行中');
    int? searchOutputStart;
    final source = widget.searchSourceText;
    final sourceStart = widget.searchStart;
    if (_searchTarget &&
        visibleOutput != null &&
        source != null &&
        sourceStart != null) {
      final sectionStart = source.lastIndexOf(visibleOutput);
      final candidate = sourceStart - sectionStart;
      if (sectionStart >= 0 &&
          candidate >= 0 &&
          candidate < visibleOutput.length) {
        searchOutputStart = candidate;
      }
    }
    return SearchTargetFrame(
      rowId: _rowId,
      activeRowId: widget.searchTargetRowId,
      targetKey: widget.searchTargetKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(4),
            onTap: _toggle,
            child: Padding(
              // 2026-10-23 用户反馈：流式工作行行距收半档（7→5，相邻行
              // 间隙 14→10）——紧凑一点不拥挤。
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 5),
              child: Row(
                children: [
                  // 静态图标（官方：运行态不转 loader，状态用文字表达）。
                  // 2026-10-23 用户反馈批：运行态图标与状态词同用 running
                  // 琥珀（对齐官方 running=warning），不再刻意降灰。
                  Icon(Icons.build_circle_outlined, size: 15, color: color),
                  const SizedBox(width: 7),
                  Expanded(
                    // V3 动效包#6：执行中扫光（官方运行态 kindLabel 同款）。
                    // 2026-10-23 用户反馈批：扫光文字从前景色改 running
                    // 琥珀——与思考条同配方，运行行一眼可辨；静止回最浅
                    // 文本色不变。
                    // 官方
                    // 工具行是常规无衬线 14px（ToolSummaryRow.tsx:186 text-ui-base，
                    // 等宽只用于代码块/输出区）；中英混排基线问题随之消失。
                    // 批4 反馈②（2026-10-23 用户）：流式期编辑行也显示
                    // ±N 先行值（从输入参数推——官方 fileSummaries.ts 在工具
                    // 完成前同样从 raw input 推行数；完成后换
                    // output.display 权威值）。扫光只作用工具名行，计数
                    // 常亮尾随。
                    child: statusLabel == '执行中'
                        ? Row(
                            children: [
                              Expanded(
                                child: ShimmerText(
                                  text: preview.isEmpty
                                      ? toolDisplayName(name)
                                      : '${toolDisplayName(name)} · $preview',
                                  maxLines: 1,
                                  style: TextStyle(
                                    fontSize: AppType.uiBase,
                                    fontWeight: FontWeight.w500,
                                    color: context.colors.running,
                                  ),
                                ),
                              ),
                              Text.rich(
                                TextSpan(children: _diffCountSpans(row)),
                                maxLines: 1,
                                style: TextStyle(
                                  fontSize: AppType.uiBase,
                                  color: context.colors.foregroundSubtlest,
                                ),
                              ),
                            ],
                          )
                        : Text.rich(
                            // -2：编辑/写入摘要带 +N -M 行数
                            // （官方 edit.tsx:125-148 彩色计数，两者皆≤0
                            // 不显示——官方隐藏规则照抄）。
                            TextSpan(
                              children: [
                                TextSpan(
                                  text: preview.isEmpty
                                      ? toolDisplayName(name)
                                      : '${toolDisplayName(name)} · $preview',
                                ),
                                ..._diffCountSpans(row),
                              ],
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: AppType.uiBase,
                              color: context.colors.foregroundSubtlest,
                            ),
                          ),
                  ),
                  // 收敛：官方完成态不显示状态词（ToolLayout.tsx:119
                  // shouldShowStatusLabel=运行/失败才显示）——「已执行」不再
                  // 每行常驻，降噪。
                  if (statusLabel != '已执行') ...[
                    const SizedBox(width: 8),
                    Text(
                      statusLabel,
                      style: TextStyle(
                        fontSize: AppType.uiXs,
                        color: color,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                  Icon(
                    _open ? Icons.expand_less : Icons.expand_more,
                    size: 15,
                    color: context.colors.foregroundSubtlest,
                  ),
                ],
              ),
            ),
          ),
          // 优化批 #5：运行中且服务端带来 row.progress 时，在工具名+状态
          // 词行下方出细进度条（间距 4dp；左缘 24=图标 15+间隙 7+行内距
          // 2，与工具名首字对齐）。放 InkWell 外、折叠区前——折叠态也
          // 可见（进度不该要求展开才能看）。
          if (statusLabel == '执行中' && progressMap != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 4, 2, 0),
              child: ToolProgressLine(
                fraction: progressFraction,
                message: progressMessage,
              ),
            ),
          // ②折叠动画（官方 300ms 高度过渡对位，用户拍板 2026-10-22）。
          AnimatedSize(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOutCubic,
            alignment: Alignment.topCenter,
            clipBehavior: Clip.antiAlias,
            // 官方工具展开内容无导线
            // （ToolLayout.tsx:20-21 仅 pt-2），导线是思考条专属语言。
            // 展开区（-1/4-3 批3 重构，2026-10-22）：
            // ①编辑/写入首块=内联 diff（官方 EditInlineDiffContent 对位）；
            // ②输出=限高滚动视口（官方 max-h-5lh overflow-auto——原 8 行
            // ellipsis 死截断第 9 行起永久不可读，与"展开的价值是看输出"
            // 自相矛盾）+运行中吸底+上滚冻结；③取值链 error.message →
            // outputPreview（replayable 档不流 output.text）→ output.text
            // → bash display.output；④全空出「没有输出。」占位（官方
            // execute.tsx:319）；⑤SelectableText=官方错误复制钮的手机等价。
            // 命令回显维持不回（2026-10-22 拍板，4a/4b 复核维持）。
            child: _open
                ? Container(
                    margin: const EdgeInsets.only(left: 8, bottom: 6),
                    padding: const EdgeInsets.only(left: 12, top: 2),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (_fileDiff(row) case final fd?)
                          InlineDiffPreview(display: fd),
                        OutputViewport(
                          text: visibleOutput,
                          follow: statusLabel == '执行中',
                          searchStart: searchOutputStart,
                          // 文件预览高亮（2026-10-23 真机反馈）：读取类
                          // 工具完成态按输入参数的文件路径推语言；运行中
                          // 保持纯文本（官方流式不高亮同策略）。
                          language: statusLabel == '执行中'
                              ? null
                              : _filePreviewLanguage(row),
                        ),
                      ],
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}

/// 工具行运行进度条（优化批 #5，官方 ToolCallProgressIndicator 对位：
/// “工具摘要行里的细进度条——有 fraction 用 determinate，否则
/// indeterminate 扫光；message 跟在后面”）。官方是摘要行内 h-1 小胶囊
/// 细条；手机侧放名称行下方独立一行：determinate 铺满可用宽（flex 2）
/// + message 尾随（flex 1），indeterminate=16×2 细条。颜色
/// brandAccent（官方 bg-brand 智谱蓝 token 同族）。

class ToolProgressLine extends StatelessWidget {
  final double? fraction;

  /// 服务端 message（协议已截 200 字；协议载荷保持原文不本地化）。
  final String message;

  const ToolProgressLine({required this.fraction, required this.message});

  @override
  Widget build(BuildContext context) {
    final accent = context.colors.brandAccent;
    return Row(
      children: [
        if (fraction != null)
          Expanded(
            flex: 2,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                key: const ValueKey('tool-progress'),
                value: fraction,
                minHeight: 4,
                color: accent,
                backgroundColor: context.colors.foregroundSubtlest.withValues(
                  alpha: AppAlpha.faint,
                ),
              ),
            ),
          )
        else
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: SizedBox(
              width: 16,
              height: 2,
              child: LinearProgressIndicator(
                key: const ValueKey('tool-progress'),
                minHeight: 2,
                color: accent,
                backgroundColor: context.colors.foregroundSubtlest.withValues(
                  alpha: AppAlpha.faint,
                ),
              ),
            ),
          ),
        if (message.isNotEmpty) ...[
          const SizedBox(width: 8),
          Expanded(
            flex: 1,
            child: Text(
              message,
              translate: false,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: AppType.uiXs,
                color: context.colors.foregroundSubtle,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// ExitPlanMode 专用计划卡（优化批 #11，官方 switch-mode.tsx
/// SwitchModeToolCallBlock 对位）：头部=旗帜图标+「计划」标签+计划文件
/// 名（planFilePath 叶子，官方 getPlanFileLabel 只显叶子）+右上复制；
/// 正文=MarkdownView 限高 200+底部渐隐（kBottomFadeMask 单源；官方
/// max-h-64+mask-image 同构——max-height 与渐隐必须在同一裁切节点，
/// 分层会让渐隐落空，官方注释实证）；底部「查看完整计划」按钮推全屏
/// 只读页。计划文本=协议载荷（AI 产出 markdown），保持原文。

class PlanModeCard extends StatelessWidget {
  final String markdown;
  final String planFilePath;

  const PlanModeCard({required this.markdown, this.planFilePath = ''});

  void _copy(BuildContext context) {
    Clipboard.setData(ClipboardData(text: markdown));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('计划已复制'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  void _openDetail(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlanModeDetailPage(
          markdown: markdown,
          planFilePath: planFilePath,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final fileLeaf = planFilePath.trim().isEmpty
        ? null
        : planFilePath.trim().split(RegExp(r'[\/]')).last;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: context.colors.card,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: context.colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 4, 0),
            child: Row(
              children: [
                Icon(
                  Icons.flag_outlined,
                  size: 16,
                  color: context.colors.foregroundSubtle,
                ),
                const SizedBox(width: 6),
                Text(
                  '计划',
                  style: TextStyle(
                    fontSize: AppType.uiCaption,
                    fontWeight: FontWeight.w500,
                    color: context.colors.foregroundSubtle,
                  ),
                ),
                if (fileLeaf != null && fileLeaf.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      fileLeaf,
                      translate: false,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: AppType.uiXs,
                        fontFamily: 'monospace',
                        color: context.colors.foregroundSubtlest,
                      ),
                    ),
                  ),
                ],
                IconButton(
                  padding: EdgeInsets.zero,
                  iconSize: 18,
                  tooltip: '复制计划',
                  onPressed: () => _copy(context),
                  icon: Icon(
                    Icons.copy_outlined,
                    size: 16,
                    color: context.colors.foregroundSubtlest,
                  ),
                ),
              ],
            ),
          ),
          ShaderMask(
            blendMode: BlendMode.dstIn,
            shaderCallback: (bounds) => kBottomFadeMask.createShader(bounds),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 200),
              child: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                  child: MarkdownView(
                    data: markdown,
                    codeHighlightEnabled: AppStateScope.of(context)
                        .uiPrefs
                        .codeHighlightEnabled,
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Align(
              alignment: Alignment.center,
              child: TextButton(
                onPressed: () => _openDetail(context),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('查看完整计划'),
                    SizedBox(width: 4),
                    Icon(Icons.arrow_forward, size: 14),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 计划全文页（优化批 #11）：Simple Scaffold + MarkdownView 全文可滚动
/// （次级页面全屏推入，本仓次级页统一模式——workflow_runs 同款
/// AppBar/背景 token）。

class PlanModeDetailPage extends StatelessWidget {
  final String markdown;
  final String planFilePath;

  const PlanModeDetailPage({required this.markdown, this.planFilePath = ''});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.colors.background,
      appBar: AppBar(
        backgroundColor: context.colors.background,
        surfaceTintColor: Colors.transparent,
        title: const Text('计划'),
        actions: [
          IconButton(
            iconSize: 20,
            tooltip: '复制计划',
            onPressed: () {
              Clipboard.setData(ClipboardData(text: markdown));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('计划已复制'),
                  duration: Duration(seconds: 2),
                ),
              );
            },
            icon: Icon(
              Icons.copy_outlined,
              size: 20,
              color: context.colors.foregroundSubtle,
            ),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        child: MarkdownView(
          data: markdown,
          codeHighlightEnabled: AppStateScope.of(context)
              .uiPrefs
              .codeHighlightEnabled,
        ),
      ),
    );
  }
}

/// 连续同类工具组（官方 explore.tsx / execute-group.tsx 对位）：
/// 收起态=计数摘要（运行中显示最新活跃子工具摘要，官方同款）；
/// 展开=左导线缩进子列表（官方 ml-2 border-l pl-3.5），子行复用
/// ToolCallTile（失败自动展开等折叠策略对子行照常生效）。

class OutputViewport extends StatefulWidget {
  final String? text;
  final bool follow;

  /// 文件预览语言（2026-10-23 用户真机反馈补齐：「读取」工具展开的
  /// 文件内容接语法高亮——官方 InlineCodeContent 同款；null=普通输出
  /// 保持纯文本。语言由调用方按文件扩展名推（languageForFilePath）。
  final String? language;
  final int? searchStart;

  const OutputViewport({
    required this.text,
    required this.follow,
    this.language,
    this.searchStart,
  });

  @override
  State<OutputViewport> createState() => OutputViewportState();
}

class OutputViewportState extends State<OutputViewport> {
  final _scroll = ScrollController();
  bool _autoFollow = true;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (!_scroll.hasClients) return;
      final pos = _scroll.position;
      _autoFollow = pos.maxScrollExtent - pos.pixels <= 2.0;
    });
    _scheduleSearchReveal();
  }

  void _scheduleSearchReveal() {
    final requested = widget.searchStart;
    if (requested == null) return;
    _autoFollow = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final text = widget.text;
      if (!mounted ||
          text == null ||
          widget.searchStart != requested ||
          !_scroll.hasClients) {
        return;
      }
      final start = requested.clamp(0, text.length);
      final totalLines = text.split('\n').length;
      final beforeLines = text.substring(0, start).split('\n').length - 1;
      final fraction = totalLines > 1
          ? beforeLines / totalLines
          : (text.isEmpty ? 0.0 : start / text.length);
      final max = _scroll.position.maxScrollExtent;
      final target = (max * fraction).clamp(0.0, max);
      _scroll.jumpTo(target);
    });
  }

  @override
  void didUpdateWidget(covariant OutputViewport oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.searchStart != oldWidget.searchStart ||
        widget.text != oldWidget.text) {
      _scheduleSearchReveal();
    }
    if (widget.searchStart == null &&
        widget.follow &&
        _autoFollow &&
        widget.text != oldWidget.text) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scroll.hasClients) return;
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      });
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.text;
    if (t == null || t.trim().isEmpty) {
      return Padding(
        padding: EdgeInsets.only(top: 4),
        child: Text(
          '没有输出。',
          style: TextStyle(
            fontSize: AppType.uiXs,
            color: context.colors.foregroundSubtlest,
          ),
        ),
      );
    }
    final baseStyle = TextStyle(
      fontSize: AppType.uiXs,
      fontFamily: 'monospace',
      // （2026-10-24 修复批，用户拍板 a 案）：深底 mono 输出提亮一档
      // ——官方 ExecuteOutput.tsx:44 同档（foreground-subtle），深色对比
      // 3.6:1→4.85:1 过 WCAG AA；浅色为设计基准不动（仍 subtlest）。
      color: Theme.of(context).brightness == Brightness.dark
          ? context.colors.foregroundSubtle
          : context.colors.foregroundSubtlest,
      height: 1.45,
    );
    // 文件预览高亮（批：读取工具展开区）：引擎与消息代码块同源
    // （code_highlight），着色 span 只覆写颜色，字号/等宽/行高继承
    // baseStyle；解析失败/语言未知回落纯文本，不损原有渲染。
    List<InlineSpan>? spans;
    if (widget.language != null &&
        AppStateScope.of(context).uiPrefs.codeHighlightEnabled) {
      spans = highlightCode(
        t,
        widget.language,
        brightness: Theme.of(context).brightness,
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 220),
        child: SingleChildScrollView(
          controller: _scroll,
          child: spans != null
              ? SelectableText.rich(TextSpan(style: baseStyle, children: spans))
              : SelectableText(t, style: baseStyle),
        ),
      ),
    );
  }
}

/// 编辑/写入展开区内联 diff 预览（官方 EditInlineDiffContent 对位：
/// structuredPatch ±行着色、限高滚动；-3，2026-10-22）。
