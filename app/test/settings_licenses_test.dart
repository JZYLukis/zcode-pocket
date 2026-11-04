// 开源许可页回归（2026-10-28 开源准备批；2026-11-04 关于页聚合同步）：
// 设置-关于组 → 关于 ZCode Pocket → 开源依赖许可入口 → Flutter
// LicensePage（第三方依赖许可文本随安装包分发的合规入口）；英文界面下
// applicationLegalese 走翻译（无中文残留）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/l10n.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/ui/settings_page.dart';

Future<void> _openLicenses(WidgetTester tester, AppState app) async {
  await tester.pumpWidget(
    AppStateScope(app: app, child: const MaterialApp(home: SettingsPage())),
  );
  await tester.pump();
  await tester.scrollUntilVisible(
    find.byKey(const ValueKey('settings-about')),
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pump();
  await tester.tap(find.byKey(const ValueKey('settings-about')));
  await tester.pumpAndSettle();
  await tester.scrollUntilVisible(
    find.byKey(const ValueKey('about-dependency-licenses')),
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pump();
  await tester.tap(find.byKey(const ValueKey('about-dependency-licenses')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('设置关于组有开源许可入口，点击打开 LicensePage', (tester) async {
    final app = AppState()..loaded = true;
    await _openLicenses(tester, app);
    expect(find.byType(LicensePage), findsOneWidget);
    // 非官方声明在许可页首屏。
    expect(find.textContaining('非官方第三方客户端'), findsOneWidget);
  });

  testWidgets('英文界面：声明文案走翻译（无中文残留）', (tester) async {
    final app = AppState()..loaded = true;
    L10n.setTestLocale('en-US');
    addTearDown(() => L10n.setTestLocale('zh-CN'));
    await _openLicenses(tester, app);
    expect(find.byType(LicensePage), findsOneWidget);
    expect(find.textContaining('Unofficial third-party client'), findsOneWidget);
    expect(find.textContaining('非官方'), findsNothing);
  });
}
