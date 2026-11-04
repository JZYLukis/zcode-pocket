import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/ui/settings_page.dart';
import 'package:zcode_pocket/ui/settings_voice_page.dart';

/// 语音整理多提供商（2026-10-19）：设置页 UI 联动 widget 测试——
/// 提供商切换、key 对话框标题/提示随提供商变化。
/// 2026-10-20 设置页二级化（ADR 0028）：用例先从一级页点"语音输入"
/// 入口进子页再断言；新增一级"通知"入口可达 + 审批提醒开关走原
/// setter 切换的用例。
/// 存储处理与既有用例同款：测试环境 secure storage 不可用，UiPrefs
/// setter 自吞写失败（ui_prefs.dart 各 try/catch），无需 mock。
void main() {
  Future<void> pumpSettings(WidgetTester tester, AppState app) async {
    await tester.pumpWidget(
      AppStateScope(app: app, child: const MaterialApp(home: SettingsPage())),
    );
    // 一级页点"语音输入"入口进语音子页（ADR 0028）。
    await tester.tap(find.text('语音输入'));
    await tester.pumpAndSettle();
    // 语音区在列表深处——滚动到目标（revealSetting 同款手法）。
    await tester.scrollUntilVisible(
      find.text('整理服务提供商'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
  }

  testWidgets('默认智谱；切换 DeepSeek 后标签与 key 提示联动', (tester) async {
    final app = AppState()..loaded = true;
    await pumpSettings(tester, app);

    // 进的是语音子页
    expect(find.byType(SettingsVoicePage), findsOneWidget);

    // 默认 = 智谱（老配置兼容）
    expect(find.textContaining('智谱（免费档模型）'), findsOneWidget);
    expect(find.textContaining('智谱 API key（整理用）'), findsOneWidget);

    // 打开提供商选择 → 三个选项
    await tester.tap(find.text('整理服务提供商'));
    await tester.pumpAndSettle();
    expect(find.byType(RadioListTile<String>), findsNWidgets(3));
    expect(find.textContaining('deepseek-chat'), findsOneWidget);
    expect(find.textContaining('kimi-latest'), findsOneWidget);

    // 选 DeepSeek
    await tester.tap(find.byKey(const ValueKey('voice-provider-deepseek')));
    await tester.pumpAndSettle();
    expect(app.uiPrefs.voiceApiProvider, 'deepseek');
    expect(find.textContaining('DeepSeek（按量计费（极便宜））'), findsOneWidget);

    // key 对话框标题/提示随提供商变化
    await tester.tap(find.textContaining('API key（整理用）'));
    await tester.pumpAndSettle();
    expect(find.text('DeepSeek API key'), findsOneWidget);
    expect(find.textContaining('platform.deepseek.com 的 API key'),
        findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
  });

  testWidgets('切回智谱与切 Kimi 的状态写对', (tester) async {
    final app = AppState()..loaded = true;
    await pumpSettings(tester, app);

    await tester.tap(find.text('整理服务提供商'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('voice-provider-kimi')));
    await tester.pumpAndSettle();
    expect(app.uiPrefs.voiceApiProvider, 'kimi');

    await tester.tap(find.text('整理服务提供商'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('voice-provider-zhipu')));
    await tester.pumpAndSettle();
    expect(app.uiPrefs.voiceApiProvider, 'zhipu');
  });

  testWidgets('一级"通知"入口可进通知子页；审批提醒开关可切换', (tester) async {
    final app = AppState()..loaded = true;
    // 审批提醒走 AppState.setAlertsEnabled：开启时会经 MethodChannel
    // 'companion/notify' 启动前台服务——测试环境挂 mock 通道让
    // startForeground 成功（否则启动失败会把开关回弹成关）。
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('companion/notify'),
      (call) async => null,
    );
    await tester.pumpWidget(
      AppStateScope(app: app, child: const MaterialApp(home: SettingsPage())),
    );
    // 一级页点"通知"入口 → 通知子页
    await tester.tap(find.text('通知'));
    await tester.pumpAndSettle();
    expect(find.text('审批提醒'), findsOneWidget);
    expect(find.text('等审批通知'), findsOneWidget);
    expect(find.text('任务完成通知'), findsOneWidget);
    expect(find.text('目标进展通知'), findsOneWidget);

    // 审批提醒默认关；点击开关走页面原 setter（app.setAlertsEnabled）
    expect(app.uiPrefs.alertsEnabled, isFalse);
    await tester.tap(find.text('审批提醒'));
    await tester.pumpAndSettle();
    expect(app.uiPrefs.alertsEnabled, isTrue);
  });
}
