import 'package:flutter/material.dart' hide Text;
import '../core/localized_text.dart';
import 'package:flutter/services.dart';

import '../core/theme.dart';

/// 后台与通知保障引导页（阶段 3 第二段后台专项，三层兜底）：
/// ①按钮自动跳转系统设置（组件名依次尝试）→ ②跳应用详情页手点 →
/// ③跳不动时图文指引。部分厂商省电机制下代码全对也可能被杀，这三步是
/// "审批提醒"可靠工作的前提（用户 2026-10-18 拍板：开提醒时一次配好）。
class NotifyGuidePage extends StatefulWidget {
  const NotifyGuidePage({super.key});

  @override
  State<NotifyGuidePage> createState() => _NotifyGuidePageState();
}

class _NotifyGuidePageState extends State<NotifyGuidePage> {
  static const _channel = MethodChannel('companion/notify');
  String _startupJumpResult = '';
  bool? _batteryIgnored;

  @override
  void initState() {
    super.initState();
    _refreshBattery();
  }

  Future<void> _refreshBattery() async {
    try {
      final ok = await _channel.invokeMethod<bool>('isIgnoringBatteryOptimizations');
      if (mounted) setState(() => _batteryIgnored = ok ?? false);
    } catch (_) {}
  }

  Future<void> _jumpStartupManage() async {
    try {
      final res = await _channel.invokeMethod<String>('openStartupManage');
      if (!mounted) return;
      setState(() => _startupJumpResult = switch (res) {
        'startup' => '已跳到「启动管理」：找到 ZCode Pocket 改为手动管理，'
            '开启自启动/关联启动/后台活动三个开关',
        'details' => '已跳到应用详情页：请点「启动管理」（或「应用启动管理」）'
            '进入后改为手动管理，开三个开关',
        _ => '跳转失败，请按下方图文步骤手动操作',
      });
    } catch (_) {
      if (mounted) {
        setState(() => _startupJumpResult = '跳转失败，请按下方图文步骤手动操作');
      }
    }
  }

  Future<void> _jumpNotificationSettings() async {
    try {
      await _channel.invokeMethod('openNotificationSettings');
    } catch (_) {}
  }

  Future<void> _requestBattery() async {
    try {
      await _channel.invokeMethod('requestIgnoreBatteryOptimizations');
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await _refreshBattery();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.colors.background,
      appBar: AppBar(
        title: const Text('后台与通知保障', style: TextStyle(fontSize: AppType.uiLg)),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: context.colors.border),
        ),
      ),
      body: ListView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: context.colors.accent,
              borderRadius: BorderRadius.circular(AppRadius.bubble),
              border: Border.all(color: context.colors.border),
            ),
            child: const Text(
              '部分手机的省电机制会在后台清理应用——代码全部正确，通知仍可能'
              '收不到。开启「审批提醒」前，请把下面几步一次配好（全阶段只用配一次）。',
              style: TextStyle(fontSize: AppType.uiBase, height: 1.5),
            ),
          ),
          const SizedBox(height: 16),
          _StepCard(
            index: 1,
            title: '启动管理三开关',
            body: '设置 → 应用 → 应用启动管理 → ZCode Pocket → 改为"手动管理"，'
                '开启 自启动 / 关联启动 / 后台活动 三个开关。',
            actionLabel: '去设置',
            onAction: _jumpStartupManage,
            footnote: _startupJumpResult,
          ),
          _StepCard(
            index: 2,
            title: '通知双开关',
            body: '设置 → 通知 → ZCode Pocket：「允许通知」与「锁屏通知」都打开'
                '（锁屏上要看到提醒，两个都必须开）。',
            actionLabel: '去通知设置',
            onAction: _jumpNotificationSettings,
          ),
          _StepCard(
            index: 3,
            title: '忽略电池优化',
            body: '允许应用不受电池优化限制，后台连接不被系统休眠打断。',
            actionLabel: _batteryIgnored == true ? '已配置 ✓' : '去设置',
            onAction: _batteryIgnored == true ? null : _requestBattery,
            footnote: _batteryIgnored == null ? null : (_batteryIgnored! ? '已忽略电池优化' : null),
          ),
          _StepCard(
            index: 4,
            title: '最近任务锁定（手动）',
            body: '打开最近任务（多任务）视图 → 找到 ZCode Pocket 卡片 → 下拉'
                '（或长按）→ 点锁图标 🔒。锁定后上滑清理不会误清本应用。\n'
                '此步无法自动跳转，请在最近任务界面对照操作。',
          ),
          const SizedBox(height: 24),
          Text(
            '配置完成后回到设置页打开「审批提醒」即可。平时不开提醒时，应用退到'
            '后台约一分半钟会主动断开连接以省电，回到前台数秒内自动恢复。',
            style: TextStyle(
              fontSize: AppType.uiCaption,
              color: context.colors.foregroundSubtle,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

class _StepCard extends StatelessWidget {
  final int index;
  final String title;
  final String body;
  final String? actionLabel;
  final VoidCallback? onAction;
  final String? footnote;

  const _StepCard({
    required this.index,
    required this.title,
    required this.body,
    this.actionLabel,
    this.onAction,
    this.footnote,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: context.colors.surface,
        borderRadius: BorderRadius.circular(AppRadius.bubble),
        border: Border.all(color: context.colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 22,
                height: 22,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: context.colors.accent,
                  shape: BoxShape.circle,
                ),
                child: Text(
                  '$index',
                  style: const TextStyle(
                    fontSize: AppType.uiSm,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                title,
                style: const TextStyle(
                  fontSize: AppType.uiBase,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            body,
            style: const TextStyle(fontSize: AppType.uiBase, height: 1.5),
          ),
          if (footnote != null && footnote!.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              footnote!,
              style: TextStyle(
                fontSize: AppType.uiCaption,
                color: context.colors.foregroundSubtle,
                height: 1.4,
              ),
            ),
          ],
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.tonal(
                onPressed: onAction,
                child: Text(actionLabel!, style: const TextStyle(fontSize: AppType.uiBase)),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
