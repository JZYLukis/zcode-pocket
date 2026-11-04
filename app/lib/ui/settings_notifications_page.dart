import 'package:flutter/material.dart' hide Text;
import '../core/localized_text.dart';

import '../core/theme.dart';
import '../state/app_state_scope.dart';
import 'notify_guide_page.dart';
import 'notify_ledger_page.dart';

/// 通知设置子页（ADR 0028，2026-10-20）：审批提醒总开关 + 等审批/任务
/// 完成/目标进展三个通道开关 + 后台保障设置/通知台账两个入口——六项
/// 原样自 settings_page 一级页迁入（文案/存储 key/控件行为不变，阶段 3
/// 第二段的"零漏发"链路不动）。子页骨架同 notify_ledger_page。
class SettingsNotificationsPage extends StatelessWidget {
  const SettingsNotificationsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppStateScope.of(context);
    return Scaffold(
      backgroundColor: context.colors.background,
      appBar: AppBar(
        title: const Text('通知', style: TextStyle(fontSize: AppType.uiLg)),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: context.colors.border),
        ),
      ),
      body: ListenableBuilder(
        listenable: app.uiPrefs,
        builder: (context, _) => ListView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          children: [
            SwitchListTile(
              value: app.uiPrefs.alertsEnabled,
              onChanged: (v) => app.setAlertsEnabled(v),
              title: const Text(
                '审批提醒',
                style: TextStyle(fontSize: AppType.uiBase),
              ),
              subtitle: const Text(
                '开启后后台保持连接，任务完成/失败/等审批实时通知'
                '（首次开启建议先过一遍下方「后台保障设置」）；'
                '关闭时退到后台约一分半钟自动断开省电，回前台数秒恢复',
                style: TextStyle(fontSize: AppType.uiCaption),
              ),
            ),
            SwitchListTile(
              value: !app.uiPrefs.muteApprovals,
              onChanged: (v) => app.uiPrefs.setChannelMute('approvals', !v),
              title: const Text(
                '等审批通知',
                style: TextStyle(fontSize: AppType.uiBase),
              ),
              subtitle: const Text(
                '会话等待你审批或输入时提醒',
                style: TextStyle(fontSize: AppType.uiCaption),
              ),
            ),
            SwitchListTile(
              value: !app.uiPrefs.muteTasks,
              onChanged: (v) => app.uiPrefs.setChannelMute('tasks', !v),
              title: const Text(
                '任务完成通知',
                style: TextStyle(fontSize: AppType.uiBase),
              ),
              subtitle: const Text(
                '任务完成/失败时提醒（含离线期间的完成汇总）',
                style: TextStyle(fontSize: AppType.uiCaption),
              ),
            ),
            SwitchListTile(
              value: !app.uiPrefs.muteGoals,
              onChanged: (v) => app.uiPrefs.setChannelMute('goals', !v),
              title: const Text(
                '目标进展通知',
                style: TextStyle(fontSize: AppType.uiBase),
              ),
              subtitle: const Text(
                '目标模式达成/未达成结论时提醒',
                style: TextStyle(fontSize: AppType.uiCaption),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.tune_outlined, size: 20),
              title: const Text(
                '后台保障设置',
                style: TextStyle(fontSize: AppType.uiBase),
              ),
              subtitle: const Text(
                '部分手机的省电白名单（开"审批提醒"前配一次）',
                style: TextStyle(fontSize: AppType.uiCaption),
              ),
              trailing: const Icon(Icons.chevron_right, size: 18),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const NotifyGuidePage()),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.receipt_long_outlined, size: 20),
              title: const Text(
                '通知台账',
                style: TextStyle(fontSize: AppType.uiBase),
              ),
              subtitle: const Text(
                '逐条核对"零漏发"（事件/处置结果/点开记录）',
                style: TextStyle(fontSize: AppType.uiCaption),
              ),
              trailing: const Icon(Icons.chevron_right, size: 18),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const NotifyLedgerPage()),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
