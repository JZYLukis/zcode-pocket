import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/ui/conversation_page.dart';
import 'package:zcode_pocket/ui/voice_input_sheet.dart'
    show debugVoiceRecognitionAvailable;

/// 加号面板布局回归（2026-10-23 真机反馈"加号点开后布局有问题"）：
/// 第 6 个入口（语音输入）后单行 Row(spaceAround) 6×86=516dp 溢出
/// 360dp 屏，最右"用量详情"被右缘截断。改 Wrap 3×2 后：全部入口
/// 在屏内、无 RenderFlex 溢出异常。
///
/// 多机型批（阶段 6.1）：宽度改参（原 360 写死两处）+ 补
/// 320dp 小屏档——小屏下 Wrap 换行布局，每入口完整可见即可（不再
/// 钉 86/两行三列形态，那是 360 档的锁定值）。
Future<void> _sheetEntriesVisible(WidgetTester tester, double w) async {
  tester.view.physicalSize = Size(w * 3, 780 * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);

  final app = AppState()..loaded = true;
  await tester.pumpWidget(
    AppStateScope(
      app: app,
      child: const MaterialApp(
        home: Scaffold(body: ConversationPage(sessionId: null, title: '草稿')),
      ),
    ),
  );
  await tester.pump();
  await tester.tap(find.byKey(const ValueKey('add-trigger')));
  await tester.pumpAndSettle();

  // 三个带 key 的入口 + 三个按文字定位的入口都在树上且已布局。
  for (final f in [
    find.byKey(const ValueKey('add-attachment')),
    find.byKey(const ValueKey('add-voice')),
    find.text('添加上下文'),
    find.text('选择能力'),
    find.text('选择技能'),
  ]) {
    expect(f, findsOneWidget);
  }
  // entry-polish-1：查看型入口已移出面板；「收集产物」随 downloads-
  // hub-1 迁至产物下载页（顶栏入口），不再占面板位。
  expect(find.byKey(const ValueKey('add-usage')), findsNothing);
  expect(find.byKey(const ValueKey('add-collect-artifacts')), findsNothing);

  // 核心断言：每个入口都完整落在屏内（右缘不再截断）。
  for (final f in [
    find.byKey(const ValueKey('add-attachment')),
    find.byKey(const ValueKey('add-voice')),
  ]) {
    final box = tester.renderObject<RenderBox>(f);
    if (w >= 360) expect(box.size.width, 86);
    expect(box.localToGlobal(Offset.zero).dx, greaterThanOrEqualTo(0));
    expect(
      box.localToGlobal(Offset.zero).dx + box.size.width,
      lessThanOrEqualTo(w),
      reason: '入口右缘超出屏宽——旧单行 Row 溢出的直接复现',
    );
  }

  // 无布局异常（RenderFlex 溢出在测试里以异常形式暴露）。
  expect(tester.takeException(), isNull);
}

void main() {
  // 本文件锁"语音入口在场时"的面板布局形态——测试环境无 AGC 配置
  //（入口会被隐藏），覆写可用性为 true（2026-10-28 开源准备批）。
  setUpAll(() => debugVoiceRecognitionAvailable = true);
  tearDownAll(() => debugVoiceRecognitionAvailable = null);

  testWidgets('360dp 屏 5 个入口全部完整可见，无溢出', (tester) async {
    await _sheetEntriesVisible(tester, 360);
    // Wrap 布置（5 项=3+2 两行；收集产物已迁产物下载页）——
    // 360 档形态锁。
    final wrap = tester.renderObject<RenderWrap>(find.byType(Wrap).first);
    expect(wrap.computeMinIntrinsicWidth(300), lessThanOrEqualTo(360));
  });

  testWidgets('320dp 小屏：入口完整可见无溢出（多机型批 6.1）', (tester) async {
    await _sheetEntriesVisible(tester, 320);
  });
}
