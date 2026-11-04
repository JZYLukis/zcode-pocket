import 'package:flutter/material.dart' hide Text;
import '../core/localized_text.dart';
import 'package:flutter/services.dart';

import '../core/theme.dart';
import '../state/app_state_scope.dart';
import '../state/notify_core.dart' show LedgerEntry;

/// 通知台账页（阶段 3 第二段）："零漏发"以台账核对判定（ADR 0018 决策
/// 2/6）——每条差分事件的处置结果（已发/首见抑制/去重/静音/聚合）逐行
/// 落盘，真用期对照通知栏核对。支持一键复制文本（发给 AI 排查用）。
class NotifyLedgerPage extends StatelessWidget {
  const NotifyLedgerPage({super.key});

  static const _kindLabel = {
    'taskCompleted': '任务完成',
    'taskFailed': '任务失败',
    'approvalPending': '等审批',
    'goalSettled': '目标结论',
    'awayAggregated': '离线聚合',
  };

  static const _outcomeLabel = {
    'posted': '已通知',
    'firstSeen': '首见建基线',
    'deduped': '已去重',
    'muted': '通道静音',
    'viewing': '查看中未打扰',
    'aggregated': '并入聚合',
    // ADR 0029 对账补发收敛：超阈值单条只落台账不逐条弹通知。
    'converged': '补发收敛未弹',
    'noChannel': '通知不可用',
  };

  String _formatLine(LedgerEntry e) {
    final time = DateTime.fromMillisecondsSinceEpoch(e.ts);
    String two(int v) => v.toString().padLeft(2, '0');
    final ts =
        '${two(time.month)}-${two(time.day)} ${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
    final kind = _kindLabel[e.kind] ?? e.kind;
    final outcome = _outcomeLabel[e.outcome] ?? e.outcome;
    final click = e.clicked ? '（已点开）' : '';
    return '$ts $kind $outcome$click ${e.title}';
  }

  @override
  Widget build(BuildContext context) {
    final app = AppStateScope.of(context);
    final entries = app.notifyStore?.recentLedger(limit: 200) ?? const [];
    return Scaffold(
      backgroundColor: context.colors.background,
      appBar: AppBar(
        title: const Text('通知台账', style: TextStyle(fontSize: AppType.uiLg)),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: context.colors.border),
        ),
        actions: [
          IconButton(
            tooltip: tr('复制全部'),
            icon: const Icon(Icons.copy_outlined, size: 20),
            onPressed: entries.isEmpty
                ? null
                : () {
                    Clipboard.setData(
                      ClipboardData(text: entries.map(_formatLine).join('\n')),
                    );
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('已复制 200 条内台账文本')),
                    );
                  },
          ),
        ],
      ),
      body: entries.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.notifications_none_outlined,
                    size: 40,
                    color: context.colors.foregroundSubtlest,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '还没有通知事件\n连接电脑并产生任务活动后，这里会逐条记录',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: AppType.uiBase,
                      color: context.colors.foregroundSubtle,
                      height: 1.6,
                    ),
                  ),
                ],
              ),
            )
          : ListView.builder(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: entries.length,
              itemBuilder: (context, i) {
                // 倒序显示（最新在上）。行结构：图标｜标题（恒正常对比度）
                // ｜时间·类型副行｜处置结果彩色标签——视觉审查修订
                // （2026-10-18）：静音/失败行整行淡化导致"最该被看见的
                // 一条反而最看不清"；处置结果用颜色区分可扫读。
                final e = entries[entries.length - 1 - i];
                final (chipColor, chipText) = _outcomeChip(context, e.outcome);
                final time = DateTime.fromMillisecondsSinceEpoch(e.ts);
                String two(int v) => v.toString().padLeft(2, '0');
                final timeText =
                    '${two(time.month)}-${two(time.day)} ${two(time.hour)}:'
                    '${two(time.minute)}:${two(time.second)}';
                // V1 审美优化：失败行左缘 3px 红竖条——最该被看见的行
                // 视觉最强（此前红图标+橙胶囊组合反而弱于绿，评审 2.3#2）。
                final failed =
                    e.kind == 'taskFailed' || e.outcome == 'noChannel';
                return Container(
                  decoration: failed
                      ? BoxDecoration(
                          border: Border(
                            left: BorderSide(
                              color: context.colors.destructive,
                              width: 3,
                            ),
                          ),
                        )
                      : null,
                  child: ListTile(
                    dense: true,
                    leading: Icon(
                      switch (e.kind) {
                        'approvalPending' => Icons.approval_outlined,
                        'taskFailed' => Icons.error_outline,
                        'awayAggregated' => Icons.done_all_outlined,
                        'goalSettled' => Icons.flag_outlined,
                        _ => Icons.task_alt_outlined,
                      },
                      size: 20,
                      color: failed
                          ? context.colors.destructive
                          : e.outcome == 'muted'
                          ? context.colors.warning
                          : context.colors.foregroundSubtle,
                    ),
                    title: Text(
                      e.title.isEmpty ? '（无标题）' : e.title,
                      translate: e.title.isEmpty,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: AppType.uiSm,
                        color: context.colors.foreground,
                      ),
                    ),
                    subtitle: Text(
                      '$timeText · ${_kindLabel[e.kind] ?? e.kind}'
                      '${e.clicked ? ' · 已点开' : ''}',
                      style: TextStyle(
                        fontSize: AppType.uiSm,
                        color: context.colors.foregroundSubtle,
                      ),
                    ),
                    trailing: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: chipColor.withValues(alpha: AppAlpha.light),
                        borderRadius: BorderRadius.circular(AppRadius.pill),
                        border: Border.all(
                          color: chipColor.withValues(alpha: AppAlpha.mid),
                        ),
                      ),
                      child: Text(
                        chipText,
                        style: TextStyle(
                          fontSize: AppType.uiSm,
                          color: chipColor,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }

  (Color, String) _outcomeChip(BuildContext context, String outcome) => switch (outcome) {
    'posted' => (context.colors.success, '已通知'),
    'muted' => (context.colors.warning, '通道静音'),
    'noChannel' => (context.colors.destructive, '通知不可用'),
    'deduped' => (context.colors.foregroundSubtle, '已去重'),
    'viewing' => (context.colors.foregroundSubtle, '查看中未打扰'),
    'firstSeen' => (context.colors.foregroundSubtle, '首见建基线'),
    'aggregated' => (context.colors.foregroundSubtle, '并入聚合'),
    _ => (context.colors.foregroundSubtle, outcome),
  };
}
