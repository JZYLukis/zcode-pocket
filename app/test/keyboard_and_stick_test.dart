import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/state/cache_policy.dart';
import 'package:zcode_pocket/ui/conversation_page.dart';
import 'package:zcode_pocket/ui/voice_input_sheet.dart';

/// 2026-10-23 用户反馈两件回归：
/// ① 流式输出不持续粘底——解除粘底后（上滑回看）手动滑回底部不恢复
///    跟随，得点悬浮球才行；官方网页端贴底即恢复。断言链：拖回底部后
///    视口缩小（键盘弹起）仍自动贴底=粘底已恢复。
/// ② 语音面板被输入法盖住——showVoiceInputSheet 补 viewInsets 垫高。
class _CacheAppState extends AppState {
  _CacheAppState(this.rows);
  final List<Map<String, dynamic>> rows;

  @override
  Future<SessionCacheEntry?> readSessionCache(String id) async =>
      SessionCacheEntry(
        deviceSid: 'd1',
        sessionId: id,
        rows: rows,
        logEpoch: 'e1',
        lastSeq: rows.length,
        firstRowId: 1,
        totalCount: rows.length,
        snapshotControl: null,
        savedAt: DateTime.now().millisecondsSinceEpoch,
        byteSize: 1024,
      );
}

Widget _host(AppState app, Widget page) => AppStateScope(
      app: app,
      child: MaterialApp(home: page),
    );

List<Map<String, dynamic>> _tallRows() => [
      for (var i = 0; i < 60; i++)
        {
          'rowId': i + 1,
          'kind': i.isEven ? 'userInput' : 'assistantText',
          'text': '消息 $i——占位文本，撑出足够滚动高度。',
        },
    ];

ScrollPosition _pos(WidgetTester tester) => tester
    .state<ScrollableState>(
      find.descendant(
        of: find.byKey(const ValueKey('chat-scroll')),
        matching: find.byType(Scrollable),
      ),
    )
    .position;

/// 多机型批（6.1）：测试屏宽常量化（原 360 写死——改参便于小屏变体）。
const kTestPhoneW = 360.0;

void main() {
  testWidgets('① 滑回底部重新粘底：视口缩小仍自动贴底', (tester) async {
    tester.view.physicalSize = const Size(kTestPhoneW, 780);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final app = _CacheAppState(_tallRows());
    await tester.pumpWidget(
      _host(app, const ConversationPage(sessionId: 's1', title: '会话')),
    );
    // 缓存预渲链跨多帧，有界泵到稳定。
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final pos = _pos(tester);
    expect(pos.maxScrollExtent, greaterThan(300), reason: '前置：内容足够高');
    expect(pos.pixels, pos.maxScrollExtent, reason: '前置：打开即在底部');

    // 回看历史（手指向下拖=向旧内容方向），解除粘底：位置停在半途不回吸。
    await tester.drag(find.byKey(const ValueKey('chat-scroll')), const Offset(0, 260));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(pos.maxScrollExtent - pos.pixels, greaterThan(100),
        reason: '解除粘底后不应回吸底部');

    // 滑回底部（修复点）：贴底即恢复粘底。
    while (pos.maxScrollExtent - pos.pixels > 1) {
      await tester.drag(
        find.byKey(const ValueKey('chat-scroll')),
        const Offset(0, -400),
        warnIfMissed: false,
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(pos.pixels, pos.maxScrollExtent, reason: '已滑回底部');

    // 视口缩小（键盘弹起）：粘底恢复则自动跟到新底；未恢复则停在旧 offset。
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    for (var i = 0; i < 15; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(
      pos.pixels,
      pos.maxScrollExtent,
      reason: '滑回底部后粘底应已恢复——键盘弹起（视口缩小）仍自动贴底',
    );
    tester.view.viewInsets = FakeViewPadding.zero;
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('② 语音面板随键盘垫高（viewInsets.bottom 透传）', (tester) async {
    tester.view.physicalSize = const Size(kTestPhoneW, 780);
    tester.view.devicePixelRatio = 1.0;
    tester.view.viewInsets = const FakeViewPadding(bottom: 260);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_host(AppState(), const Scaffold(body: SizedBox())));
    await tester.pump();
    // 不 await：sheet 的关闭由用户手势驱动，await 会等成超时。
    unawaited(
      showVoiceInputSheet(tester.element(find.byType(Scaffold)), onSend: (_) {}),
    );
    for (var i = 0; i < 15; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    // 无麦克风权限的测试环境走 failed 分支——结构断言：面板外壳存在
    // viewInsets 垫高 Padding（修复本体），垫高值=键盘 inset。
    final sheet = find.descendant(
      of: find.byType(BottomSheet),
      matching: find.byType(VoiceInputSheet),
    );
    expect(sheet, findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (w) => w is Padding && (w.padding as EdgeInsets).bottom == 260,
      ),
      findsOneWidget,
      reason: '键盘弹起时面板应垫到键盘上方',
    );
    // 面板整体在键盘上方（不与其重叠）。
    final box = tester.renderObject<RenderBox>(sheet);
    expect(
      box.localToGlobal(Offset.zero).dy + box.size.height,
      lessThanOrEqualTo(780 - 260),
    );
  });
}
