// 2026-10-23 用户真机反馈回填（回填律）：「工具行读取的文件预览没有
// 颜色」——官方桌面端 InlineCodeContent 是带高亮的 CodeBlock
// （ToolCallBody.tsx:131），我们此前 _OutputViewport 恒纯文本。本批
// 给读取类工具的文件预览接语法高亮（语言按输入参数文件扩展名推）。
// 本文件锁：.dart 文件预览走富文本着色、未知语言回落纯文本、运行中
// 不高亮。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/state/cache_policy.dart';
import 'package:zcode_pocket/ui/conversation_page.dart';

class _RowsApp extends AppState {
  _RowsApp(this.rows);
  final List<Map<String, dynamic>> rows;

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
          'title': '文件预览高亮',
          'control': {'phase': 'idle'},
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

Future<void> _pump(WidgetTester tester) async {
  for (var i = 0; i < 15; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

List<Map<String, dynamic>> _rows({
  required String path,
  required String status,
}) => [
      {'rowId': 1, 'kind': 'userInput', 'text': '读文件'},
      {'rowId': 2, 'kind': 'turnHeader', 'state': status == 'running' ? 'running' : 'completedSuccess'},
      {
        'rowId': 3,
        'kind': 'toolCall',
        'toolName': 'Read',
        'status': status,
        'inputText': '{"file_path":"$path"}',
        'output': {'text': 'class Foo {\n  final bar = "baz";\n}\n'},
      },
    ];

void main() {
  testWidgets('读取 .dart 文件预览：完成态走富文本着色（rich 路径）',
      (tester) async {
    await tester.pumpWidget(_host(
        _RowsApp(_rows(path: 'lib/ui/theme.dart', status: 'success')),
        const ConversationPage(sessionId: 's1', title: '文件预览高亮')));
    await _pump(tester);
    // 完成轮默认收起——展开。
    await tester.tap(find.byIcon(Icons.expand_more).first);
    await _pump(tester);
    final st = tester.widgetList<SelectableText>(find.byType(SelectableText));
    expect(st, isNotEmpty, reason: '展开区应有输出视口');
    // 高亮路径=SelectableText.rich（data 为 null）；纯文本路径 data 非空。
    expect(st.any((w) => w.data == null), isTrue,
        reason: '.dart 文件预览应走富文本着色渲染');
  });

  testWidgets('未知扩展名文件预览：回落纯文本（data 路径）', (tester) async {
    // 会话级折叠记忆是静态表——与上一用例错开 sessionId 防串台
    // （同 id 会继承上一轮的展开态，expand_more 命中错元素）。
    await tester.pumpWidget(_host(
        _RowsApp(_rows(path: 'notes.unknownext', status: 'success')),
        const ConversationPage(sessionId: 's2', title: '文件预览高亮')));
    await _pump(tester);
    await tester.tap(find.byIcon(Icons.expand_more).first);
    await _pump(tester);
    final st = tester.widgetList<SelectableText>(find.byType(SelectableText));
    expect(st.isNotEmpty && st.every((w) => w.data != null), isTrue,
        reason: '未知语言回落纯文本（不高亮不损渲染）');
  });
}
