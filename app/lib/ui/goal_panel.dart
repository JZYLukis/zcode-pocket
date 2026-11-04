import 'package:flutter/material.dart' hide Text;
import '../core/localized_text.dart';

import '../core/theme.dart';
import '../state/app_state_scope.dart';
import '../transport/conversation.dart';

/// Goal 面板（2.4，设计稿 §3.4）：会话页顶部目标卡。
/// 数据源 snapshot.goal（goalStateSchema：objective/status/iteration/
/// verifications/timeUsedSeconds）；操作 sendGoalCommand/pauseGoal/resumeGoal。
class GoalPanel extends StatefulWidget {
  final ConversationState state;
  final String? sessionId;

  const GoalPanel({super.key, required this.state, required this.sessionId});

  @override
  State<GoalPanel> createState() => _GoalPanelState();
}

class _GoalPanelState extends State<GoalPanel> {
  /// 默认折叠为一行（盲审 #1：chrome 区堆叠挤压内容区）；
  /// 点击展开详情与操作。
  bool _expanded = false;

  String get _statusLabel => switch (goal?['status']) {
    'active' => '运行中',
    'paused' => '已暂停',
    'verifying' => '验证中',
    'verified' => '已达成',
    'notSatisfied' => '未满足',
    'failed' => '失败',
    _ => '',
  };

  Map<String, dynamic>? get goal => widget.state.goal;

  IconData get _statusIcon => switch (goal?['status']) {
    'active' => Icons.play_arrow,
    'paused' => Icons.pause,
    'verifying' => Icons.fact_check_outlined,
    'verified' => Icons.verified,
    'failed' => Icons.error_outline,
    _ => Icons.flag_outlined,
  };

  Color get _statusColor => switch (goal?['status']) {
    'active' => context.colors.running,
    'paused' => context.colors.warning,
    'verifying' => context.colors.interactionAskForeground,
    'verified' => context.colors.success,
    'notSatisfied' || 'failed' => context.colors.destructive,
    _ => context.colors.idleTask,
  };

  Future<void> _act(
    BuildContext context,
    Future<dynamic> Function() run,
  ) async {
    try {
      await run();
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('操作失败：$e'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
  }

  Future<void> _advance(BuildContext context) {
    final id = widget.sessionId;
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => _AdvanceDialog(
        onSubmit: (text) => _act(
          context,
          () => AppStateScope.of(context).sendGoalCommand(id!, text),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final goal = this.goal;
    final id = widget.sessionId;
    if (goal == null || id == null) return const SizedBox.shrink();

    final objective = '${goal['objective'] ?? ''}'.trim();
    if (objective.isEmpty) return const SizedBox.shrink();
    final iteration = (goal['iteration'] as num?)?.toInt() ?? 0;
    final timeUsed = (goal['timeUsedSeconds'] as num?)?.toInt() ?? 0;
    final verifications =
        (goal['verifications'] as List?)?.whereType<Map>().toList() ?? const [];
    final passed = verifications.where((v) => v['outcome'] == 'pass').length;
    final status = '${goal['status']}';

    if (!_expanded) {
      // 折叠态：单行（状态点 + 目标摘要 + 轮次），点击展开
      return Container(
        margin: const EdgeInsets.fromLTRB(8, 2, 8, 0),
        child: InkWell(
          key: const ValueKey('goal-panel-collapsed'),
          borderRadius: BorderRadius.circular(AppRadius.sm),
          onTap: () => setState(() => _expanded = true),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: context.colors.card,
              borderRadius: BorderRadius.circular(AppRadius.sm),
              border: Border.all(color: _statusColor.withValues(alpha: AppAlpha.mid)),
            ),
            child: Row(
              children: [
                const Icon(Icons.flag_outlined, size: 13), // 批次4：emoji→Icon（无障碍/跨端渲染一致）
                const SizedBox(width: 6),
                Icon(_statusIcon, size: 13, color: _statusColor),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    objective,
                    translate: false,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppType.uiCaption,
                      color: context.colors.foregroundSubtle,
                    ),
                  ),
                ),
                Text(
                  tr('第$iteration轮'),
                  style: TextStyle(
                    fontSize: AppType.uiXs,
                    color: context.colors.foregroundSubtlest,
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  Icons.expand_less,
                  size: 14,
                  color: context.colors.foregroundSubtlest,
                ),
              ],
            ),
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
        border: Border.all(color: _statusColor.withValues(alpha: AppAlpha.mid)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.flag_outlined, size: 16),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '${tr('目标')} · ${tr('第 $iteration 轮')} · ${tr(_statusLabel)}',
                  style: TextStyle(
                    fontSize: AppType.uiCaption,
                    fontWeight: FontWeight.w600,
                    color: _statusColor,
                  ),
                ),
              ),
              InkWell(
                key: const ValueKey('goal-panel-collapse'),
                onTap: () => setState(() => _expanded = false),
                child: Icon(
                  Icons.expand_more,
                  size: 16,
                  color: context.colors.foregroundSubtlest,
                ),
              ),
              const SizedBox(width: 4),
              Icon(_statusIcon, size: 16, color: _statusColor),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            objective,
            translate: false,
            style: const TextStyle(
              fontSize: AppType.uiBase,
              height: 1.4,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(
                Icons.timer_outlined,
                size: 12,
                color: context.colors.foregroundSubtlest,
              ),
              const SizedBox(width: 4),
              Text(
                _formatDuration(timeUsed),
                style: TextStyle(
                  fontSize: AppType.uiXs,
                  color: context.colors.foregroundSubtlest,
                ),
              ),
              if (verifications.isNotEmpty) ...[
                const SizedBox(width: 12),
                Text(
                  '验证 $passed/${verifications.length}',
                  style: TextStyle(
                    fontSize: AppType.uiXs,
                    color: context.colors.foregroundSubtlest,
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              if (status == 'active')
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 4,
                    ),
                    minimumSize: Size.zero,
                  ),
                  onPressed: () => _act(
                    context,
                    () => AppStateScope.of(context).pauseGoal(id),
                  ),
                  icon: const Icon(Icons.pause, size: 14),
                  label: const Text(
                    '暂停',
                    style: TextStyle(fontSize: AppType.uiCaption),
                  ),
                ),
              if (status == 'paused')
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 4,
                    ),
                    minimumSize: Size.zero,
                  ),
                  onPressed: () => _act(
                    context,
                    () => AppStateScope.of(context).resumeGoal(id),
                  ),
                  icon: const Icon(Icons.play_arrow, size: 14),
                  label: const Text(
                    '恢复',
                    style: TextStyle(fontSize: AppType.uiCaption),
                  ),
                ),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                  minimumSize: Size.zero,
                ),
                onPressed: () => _advance(context),
                icon: const Icon(Icons.arrow_forward, size: 14),
                label: const Text(
                  '推进',
                  style: TextStyle(fontSize: AppType.uiCaption),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

String _formatDuration(int seconds) {
  if (seconds < 60) return '$seconds 秒';
  final m = seconds ~/ 60;
  if (m < 60) return '$m 分钟';
  final h = m ~/ 60;
  return '$h 小时 ${m % 60} 分';
}

/// 推进对话框：输入新的指示 → sendGoalCommand。
class _AdvanceDialog extends StatefulWidget {
  final void Function(String text) onSubmit;

  const _AdvanceDialog({required this.onSubmit});

  @override
  State<_AdvanceDialog> createState() => _AdvanceDialogState();
}

class _AdvanceDialogState extends State<_AdvanceDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('推进目标', style: TextStyle(fontSize: AppType.uiLg)),
      content: TextField(
        controller: _controller,
        maxLines: 3,
        autofocus: true,
        decoration: InputDecoration(
          hintText: tr('补充指示或调整方向…'),
          border: OutlineInputBorder(),
          isDense: true,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: context.colors.brand,
            foregroundColor: context.colors.onBrand,
          ),
          onPressed: () {
            final text = _controller.text.trim();
            if (text.isEmpty) return;
            widget.onSubmit(text);
            Navigator.of(context).pop();
          },
          child: const Text('发送'),
        ),
      ],
    );
  }
}
