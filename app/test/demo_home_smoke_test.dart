// demo 全树冒烟（ios-adaptation-4 配套）：与 integration_test/
// ios_smoke_test.dart 同链路的本地快速车道（widget 环境+手机画布）——
// CI 集成问题先在此秒级复现，不烧 macOS 额度。
//
// 全链路旅程：任务首页 → 打开会话（push-first）→ 审批卡允许 →
// 发送消息→流式重放→后续审批→完成 → 加号面板开合 → 返回。
//
// 画布钉手机逻辑尺寸（402×874≈iPhone 16 Pro）：widget 测试默认
// 800×600 落宽屏档（≥600dp 双栏）——手机语义必须显式设表面。
// teardown：拆树+DemoAppState.dispose（订阅/注册表/桥的拆除链，
// ios-adaptation-3 补全）满足 testWidgets 的 pending-timer 不变量。
import 'package:flutter/material.dart' as material;
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/app.dart';
import 'package:zcode_pocket/demo/demo_app_state.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/ui/conversation_page.dart';

const _firstTaskTitle = '修复深色模式下图表颜色对比度不足';
const _replayFinalText = '吸顶效果完成';
final _kInteractionCard = material.ValueKey('interaction-ia-chart-dark');

Future<bool> _wait(
  WidgetTester tester,
  bool Function() cond, {
  Duration timeout = const Duration(seconds: 25),
}) async {
  final end = DateTime.now().add(timeout);
  while (!cond()) {
    if (DateTime.now().isAfter(end)) return false;
    await tester.pump(const Duration(milliseconds: 200));
  }
  return true;
}

/// 流式重放期间会出现审批卡（首卡 ia-chart-dark 的后续 + 发送重放的
/// ia-live）——循环裁决直到 [done] 或超时。
Future<int> _resolveApprovalsUntil(
  WidgetTester tester,
  bool Function() done,
) async {
  var resolved = 0;
  final end = DateTime.now().add(const Duration(seconds: 40));
  while (!done()) {
    if (DateTime.now().isAfter(end)) break;
    final allow = find.text('允许');
    if (allow.evaluate().isNotEmpty) {
      await tester.tap(allow.first);
      resolved++;
      await tester.pump(const Duration(milliseconds: 600));
    }
    await tester.pump(const Duration(milliseconds: 400));
  }
  return resolved;
}

void main() {
  testWidgets('demo 全链路：首页 → 会话 → 审批 → 发送流式 → 面板 → 返回', (
    tester,
  ) async {
    tester.view.physicalSize = const material.Size(402 * 3, 874 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.platformDispatcher.clearAllTestValues);

    final AppState app = DemoAppState();
    await tester.pumpWidget(ZcodeCompanionApp(app: app));

    // ① 任务首页渲染。
    final homeReady = await _wait(
      tester,
      () => find.text(_firstTaskTitle).evaluate().isNotEmpty,
    );
    expect(homeReady, isTrue, reason: 'demo 任务未在首页出现');

    // ② 打开会话（push-first：瞬间推页，页内等桥订阅）。
    await tester.tap(find.text(_firstTaskTitle).first);
    expect(
      await _wait(
        tester,
        () => find.byType(ConversationPage).evaluate().isNotEmpty,
      ),
      isTrue,
      reason: '会话页未打开',
    );

    // ③ 审批卡在场（静态 pendingInteractions 的 Bash 权限）→ 允许 → 卡收口。
    // （running 会话的输入区是 stop-button 分支——send-button 仅非运行
    // 态构建，发送旅程换已完成会话，见 ⑤。）
    expect(
      await _wait(
        tester,
        () => find.byKey(_kInteractionCard).evaluate().isNotEmpty,
      ),
      isTrue,
      reason: '审批卡未出现',
    );
    await tester.tap(find.text('允许').first);
    expect(
      await _wait(
        tester,
        () => find.byKey(_kInteractionCard).evaluate().isEmpty,
      ),
      isTrue,
      reason: '允许后审批卡未收口',
    );

    // ④ 返回首页，换已完成会话（t-menu-fix，completedSuccess）。
    await tester.binding.handlePopRoute();
    expect(
      await _wait(
        tester,
        () => find.byType(ConversationPage).evaluate().isEmpty,
      ),
      isTrue,
      reason: '返回未回到首页',
    );

    // ⑤ 发送消息 → 流式重放（用户消息上屏→打字机→审批→完成）。
    const secondTaskTitle = '修复 #142 安卓返回键无法收起抽屉菜单';
    expect(
      await _wait(
        tester,
        () => find.text(secondTaskTitle).evaluate().isNotEmpty,
      ),
      isTrue,
      reason: '已完成任务未在首页出现',
    );
    await tester.tap(find.text(secondTaskTitle).first);
    expect(
      await _wait(
        tester,
        () => find.byType(ConversationPage).evaluate().isNotEmpty,
      ),
      isTrue,
      reason: '第二个会话页未打开',
    );
    final input = find.byKey(material.ValueKey('chat-input'));
    expect(
      await _wait(tester, () => input.evaluate().isNotEmpty),
      isTrue,
      reason: '输入栏不在场',
    );
    await tester.enterText(input, '帮我把列表滚动吸顶');
    expect(
      await _wait(
        tester,
        () => find.byKey(material.ValueKey('send-button')).evaluate().isNotEmpty,
      ),
      isTrue,
      reason: 'send-button 不在场（非运行态应构建）',
    );
    await tester.pump(const Duration(milliseconds: 300));
    // 探针（临时）：发送键 enabled 态。
    await tester.tap(find.byKey(material.ValueKey('send-button')));
    await tester.pump(const Duration(milliseconds: 800));
    // 重放期审批（ia-live）循环允许，直到完成标记。
    final resolved = await _resolveApprovalsUntil(
      tester,
      () => find.textContaining(_replayFinalText).evaluate().isNotEmpty,
    );
    expect(resolved, greaterThanOrEqualTo(1), reason: '重放期无审批可裁决');
    expect(
      find.textContaining(_replayFinalText).evaluate(),
      isNotEmpty,
      reason: '流式收尾总结未上屏',
    );

    // ⑤ 加号面板开合（附件入口在场——iOS file_picker 的触发点同路径）。
    await tester.tap(find.byKey(material.ValueKey('add-trigger')));
    expect(
      await _wait(
        tester,
        () => find
            .byKey(const material.ValueKey('add-attachment'))
            .evaluate()
            .isNotEmpty,
      ),
      isTrue,
      reason: '加号面板未打开（附件入口不在场）',
    );

    // ⑥ 关面板（弹层在栈顶，pop 先关面板）→ 返回首页（系统返回语义）。
    await tester.binding.handlePopRoute();
    expect(
      await _wait(
        tester,
        () => find
            .byKey(material.ValueKey('add-attachment'))
            .evaluate()
            .isEmpty,
      ),
      isTrue,
      reason: '加号面板未关闭',
    );
    await tester.binding.handlePopRoute();
    expect(
      await _wait(
        tester,
        () => find.byType(ConversationPage).evaluate().isEmpty,
      ),
      isTrue,
      reason: '返回未回到首页',
    );

    // 收尾：拆树+dispose。
    await tester.pumpWidget(const material.SizedBox.shrink());
    app.dispose();
    await tester.pump(const Duration(seconds: 2));
  }, timeout: const Timeout(Duration(minutes: 3)));
}
