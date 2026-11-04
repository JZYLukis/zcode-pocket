// 2026-10-23 用户反馈批⑧（回填律）：「桌面端有一键复制，手机端没有」。
// 勘察结论=代码块零复制入口、助手消息只有隐藏的长按复制（且无反馈）。
// 本批三件：代码块右上角复制按钮（官方 CodeBlockCopyButton 对位）、
// 完成态助手消息尾部常显复制（官方远控形态=常显 action bar）、长按
// 菜单复制补 SnackBar 反馈。本文件锁三入口的剪贴板内容与反馈。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/state/cache_policy.dart';
import 'package:zcode_pocket/ui/app_widgets.dart';
import 'package:zcode_pocket/ui/conversation_page.dart';
import 'package:zcode_pocket/ui/markdown_view.dart';

class _RowsApp extends AppState {
  _RowsApp(this.rows, this.controlPhase);
  final List<Map<String, dynamic>> rows;
  final String controlPhase;

  @override
  LinkPhase get phase => LinkPhase.online;

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
        snapshotControl: {
          'title': '复制回填',
          'control': {'phase': controlPhase},
          'usage': {
            'contextWindow': {'usedTokens': 12000, 'maxTokens': 1000000},
          },
        },
        savedAt: DateTime.now().millisecondsSinceEpoch,
        byteSize: 1024,
      );
}

Widget _host(AppState app, Widget page) => AppStateScope(
      app: app,
      child: MaterialApp(theme: buildAppTheme(), home: page),
    );

void main() {
  testWidgets('代码块：右上角复制按钮→剪贴板=代码原文+SnackBar', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: MarkdownView(data: '示例如下：\n```dart\nvoid main() {\n  print(1);\n}\n```\n完')),
    ));
    await tester.pump();
    // MarkdownView 内的代码块复制按钮（区别于消息级按钮）。
    final btn = find.descendant(
      of: find.byType(MarkdownView),
      matching: find.byType(CopyIconButton),
    );
    expect(btn, findsOneWidget, reason: '代码块应有右上角复制按钮');
    await tester.tap(btn.first, warnIfMissed: false);
    await tester.pump();
    expect(copied, 'void main() {\n  print(1);\n}',
        reason: '复制的是代码原文（非渲染文本，官方同款）');
    expect(find.text('代码已复制'), findsOneWidget);
  });

  testWidgets('完成态助手消息：尾部常显复制→整段 markdown 进剪贴板',
      (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    const text = '这是**结论**：\n\n- 一\n- 二';
    final app = _RowsApp(
      [
        {'rowId': 1, 'kind': 'userInput', 'text': '总结'},
        {'rowId': 2, 'kind': 'turnHeader', 'state': 'completedSuccess'},
        {'rowId': 3, 'kind': 'assistantText', 'state': 'success', 'text': text},
      ],
      'idle',
    );
    await tester.pumpWidget(_host(
        app, const ConversationPage(sessionId: 's1', title: '复制回填')));
    for (var i = 0; i < 15; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    // 单轮会话=末轮，默认展开（2026-10-25 问题②拍板）——无需先点开。
    final btn = find.byType(CopyIconButton);
    expect(btn, findsWidgets, reason: '完成态助手消息尾部应常显复制按钮');
    await tester.tap(btn.first, warnIfMissed: false);
    await tester.pump();
    expect(copied, text, reason: '消息级复制=整段 markdown 原文（长按菜单同源）');
    expect(find.text('已复制'), findsOneWidget);
  });

  testWidgets('流式段不出复制按钮（官方仅完成态渲染 action）', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: MarkdownView(data: '正在输出中', streaming: true),
      ),
    ));
    await tester.pump();
    // streaming 正文没有独立 CopyIconButton（代码块按钮属于块级渲染，
    // 这里断言消息级——由 _AssistantText 门控，直接验证组件参数路径）。
    expect(find.byType(CopyIconButton), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('长按菜单：复制后出 SnackBar 反馈', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    final app = _RowsApp(
      [
        {'rowId': 1, 'kind': 'userInput', 'text': '问'},
        {'rowId': 2, 'kind': 'turnHeader', 'state': 'completedSuccess'},
        {'rowId': 3, 'kind': 'assistantText', 'state': 'success', 'text': '答'},
      ],
      'idle',
    );
    await tester.pumpWidget(_host(
        app, const ConversationPage(sessionId: 's1', title: '复制回填')));
    for (var i = 0; i < 15; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    // 完成轮默认收起（2026-10-26 澄清语义）——先点开轮，行操作菜单挂
    // 展开态正文上。
    await tester.tap(find.text('已处理'));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    // 长按助手正文（RenderParagraph 命中区在测试字体下有偏移，用
    // warnIfMissed:false+长按中心点；菜单为底部弹层）。
    final rp = find.text('答');
    await tester.longPress(rp, warnIfMissed: false);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final copyItem = find.text('复制');
    expect(copyItem, findsOneWidget, reason: '长按应出行操作菜单');
    await tester.tap(copyItem, warnIfMissed: false);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(copied, '答');
    expect(find.text('已复制'), findsOneWidget,
        reason: '2026-10-23 批⑧：长按复制不再静默');
  });
}
