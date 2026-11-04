import 'dart:async';

import 'package:flutter/material.dart' hide Text;
import '../core/localized_text.dart';

import '../core/theme.dart';
import '../state/app_state_scope.dart';
import '../transport/conversation.dart';
import 'inline_diff_preview.dart';

/// 审批横幅（2.2，设计稿 §3.3）：pendingInteractions → 横幅贴输入栏上方。
///
/// 变体：
/// - permission：工具请求权限（toolName + summary + allowOnce/allowAlways/
///   deny 选项按钮）；
/// - userInput：等待输入（prompt + 选项/自由输入）；
/// - plan 变体：会话存在 plan 且来的是 userInput 审批时，标题"执行计划？"
///   并内嵌 plan 条目清单（✓已完成 ○待办）。
///
/// 应答走 resolveInteraction（先到先得，晚到 alreadyResolved 静默——
/// 横幅随 state.updated 的 pendingInteractions 清空自然消失）。
class InteractionBanner extends StatelessWidget {
  final ConversationState state;
  final String? sessionId;

  const InteractionBanner({
    super.key,
    required this.state,
    required this.sessionId,
  });

  Future<void> _resolve(
    BuildContext context, {
    required Map<String, dynamic> interaction,
    String? optionId,
    String? freeText,
    String? action,
    Map<String, dynamic>? content,
  }) async {
    final id = sessionId;
    if (id == null) return;
    try {
      await AppStateScope.of(context).resolveInteraction(
        id,
        '${interaction['interactionId'] ?? ''}',
        optionId: optionId,
        freeText: freeText,
        action: action,
        content: content,
      );
    } catch (e) {
      // alreadyResolved（先到先得）静默；其余（网络失败等）必须让用户知道
      // 应答没发出去（ #8：静默吞失败会让用户误以为已批准）。
      // A5（2026-10-19 审查）：精确匹配 alreadyResolved——原
      // `|| msg.contains('already')` 会把任何恰好含 already 的错误
      // （如 "already in progress"）也静默吞掉。alreadyResolved 仍静默
      // （波次 2 的刻意行为，回归防护 7.1 钉死）。
      final msg = '$e';
      if (msg.contains('alreadyResolved')) return;
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('应答发送失败，请重试：$msg'),
            duration: const Duration(seconds: 4),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final interactions = state.pendingInteractions;
    if (interactions.isEmpty || sessionId == null) {
      return const SizedBox.shrink();
    }
    // 多条审批同屏会挤压内容区（ #1/#9）——单槽展示第一条 +
    // 计数提示；卡片内部限高滚动，保证选项按钮始终可达。
    return Column(
      children: [
        _InteractionCard(
          // 一次一题的题序/草稿属单次交互状态——按 interactionId 挂 key，
          // 待答切换（首条解决后下一条顶上）时整卡重置（旧实现选择草稿
          // 会泄漏到下一张卡，同样被此修复）。
          key: ValueKey(
              'interaction-${interactions.first['interactionId'] ?? ''}'),
          interaction: interactions.first,
          sessionId: sessionId,
          plan: state.plan,
          onResolve: ({optionId, freeText, action, content}) => _resolve(
            context,
            interaction: interactions.first,
            optionId: optionId,
            freeText: freeText,
            action: action,
            content: content,
          ),
        ),
        if (interactions.length > 1)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
            child: Text(
              '还有 ${interactions.length - 1} 个待处理，处理完当前后依次出现',
              style: TextStyle(
                fontSize: AppType.uiXs,
                color: context.colors.foregroundSubtlest,
              ),
            ),
          ),
      ],
    );
  }
}

class _InteractionCard extends StatefulWidget {
  final Map<String, dynamic> interaction;
  final String? sessionId;
  final Map<String, dynamic>? plan;
  final Future<void> Function({
    String? optionId,
    String? freeText,
    String? action,
    Map<String, dynamic>? content,
  })
  onResolve;

  const _InteractionCard({
    super.key,
    required this.interaction,
    this.sessionId,
    required this.plan,
    required this.onResolve,
  });

  @override
  State<_InteractionCard> createState() => _InteractionCardState();
}

/// AskUserQuestion 应答 content 组装（官方 ElicitationDialog
/// buildElicitationResponseContent.tsx:273-302 对位）：
/// - answers：{问题文本: "value1, value2"}（仅真实作答的题）；
/// - answer_N：每题按序（multiSelect=数组，否则单值）；
/// - answer：单题时兼容旧读取路径。
/// 只提交用户真实选择的项——空答案由 Agent 自行判断（官方注释同款：
/// 避免用空串伪造偏好）。
Map<String, dynamic> buildQuestionsResponseContent(
  List<Map<String, dynamic>> questions,
  Map<int, Set<String>> selected, {
  Map<int, String> custom = const {},
}) {
  final answers = <String, String>{};
  final content = <String, dynamic>{};
  for (var i = 0; i < questions.length; i++) {
    final q = questions[i];
    final picked = selected[i];
    // B2（官方 ElicitationDialog customAnswer 对位）：
    // 自定义答案并入该题作答（selected+custom 同数组，getQuestionAnswers
    // 同款）；单选时自定义顶替选项选择。
    final customText = (custom[i] ?? '').trim();
    if ((picked == null || picked.isEmpty) && customText.isEmpty) {
      continue;
    }
    // 按 wire 选项序输出（确定性；官方按点击序，语义等价）。
    final ordered = <String>[];
    final opts = q['options'];
    if (opts is List) {
      for (final raw in opts.whereType<Map>()) {
        final v = '${raw['value'] ?? raw['label'] ?? ''}';
        if (picked != null && picked.contains(v)) ordered.add(v);
      }
    }
    if (customText.isNotEmpty && !ordered.contains(customText)) {
      ordered.add(customText);
    }
    if (ordered.isEmpty) continue;
    final multi = q['multiSelect'] == true;
    answers['${q['question'] ?? ''}'] = ordered.join(', ');
    content['answer_$i'] = multi ? ordered : ordered.first;
  }
  content['answers'] = answers;
  if (questions.length == 1 && content.containsKey('answer_0')) {
    content['answer'] = content['answer_0'];
  }
  return content;
}

class _InteractionCardState extends State<_InteractionCard> {
  final _freeText = TextEditingController();
  bool _busy = false;
  bool _showFreeInput = false;

  /// AskUserQuestion（questions 载荷）逐题选择草稿：题序 → 选中的
  /// option value 集合（官方 ElicitationDialog 同款）。
  final Map<int, Set<String>> _qSelected = {};

  /// B2：每题自定义答案（官方 customAnswer）；_qCustomOpen=当前展开
  /// 自定义输入框的题序（-1=无）。
  final Map<int, String> _qCustom = {};
  int _qCustomOpen = -1;
  final _qCustomInput = TextEditingController();

  /// 一次一题（2026-10-26 用户拍板+官方 ElicitationDialog questionIndex
  /// 对位）：单选题选中即自动进下一题、末题答完即提交；多选题停留等
  /// 显式提交。此前一次性平铺全部题目+总提交=官方形态的走样。
  int _qIndex = 0;

  /// R5a（2026-10-17 真机反馈）：权限类审批默认折叠明细——横幅不再
  /// 挤压对话区（标题+倒计时+选项按钮常驻，一眼可批）；计划审核等
  /// 需要明细才能决策的默认展开。
  late bool _detailsExpanded = widget.interaction['payload'] is Map &&
      '${(widget.interaction['payload'] as Map)['kind']}' != 'permission';

  /// 18077 验收#6（优化意见 A）：整卡暂时收起——想先看上下文再回来
  /// 审批；收起态=一行摘要条（interaction 未应答，仅视觉收纳）。
  bool _minimized = false;

  @override
  void dispose() {
    _freeText.dispose();
    _qCustomInput.dispose();
    super.dispose();
  }

  Future<void> _go({
    String? optionId,
    String? freeText,
    String? action,
    Map<String, dynamic>? content,
  }) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.onResolve(
        optionId: optionId,
        freeText: freeText,
        action: action,
        content: content,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 单选推进（官方 advanceFromQuestion 对位）：非末题进下一题；末题
  /// 已有作答则直接提交。
  void _advanceQuestion() {
    final total = _questionsTotal;
    if (_qIndex + 1 < total) {
      setState(() => _qIndex += 1);
      return;
    }
    if (_anyQAnswered) _submitQuestions();
  }

  int get _questionsTotal =>
      (widget.interaction['payload'] as Map?)?['questions'] is List
          ? ((widget.interaction['payload'] as Map)['questions'] as List).length
          : 0;

  //（O1 P1-1/O2 P1-1/O3 P1-2 三路同根）：某题「已作答」
  /// =选中项**或非空自定义**——官方 getQuestionAnswers（ElicitationDialog
  /// .tsx:263-270）把 customAnswer 与选中项同为合法作答。提交使能/翻页
  /// /计数统一走本判据：多选题仅填自定义不再死锁在「选择后继续」。
  bool _qAnswered(int qi) =>
      (_qSelected[qi]?.isNotEmpty ?? false) ||
      (_qCustom[qi] ?? '').trim().isNotEmpty;

  /// 全卷任一题已作答（主提交钮使能；与 _advanceQuestion 末题提交口径
  /// 一致——空集合不算作答，多选反选到空不虚亮按钮）。
  bool get _anyQAnswered =>
      _qSelected.values.any((s) => s.isNotEmpty) || _qCustom.isNotEmpty;

  /// 已作答题数（按钮「已选 N 题」计数；与 buildQuestionsResponseContent
  /// 的合成口径一致——custom-only 的题也计入，修复「已选 0 题」失真）。
  int get _answeredCount {
    var n = 0;
    for (var i = 0; i < _questionsTotal; i++) {
      if (_qAnswered(i)) n++;
    }
    return n;
  }

  void _submitQuestions() {
    final payload = widget.interaction['payload'];
    final questions = payload is Map && payload['questions'] is List
        ? (payload['questions'] as List)
            .whereType<Map>()
            .map((e) => e.cast<String, dynamic>())
            .toList()
        : const <Map<String, dynamic>>[];
    _go(
      action: 'accept',
      content: buildQuestionsResponseContent(
        questions,
        _qSelected,
        custom: _qCustom,
      ),
    );
  }

  /// 自定义答案行（B2：官方每题末尾自由输入补偿项对位）。
  List<Widget> _customAnswerBlock(List questions, int qi, bool multi) {
    final open = _qCustomOpen == qi;
    final saved = (_qCustom[qi] ?? '').trim();
    if (!open) {
      return [
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: InkWell(
            key: ValueKey('q-custom-open-$qi'),
            borderRadius: BorderRadius.circular(AppRadius.sm),
            onTap: _busy
                ? null
                : () => setState(() {
                    _qCustomOpen = qi;
                    _qCustomInput.text = saved;
                  }),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppRadius.sm),
                color: saved.isNotEmpty ? context.colors.selected : null,
                border: Border.all(color: context.colors.borderFaint),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.edit_outlined,
                    size: 14,
                    color: context.colors.foregroundSubtle,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      saved.isNotEmpty
                          ? tr('自定义：') + saved
                          : tr('自定义答案…'),
                      translate: false,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: AppType.uiSm,
                        color: context.colors.foregroundSubtle,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ];
    }
    return [
      Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                key: ValueKey('q-custom-input-$qi'),
                controller: _qCustomInput,
                autofocus: true,
                minLines: 1,
                maxLines: 3,
                decoration: InputDecoration(
                  hintText: tr('输入自定义答案'),
                  isDense: true,
                  border: const OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 6),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  key: ValueKey('q-custom-confirm-$qi'),
                  icon: const Icon(Icons.check, size: 18),
                  onPressed: _busy
                      ? null
                      : () {
                          final text = _qCustomInput.text.trim();
                          setState(() {
                            _qCustomOpen = -1;
                            if (text.isEmpty) {
                              _qCustom.remove(qi);
                            } else {
                              _qCustom[qi] = text;
                              // 单选：自定义顶替选项选择（官方
                              // selectedValues+customAnswer 单选语义）。
                              if (!multi) _qSelected.remove(qi);
                            }
                          });
                          if (!multi) _advanceQuestion();
                        },
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () =>
                      setState(() => _qCustomOpen = -1),
                ),
              ],
            ),
          ],
        ),
      ),
    ];
  }

  /// 一道选择题的渲染块（全宽行选项，触控友好；选中=品牌蓝描边+浅蓝底）。
  List<Widget> _questionBlock(List questions, int qi) {
    final q = questions[qi];
    if (q is! Map) return const [];
    final opts = q['options'];
    final multi = q['multiSelect'] == true;
    final selected = _qSelected[qi] ?? const <String>{};
    return [
      if (qi > 0) const SizedBox(height: 12),
      if ('${q['header'] ?? ''}'.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 2),
          child: Text(
            '${q['header']}',
            translate: false,
            style: TextStyle(
              fontSize: AppType.uiXs,
              fontWeight: FontWeight.w600,
              color: context.colors.foregroundSubtlest,
            ),
          ),
        ),
      Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Text(
          '${q['question'] ?? ''}',
          translate: false,
          style: TextStyle(
            fontSize: AppType.uiCaption,
            fontWeight: FontWeight.w600,
            color: context.colors.foreground,
          ),
        ),
      ),
      const SizedBox(height: 8),
      if (opts is List)
        for (final (rawIndex, raw) in opts.whereType<Map>().indexed)
          () {
            final opt = raw.cast<String, dynamic>();
            final value = '${opt['value'] ?? opt['label'] ?? ''}';
            final sel = selected.contains(value);
            final desc = '${opt['description'] ?? opt['preview'] ?? ''}';
            return Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: InkWell(
                borderRadius: BorderRadius.circular(AppRadius.sm),
                onTap: _busy
                    ? null
                    : () {
                        setState(() {
                          final cur = _qSelected.putIfAbsent(
                            qi,
                            () => <String>{},
                          );
                          if (multi) {
                            cur.contains(value)
                                ? cur.remove(value)
                                : cur.add(value);
                          } else {
                            cur
                              ..clear()
                              ..add(value);
                            // （O2 P2-1）：单选选中=重置该题
                            // 自定义草稿（官方 updateElicitationDraftsForOption
                            // 单选分支 customAnswer:""，ElicitationDialog.tsx
                            // :321）——否则已放弃的自定义文本随 answers 发出
                            // 且与 answer_N 单值互相矛盾（'B, foo' vs 'B'）。
                            // 多选分支官方保留 customAnswer，不动。
                            _qCustom.remove(qi);
                          }
                        });
                        // 一次一题（官方 advanceFromQuestion 对位）：单选
                        // 选中即推进——末题答完直接提交，多选停留等提交。
                        if (!multi) _advanceQuestion();
                      },
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                    // 官方 ElicitationDialog 选项行（2026-10-26 对齐批 D）：
                    // 选中=bg-selected 整行底色，无彩色描边；单选无 radio
                    // 图标——序号「n.」选中提亮表达；多选保留复选框。
                    color: sel ? context.colors.selected : null,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (multi)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: Icon(
                            sel
                                ? Icons.check_box
                                : Icons.check_box_outline_blank,
                            size: 18,
                            color: sel
                                ? context.colors.foreground
                                : context.colors.foregroundSubtlest,
                          ),
                        )
                      else
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: Text(
                            '${rawIndex + 1}.',
                            style: TextStyle(
                              fontSize: AppType.uiCaption,
                              fontWeight: FontWeight.w500,
                              color: sel
                                  ? context.colors.foreground
                                  : context.colors.foregroundSubtlest,
                            ),
                          ),
                        ),
                      Expanded(
                        // 官方：label 与描述同一行内联（ml-2 subtle）。
                        child: Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(
                                text: '${opt['label'] ?? value}',
                                style: TextStyle(
                                  fontSize: AppType.uiCaption,
                                  fontWeight: FontWeight.w500,
                                  color: context.colors.foreground,
                                ),
                              ),
                              if (desc.isNotEmpty)
                                TextSpan(
                                  text: '  $desc',
                                  style: TextStyle(
                                    fontSize: AppType.uiCaption,
                                    color: context.colors.foregroundSubtle,
                                  ),
                                ),
                            ],
                          ),
                          translate: false,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }(),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final payload = widget.interaction['payload'];
    if (payload is! Map) return const SizedBox.shrink();
    final kind = '${payload['kind']}';
    final planItems = widget.plan?['items'];
    // AskUserQuestion（官方 Elicitation 对位）：questions 载荷优先于
    // plan/legacy options 判定——2026-10-22 真机反馈：agent 提问时只
    // 见问题文本不见选项，根因=横幅未实现 questions 分支。
    final questions = payload['questions'];
    final isQuestions =
        kind == 'userInput' && questions is List && questions.isNotEmpty;
    // 2026-10-22 真机反馈①：AskUserQuestion 到达时会话常有 TodoWrite
    // 计划（state.plan 非空）——questions 优先，不再叠加计划清单/改标题
    // 「执行计划？」（截图中提问卡被塞进整份待办即此根因）。
    final isPlanApproval = kind == 'userInput' &&
        planItems is List &&
        planItems.isNotEmpty &&
        !isQuestions;
    // 优化批 #10：审批富预览载荷（命令类=等宽代码块、编辑/写入类=内联
    // diff），null=无富预览（读取/通用类维持纯文本明细行）。见
    // _permissionRichPreview。
    final rich = kind == 'permission' ? _permissionRichPreview(payload) : null;

    final title = switch (kind) {
      'permission' => '工具请求权限 · ${payload['toolName'] ?? ''}',
      'userInput' => isPlanApproval
          ? '执行计划？'
          : isQuestions
              ? '等待你的选择'
              : '等待你的输入',
      'workspaceHookReview' => '工作区 Hook 审核',
      _ => '需要确认',
    };

    final color = kind == 'permission'
        ? context.colors.interactionAskForeground
        : context.colors.success;

    // 18077 验收#6（优化意见 A）：收起态——一行摘要条，点击恢复整卡
    // （interaction 本身未应答，服务端倒计时照常走，只是视觉收纳）。
    if (_minimized) {
      return Container(
        margin: const EdgeInsets.fromLTRB(8, 4, 8, 0),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: context.colors.card,
          borderRadius: BorderRadius.circular(AppRadius.card),
          border: Border.all(color: color.withValues(alpha: AppAlpha.mid)),
        ),
        child: InkWell(
          key: const ValueKey('interaction-minimized-bar'),
          borderRadius: BorderRadius.circular(AppRadius.sm),
          onTap: () => setState(() => _minimized = false),
          child: Row(
            children: [
              Icon(
                kind == 'permission'
                    ? Icons.privacy_tip_outlined
                    : Icons.help_outline,
                size: 14,
                color: color,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '$title · ${tr('待处理，点击展开')}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: AppType.uiCaption,
                    color: context.colors.foregroundSubtle,
                  ),
                ),
              ),
              _AutoResolutionCountdown(
                interaction: widget.interaction,
                sessionId: widget.sessionId,
              ),
              Icon(
                Icons.expand_more,
                size: 16,
                color: context.colors.foregroundSubtlest,
              ),
            ],
          ),
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.fromLTRB(8, 4, 8, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: context.colors.card,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: color.withValues(alpha: AppAlpha.strong)),
        boxShadow: context.shadows.md,
      ),
      child: ConstrainedBox(
        // questions 多题+选项描述体量大：320 硬裁在真机上呈"切一半"
        // （反馈①）——提问卡放宽到近半屏，其余维持 320。
        constraints: BoxConstraints(
          maxHeight:
              isQuestions ? MediaQuery.sizeOf(context).height * 0.48 : 320,
        ),
        child: SingleChildScrollView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    kind == 'permission'
                        ? Icons.privacy_tip_outlined
                        : Icons.help_outline,
                    size: 15,
                    color: color,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      title,
                      // 18077 审美门必修 1A（用户拍板）：标题行瘦身——倒计
                      // 时降级到下方独立行后，标题有整行宽度；单行省略防
                      // 工具名被挤孤悬第二行。
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: AppType.uiBase,
                        fontWeight: FontWeight.w600,
                        color: color,
                      ),
                    ),
                  ),
                  if (kind == 'permission')
                    // 批次4 触控目标：20×20 裸 GestureDetector → IconButton
                    // （ripple+tooltip 无障碍标签）。
                    // 批次A（设计审计）：44→48——外层 tight SizedBox 会压掉
                    // IconButton 默认的 48 最小盒，去掉 tight 约束即恢复。
                    // 18077 审美门建议②：可见图形 20→24（隐性触控面 48
                    // 不变，可见尺寸进 40dp 档）。
                    IconButton(
                      padding: EdgeInsets.zero,
                      iconSize: 24,
                      // O1 P2-5：tooltip 不是 Text 组件，不经
                      // 自定义 Text 的自动查表——需显式 tr()。
                      tooltip: _detailsExpanded ? tr('收起明细') : tr('展开明细'),
                      onPressed: () =>
                          setState(() => _detailsExpanded = !_detailsExpanded),
                      icon: Icon(
                        _detailsExpanded
                            ? Icons.expand_less
                            : Icons.expand_more,
                        size: 24,
                        color: context.colors.foregroundSubtle,
                      ),
                    ),
                  // 18077 验收#6（优化意见 A）：整卡收起（先看上下文再回
                  // 来审批）。建议②：可见图形放大。
                  IconButton(
                    padding: EdgeInsets.zero,
                    iconSize: 24,
                    tooltip: tr('暂时收起'),
                    onPressed: () => setState(() => _minimized = true),
                    icon: Icon(
                      Icons.minimize,
                      size: 24,
                      color: context.colors.foregroundSubtle,
                    ),
                  ),
                ],
              ),
              // 18077 审美门必修 1A（用户拍板）：倒计时从标题行降级到
              // 标题行下方独立一行——标题行原本 5 类元素（图标+标题+
              // 胶囊+两按钮）超审美门拥挤判据，且工具名被挤孤悬。
              if (widget.interaction['autoResolution'] is Map)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: _AutoResolutionCountdown(
                      interaction: widget.interaction,
                      sessionId: widget.sessionId,
                    ),
                  ),
                ),
              if (kind == 'permission') ...[
                // 优化批 #10：富预览优先——命令类（execute/bash）出等宽
                // 代码块、编辑/写入类出内联 diff（官方 PermissionDialog
                // buildPermissionToolCall 同思路：把权限请求还原成
                // toolCall 交给聊天区渲染器，命令/编辑各有专用块）。富预
                // 览已是完整内容，不再与 R5 明细行/展开态全文叠放。
                if (rich case final richPreview?)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: richPreview['kind'] == 'command'
                        ? _PermissionCommandBlock(
                            command: '${richPreview['text']}',
                          )
                        : InlineDiffPreview(
                            display: (richPreview['display'] as Map)
                                .cast<String, dynamic>(),
                            // 18077 验收#6（A）：大 diff 折叠（默认 24 行
                            // +显示全部）。
                            collapsible: true,
                          ),
                  )
                // R5：一行明细预览常驻（用户核心诉求"批准的具体是什么"），
                // 完整内容展开看。优先 detail（真实操作），summary 过滤
                // 通用策略文案后仅作补充说明。
                else if (_permissionDetailLine(payload) case final detailLine?)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      detailLine,
                      maxLines: _detailsExpanded ? 6 : 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: AppType.uiCaption,
                        color: context.colors.foreground,
                      ),
                    ),
                  ),
                if (_detailsExpanded && rich == null) ...[
                  if (_permissionDetailLine(payload) case final full?)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        '$full',
                        maxLines: 8,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: AppType.uiXs,
                          color: context.colors.foregroundSubtle,
                        ),
                      ),
                    ),
                  if ('${payload['summary'] ?? ''}'.isNotEmpty &&
                      !_genericReasons.contains('${payload['summary']}'))
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        '${payload['summary']}',
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: AppType.uiXs,
                          color: context.colors.foregroundSubtle,
                        ),
                      ),
                    ),
                ],
              ],
              // questions 模式不渲染 prompt——服务端 prompt 是英文原文
              // （"Tool AskUserQuestion requires user interaction"），官方
              // ElicitationDialog 以首题 question 为正文（prompt 仅兜底，
              // pendingInteractionAdapter.ts:130）。
              if (kind == 'userInput' &&
                  !isQuestions &&
                  '${payload['prompt'] ?? ''}'.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    '${payload['prompt']}',
                    translate: false,
                    style: TextStyle(
                      fontSize: AppType.uiCaption,
                      color: context.colors.foregroundSubtle,
                    ),
                  ),
                ),
              // Plan 变体：内嵌计划条目（✓已完成 ○待办 · 进行中高亮）
              if (isPlanApproval) ...[
                const SizedBox(height: 8),
                ...[
                  for (final item in planItems.whereType<Map>().take(12))
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            switch ('${item['status']}') {
                              'completed' => Icons.check_circle,
                              'inProgress' => Icons.play_circle,
                              _ => Icons.radio_button_unchecked,
                            },
                            size: 15,
                            color: switch ('${item['status']}') {
                              'completed' => context.colors.success,
                              'inProgress' => context.colors.running,
                              _ => context.colors.foregroundSubtlest,
                            },
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              '${item['content']}',
                              translate: false,
                              style: TextStyle(
                                fontSize: AppType.uiCaption,
                                height: 1.4,
                                color: '${item['status']}' == 'completed'
                                    ? context.colors.foregroundSubtlest
                                    : context.colors.foreground,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ],
              // AskUserQuestion：一次一题（2026-10-26 用户拍板，官方
              // ElicitationDialog questionIndex 对位——单选选中即进下一题/
              // 末题提交，多选停留等提交；此前全部平铺+总提交是走样）。
              if (isQuestions) ...[
                // 官方 ElicitationDialog 控制列（2026-10-26 对齐批 D）：
                // 头部一行「‹ n / m ›」（上一题在此，非底部按钮）。
                if (questions.length > 1)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 32,
                          height: 32,
                          child: IconButton(
                            key: const ValueKey('question-prev'),
                            padding: EdgeInsets.zero,
                            iconSize: 16,
                            tooltip: tr('上一题'),
                            onPressed: _busy || _qIndex == 0
                                ? null
                                : () => setState(() => _qIndex -= 1),
                            icon: const Icon(Icons.chevron_left),
                          ),
                        ),
                        Text(
                          '${_qIndex + 1} / ${questions.length}',
                          style: TextStyle(
                            fontSize: AppType.uiCaption,
                            fontWeight: FontWeight.w500,
                            color: context.colors.foregroundSubtlest,
                          ),
                        ),
                        SizedBox(
                          width: 32,
                          height: 32,
                          child: IconButton(
                            key: const ValueKey('question-next'),
                            padding: EdgeInsets.zero,
                            iconSize: 16,
                            tooltip: tr('下一题（已有作答时）'),
                            onPressed: _busy ||
                                    _qIndex >= questions.length - 1 ||
                                    !_qAnswered(_qIndex)
                                ? null
                                : () => setState(() => _qIndex += 1),
                            icon: const Icon(Icons.chevron_right),
                          ),
                        ),
                      ],
                    ),
                  ),
                ..._questionBlock(questions, _qIndex),
                ..._customAnswerBlock(
                  questions,
                  _qIndex,
                  (questions[_qIndex] is Map) &&
                      (questions[_qIndex] as Map)['multiSelect'] == true,
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    const Spacer(),
                    TextButton(
                      onPressed: _busy ? null : () => _go(action: 'decline'),
                      child: const Text(
                        '跳过',
                        style: TextStyle(fontSize: AppType.uiCaption),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      // 18077 审美门建议③（用户拍板）：未选时禁用态从灰底
                      // 灰字（易误读为「渲染坏了」）改描边禁用态——明确
                      // 「这是一个按钮，还没到能点的状态」。
                      child: (_busy || !_anyQAnswered)
                          ? OutlinedButton(
                              style: OutlinedButton.styleFrom(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 8),
                              ),
                              onPressed: null,
                              child: Text(
                                !_anyQAnswered
                                    ? '选择后继续'
                                    : '处理中…',
                                style: const TextStyle(
                                  fontSize: AppType.uiCaption,
                                ),
                              ),
                            )
                          : FilledButton(
                              style: FilledButton.styleFrom(
                                backgroundColor: context.colors.brand,
                                foregroundColor: context.colors.onBrand,
                                padding: const EdgeInsets.symmetric(vertical: 8),
                              ),
                              onPressed: (_qIndex + 1 < questions.length)
                                  ? () => setState(() => _qIndex += 1)
                                  : _submitQuestions,
                              child: Text(
                                _qIndex + 1 < questions.length
                                    ? '下一题（已选 ${_answeredCount} 题）'
                                    : '提交（已选 ${_answeredCount} 题）',
                                style: const TextStyle(
                                  fontSize: AppType.uiCaption,
                                ),
                              ),
                            ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 10),
              if (!isQuestions &&
                  payload['options'] is List &&
                  (payload['options'] as List).isNotEmpty)
                // 官方 PermissionDialog（2026-10-26 对齐批 D，调研实证）：
                // 选项=纵向整宽行列表（序号+label+描述内联+同权重，
                // 无彩色主次）——原 Wrap 横向摊开是自造形态。手机裁量：
                // 点选即执行（官方桌面需二次确认钮）。
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final (oi, raw) in (payload['options'] as List).indexed)
                      if (raw is Map)
                        () {
                          final opt = raw.cast<String, dynamic>();
                          final rawLabel =
                              '${opt['label'] ?? opt['optionId'] ?? ''}';
                          final label = _optionLabelZh[rawLabel] ??
                              _optionLabelZh[rawLabel.toLowerCase()] ??
                              rawLabel;
                          final desc = '${opt['description'] ?? ''}';
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: InkWell(
                              borderRadius:
                                  BorderRadius.circular(AppRadius.sm),
                              onTap: _busy
                                  ? null
                                  : () => _go(
                                        optionId: '${opt['optionId'] ?? ''}',
                                        // permission
                                        // 官方形态=optionId(+content)不带
                                        // action——action 会让 broker 走
                                        // accept/decline 精确映射，deny_once
                                        // 等粒度可能被折叠成裸 decline
                                        // （官方 V4InteractionDialogs:358）。
                                        content: {
                                          for (final key
                                              in const ['value', 'label', 'kind'])
                                            if (opt[key] != null)
                                              key: opt[key],
                                        },
                                      ),
                              child: Container(
                                width: double.infinity,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 8,
                                ),
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(
                                      AppRadius.sm),
                                  color: context.colors.sidebar,
                                ),
                                child: Row(
                                  children: [
                                    Padding(
                                      padding: const EdgeInsets.only(right: 8),
                                      child: Text(
                                        '${oi + 1}.',
                                        style: TextStyle(
                                          fontSize: AppType.uiCaption,
                                          fontWeight: FontWeight.w500,
                                          color: context
                                              .colors.foregroundSubtlest,
                                        ),
                                      ),
                                    ),
                                    Expanded(
                                      child: Text.rich(
                                        TextSpan(
                                          children: [
                                            TextSpan(
                                              text: label,
                                              style: TextStyle(
                                                fontSize: AppType.uiCaption,
                                                fontWeight: FontWeight.w500,
                                                color: context
                                                    .colors.foreground,
                                              ),
                                            ),
                                            if (desc.isNotEmpty)
                                              TextSpan(
                                                text: '  $desc',
                                                style: TextStyle(
                                                  fontSize:
                                                      AppType.uiCaption,
                                                  color: context.colors
                                                      .foregroundSubtle,
                                                ),
                                              ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        }(),
                  ],
                ),
              // 附言输入仅权限/输入类交互（2026-10-26 真机事故根因修复：
              // 问题卡（AskUserQuestion）也带 freeText 标志时曾同时出现
              // "附言确认"第二提交入口——只带 freeText 不带选项答案提交，
              // 桌面端校验"必须有答案"直接拒绝。官方 Elicitation 无附言
              // 通道，问题卡一律不渲染）。
              if (!isQuestions && payload['freeText'] == true) ...[
                if (!_showFreeInput)
                  TextButton.icon(
                    onPressed: _busy
                        ? null
                        : () => setState(() => _showFreeInput = true),
                    icon: const Icon(Icons.edit_note, size: 16),
                    label: const Text(
                      '附言输入',
                      style: TextStyle(fontSize: AppType.uiCaption),
                    ),
                  )
                else ...[
                  const SizedBox(height: 8),
                  TextField(
                    controller: _freeText,
                    minLines: 1,
                    maxLines: 3,
                    style: const TextStyle(fontSize: AppType.mobileInputSafe),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: tr('反馈（可选）'),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(AppRadius.sm),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: context.colors.brand,
                        foregroundColor: context.colors.onBrand,
                      ),
                      onPressed: _busy
                          ? null
                          // 官方自由输入只发
                          // freeText（V4UserInputDialog:37）——action 会让
                          // broker 走映射路径，freeText 可能被忽略。
                          : () => _go(freeText: _freeText.text),
                      child: const Text(
                        '确认',
                        style: TextStyle(fontSize: AppType.uiCaption),
                      ),
                    ),
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 选项按钮三档语言（V2 审美优化，评审 2.2#8）：allowOnce 黑实心
/// （主操作，与发送键同族）/ allowAlways 淡填充（次）/ deny 红描边（危险）。
/// R5（2026-10-17 refs 实证）：审批"具体在批准什么"来自 payload.detail
/// （= 工具 input 原样，官方 PermissionDialog 经 getPermissionRequestPreview
/// 解析 command/filePath/fileChanges）。summary 只是策略 reason，且官方
/// 明确过滤两句通用英文文案——此前我们只显示 summary，用户看不到内容。
String? _permissionDetailLine(Map payload) {
  Object? detail = payload['detail'];
  if (detail is! Map) return null;
  // raw 包装（官方 readRawToolCallInput：detail.input/rawInput）
  if (detail['input'] is Map && detail['command'] == null) {
    detail = detail['input'] as Map;
  }
  for (final k in ['command', 'cmd', 'script', 'shellCommand']) {
    final v = detail[k];
    if (v is String && v.trim().isNotEmpty) {
      final args = detail['args'];
      final full = (args is List && args.isNotEmpty)
          ? '$v ${args.join(' ')}'
          : v;
      return '命令：$full';
    }
  }
  for (final k in ['file_path', 'filePath', 'path', 'target', 'notebook']) {
    final v = detail[k];
    if (v is String && v.trim().isNotEmpty) return '文件：$v';
  }
  final files = detail['files'];
  if (files is List && files.isNotEmpty) {
    final names = [
      for (final f in files.take(3))
        f is Map ? '${f['path'] ?? f['file_path'] ?? f}' : '$f',
    ];
    return '文件（${files.length}）：${names.join('、')}'
        '${files.length > 3 ? ' 等' : ''}';
  }
  final changes = detail['changes'];
  if (changes is Map && changes.isNotEmpty) {
    return '变更 ${changes.length} 个文件';
  }
  final content = detail['content'] ?? detail['pattern'];
  if (content is String && content.trim().isNotEmpty && detail['file_path'] != null) {
    return null; // 有文件路径时内容体量留给展开态
  }
  return null;
}

/// 优化批 #10：审批富预览分流（官方 PermissionDialog
/// buildPermissionToolCall 把权限请求还原成 TaskChatToolCall 交给聊天
/// 区同款 tool 渲染器——命令出命令块、编辑出 diff；手机侧从同一份
/// payload.detail 合成）。返回 {'kind': 'command', 'text': 全命令} 或
/// {'kind': 'diff', 'display': InlineDiffPreview 消费形状}；null=无富
/// 预览（读取/通用类维持 R5 纯文本明细行）。
Map<String, dynamic>? _permissionRichPreview(Map payload) {
  final toolName = '${payload['toolName'] ?? ''}'.toLowerCase();
  Object? detail = payload['detail'];
  if (detail is! Map) return null;
  // raw 包装（官方 readRawToolCallInput：detail.input/rawInput）。
  if (detail['input'] is Map && detail['command'] == null) {
    detail = detail['input'] as Map;
  }
  // 上游显式 diff（file_diff display 形状）优先直传。
  final explicitDiff = detail['diff'] ?? payload['diff'];
  if (explicitDiff is Map && explicitDiff['structuredPatch'] is List) {
    return {'kind': 'diff', 'display': explicitDiff};
  }
  final isCommandTool =
      toolName.contains('execute') || toolName.contains('bash');
  if (isCommandTool) {
    for (final k in ['command', 'cmd', 'script', 'shellCommand']) {
      final v = detail[k];
      if (v is String && v.trim().isNotEmpty) {
        final args = detail['args'];
        return {
          'kind': 'command',
          'text': args is List && args.isNotEmpty
              ? '$v ${args.join(' ')}'
              : v,
        };
      }
    }
    return null;
  }
  // 编辑/写入类：从 old/new（或 content）合成 structuredPatch——行首
  // +/- marker 语义对齐 highlightDiffLines（协议 marker 非代码内容）。
  final isEdit = toolName.contains('edit') || toolName.contains('apply');
  final isWrite = toolName.contains('write') || toolName.contains('create');
  if (!isEdit && !isWrite) return null;
  final oldS = isEdit ? _readStringField(detail, _editOldKeys) : null;
  final newS = isEdit ? _readStringField(detail, _editNewKeys) : null;
  final content = isWrite ? _readStringField(detail, const ['content']) : null;
  if (isEdit && oldS == null && newS == null) return null;
  if (isWrite && content == null) return null;
  final lines = <String>[
    // 空串也是合法编辑（纯删除/纯新增），split 尾空行照排与 jsdiff
    // structuredPatch 行为一致。
    if (oldS != null) for (final l in oldS.split('\n')) '-$l',
    if (newS != null) for (final l in newS.split('\n')) '+$l',
    if (content != null) for (final l in content.split('\n')) '+$l',
  ];
  if (lines.isEmpty) return null;
  return {
    'kind': 'diff',
    'display': {
      'kind': 'file_diff',
      'filePath': _readStringField(
        detail,
        const ['file_path', 'filePath', 'path', 'target'],
      ),
      'additions': lines.where((l) => l.startsWith('+')).length,
      'deletions': lines.where((l) => l.startsWith('-')).length,
      'structuredPatch': [
        {'lines': lines},
      ],
    },
  };
}

String? _readStringField(Map m, List<String> keys) {
  for (final k in keys) {
    final v = m[k];
    if (v is String) return v;
  }
  return null;
}

/// 键位矩阵对齐官方 fileSummaryHeuristics.ts（_ToolCallTile
/// _inputDiffCounts 同款，第三方工具用 before/after 等变体）。
const _editOldKeys = [
  'old_string',
  'oldString',
  'oldText',
  'before',
  'old_content',
  'oldContent',
];
const _editNewKeys = [
  'new_string',
  'newString',
  'newText',
  'after',
  'new_content',
  'newContent',
];

/// 审批富预览·命令块（优化批 #10）：等宽代码块渲染命令全文（容器
/// 语言与 InlineDiffPreview 同款；官方 execute 命令块对位）。命令是
/// 协议载荷保持原文；卡片本体在限高滚动容器内，长命令滚动可达。
class _PermissionCommandBlock extends StatelessWidget {
  final String command;

  const _PermissionCommandBlock({required this.command});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: context.colors.surface,
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Text(
        command,
        translate: false,
        style: TextStyle(
          fontSize: AppType.uiXs,
          fontFamily: 'monospace',
          height: 1.4,
          color: context.colors.foreground,
        ),
      ),
    );
  }
}

/// 官方 NON_USER_FACING_PERMISSION_REASONS：两句策略级通用文案不该示人。
const _genericReasons = {
  'High risk tools require explicit approval',
  'Tool has side effects and requires approval',
};

/// R7（2026-10-17 真机反馈）：审批选项文案由服务端下发（英文），
/// 桌面端整体为中文观感——已知文案映射为中文，未知原样透传。
const _optionLabelZh = <String, String>{
  'Allow': '允许',
  'Always allow': '总是允许',
  'Allow once': '允许一次',
  'Deny': '拒绝',
  'Reject': '拒绝',
  'Decline': '拒绝',
  'Accept': '接受',
  'Skip': '跳过',
  'Cancel': '取消',
  'Proceed': '继续',
  'Continue': '继续',
  'Yes': '是',
  'No': '否',
  'OK': '确定',
  'Edit': '编辑',
  'Answer': '回答',
  // 18077 验收#6（Bug B）：ExitPlanMode 计划批准选项此前不在词表
  // （R7 机制原样透传英文，真机实锤「批准选项是英文的」）。
  'Approve': '批准',
  'Approve plan': '批准计划',
  'Keep planning': '继续规划',
  'Reject plan': '拒绝计划',
  // 早期反馈②a：官方 GLOBAL_PERMISSION_OPTION_NAME_LABELS 全集
  // （PermissionDialog.tsx:179-200 + zh-CN.ts:5999-6005）。
  'always allow in this project': '始终允许本项目',
  'always allow in this session': '允许本会话',
  'always allow computer use in this project': '始终允许本项目电脑使用',
  'full access': '完全访问',
};


/// autoResolution 倒计时（波次 3c）：deadlineAt 可见时显示剩余秒数，
/// 提示未处理将自动结束（snooze 由首次有效操作天然触发，服务端语义）。
class _AutoResolutionCountdown extends StatefulWidget {
  final Map<String, dynamic> interaction;
  final String? sessionId;
  const _AutoResolutionCountdown({
    required this.interaction,
    this.sessionId,
  });

  @override
  State<_AutoResolutionCountdown> createState() =>
      _AutoResolutionCountdownState();
}

class _AutoResolutionCountdownState extends State<_AutoResolutionCountdown> {
  Timer? _ticker;

  /// A2：每个交互只发一次幂等 snooze（跨重建防重）。
  static final Set<String> _snoozed = {};

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  void _sendSnoozeOnce() {
    // 官方语义：交互可见即发 snooze（dialog/taskBadge 共用同一条幂等
    // 命令）；此前不发=倒计时照跑、未处理的提问被提前自动结束。
    final sessionId = widget.sessionId;
    final interactionId = '${widget.interaction['interactionId'] ?? ''}';
    final auto = widget.interaction['autoResolution'];
    // 官方 V4InteractionDialogs 的 useEffect 以
    // interactionId 为 deps——pending 挂载即发（hiddenGrace 静默期同样
    // 带 deadlineAt 倒计时）。此前限定 visibleCountdown=静默期看题仍会
    // 被自动结束（审查 D1a 实锤，官方源码核验）。
    if (sessionId == null || interactionId.isEmpty || auto is! Map) {
      return;
    }
    final key = '$sessionId:$interactionId';
    if (!_snoozed.add(key)) return;
    AppStateScope.of(context)
        .snoozeInteractionAutoResolution(sessionId, interactionId)
        .catchError((Object e) {
          // 失败不重试不打扰：服务端 snoozed 状态或倒计时 UI 仍可呈现。
          _snoozed.remove(key);
        });
  }

  @override
  Widget build(BuildContext context) {
    final auto = widget.interaction['autoResolution'];
    if (auto is! Map) return const SizedBox.shrink();
    final deadline = (auto['deadlineAt'] as num?)?.toInt();
    if (deadline == null) return const SizedBox.shrink();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _sendSnoozeOnce();
    });
    _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    final left = (deadline - DateTime.now().millisecondsSinceEpoch) ~/ 1000;
    if (left <= 0) return const SizedBox.shrink();
    // R5b：倒计时随标题行常驻（原在正文下方易被忽略）——低剩余量
    // 转警示色胶囊，秒数低于 60 真机必须一眼可见。
    final urgent = left <= 60;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: (urgent ? context.colors.destructive : context.colors.foregroundSubtlest)
            .withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            urgent ? Icons.timer : Icons.timer_outlined,
            size: 12,
            color: urgent
                ? context.colors.destructive
                : context.colors.foregroundSubtle,
          ),
          const SizedBox(width: 4),
          Text(
            '$left 秒后自动结束',
            style: TextStyle(
              fontSize: AppType.uiXs,
              color: urgent
                  ? context.colors.destructive
                  : context.colors.foregroundSubtle,
            ),
          ),
        ],
      ),
    );
  }
}
