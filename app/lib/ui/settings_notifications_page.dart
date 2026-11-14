import 'package:flutter/material.dart' hide Text;
import '../core/localized_text.dart';

import '../core/theme.dart';
import '../platform/capabilities.dart';
import '../state/app_state_scope.dart';
import 'notify_guide_page.dart';
import 'notify_ledger_page.dart';

/// 通知设置子页（2026-10-20）：审批提醒总开关 + 等审批/任务
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
        // alertsError 挂在 AppState（fullsweep-1108：通知权限被拒时
        // 开关回弹+此提示），与 uiPrefs 合并监听。
        listenable: Listenable.merge([app, app.uiPrefs]),
        builder: (context, _) => ListView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          children: [
            if (app.alertsError != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Row(
                  children: [
                    Icon(Icons.notifications_off_outlined,
                        size: 16, color: context.colors.warning),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        app.alertsError!,
                        style: TextStyle(
                            fontSize: AppType.uiCaption,
                            color: context.colors.warning),
                      ),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      onPressed: app.clearAlertsError,
                      icon: Icon(Icons.close,
                          size: 16, color: context.colors.foregroundSubtle),
                    ),
                  ],
                ),
              ),
            SwitchListTile(
              value: app.uiPrefs.alertsEnabled,
              onChanged: (v) => app.setAlertsEnabled(v),
              title: const Text(
                '审批提醒',
                style: TextStyle(fontSize: AppType.uiBase),
              ),
              // 文案分档（ios-adaptation-1）：Android=前台服务保活语义；
              // iOS 无保活（supportsBackgroundKeepAlive=false）按「前台
              // 实时+回前台对账」档呈现，不承诺后台实时通知。
              subtitle: Text(
                ZpCapabilities.supportsBackgroundKeepAlive
                    ? '开启后后台保持连接，任务完成/失败/等审批实时通知'
                        '（首次开启建议先过一遍下方「后台保障设置」）；'
                        '关闭时退到后台约一分半钟自动断开省电，回前台数秒恢复'
                    : '开启后使用期间实时通知任务完成/失败/等待审批；'
                        'iOS 后台不保持连接，回到 App 时自动补齐错过的事件并通知',
                style: const TextStyle(fontSize: AppType.uiCaption),
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
            // OEM 省电白名单引导（notify-guide-oem-1）：iOS 无此概念
            // （结构性，supportsOemPowerGuide）入口隐藏（ios-adaptation-1）。
            if (ZpCapabilities.supportsOemPowerGuide)
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
