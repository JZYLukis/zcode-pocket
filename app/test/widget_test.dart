import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/app.dart';
import 'package:zcode_pocket/core/breakpoints.dart';
import 'package:zcode_pocket/ui/pairing_page.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';

void main() {
  testWidgets('无档案时进入配对页', (tester) async {
    // 测试环境 secure storage 不可用（read 挂起），注入已就绪的空档案状态
    final app = AppState()..loaded = true;
    await tester.pumpWidget(ZcodeCompanionApp(app: app));
    await tester.pump();
    expect(find.byType(PairingPage), findsOneWidget);
    expect(find.text('扫码添加'), findsOneWidget);
  });

  testWidgets('配对页链接校验：非法 URL 报错且不崩', (tester) async {
    final app = AppState();
    await tester.pumpWidget(
      AppStateScope(
        app: app,
        child: const MaterialApp(home: PairingPage()),
      ),
    );
    await tester.enterText(
      find.byType(TextField).first,
      'https://example.com/not-a-remote-url',
    );
    await tester.tap(find.text('连接'));
    await tester.pump();
    expect(find.textContaining('链接无效'), findsOneWidget);
    app.dispose();
  });

  testWidgets('冷启根组件冒烟：无注入 AppState 也可构建不抛异常', (tester) async {
    // AppState 默认 offline；HomeShell 在无档案时显示配对页——
    // 这里仅验证根组件可构建不抛异常（开源审查 R1 P3-3：原名"任务中心
    // 状态横幅"名不副实，横幅行为不在此断言，避免误导后来者以为有回归
    // 保护）。
    await tester.pumpWidget(const ZcodeCompanionApp());
    expect(find.byType(AppStateScope), findsOneWidget);
  });

  test('断点：折叠屏两形态落位', () {
    expect(formFactorOf(const Size(375, 806)), AppFormFactor.compact); // 外屏
    expect(formFactorOf(const Size(673, 841)), AppFormFactor.medium); // 内屏
    expect(formFactorOf(const Size(1000, 800)), AppFormFactor.expanded);
  });
}
