// 关于页回归（2026-11-04 开源说明聚合批）：声明/隐私/项目许可/
// 第三方来源/依赖许可集中呈现；许可证文本随包分发、应用内可读。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/l10n.dart';
import 'package:zcode_pocket/ui/about_page.dart';

Future<void> _pumpAbout(WidgetTester tester) async {
  await tester.pumpWidget(
    const MaterialApp(home: AboutZcodePocketPage(versionOverride: '1.0.0')),
  );
  await tester.pump();
}

Future<void> _tapRow(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey(key));
  await tester.scrollUntilVisible(
    finder,
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pump();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('关于页展示版本与声明/隐私说明', (tester) async {
    await _pumpAbout(tester);
    expect(find.text('1.0.0'), findsOneWidget);
    expect(find.textContaining('社区驱动的第三方客户端'), findsOneWidget);
    expect(find.textContaining('官方服务条款'), findsOneWidget);
    expect(find.textContaining('无遥测'), findsOneWidget);
    expect(find.text('项目许可证（Apache 2.0）'), findsOneWidget);
    expect(find.text('第三方来源声明'), findsOneWidget);
    // 版权行在页尾（折叠线下），滚到可见再断言署名。
    await tester.scrollUntilVisible(
      find.textContaining('JZYLukis'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.textContaining('JZYLukis'), findsOneWidget, reason: '版权行署名');
  });

  testWidgets('项目许可证正文随包分发（Apache 2.0 全文）', (tester) async {
    await _pumpAbout(tester);
    await _tapRow(tester, 'about-project-license');
    final text = tester.widget<SelectableText>(find.byType(SelectableText));
    expect(text.data, contains('Apache License'));
    expect(text.data, contains('Version 2.0'));
  });

  testWidgets('第三方来源声明随包分发（MIT 全文与图标声明）', (tester) async {
    await _pumpAbout(tester);
    await _tapRow(tester, 'about-third-party-notices');
    expect(find.textContaining('MIT License', findRichText: true), findsWidgets);
    expect(find.textContaining('Simple Icons', findRichText: true), findsWidgets);
    // 双语声明（2026-11-04）：英文概要段在文件首部，应用内同步可见。
    expect(find.textContaining('English summary', findRichText: true),
        findsWidgets);
  });

  testWidgets('英文界面：关于页文案与许可入口走翻译', (tester) async {
    L10n.setTestLocale('en-US');
    addTearDown(() => L10n.setTestLocale('zh-CN'));
    await _pumpAbout(tester);
    expect(find.text('About ZCode Pocket'), findsOneWidget);
    expect(find.text('Notices'), findsOneWidget);
    expect(find.text('Privacy'), findsOneWidget);
    expect(find.text('Project license (Apache 2.0)'), findsOneWidget);
    expect(find.text('声明'), findsNothing);
  });
}
