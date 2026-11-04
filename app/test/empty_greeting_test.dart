// 2026-10-23 用户反馈批⑥（回填律）：草稿空态对齐官方欢迎屏——分时
// 问候语六档原文（官方 ConversationDraftEmptyState.tsx:32-44 + zh-CN
// i18n）+ Z 水印（若隐若现、下端渐隐、不挡指针）。本文件锁档位边界
// 与欢迎屏结构。
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/ui/conversation_page.dart';

Widget _host(Widget page, {Brightness b = Brightness.light, AppState? app}) =>
    AppStateScope(
      app: app ?? (AppState()..loaded = true),
      child: MaterialApp(
        theme:
            b == Brightness.dark ? buildAppTheme(Brightness.dark) : buildAppTheme(),
        home: page,
      ),
    );

class _DraftWorkspaceApp extends AppState {
  @override
  bool get loaded => true;
  @override
  String? get activeProjectId => 'p1';
  @override
  Map<String, dynamic>? get activeWorkspace => const {
        'label': '示例项目',
        'workspacePath': 'D:/示例项目',
      };
}

void main() {
  testWidgets('草稿副行标明新建落点（工作区/项目名）', (tester) async {
    final app = _DraftWorkspaceApp();
    await tester.pumpWidget(_host(
      const ConversationPage(sessionId: null, title: '新会话'),
      app: app,
    ));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byKey(const ValueKey('draft-workspace-chip')), findsOneWidget);
    expect(find.text('新建于 示例项目'), findsOneWidget);
  });

  test('chatEmptyGreeting 六档边界（官方分档原文）', () {
    expect(chatEmptyGreeting(0), '夜深啦，别忘了照顾好自己哦');
    expect(chatEmptyGreeting(4), '夜深啦，别忘了照顾好自己哦');
    expect(chatEmptyGreeting(23), '夜深啦，别忘了照顾好自己哦');
    expect(chatEmptyGreeting(5), '早上好呀，新的一天开始啦');
    expect(chatEmptyGreeting(8), '早上好呀，新的一天开始啦');
    expect(chatEmptyGreeting(9), '上午好呀，有什么想让我帮忙的吗');
    expect(chatEmptyGreeting(11), '上午好呀，有什么想让我帮忙的吗');
    expect(chatEmptyGreeting(12), '中午好呀，要不要先休息一下');
    expect(chatEmptyGreeting(13), '中午好呀，要不要先休息一下');
    expect(chatEmptyGreeting(14), '下午好呀，接下来交给我吧');
    expect(chatEmptyGreeting(17), '下午好呀，接下来交给我吧');
    expect(chatEmptyGreeting(18), '晚上好呀，今天辛苦啦');
    expect(chatEmptyGreeting(22), '晚上好呀，今天辛苦啦');
  });

  testWidgets('草稿空态：问候语按注入时刻+Z 水印+建议 chips（浅色）',
      (tester) async {
    await tester.pumpWidget(_host(ConversationPage(
      sessionId: null,
      title: '新会话',
      greetingNow: DateTime(2026, 10, 23, 15),
    )));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('下午好呀，接下来交给我吧'), findsOneWidget);
    // Z 水印存在（品牌 Z 标资产，染色前景色+透明档）。
    expect(find.byType(SvgPicture), findsOneWidget);
    // 建议 chips 保留（手机端对官方 suggested prompts 的既有形态）。
    expect(find.text('总结这个项目'), findsOneWidget);
    expect(find.text('解释最近改动'), findsOneWidget);
    expect(find.text('跑一下测试'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('深色：同结构可渲染（水印随主题染前景色）', (tester) async {
    await tester.pumpWidget(_host(
      ConversationPage(
        sessionId: null,
        title: '新会话',
        greetingNow: DateTime(2026, 10, 23, 23),
      ),
      b: Brightness.dark,
    ));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('夜深啦，别忘了照顾好自己哦'), findsOneWidget);
    expect(find.byType(SvgPicture), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
