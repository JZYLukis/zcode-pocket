import 'dart:async';
import 'package:flutter/material.dart' hide Text;
import 'package:flutter/services.dart';

import '../core/localized_text.dart';
import '../core/theme.dart';
import '../state/app_state_scope.dart';
import 'app_widgets.dart';
import 'about_page.dart';
import 'settings_accounts_page.dart';
import 'settings_security_page.dart';
import 'update_flow.dart';
import 'settings_conversation_page.dart';
import 'settings_notifications_page.dart';
import 'settings_voice_page.dart';
import 'subagents_page.dart';
import 'usage_page.dart';

/// 设置页（ 二级化改造，2026-10-20）：一级页只留分组入口——
/// 偏好组（对话/通知/语音输入三入口进二级页）+ 功能组（子智能体/订阅
/// 用量维持原直达跳转）+ 关于组（版本信息内联底部）。各设置项的显示
/// 文案/存储 key/控件行为原样迁入对应二级页，不新增语义。分组头统一用
/// 共享 AppSectionHeader（原私有 _SectionHeader 已删，收敛重复）。
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppStateScope.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('设置', style: TextStyle(fontSize: AppType.uiLg)),
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
            const AppSectionHeader('外观'),
            ListTile(
              leading: const Icon(Icons.dark_mode_outlined, size: 20),
              title: const Text(
                '主题',
                style: TextStyle(fontSize: AppType.uiBase),
              ),
              subtitle: const Text(
                '跟随系统或固定浅色/深色',
                style: TextStyle(fontSize: AppType.uiCaption),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: _SegmentSelector(
                keyValue: 'theme',
                options: const [
                  ('system', '跟随系统'),
                  ('light', '浅色'),
                  ('dark', '深色'),
                ],
                value: app.uiPrefs.themeMode,
                onChanged: (v) => app.uiPrefs.setThemeMode(v),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.language, size: 20),
              title: const Text(
                '语言',
                style: TextStyle(fontSize: AppType.uiBase),
              ),
              subtitle: const Text(
                '跟随系统或选择简体中文/English',
                style: TextStyle(fontSize: AppType.uiCaption),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: _SegmentSelector(
                keyValue: 'locale',
                options: const [
                  ('system', '跟随系统'),
                  ('zh-CN', '中文'),
                  ('en-US', 'English'),
                ],
                value: app.uiPrefs.localePreference,
                onChanged: (v) => app.uiPrefs.setLocalePreference(v),
              ),
            ),
            const AppSectionHeader('偏好'),
            ListTile(
              leading: const Icon(Icons.forum_outlined, size: 20),
              title: const Text(
                '对话',
                style: TextStyle(fontSize: AppType.uiBase),
              ),
              subtitle: const Text(
                '工具活动的显示与运行中新消息的处理方式',
                style: TextStyle(fontSize: AppType.uiCaption),
              ),
              trailing: const Icon(Icons.chevron_right, size: 18),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const SettingsConversationPage(),
                ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.notifications_outlined, size: 20),
              title: const Text(
                '通知',
                style: TextStyle(fontSize: AppType.uiBase),
              ),
              subtitle: const Text(
                '审批、任务完成等事件的提醒开关与通知台账',
                style: TextStyle(fontSize: AppType.uiCaption),
              ),
              trailing: const Icon(Icons.chevron_right, size: 18),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const SettingsNotificationsPage(),
                ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.mic_outlined, size: 20),
              title: const Text(
                '语音输入',
                style: TextStyle(fontSize: AppType.uiBase),
              ),
              subtitle: const Text(
                '听写内容自动整理成规范指令',
                style: TextStyle(fontSize: AppType.uiCaption),
              ),
              trailing: const Icon(Icons.chevron_right, size: 18),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SettingsVoicePage()),
              ),
            ),
            const AppSectionHeader('功能'),
            // 早前批次 批4（2026-11-04 拍板）：多电脑任务聚合
            // 开关（默认关）——纯读本地缓存快照，不建连接不订阅。
            SwitchListTile(
              key: const ValueKey('settings-show-other-computers'),
              secondary: const Icon(Icons.devices_other_outlined, size: 20),
              title: const Text(
                '首页显示其他电脑任务',
                style: TextStyle(fontSize: AppType.uiBase),
              ),
              subtitle: const Text(
                '来自本地缓存快照（可能过期，会标注缓存时间）；不额外连接电脑',
                style: TextStyle(fontSize: AppType.uiCaption),
              ),
              value: app.uiPrefs.showOtherComputers,
              onChanged: (v) => app.uiPrefs.setShowOtherComputers(v),
            ),
            ListTile(
              leading: const Icon(Icons.manage_accounts_outlined, size: 20),
              title: const Text(
                '账号管理',
                style: TextStyle(fontSize: AppType.uiBase),
              ),
              subtitle: const Text(
                '多账号添加/切换/删除（电脑按账号归属连接）',
                style: TextStyle(fontSize: AppType.uiCaption),
              ),
              trailing: const Icon(Icons.chevron_right, size: 18),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SettingsAccountsPage()),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.smart_toy_outlined, size: 20),
              title: const Text(
                '子智能体',
                style: TextStyle(fontSize: AppType.uiBase),
              ),
              subtitle: const Text(
                '定义/启停/编辑（与桌面端设置同步）',
                style: TextStyle(fontSize: AppType.uiCaption),
              ),
              trailing: const Icon(Icons.chevron_right, size: 18),
              onTap: () => Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const SubagentsPage())),
            ),
            ListTile(
              leading: const Icon(Icons.data_usage_outlined, size: 20),
              title: const Text(
                '订阅用量',
                style: TextStyle(fontSize: AppType.uiBase),
              ),
              subtitle: const Text(
                '额度/配额/订阅详情',
                style: TextStyle(fontSize: AppType.uiCaption),
              ),
              trailing: const Icon(Icons.chevron_right, size: 18),
              onTap: () => Navigator.of(context)
                  .push(MaterialPageRoute(builder: (_) => const UsagePage())),
            ),
            // 应用内更新（早前批次）：入口行（检查更新+开关收在
            // 二级动作——开关单独一行，避免一级页过长）。
            ListTile(
              leading: const Icon(Icons.system_update_outlined, size: 20),
              title: const Text(
                '软件更新',
                style: TextStyle(fontSize: AppType.uiBase),
              ),
              subtitle: const Text(
                '检查新版本并应用内下载安装（需安装权限）',
                style: TextStyle(fontSize: AppType.uiCaption),
              ),
              trailing: const Icon(Icons.chevron_right, size: 18),
              onTap: () => unawaited(checkAndPrompt(context, manual: true)),
            ),
            SwitchListTile(
              key: const ValueKey('settings-update-in-app'),
              secondary: const Icon(Icons.download_outlined, size: 20),
              title: const Text(
                '应用内更新',
                style: TextStyle(fontSize: AppType.uiBase),
              ),
              subtitle: const Text(
                '关闭后仅提示新版本，不下载也不申请安装权限',
                style: TextStyle(fontSize: AppType.uiCaption),
              ),
              value: app.uiPrefs.updateInAppEnabled,
              onChanged: (v) => app.uiPrefs.setUpdateInAppEnabled(v),
            ),
            // 应用锁（早前批次）：安全组（方式三态/自动锁定/防泄露）。
            const AppSectionHeader('安全'),
            ListTile(
              leading: const Icon(Icons.lock_outline, size: 20),
              title: const Text(
                '应用锁',
                style: TextStyle(fontSize: AppType.uiBase),
              ),
              subtitle: const Text(
                '冷启动与后台锁定需验证（系统锁屏 / PIN 码）',
                style: TextStyle(fontSize: AppType.uiCaption),
              ),
              trailing: const Icon(Icons.chevron_right, size: 18),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SettingsSecurityPage()),
              ),
            ),
            const AppSectionHeader('关于'),
            // 关于页（2026-11-04 开源说明聚合批）：声明/隐私/项目许可/
            // 第三方来源/依赖许可集中到二级页，一级页只留一个入口。
            ListTile(
              key: const ValueKey('settings-about'),
              leading: const Icon(Icons.info_outline, size: 20),
              title: const Text(
                '关于 ZCode Pocket',
                style: TextStyle(fontSize: AppType.uiBase),
              ),
              subtitle: const _AppVersionText(),
              trailing: const Icon(Icons.chevron_right, size: 18),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const AboutZcodePocketPage(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

//三档段选器（/ 收敛单源：语言/主题两份逐行
/// 同构实现——触控规格/视觉调整需双改，历史上触控高 46→48 修正两处各
/// 记一遍）。自绘 token 化（官方黑白骨架语言：选中=selected 底+
/// foreground 字，未选=transparent 底+foregroundSubtle 字；48dp 触控高；
/// 胶囊外形）。交互范式参考 zemote 三段式（ 纪律：只参考设计
/// 不移植代码）。
class _SegmentSelector extends StatelessWidget {
  const _SegmentSelector({
    required this.keyValue,
    required this.options,
    required this.value,
    required this.onChanged,
  });

  /// 键前缀（'locale'/'theme'）：容器键 `<keyValue>-selector`、
  /// 分段键 `<keyValue>-<id>`（测试断言依赖既有键名）。
  final String keyValue;

  final List<(String, String)> options;
  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: ValueKey('$keyValue-selector'),
      // 触控高按内容区算：48 目标 + 上下边框 1×2（design_guard 实测 46
      // 被拦后修正——Container 高度含 border，内容区才是命中层）。
      height: 50,
      decoration: BoxDecoration(
        color: context.colors.surface,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: context.colors.borderFaint),
      ),
      child: Row(
        children: [
          for (final (id, label) in options)
            Expanded(
              // 触控目标=整格 48 高（design_guard 实测 46<48 被拦后修正）：
              // GestureDetector 撑满外格，药丸视觉缩进仅是内边距。
              child: GestureDetector(
                key: ValueKey('$keyValue-$id'),
                behavior: HitTestBehavior.opaque,
                onTap: () => onChanged(id),
                child: Container(
                  alignment: Alignment.center,
                  padding: const EdgeInsets.all(3),
                  child: Container(
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: value == id
                          ? context.colors.selected
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                    ),
                    child: Text(
                      label,
                      maxLines: 1,
                      style: TextStyle(
                        fontSize: AppType.uiCaption,
                        color: value == id
                            ? context.colors.foreground
                            : context.colors.foregroundSubtle,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 关于行副标题：本机版本（release 含 HEAD 指纹）+ 桌面端版本。
/// 官方快照 channel 读包管理器，测试环境回落静态文案。
class _AppVersionText extends StatefulWidget {
  const _AppVersionText();

  @override
  State<_AppVersionText> createState() => _AppVersionTextState();
}

class _AppVersionTextState extends State<_AppVersionText> {
  String? _localVersion;

  @override
  void initState() {
    super.initState();
    const MethodChannel('companion/appinfo')
        .invokeMethod<Map>('get')
        .then((res) {
          // 缺键/非字符串时显式判 null（原实现
          // '${res['versionName']}' 会把 null 插值成 "null" 字符串通过
          // 非空校验；当前 native 恒填，纯防御）。
          final raw = res?['versionName'];
          final name = raw is String && raw.trim().isNotEmpty ? raw : null;
          if (mounted && name != null) {
            setState(() => _localVersion = name);
          }
        })
        .catchError((Object _) {});
  }

  @override
  Widget build(BuildContext context) {
    final desktop = AppStateScope.of(context).desktopAppVersion;
    final local = _localVersion;
    return Text(
      local == null
          ? (desktop == null ? '' : tr('桌面端 ') + desktop)
          : tr('本机 ') +
                local +
                (desktop == null ? '' : tr(' · 桌面端 ') + desktop),
      style: const TextStyle(fontSize: AppType.uiCaption),
    );
  }
}
