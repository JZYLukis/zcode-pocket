import 'package:flutter/material.dart' hide Text;

import '../core/localized_text.dart';
import '../core/theme.dart';
import '../state/app_state_scope.dart';
import '../transport/channel_client.dart';

/// 对话设置子页（2026-10-20）：显示工具调用开关 + 运行中收到
/// 新消息选择器——两项原样自 settings_page 一级页迁入（文案/存储 key/
/// 控件行为不变）。子页骨架同 notify_ledger_page（AppBar 背景色 + 1px
/// 底分隔线，返回按钮默认）。
class SettingsConversationPage extends StatelessWidget {
  const SettingsConversationPage({super.key});

  /// ：快速连点两次产生两条并发 sync RPC，通道层无序
  /// 保证时后发的最新值可能被先发的旧值覆盖（本地偏好与桌面端漂移到
  /// 下次拨动）。在飞合并：串行化，前一次完成后只发最新捕获值。
  static Future<void> _syncInFlight = Future<void>.value();

  @override
  Widget build(BuildContext context) {
    final app = AppStateScope.of(context);
    return Scaffold(
      backgroundColor: context.colors.background,
      appBar: AppBar(
        title: const Text('对话', style: TextStyle(fontSize: AppType.uiLg)),
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
            // 工具调用显示开关（需求池 #1——用户要求工具活动显示与否可
            // 配置，参照桌面端设置里的工具组折叠开关）。
            SwitchListTile(
              value: app.uiPrefs.showToolCalls,
              onChanged: (v) => app.uiPrefs.setShowToolCalls(v),
              title: const Text(
                '显示工具调用',
                style: TextStyle(fontSize: AppType.uiBase),
              ),
              subtitle: const Text(
                '关闭后隐藏 edit / bash / read / write 等工具活动，'
                '仅保留思考与回复内容',
                style: TextStyle(fontSize: AppType.uiCaption),
              ),
            ),
            // 代码语法高亮开关（批 2-5，2026-10-23 用户要求可关；
            // 默认开——业界通行无条件开启，此开关定位兜底）。
            SwitchListTile(
              value: app.uiPrefs.codeHighlightEnabled,
              onChanged: (v) => app.uiPrefs.setCodeHighlightEnabled(v),
              title: const Text(
                '代码语法高亮',
                style: TextStyle(fontSize: AppType.uiBase),
              ),
              subtitle: const Text(
                '回复中代码块的关键字/字符串等着色（对齐官方桌面端，'
                '浅深两套自动跟随；关闭后恢复纯文本',
                style: TextStyle(fontSize: AppType.uiCaption),
              ),
            ),
            // 提问自动采纳开关（官方
            // askUserQuestionAutoResolutionEnabled 对位，默认开）——经
            // zcode-agent.syncAppRuntimePreferences 下发 CLI；未连接时
            // 只存偏好，下次连接不自动补发（官方语义=设置页改即推）。
            SwitchListTile(
              value: app.uiPrefs.askAutoResolutionEnabled,
              onChanged: (v) async {
                await app.uiPrefs.setAskAutoResolutionEnabled(v);
                final bridge = app.bridge;
                if (bridge == null) return;
                // 串行化在飞 sync（见 _syncInFlight 注释）。
                final pending = _syncInFlight;
                final task = () async {
                  await pending;
                  try {
                    // /M2/M3 三路同报：payload 只含本端拥有的键。
                    // modelIoFullRetentionEnabled 官方契约为 optional
                    //（官方 3.17.1 源码快照 zcodeAgent.ts:634），官方桌面 UI
                    // 下发的是 setting.json 当前值——本端不拥有该偏好也无从
                    // 读回，硬编码 false 会静默覆写桌面端已开启的「完整保留
                    // 模型 I/O」。注：现行 CLI 对缺省键按 === true 归一为
                    // false（zcodeAgentService.ts:4396），彻底不覆写需官方
                    // 支持部分合并——至少不再主动断言不属于本端的值。
                    await bridge.channels.call(
                      Channels.zcodeAgent,
                      'syncAppRuntimePreferences',
                      [
                        {'askUserQuestionAutoResolutionEnabled': v},
                      ],
                      timeout: const Duration(seconds: 10),
                    );
                  } catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(tr('已保存；下发桌面端失败：') + '$e'),
                          duration: const Duration(seconds: 3),
                        ),
                      );
                    }
                  }
                }();
                _syncInFlight = task;
                await task;
              },
              title: const Text(
                '提问自动采纳',
                style: TextStyle(fontSize: AppType.uiBase),
              ),
              subtitle: const Text(
                '关闭后 AI 提问不再倒计时自动选择（仍可手动作答）',
                style: TextStyle(fontSize: AppType.uiCaption),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.low_priority_outlined, size: 20),
              title: const Text(
                '运行中收到新消息',
                style: TextStyle(fontSize: AppType.uiBase),
              ),
              subtitle: Text(
                app.uiPrefs.followupMode == 'guide'
                    ? '引导：插入到下一轮工具调用后生效'
                    : '队列：排队等当前回合结束后依次发送',
                style: const TextStyle(fontSize: AppType.uiCaption),
              ),
              trailing: const Icon(Icons.chevron_right, size: 18),
              onTap: () async {
                final picked = await showDialog<String>(
                  context: context,
                  builder: (dialogContext) => SimpleDialog(
                    title: const Text('运行中收到新消息'),
                    children: [
                      SimpleDialogOption(
                        onPressed: () => Navigator.pop(dialogContext, 'queue'),
                        child: const Text('队列——排队等回合结束依次发送'),
                      ),
                      SimpleDialogOption(
                        onPressed: () => Navigator.pop(dialogContext, 'guide'),
                        child: const Text('引导——插到下一轮工具调用后运行'),
                      ),
                    ],
                  ),
                );
                if (picked != null) await app.changeFollowupMode(picked);
              },
            ),
          ],
        ),
      ),
    );
  }
}
