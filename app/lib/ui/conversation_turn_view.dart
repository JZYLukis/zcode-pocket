import 'dart:async';

import 'package:flutter/material.dart' hide Text;

import '../core/localized_text.dart';
import '../core/payload_guard.dart';
import '../core/theme.dart';
import 'conversation_message_cells.dart';
import 'conversation_session_opener.dart';
import 'conversation_tool_tiles.dart';
import 'motion.dart';
import 'turn_model.dart';
import 'workflow_runs_page.dart';

class TurnBar extends StatefulWidget {
  /// 会话 id（轮尾操作行的反馈/分支命令用；null=协议按钮禁用）。
  final String? sessionId;

  /// 快照 workflowRuns 投影（run 卡 toolCallId 联接权威源）。
  final List<Map<String, dynamic>>? workflowRuns;
  final TurnWork work;
  final bool showTools;
  final DateTime? Function(Map<String, dynamic> row) firstSeenOf;
  final Map<int, bool> toolOpen;

  /// 思考条完成态实测时长（页面级定格，见 _reasoningElapsedMs）。
  final int? Function(Map<String, dynamic> row) elapsedMsOf;

  /// 段内正文行的长按行操作（编辑重发等——正文移入段内后由段条转交）。
  final void Function(Map<String, dynamic> row)? onRowActions;

  /// 是否会话末轮。语义注（2026-10-26 用户澄清，拨回 拍板②）：
  /// 末轮不再默认展开——语义=运行中展开、完成后收起只剩最后回复；
  /// 当时报的"冻结重进整页收起"由 [phaseRunning] 承接。字段保留（轮尾
  /// 操作行等仍按末轮定位，且后续或有用）。
  final bool isLastTurn;

  /// 会话控制块 phase==running 且本轮是末轮（2026-10-26 用户澄清修复）：
  /// 窗口仍在运行时（含后台冻结很久回 app 的缓存预渲期——缓存 header
  /// 可能还停在上一轮的完成态）末轮必须以展开态呈现，不显示为收起。
  /// 显示层等价于 running；live 快照到达/轮真正完成后恢复完成语义。
  final bool phaseRunning;

  /// 运行中实时折叠的外部覆盖（回合快捷菜单）——按 header rowId 读写。
  /// null=未覆盖，沿用 tile 内部 _liveCollapsed/_open。
  final Map<int, bool>? liveCollapsedByRow;
  final int? searchTargetRowId;
  final GlobalKey? searchTargetKey;
  final int? searchStart;
  final String? searchSourceText;
  final String? searchSnippet;

  /// 搜索命中词级高亮（优化批 #25）：非空=搜索激活，段内正文切换为
  /// 纯文本预览+命中词底色（见 AssistantText.searchQuery）。
  final String? searchQuery;
  final ConversationSessionOpener openSession;
  final void Function(bool collapsed)? onLiveCollapsedChanged;

  const TurnBar({
    this.sessionId,
    this.workflowRuns,
    required this.work,
    required this.showTools,
    required this.firstSeenOf,
    required this.toolOpen,
    required this.elapsedMsOf,
    this.onRowActions,
    this.isLastTurn = false,
    this.phaseRunning = false,
    this.liveCollapsedByRow,
    this.searchTargetRowId,
    this.searchTargetKey,
    this.searchStart,
    this.searchSourceText,
    this.searchSnippet,
    this.searchQuery,
    required this.openSession,
    this.onLiveCollapsedChanged,
  });

  @override
  State<TurnBar> createState() => TurnBarState();
}

class TurnBarState extends State<TurnBar> {
  /// 默认展开档（收敛 2026-10-22，官方三条件手机化）：
  /// ①异常终态（completedInterrupted/failed 官方强制展开——不展会把
  /// 我方"失败工具自动展开"整个吞进收起区）；②无可见正文轮（收起=
  /// 光杆空条，官方同样默认展开）。
  /// ③末轮默认展开（2026-10-25 拍板）**已拨回**（2026-10-26 用户澄清：
  /// 语义=运行中展开、完成后收起只剩最后回复；当时报的"冻结重进整页
  /// 收起"其实是运行中会话被显示为收起——由 phaseRunning 修复，见
  /// [widget.phaseRunning] 注释）。正常完成轮（含末轮）默认收起。
  /// 手机化偏离保留：允许手动收起（官方钉死不可收，失败长回合在手机
  /// 上会永久占屏）。
  static bool _defaultOpen(TurnWork w) =>
      const [
        'completedInterrupted',
        'failed',
      ].contains('${w.header?['state']}') ||
      (w.visibleTextRow == null && w.work.isNotEmpty);

  late bool _open = _defaultOpen(widget.work);

  /// 运行中的历史区被用户手动折叠（ #5：不可折叠会顶满屏）。
  /// ③（2026-10-20）：工具显示关=运行中默认收起（免打扰只看进度条）；
  /// 用户点开仍见全部步骤（桌面三层折叠语义）。
  late bool _liveCollapsed = !widget.showTools;

  /// 窄修（2026-10-25 批①，用户拍板"只修手动收起"）：运行中被用户
  /// 收起=显式选择，完成边沿不得按末轮默认档强行展开覆盖（
  /// "手动收起不变"承诺的补落地；重新点开则回到自动档）。上轮失去末轮
  /// 身份的自动收起不在本修范围（用户拍板接受现状）。
  bool _manuallyCollapsedWhileRunning = false;
  bool _wasRunning = false;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    // 挂载即运行的轮（搜索跳转/懒列表重挂进
    // running 但桌面静默的回合）没有 didUpdateWidget 驱动——秒表冻在
    // 挂载瞬间值。与 ReasoningTile 的 initState→_startTicker 同构。
    _wasRunning = _effectiveRunning;
    _ensureTicker(_wasRunning);
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  void _ensureTicker(bool running) {
    if (running && _ticker == null) {
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else if (!running && _ticker != null) {
      // #7：build 期间不可 setState（running→completed 边沿会踩
      // 断言）——停 ticker 即可，didUpdateWidget 已触发重建。
      _ticker?.cancel();
      _ticker = null;
    }
  }

  @override
  void didUpdateWidget(covariant TurnBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    final running = _effectiveRunning;
    if (_wasRunning && !running) {
      // 官方语义：defaultOpen 翻转时 effect 重置展开态——正常轮收起
      // （含运行完成/phaseRunning 解除，"完成后收起只剩最后回复"），
      // 异常/无正文按默认档展开。例外：运行中被手动收起=用户
      // 选择优先，保持收起。
      _open = _manuallyCollapsedWhileRunning
          ? false
          : _defaultOpen(widget.work);
      _liveCollapsed = false;
      _manuallyCollapsedWhileRunning = false;
      widget.onLiveCollapsedChanged?.call(!_open);
    }
    _wasRunning = running;
    _ensureTicker(running);
  }

  /// 有效运行态：轮自身 running，或"窗口运行中"的末轮承接（phaseRunning，
  /// 2026-10-26 用户澄清修复——冻结重进缓存预渲期窗口仍运行时不得收起）。
  bool get _effectiveRunning =>
      widget.work.stateLabel == 'running' || widget.phaseRunning;

  /// 折叠覆盖键改 TurnWork.collapseKeyId 单源（有头
  /// 按 header rowId、无头半截回合按段内首行 rowId）——多个 -1 哨兵键会让
  /// 折叠状态跨回合串扰；页面侧写入同源。
  int get _turnId => widget.work.collapseKeyId;

  String _durationLabel() => workBarLabel(widget.work);

  /// 回合结束时刻（HH:mm；Paseo 参考 2026-10-23）。endedAt 缺失时用
  /// startedAt+activeMs 推（协议权威字段优先）。
  String? get _endedClock {
    final header = widget.work.header;
    final ended = intOf(header?['endedAt']);
    final active = intOf(header?['activeMs']);
    final started = intOf(header?['startedAt']);
    final ms =
        ended ?? (active != null && started != null ? started + active : null);
    if (ms == null) return null;
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final work = widget.work;
    final running = _effectiveRunning;
    // controlOnly 轮（官方 executionKind 门控）：不出工作条，内容直出。
    final controlOnly = work.isControlOnly;
    // 完成边沿的收敛/ticker 启停在 didUpdateWidget（ #7）。
    // 搜索命中只临时展开目标，不写 _open/liveCollapsedByRow；关闭搜索
    // 或切换命中后恢复用户原有折叠选择。
    final searchReveal = work.work.any(
      (row) => intOf(row['rowId']) == widget.searchTargetRowId,
    );
    final expanded =
        searchReveal ||
        (controlOnly
            ? true
            : (running
                  ? !(widget.liveCollapsedByRow?[_turnId] ?? _liveCollapsed)
                  : (widget.liveCollapsedByRow?[_turnId] == null
                        ? _open
                        : !widget.liveCollapsedByRow![_turnId]!)));
    // ③（2026-10-20 二轮澄清）：展开=用户显式想看步骤列表，不受工具
    // 显示开关限制（开关只管运行中的实时展示）；仅无工作行才不可展开。
    // controlOnly 不再钉死收起分支——旧实现把设置轮
    // 钉进收起态（只显最后一段正文，轮内更早正文/工具行永不渲染、
    // 搜索命中也无法展开）；「不出工作条」语义由下方 header 隐藏承接，
    // 有工作行的 controlOnly 轮照走展开分支（内容直出）。
    final expandable = turnWorkExpandable(work.work);

    final headerRow = Container(
      padding: const EdgeInsets.only(bottom: 8),
      // 收敛：底分隔线官方为 border 的 50%（border-b
      // border-[var(--color-border)]/50）——降浓不再抢正文。
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: context.colors.border.withValues(alpha: 0.5),
          ),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              _durationLabel(),
              // 收敛：工作区行族 13→14（官方 text-ui-base，
              // ConversationTurnGroup.tsx:683）；完成态退到最淡档（官方
              // foreground-subtlest，让工作行整体退后于正文）。
              style: TextStyle(
                fontSize: AppType.uiBase,
                color: running
                    ? context.colors.running
                    : context.colors.foregroundSubtlest,
              ),
            ),
          ),
          // Paseo 参考（2026-10-23）：完成态附回合结束绝对时刻（HH:mm）
          // ——运行中已有实时时长，完成后"何时结束"比"干了多久"更常被
          // 回看；endedAt 缺失（中断兜底等）不显示。
          if (!running && _endedClock != null)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Text(
                _endedClock!,
                style: TextStyle(
                  fontSize: AppType.uiXs,
                  color: context.colors.foregroundSubtlest,
                ),
              ),
            ),
          // 勘误（2026-10-22）：官方仅“默认展开态”（运行中/
          // 强开）隐藏 chevron，手动展开完成轮时保留旋转箭头；我方全
          // 态允许收起，箭头常驻并随展开翻转。
          if (expandable)
            Icon(
              expanded ? Icons.expand_less : Icons.expand_more,
              size: 16,
              color: context.colors.foregroundSubtlest,
            ),
        ],
      ),
    );

    final header = !expandable || controlOnly
        ? const SizedBox.shrink()
        : InkWell(
            borderRadius: BorderRadius.circular(4),
            onTap: () => setState(() {
              if (running) {
                _liveCollapsed = !_liveCollapsed;
                // 运行中的收起是显式选择（重开=回到自动档）。
                _manuallyCollapsedWhileRunning = _liveCollapsed;
                widget.onLiveCollapsedChanged?.call(_liveCollapsed);
              } else {
                _open = !_open;
                widget.onLiveCollapsedChanged?.call(!_open);
              }
            }),
            child: headerRow,
          );

    // ②折叠动画（官方 300ms 高度过渡对位，用户拍板 2026-10-22）：
    // 收起态内容（外置正文）与展开态内容（整段时间序）统一进
    // AnimatedSize——展开/收起平滑过渡；运行中流式增高也平滑跟随。
    final Widget content;
    if (!expanded || !expandable) {
      // 收起态：外置「可见正文」（官方语义：折叠区收起后最终正文
      // 仍可见，位于状态条之外）。
      final vt = work.visibleTextRow;
      // -5 折中（2026-10-22）：官方运行中即渲染文件卡
      // （in-flight 缓存档）；手机先给收起态「已更改 N 个文件」计数
      // 提示，完整文件卡仍随轮关闭投出。
      final runningFiles = running ? intOrZero(work.fileChanges?['files']) : 0;
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (vt != null) ...[
            Padding(
              padding: const EdgeInsets.only(top: 4),
              // 底边距清零（间距堆栈整改六轮定稿，用户验收
              // 拍板"差不多了"——收起态正文统一无底边距，卡侧空隙
              // 由卡自身表达）。
              child: SearchTargetFrame(
                rowId: intOf(vt['rowId']),
                activeRowId: widget.searchTargetRowId,
                targetKey: widget.searchTargetKey,
                child: AssistantText(
                  text: '${vt['text'] ?? ''}',
                  streaming: vt['state'] == 'streaming',
                  verticalPadding: 0,
                  sessionId: widget.sessionId,
                  header: work.header,
                  searchQuery: widget.searchQuery,
                ),
              ),
            ),
            // 轮尾操作行（2026-10-23 用户反馈批，桌面 ConversationRowView
            // :1580-1649 对位）：复制/点赞/点踩/分支 ghost 一排。
            // /：仅轮正常完成（官方只认 complete）且为轮内
            // 最后一个工作段（guided 追问一轮多段只挂末段）才渲染；
            // 复制内容=整轮正文合并（官方 join("\n\n")）。
            // 2026-10-24 验收：发了文件卡的轮操作行改挂卡后（官方
            // deferAssistantActions 顺序——hasSummaryCard 由 closeTurn 标记）。
            if (work.completedOk && work.isLastSegment && !work.hasSummaryCard)
              TurnTailActions(
                row: vt,
                copyText: work.allTextJoined,
                sessionId: widget.sessionId,
                createdAtMs: turnHeaderCreatedAt(work.header),
                openSession: widget.openSession,
              ),
          ],
          if (runningFiles > 0)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                '已更改 $runningFiles 个文件',
                style: TextStyle(
                  fontSize: AppType.uiCaption,
                  color: context.colors.foregroundSubtlest,
                ),
              ),
            ),
        ],
      );
    } else {
      // 展开：整段时间序回放（正文/思考/工具/子代理——思考条与工具
      // 行各自独立折叠，正文直接渲染）。
      // 展开态轮尾：最后一个 assistantText 单元下标（轮尾操作行挂它
      // 下面——与收起态外置正文同款，仅完成态）。
      final expandedUnits = buildWorkUnits(
        work.work,
        pairedSubagentByToolRowId: work.pairedSubagentByToolRowId,
        claimedSubagentRowIds: work.claimedSubagentRowIds,
      );
      var lastTextUnitIdx = -1;
      for (var ui = 0; ui < expandedUnits.length; ui++) {
        final u = expandedUnits[ui];
        if (u is RowUnit && '${u.row['kind']}' == 'assistantText') {
          lastTextUnitIdx = ui;
        }
      }
      content = Padding(
        padding: EdgeInsets.only(top: running ? 12.0 : 8.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 子步骤一行摘要（各自收起态，点开是 细节）——不按
            // showTools 过滤（③语义：显式展开永远可见步骤列表）。
            // -1/4-4（2026-10-22）：连续同类工具成组——官方
            // EXPLORE/TERMINAL 分组开关默认开（CHANGES 关=编辑不合并，
            // 不替官方开 flag）：连续 ≥2 只读类=「查阅」、连续 ≥2 Bash=
            // 「终端 · N 个命令」；单条不造组（官方同款）。
            for (var unitIdx = 0; unitIdx < expandedUnits.length; unitIdx++)
              switch (expandedUnits[unitIdx]) {
                // 合并卡（批②）：Agent 工具行原位置，含工具状态。
                SubagentPairUnit(:final toolRow, :final subagentRow) =>
                  SearchTargetFrame(
                    rowId: intOf(toolRow['rowId']),
                    activeRowId: widget.searchTargetRowId,
                    targetKey: widget.searchTargetKey,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SubagentTile(row: subagentRow, toolRow: toolRow, openSession: widget.openSession),
                        if (intOf(toolRow['rowId']) ==
                                widget.searchTargetRowId &&
                            widget.searchSnippet != null)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: Text(
                                widget.searchSnippet!,
                                translate: false,
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: AppType.uiXs,
                                  color: context.colors.accent,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                RowUnit(:final row) => switch ('${row['kind']}') {
                  // （lane 语义）：mid-turn auto-compact
                  //（lane=assistantWork）落在回合内部的标记行——内嵌
                  // 分隔线渲染，不劈开运行中轮。
                  'timelineMarker' => () {
                    final parsed = timelineMarkerLabelOf(row);
                    if (parsed == null) return const SizedBox.shrink();
                    return TimelineMarkerDivider(
                      label: parsed.$1,
                      running: parsed.$2,
                    );
                  }(),
                  'reasoning' => ReasoningTile(
                    row: row,
                    firstSeen: widget.firstSeenOf(row),
                    elapsedMs: widget.elapsedMsOf(row),
                  ),
                  'assistantText' => GestureDetector(
                    onLongPress: widget.onRowActions == null
                        ? null
                        : () => widget.onRowActions!(row),
                    child:
                        (running ||
                            unitIdx != lastTextUnitIdx ||
                            '${row['state']}' == 'streaming' ||
                            // 中断/失败轮不出操作行（官方
                            // 只认 complete）；：guided 只挂末段。
                            !work.completedOk ||
                            !work.isLastSegment ||
                            // 发了文件卡的轮操作行改挂卡尾
                            //（收起态 316 行同款守卫）——展开态漏守卫会
                            // 与 FileSummaryCard 尾部各出一条=双操作行。
                            work.hasSummaryCard)
                        ? SearchTargetFrame(
                            rowId: intOf(row['rowId']),
                            activeRowId: widget.searchTargetRowId,
                            targetKey: widget.searchTargetKey,
                            child: AssistantText(
                              text: '${row['text'] ?? ''}',
                              streaming: row['state'] == 'streaming',
                              sessionId: widget.sessionId,
                              header: work.header,
                              searchQuery: widget.searchQuery,
                            ),
                          )
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              SearchTargetFrame(
                                rowId: intOf(row['rowId']),
                                activeRowId: widget.searchTargetRowId,
                                targetKey: widget.searchTargetKey,
                                child: AssistantText(
                                  text: '${row['text'] ?? ''}',
                                  streaming: row['state'] == 'streaming',
                                  sessionId: widget.sessionId,
                                  header: work.header,
                                  searchQuery: widget.searchQuery,
                                ),
                              ),
                              TurnTailActions(
                                row: row,
                                copyText: work.allTextJoined,
                                sessionId: widget.sessionId,
                                createdAtMs: turnHeaderCreatedAt(work.header),
                openSession: widget.openSession,
                              ),
                            ],
                          ),
                  ),
                  'subagent' => SubagentTile(row: row, openSession: widget.openSession),
                  // （2026-10-29 审查）：TodoWrite 待办
                  // 清单官方有专用渲染（renderers/todo.tsx：状态图标+
                  // 完成计数+当前项）——此前降级为通用文本行。
                  'toolCall'
                      when '${row['toolName'] ?? row['name'] ?? ''}' ==
                              'OffPeakCreate' &&
                          offPeakCreateSummary(row) != null =>
                    OffPeakTaskCard(row: row),
                  // A 批（2026-11-08 拍板⑧）：CreateWorkflow 专用 run 卡
                  //（官方对位——不再淹没在通用工具行里）。
                  'toolCall'
                      when '${row['toolName'] ?? row['name'] ?? ''}' ==
                              'CreateWorkflow' =>
                    WorkflowRunCard(
                      row: row,
                      runs: widget.workflowRuns,
                      sessionId: widget.sessionId,
                    ),
                  'toolCall'
                      when '${row['toolName'] ?? row['name'] ?? ''}' ==
                              'TodoWrite' &&
                          TodoTile.todosOf(row) != null =>
                    TodoTile(
                      row: row,
                      openByRow: widget.toolOpen,
                      turnRunning: running,
                    ),
                  _ => ToolCallTile(
                    row: row,
                    openByRow: widget.toolOpen,
                    turnRunning: running,
                    searchTargetRowId: widget.searchTargetRowId,
                    searchTargetKey: widget.searchTargetKey,
                    searchStart: widget.searchStart,
                    searchSourceText: widget.searchSourceText,
                  ),
                },
                GroupUnit() => ToolGroupTile(
                  unit: expandedUnits[unitIdx] as GroupUnit,
                  toolOpen: widget.toolOpen,
                  turnRunning: running,
                  searchTargetRowId: widget.searchTargetRowId,
                  searchTargetKey: widget.searchTargetKey,
                  searchStart: widget.searchStart,
                  searchSourceText: widget.searchSourceText,
                ),
              },
            // （占位分支已随 ④ 移除：不可展开判定保证展开态必有可见
            // 内容，空轮直接渲染纯标签条。）
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header,
        AnimatedSize(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOutCubic,
          alignment: Alignment.topCenter,
          clipBehavior: Clip.antiAlias,
          child: content,
        ),
      ],
    );
  }
}

/// 思考条（官方 reasoning.tsx 对位， 重做）：**流式与完成态都默认收起**；
/// 收起时流式显示「正在思考」+ 最后一行思考的单行摘要，完成态显示
/// 「思考 · 持续了 N 秒」（无时长→「持续了几秒」）；静态大脑图标（长流式
/// 不做旋转/动画省渲染）；展开为 240px 限高内滚 + 自动吸底 + 左导线。

class ReasoningTile extends StatefulWidget {
  final Map<String, dynamic> row;
  final DateTime? firstSeen;

  /// 页面级定格的实测时长（收起期间完成等 tile 未挂载场景的兜底）。
  final int? elapsedMs;

  const ReasoningTile({
    required this.row,
    required this.firstSeen,
    this.elapsedMs,
  });

  @override
  State<ReasoningTile> createState() => ReasoningTileState();
}

class ReasoningTileState extends State<ReasoningTile> {
  final _innerScroll = ScrollController();
  Timer? _ticker;
  bool _userOpen = false;

  /// 完成边沿冻结的实测时长（-1，2026-10-22：服务端从不
  /// 下发 reasoning durationMs，官方在完成边沿用秒表实测值定稿——
  /// 此前我方测到的值被丢弃，标签退化「几秒」）。
  int? _frozenMs;
  bool _wasStreaming = false;

  /// 官方吸底跟随语义（reasoning.tsx:2px 容差）：用户离底暂停跟随、
  /// 滚回底部自动恢复——此前无条件强拉会把用户往回看的操作拽到底。
  bool _autoFollow = true;

  /// V2 折叠策略③：用户手动交互锁（官方 userInteracted 同款——手动
  /// 展开/收起过，完成时的自动收起永久让位）。
  bool _userToggled = false;

  bool get _streaming => widget.row['state'] == 'streaming';

  @override
  void initState() {
    super.initState();
    _wasStreaming = _streaming;
    if (_streaming) _startTicker();
    _innerScroll.addListener(() {
      if (!_innerScroll.hasClients) return;
      final pos = _innerScroll.position;
      _autoFollow = pos.maxScrollExtent - pos.pixels <= 2.0;
    });
  }

  @override
  void didUpdateWidget(covariant ReasoningTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 完成边沿当帧处理（-6：原 1 秒轮询最多迟 1 秒）：
    // ①秒表实测值定稿（官方 reasoning.tsx:129-133 同款）；②即时收起
    // （userInteracted 锁：用户手动展开过的不自动收）。
    if (_wasStreaming && !_streaming) {
      final seen = widget.firstSeen;
      if (seen != null) {
        _frozenMs = DateTime.now().difference(seen).inMilliseconds;
      }
      _ticker?.cancel();
      _ticker = null;
      if (reasoningAutoCollapse(userToggled: _userToggled)) {
        _userOpen = false;
      }
    }
    _wasStreaming = _streaming;
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _innerScroll.dispose();
    super.dispose();
  }

  void _startTicker() {
    _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      // -6：收起态无秒数不逐秒重绘（官方 reasoning.tsx:142-156
      // 同款省电注释）；完成检测已移交 didUpdateWidget 边沿。
      if (!_streaming || !_userOpen) return;
      setState(() {});
    });
  }

  void _followBottom() {
    if (!_innerScroll.hasClients || !_autoFollow) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_innerScroll.hasClients) return;
      _innerScroll.animateTo(
        _innerScroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
      );
    });
  }

  /// 思考文本的最后一个非空行（官方 streaming 摘要规则）。
  String get _lastLine {
    final text = '${widget.row['text'] ?? ''}';
    for (final line in text.split('\n').reversed) {
        if (line.trim().isNotEmpty) {
        // 官方语义"永远显示最新 token"，
        // 截头 60 字会让长行摘要冻结在旧内容；手机不做横滚（触屏手势
        // 冲突），前省略号截尾为等价实现。 ：截点走代理对
        // 安全版（劈开 emoji=replacement 字形）。
        return clipHeadSafe(line.trim(), 60);
      }
    }
    return '';
  }

  String _label() => reasoningLabel(
    streaming: _streaming,
    expanded: _userOpen,
    durationMs: reasoningDurationMs(widget.row),
    // tile 级边沿值优先（当帧精确），页面级定格兜底。
    measuredMs: _frozenMs ?? widget.elapsedMs,
    firstSeen: widget.firstSeen,
  );

  @override
  Widget build(BuildContext context) {
    if (_streaming) _startTicker();
    if (_userOpen && _streaming) _followBottom();
    // 收敛：完成态退最淡档（官方 foreground-subtlest，
    // reasoning.tsx:339-353）。
    final color = _streaming
        ? context.colors.running
        : context.colors.foregroundSubtlest;

    // 整列 AnimatedSize（用户拍板 2026-10-24：流式两行定高→完成一行高
    // 的收缩平滑过渡；条头与展开区高度变化统一动画）。
    return AnimatedSize(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOutCubic,
      alignment: Alignment.topCenter,
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(4),
            onTap: () {
              final opening = !_userOpen;
              setState(() {
                _userToggled = true;
                _userOpen = !_userOpen;
              });
              if (!opening) return;
              // 验收回填（2026-10-22）：展开内滚停到最下端（最新内容——
              // 收起期间 controller 保留旧 offset 会停在半截）；外层消息
              // 列表随动露出展开区（AnimatedSize 300ms 后再滚，避免滚到
              // 动画中间态）。
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!mounted || !_innerScroll.hasClients) return;
                _innerScroll.jumpTo(_innerScroll.position.maxScrollExtent);
              });
              Future.delayed(const Duration(milliseconds: 340), () {
                if (!mounted) return;
                // mounted 守卫已过；lint 对闭包内 context 误报，留痕豁免。
                Scrollable.ensureVisible(
                  // ignore: use_build_context_synchronously
                  context,
                  duration: const Duration(milliseconds: 200),
                  alignmentPolicy: ScrollPositionAlignmentPolicy.explicit,
                  alignment: 1.0,
                );
              });
            },
            child: Padding(
              // 2026-10-23 用户反馈：流式工作行行距收半档（7→5，相邻行
              // 间隙 14→10）——紧凑一点不拥挤。
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 5),
              child: Row(
                children: [
                  // 静态大脑图标（官方 BrainIcon size-4，不做旋转动画）。
                  Icon(Icons.psychology_outlined, size: 16, color: color),
                  const SizedBox(width: 7),
                  Expanded(
                    // V3 动效包#6：运行中文字扫光（官方 animated-gradient-text
                    // 复刻；ui-references 承诺补交付）。
                    child: _streaming
                        ? ShimmerText(
                            text:
                                _streaming && !_userOpen && _lastLine.isNotEmpty
                                ? '${_label()} · $_lastLine'
                                : _label(),
                            // 批4 反馈②（2026-10-23 用户）：折叠态摘要一行
                            // 信息量太少（流速快看不清）——升两行。
                            // 同日反馈二修（批因中途丢失重落地）：内容
                            // 时长短 1↔2 行切换会让下方内容上蹿下跳——
                            // minLines 固定两行占位（短句第二行留空）。
                            maxLines: 2,
                            minLines: 2,
                            // 工作区行族 13→14（官方 text-ui-base）。
                            style: TextStyle(
                              fontSize: AppType.uiBase,
                              color: color,
                            ),
                          )
                        : FixedLinesText(
                            // 用户拍板（2026-10-24 第二轮验收）：流式期两行
                            // 定高（防 1↔2 行跳动），完成态回落一行高（两行
                            // 占位在收起的流式内容族中突兀）——2→1 的高度
                            // 收缩由整列 AnimatedSize 平滑过渡。
                            text:
                                _streaming && !_userOpen && _lastLine.isNotEmpty
                                ? '${_label()} · $_lastLine'
                                : _label(),
                            lines: 1,
                            maxLines: 1,
                            style: TextStyle(
                              fontSize: AppType.uiBase,
                              color: color,
                            ),
                          ),
                  ),
                  Icon(
                    _userOpen ? Icons.expand_less : Icons.expand_more,
                    size: 15,
                    color: context.colors.foregroundSubtlest,
                  ),
                ],
              ),
            ),
          ),
          // ②折叠动画（官方 300ms 高度过渡对位，用户拍板 2026-10-22）。
          AnimatedSize(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOutCubic,
            alignment: Alignment.topCenter,
            clipBehavior: Clip.antiAlias,
            child: _userOpen
                ? Container(
                    constraints: const BoxConstraints(maxHeight: 240),
                    margin: const EdgeInsets.only(left: 8, bottom: 4),
                    padding: const EdgeInsets.only(left: 12),
                    decoration: BoxDecoration(
                      border: Border(
                        left: BorderSide(
                          color: context.colors.border,
                          width: 2,
                        ),
                      ),
                    ),
                    child: ScrollConfiguration(
                      behavior: ScrollConfiguration.of(context)
                          .copyWith(scrollbars: false),
                      child: SingleChildScrollView(
                        controller: _innerScroll,
                        keyboardDismissBehavior:
                            ScrollViewKeyboardDismissBehavior.onDrag,
                        child: Text(
                          '${widget.row['text'] ?? ''}'.isEmpty
                              ? '…'
                              : '${widget.row['text']}',
                          style: TextStyle(
                            fontSize: AppType.uiBase,
                            // 2026-11-05 反馈④：思考正文 70% 档归到与
                            // 工具行同层（subtlest）——正文黑/工作行灰
                            // 的层级差此前只达官方六成。
                            color: context.colors.foregroundSubtlest,
                            height: 1.5,
                          ),
                        ),
                      ),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}

/// 工具行（官方 ToolSummaryRow/ToolLayout 对位， 重做）：**逐行独立
/// 折叠、默认收起**，展开态按 rowId 记忆（页面级）；无 spinner——运行态
/// 用状态词+颜色表达（官方 animated-gradient-text 的手机化）；展开显示
/// 完整入参与结果摘要。状态词官方词表：等待中/执行中/已执行/执行失败/
/// 已拒绝/已停止。
/// TodoWrite 待办清单行（官方 renderers/todo.tsx 对位）：收起=
/// 「待办 · 当前项（完成数/总数）」；展开=逐项状态图标（进行中=箭头/
/// 完成=勾/未做=空圈，完成项降灰）。todos 取结构化 input（官方
/// readTodoPlan 同源），缺 todos 时由分派层兜底回通用行。

class ToolGroupTile extends StatefulWidget {
  final GroupUnit unit;
  final Map<int, bool> toolOpen;
  final bool turnRunning;
  final int? searchTargetRowId;
  final GlobalKey? searchTargetKey;
  final int? searchStart;
  final String? searchSourceText;

  const ToolGroupTile({
    required this.unit,
    required this.toolOpen,
    required this.turnRunning,
    this.searchTargetRowId,
    this.searchTargetKey,
    this.searchStart,
    this.searchSourceText,
  });

  @override
  State<ToolGroupTile> createState() => ToolGroupTileState();
}

class ToolGroupTileState extends State<ToolGroupTile> {
  @override
  Widget build(BuildContext context) {
    final rows = widget.unit.rows;
    final failed = rows.where((r) => '${r['status'] ?? ''}' == 'error').length;
    Map<String, dynamic>? runningRow;
    for (final r in rows) {
      final st = '${r['status'] ?? ''}';
      if (st == 'running' || st == 'inputStreaming') runningRow = r;
    }
    final searchReveal = rows.any(
      (row) => intOf(row['rowId']) == widget.searchTargetRowId,
    );
    final open =
        searchReveal || (widget.toolOpen[widget.unit.anchorRowId] ?? false);
    final label = switch (widget.unit.family) {
      GroupFamily.explore => '查阅 ${rows.length} 项',
      GroupFamily.terminal =>
        '终端 · ${rows.length} 个命令${failed > 0 ? '，$failed 个失败' : ''}',
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(4),
          onTap: () =>
              setState(() => widget.toolOpen[widget.unit.anchorRowId] = !open),
          child: Padding(
            // 2026-10-23 用户反馈：流式工作行行距收半档（7→5，相邻行
            // 间隙 14→10）——紧凑一点不拥挤。
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 5),
            child: Row(
              children: [
                // 2026-10-23 用户反馈批：组运行中图标同用 running 琥珀。
                Icon(
                  widget.unit.family == GroupFamily.terminal
                      ? Icons.terminal_outlined
                      : Icons.travel_explore_outlined,
                  size: 15,
                  color: runningRow != null
                      ? context.colors.running
                      : context.colors.foregroundSubtlest,
                ),
                const SizedBox(width: 7),
                Expanded(
                  // 运行中：最新活跃子工具摘要（官方 explore.tsx:440-444
                  // 同款；扫光对位单行工具行——2026-10-23 用户反馈批
                  // 起，扫光与图标统一 running 琥珀）。
                  child: runningRow != null
                      ? ShimmerText(
                          text:
                              '${toolDisplayName('${runningRow['toolName'] ?? ''}')} · ${toolPreview(runningRow.cast<String, dynamic>())}',
                          maxLines: 1,
                          style: TextStyle(
                            fontSize: AppType.uiBase,
                            color: context.colors.running,
                          ),
                        )
                      : Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: AppType.uiBase,
                            color: failed > 0
                                ? context.colors.destructive
                                : context.colors.foregroundSubtlest,
                          ),
                        ),
                ),
                Icon(
                  open ? Icons.expand_less : Icons.expand_more,
                  size: 15,
                  color: context.colors.foregroundSubtlest,
                ),
              ],
            ),
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOutCubic,
          alignment: Alignment.topCenter,
          clipBehavior: Clip.antiAlias,
          child: open
              ? Container(
                  margin: const EdgeInsets.only(left: 8, bottom: 4),
                  padding: const EdgeInsets.only(left: 12),
                  decoration: BoxDecoration(
                    border: Border(
                      left: BorderSide(color: context.colors.border, width: 2),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final row in rows)
                        ToolCallTile(
                          row: row.cast<String, dynamic>(),
                          openByRow: widget.toolOpen,
                          turnRunning: widget.turnRunning,
                          searchTargetRowId: widget.searchTargetRowId,
                          searchTargetKey: widget.searchTargetKey,
                          searchStart: widget.searchStart,
                          searchSourceText: widget.searchSourceText,
                        ),
                    ],
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }
}

/// 工具行输出视口（-1，2026-10-22）：限高滚动（官方
/// max-h-5lh overflow-auto 对位；原 8 行 ellipsis 死截断全文不可达），
/// 运行中自动吸底、用户上滚即冻结、回底恢复（官方 ExecuteOutput 同款），
/// 空输出出「没有输出。」占位；SelectableText=官方错误复制钮的手机
/// 等价物（无悬停）。

class SubagentTile extends StatelessWidget {
  final Map<String, dynamic> row;

  /// 配对的 Agent 工具行（批② 合并卡）：null=未配对的独立 subagent
  /// 卡（fail-open 保留）。工具状态参与终态判定——官方 agentToolCall 块
  /// 同携两者（配对后唯一的状态出口，不能只剩 subagent 视角）。
  final Map<String, dynamic>? toolRow;
  final ConversationSessionOpener openSession;
  const SubagentTile({required this.row, this.toolRow, required this.openSession});

  @override
  Widget build(BuildContext context) {
    final summary = '${row['summaryText'] ?? ''}';
    final type = '${row['subagentType'] ?? ''}';
    final status = '${row['status'] ?? row['state'] ?? ''}';
    final toolStatus = '${toolRow?['status'] ?? ''}';
    // 终态合成（官方状态词表：subagent running/success/failed/cancelled；
    // toolCall …/error/cancelled）：失败/取消必须可读——合并卡是配对后
    // 唯一的状态出口，灰卡无字=失败不可见（审查 实锤）。优先级：
    // 失败/取消取两侧并集；运行只认 subagent 行（子代理终态压过滞后的
    // 工具行——工具行 running 只在 subagent 状态缺席时兜底）。
    final failed = status == 'failed' || toolStatus == 'error';
    final cancelled =
        !failed && (status == 'cancelled' || toolStatus == 'cancelled');
    final running =
        !failed &&
        !cancelled &&
        (status == 'running' ||
            status == 'streaming' ||
            (status.isEmpty &&
                (toolStatus == 'running' ||
                    toolStatus == 'inputStreaming' ||
                    toolStatus == 'pendingApproval')));
    // #20 组合串不能整串查表（Text 自动 tr 只认完整键）——状态词先
    // 逐段 tr 再拼，英文界面不残留中文。
    final suffix = failed
        ? ' · ${tr('失败')}'
        : cancelled
        ? ' · ${tr('已取消')}'
        : '';
    final titleColor = failed
        ? context.colors.destructive
        : running
        ? context.colors.running
        : context.colors.foregroundSubtle;
    final iconColor = failed ? context.colors.destructive : titleColor;
    // 官方下钻语义（refs rows.ts subagentRowSchema.childSessionId 注释：
    // 存在 → UI 可下钻订阅 conversation/<childSessionId>）：有值才可点开
    // 只读会话视图（桌面 SubagentSessionSidePane 同款）。
    final childSessionId = '${row['childSessionId'] ?? ''}'.trim();
    // 2026-11-05 反馈①：类型恒显（官方 agent.tsx kindLabel+kindDetail
    // 三段式「子智能体 · 类型 · 任务描述」——此前类型只在 summary 为空
    // 时兜底，常态不可见）；下钻标题同官方 sidePaneTabPresentation
    // 优先用类型。
    final title = summary.isEmpty
        ? '${tr('子智能体')} $type'
        : summary;
    final openTitle = type.isNotEmpty ? type : title;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: context.colors.idleTaskSurface.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: context.colors.border),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.sm),
          onTap: childSessionId.isEmpty
              ? null
              : () => unawaited(
                  openSession(
                    context,
                    sessionId: childSessionId,
                    title: openTitle,
                    readOnly: true,
                  ),
                ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Row(
              children: [
                Icon(Icons.smart_toy_outlined, size: 16, color: iconColor),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    // 1.0.1 真机验收②（用户拍板）：行首机器人图标已表意
                    // ——「子智能体」前缀去掉省横向空间，标题=类型 · 摘要；
                    // 类型缺失回退原词（图标不足以自解释时）。
                    type.isEmpty
                        ? '${tr('子智能体')}${summary.isEmpty ? '' : ' · $summary'}$suffix'
                        : '$type${summary.isEmpty ? '' : ' · $summary'}$suffix',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppType.uiCaption,
                      // 2026-10-25 用户拍板：随 logo 同档——运行中标题也
                      // 琥珀（此前仅图标橙、标题恒灰，执行完回落灰）。
                      // 批②补：失败=destructive、取消=灰（suffix 可读）。
                      color: titleColor,
                    ),
                  ),
                ),
                if (childSessionId.isNotEmpty) ...[
                  const SizedBox(width: 4),
                  Icon(
                    Icons.chevron_right,
                    size: 16,
                    color: context.colors.foregroundSubtlest,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
// （排队条已随 迁出本文件——
//  OfflineSendQueueStrip 见 conversation_composer.dart、QueueStrip 的
//  sendQueuedNow/deleteQueueItem 转发层见 app_state.dart。）
