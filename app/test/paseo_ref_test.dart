// Paseo 参考批回填（2026-10-23 用户拍板采纳三项，观察归档见会话）：
// 1. 回合尾部「N 个子代理」胶囊（官方轮尾卡无此字段=裁量项）
// 2. 工作条完成态附回合结束时刻 HH:mm
// 3. 顶栏副行「当前电脑备注名」（多电脑场景常驻可见）
// 4. 会话内联 diff 预览整行底色染色（与 DiffViewer _DiffLine 同档）
// 5. DiffViewer 目录行增删合计
// 注入路径同 batch4_feedback_test：AppState 覆写 readSessionCache 预渲。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/state/cache_policy.dart';
import 'package:zcode_pocket/transport/z_transport.dart';
import 'package:zcode_pocket/ui/conversation_page.dart';
import 'package:zcode_pocket/ui/brand_logo.dart';
import 'package:zcode_pocket/ui/inline_diff_preview.dart';
import 'package:zcode_pocket/ui/diff_viewer_page.dart';

class _RowsApp extends AppState {
  _RowsApp(this.rows, {this.changes});
  final List<Map<String, dynamic>> rows;
  final Map<String, dynamic>? changes;
  SessionCacheEntry Function(String id)? readOverride;

  @override
  LinkPhase get phase => LinkPhase.online;

  @override
  Future<SessionCacheEntry?> readSessionCache(String id) async =>
      readOverride != null
          ? readOverride!(id)
          : SessionCacheEntry(
        deviceSid: 'd1',
        sessionId: id,
        rows: rows,
        logEpoch: 'e1',
        lastSeq: rows.length,
        firstRowId: 1,
        totalCount: rows.length,
        snapshotControl: {
          'title': 'Paseo参考',
          'control': {'phase': 'idle'},
        },
        savedAt: DateTime.now().millisecondsSinceEpoch,
        byteSize: 1024,
      );

  @override
  Future<dynamic> fileChanges(
    String sessionId, {
    required Map<String, dynamic> target,
  }) async => changes;
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

void main() {
  testWidgets('会话内联 diff 预览：深色侧整行染色（独立挂树）', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(Brightness.dark),
      home: Scaffold(
        body: InlineDiffPreview(
          display: const {
            'structuredPatch': [
              {'lines': ['+d']},
            ],
          },
        ),
      ),
    ));
    await tester.pump();
    // 圈定 +d 行的祖先容器再断言：原先对整棵树的
    // Container 颜色集合做 contains——任何无关容器恰好复用同主题色都会
    // 假绿（目标行未渲染时照样通过）。
    final addedRowColors = tester
        .widgetList<Container>(
          find.ancestor(of: find.text('d'), matching: find.byType(Container)),
        )
        .map((c) => c.decoration is BoxDecoration
            ? (c.decoration as BoxDecoration).color
            : c.color)
        .toSet();
    expect(
      addedRowColors.contains(
        AppThemeSpec.dark.colors.diffAdded.withValues(alpha: AppAlpha.faint),
      ),
      isTrue,
      reason: '深色侧新增行整行染色（Paseo 参考双模式通用）',
    );
  });

  testWidgets('回合尾部：子代理计数胶囊', (tester) async {
    final app = _RowsApp([
      {
        'rowId': 1,
        'kind': 'userInput',
        'text': '改一下',
      },
      {
        'rowId': 2,
        'kind': 'turnHeader',
        'state': 'completedSuccess',
        'entityId': 'ent1',
        'fileChanges': {'files': 2, 'additions': 5, 'deletions': 1},
      },
      {'rowId': 3, 'kind': 'subagent', 'status': 'success', 'text': '探路'},
      {'rowId': 4, 'kind': 'subagent', 'status': 'success', 'text': '审查'},
      {
        'rowId': 5,
        'kind': 'assistantText',
        'text': '改完了',
      },
    ]);
    await tester.pumpWidget(
        _host(app, const ConversationPage(sessionId: 's1', title: 'Paseo参考')));
    await _pump(tester);
    expect(find.textContaining('2 个文件已更改'), findsOneWidget);
    expect(find.textContaining('2 个子代理'), findsOneWidget,
        reason: 'Paseo 参考：轮尾汇总含子代理计数胶囊');
  });

  testWidgets('工作条完成态附回合结束时刻', (tester) async {
    final endedAt = DateTime(2026, 1, 1, 10, 17).millisecondsSinceEpoch;
    final app = _RowsApp([
      {'rowId': 1, 'kind': 'userInput', 'text': '跑'},
      {
        'rowId': 2,
        'kind': 'turnHeader',
        'state': 'completedSuccess',
        'activeMs': 253000,
        'endedAt': endedAt,
      },
      {
        'rowId': 3,
        'kind': 'toolCall',
        'toolName': 'Read',
        'status': 'success',
        'inputText': 'a.dart',
      },
    ]);
    await tester.pumpWidget(
        _host(app, const ConversationPage(sessionId: 's1', title: 'Paseo参考')));
    await _pump(tester);
    expect(find.textContaining('10:17'), findsOneWidget,
        reason: 'Paseo 参考：完成回合显示结束绝对时刻');
  });

  testWidgets('顶栏副行显示当前电脑备注名', (tester) async {
    final app = _RowsApp([
      {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
      {'rowId': 2, 'kind': 'turnHeader', 'state': 'completedSuccess'},
    ]);
    app.activeProfile = AccountV2Profile(
      deviceSid: 's1',
      label: 'MBP-工作机',
      addedAt: DateTime(2026, 1, 1),
    );
    await tester.pumpWidget(
        _host(app, const ConversationPage(sessionId: 's1', title: 'Paseo参考')));
    await _pump(tester);
    expect(find.text('MBP-工作机'), findsOneWidget,
        reason: 'Paseo 参考：多电脑场景顶栏常驻当前电脑名');
    expect(find.byIcon(Icons.computer), findsOneWidget);
  });

  testWidgets('DiffViewer：目录行增删合计', (tester) async {
    final app = _RowsApp(
      const [],
      changes: {
        'files': 2,
        'additions': 9,
        'deletions': 3,
        'items': [
          {'path': 'src/a.dart', 'additions': 5, 'deletions': 1},
          {'path': 'src/b.dart', 'additions': 4, 'deletions': 2},
        ],
      },
    );
    await tester.pumpWidget(_host(app, const DiffViewerPage(sessionId: 's1')));
    await _pump(tester);
    expect(find.text('src'), findsOneWidget);
    expect(find.text('+9/-3'), findsOneWidget,
        reason: 'Paseo 参考：目录行右侧带该目录增删合计');
  });

  testWidgets('会话内联 diff 预览：增删行整行底色染色+行首竖条', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: const Scaffold(
          body: InlineDiffPreview(
            display: {
              'kind': 'file_diff',
              'filePath': 'a.dart',
              'structuredPatch': [
                {
                  'lines': ['@@ -1,2 +1,2 @@', '+新行', '-旧行', ' 上下文'],
                },
              ],
            },
          ),
        ),
      ),
    );
    await tester.pump();
    final spec = AppThemeSpec.light;
    final addedBg = spec.colors.diffAdded.withValues(alpha: AppAlpha.faint);
    final removedBg = spec.colors.diffRemoved.withValues(alpha: AppAlpha.faint);
    // 2026-10-23 diff 语法高亮批起行底走 BoxDecoration（叠加语法 token
    // 色+行首 3px 竖条，官方 lightweight-diff-preview.ts:73-111 对位）；
    // Paseo 批"整行底色染色"语义保留。
    // 圈定目标行祖先容器再断言：整树颜色集合 contains
    // 会被无关同色容器假绿。
    Set<Color?> rowColors(String text) => tester
        .widgetList<Container>(
          find.ancestor(of: find.text(text), matching: find.byType(Container)),
        )
        .map((c) => c.decoration is BoxDecoration ? (c.decoration as BoxDecoration).color : c.color)
        .toSet();
    expect(rowColors('新行').contains(addedBg), isTrue,
        reason: 'Paseo 参考：新增行整行绿底');
    expect(rowColors('旧行').contains(removedBg), isTrue,
        reason: '删除行整行红底');
    final borders = tester
        .widgetList<Container>(
          find.ancestor(of: find.text('新行'), matching: find.byType(Container)),
        )
        .map((c) => c.decoration is BoxDecoration ? (c.decoration as BoxDecoration).border : null)
        .whereType<Border>()
        .toList();
    expect(
      borders.any((b) =>
          b.left.width == 3 &&
          b.left.color == spec.colors.diffAdded),
      isTrue,
      reason: '新增行行首 3px 竖条（官方 inset 竖条对位）',
    );

  });

  testWidgets('模型药丸：品牌 logo + 两级文字（GLM 高档）', (tester) async {
    final app = _RowsApp(
      [
        {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
        {'rowId': 2, 'kind': 'turnHeader', 'state': 'completedSuccess'},
      ],
    );
    // 快照 config：模型=glm-5.3-flash、思考档=high。
    app.readOverride = (id) => SessionCacheEntry(
      deviceSid: 'd1',
      sessionId: id,
      rows: app.rows,
      logEpoch: 'e1',
      lastSeq: 2,
      firstRowId: 1,
      totalCount: 2,
      snapshotControl: {
        'title': 'Paseo参考',
        'control': {'phase': 'idle'},
        'config': {'model': 'glm-5.3-flash', 'thought': 'high'},
      },
      savedAt: DateTime.now().millisecondsSinceEpoch,
      byteSize: 1024,
    );
    await tester.pumpWidget(_host(
        app, const ConversationPage(sessionId: 's1', title: 'Paseo参考')));
    await _pump(tester);
    expect(find.byType(BrandLogo), findsOneWidget,
        reason: 'Paseo 参考：GLM 模型应显示官方 Z 字标（单色矢量）');
    expect(find.text('glm-5.3F'), findsOneWidget, reason: '模型名主文字（亮，保留 id 大小写）');
    expect(find.text('高'), findsOneWidget, reason: '思考档次级文字（暗一档）');
  });

  testWidgets('模型药丸：无品牌资产回退纯文字（不留空位）', (tester) async {
    final app = _RowsApp(
      [
        {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
        {'rowId': 2, 'kind': 'turnHeader', 'state': 'completedSuccess'},
      ],
    );
    app.readOverride = (id) => SessionCacheEntry(
      deviceSid: 'd1',
      sessionId: id,
      rows: app.rows,
      logEpoch: 'e1',
      lastSeq: 2,
      firstRowId: 1,
      totalCount: 2,
      snapshotControl: {
        'title': 'Paseo参考',
        'control': {'phase': 'idle'},
        // 2026-11-05 反馈④：grok 已入资产表（x.svg）——回退用例换
        // Simple Icons 仍未收录的腾讯混元。
        'config': {'model': 'hy3'},
      },
      savedAt: DateTime.now().millisecondsSinceEpoch,
      byteSize: 1024,
    );
    await tester.pumpWidget(_host(
        app, const ConversationPage(sessionId: 's1', title: 'Paseo参考')));
    await _pump(tester);
    expect(find.byType(BrandLogo), findsNothing,
        reason: '无资产品牌回退纯文字');
  });
}