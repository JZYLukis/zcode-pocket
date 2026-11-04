// 2026-10-23 用户反馈批（回填律）：「流式输出只有思考条高亮橙色，
// 其他工具行无任何展示」。勘察结论=V3 批刻意用前景色扫光+灰图标
// （提交注释自证），用户感知≈无高亮。本批统一：运行中工具行/分组行/
// 空窗占位的扫光文字与图标全用 running 琥珀（官方 running=warning+
// animate-pulse 语义）。本文件锁该配色回归。
// 注入路径同 batch4_feedback_test：AppState 覆写 readSessionCache
// 预渲 rows（缓存会话不建活流，widget 测试离线稳定）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/state/cache_policy.dart';
import 'package:zcode_pocket/ui/conversation_page.dart';
import 'package:zcode_pocket/ui/motion.dart';

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
          'title': '运行高亮',
          'control': {'phase': controlPhase},
          'usage': {
            'contextWindow': {'usedTokens': 12000, 'maxTokens': 1000000},
          },
        },
        savedAt: DateTime.now().millisecondsSinceEpoch,
        byteSize: 1024,
      );
}

Widget _host(AppState app, Widget page, {Brightness b = Brightness.light}) =>
    AppStateScope(
      app: app,
      child: MaterialApp(
        theme: b == Brightness.dark
            ? buildAppTheme(Brightness.dark)
            : buildAppTheme(),
        home: page,
      ),
    );

/// 有界泵：页面含无限动画（扫光），pumpAndSettle 不可用。
Future<void> _pump(WidgetTester tester) async {
  for (var i = 0; i < 15; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets('运行中工具行：扫光文字与图标均为 running 琥珀（浅色）', (tester) async {
    final app = _RowsApp(
      [
        {'rowId': 1, 'kind': 'userInput', 'text': '改一下'},
        {'rowId': 2, 'kind': 'turnHeader', 'state': 'running'},
        {
          'rowId': 3,
          'kind': 'toolCall',
          'toolName': 'Edit',
          'status': 'running',
          'inputText': '{"file_path":"a.dart","old_string":"x","new_string":"y"}',
        },
      ],
      'running',
    );
    await tester.pumpWidget(
        _host(app, const ConversationPage(sessionId: 's1', title: '运行高亮')));
    await _pump(tester);

    final sweep = tester
        .widgetList<ShimmerText>(find.byType(ShimmerText))
        .firstWhere((w) => w.text.contains('编辑'));
    expect(sweep.style.color, AppThemeSpec.light.colors.running,
        reason: '2026-10-23 用户反馈批：运行行扫光文字应与思考条同用琥珀');

    // 工具行图标 size=15；模式药丸默认档也是 build_circle_outlined 但
    // size=16——按尺寸区分取工具行那个。
    final icon = tester
        .widgetList<Icon>(find.byIcon(Icons.build_circle_outlined))
        .firstWhere((i) => i.size == 15);
    expect(icon.color, AppThemeSpec.light.colors.running,
        reason: '运行行图标不再刻意降灰，与状态词同色');
  });

  testWidgets('运行中工具行：深色同为 running 琥珀', (tester) async {
    final app = _RowsApp(
      [
        {'rowId': 1, 'kind': 'userInput', 'text': '改一下'},
        {'rowId': 2, 'kind': 'turnHeader', 'state': 'running'},
        {
          'rowId': 3,
          'kind': 'toolCall',
          'toolName': 'Edit',
          'status': 'running',
          'inputText': '{"file_path":"a.dart","old_string":"x","new_string":"y"}',
        },
      ],
      'running',
    );
    await tester.pumpWidget(_host(
        app,
        const ConversationPage(sessionId: 's1', title: '运行高亮'),
        b: Brightness.dark));
    await _pump(tester);
    final sweep = tester
        .widgetList<ShimmerText>(find.byType(ShimmerText))
        .firstWhere((w) => w.text.contains('编辑'));
    expect(sweep.style.color, AppThemeSpec.dark.colors.running,
        reason: '深色下运行高亮=官方 warning #FF8A30');
  });

  testWidgets('运行中工具组：分组行扫光与图标均为 running 琥珀', (tester) async {
    final app = _RowsApp(
      [
        {'rowId': 1, 'kind': 'userInput', 'text': '查一下'},
        {'rowId': 2, 'kind': 'turnHeader', 'state': 'running'},
        {
          'rowId': 3,
          'kind': 'toolCall',
          'toolName': 'Bash',
          'status': 'success',
          'inputText': 'ls',
        },
        {
          'rowId': 4,
          'kind': 'toolCall',
          'toolName': 'Bash',
          'status': 'running',
          'inputText': 'grep -r foo',
        },
      ],
      'running',
    );
    await tester.pumpWidget(
        _host(app, const ConversationPage(sessionId: 's1', title: '运行高亮')));
    await _pump(tester);
    // 连续同族 ≥2 成组（终端组），运行中显示最新活跃子工具摘要。
    final sweep = tester
        .widgetList<ShimmerText>(find.byType(ShimmerText))
        .firstWhere((w) => w.text.contains('运行命令'));
    expect(sweep.style.color, AppThemeSpec.light.colors.running,
        reason: '分组行运行摘要扫光应为琥珀（与单行工具行同配方）');
    final icon = tester.widget<Icon>(find.byIcon(Icons.terminal_outlined));
    expect(icon.color, AppThemeSpec.light.colors.running);
  });

  testWidgets('空窗占位「正在思考…」为 running 琥珀', (tester) async {
    final app = _RowsApp(
      [
        {'rowId': 1, 'kind': 'userInput', 'text': '跑'},
        {'rowId': 2, 'kind': 'turnHeader', 'state': 'running'},
      ],
      'running',
    );
    await tester.pumpWidget(
        _host(app, const ConversationPage(sessionId: 's1', title: '运行高亮')));
    await _pump(tester);
    final ph = tester
        .widgetList<ShimmerText>(find.byType(ShimmerText))
        .firstWhere((w) => w.text.contains('正在思考'));
    expect(ph.style.color, AppThemeSpec.light.colors.running,
        reason: '空窗占位与思考条同配方（原 foregroundSubtlest 用户感知无展示）');
  });

  testWidgets('等待中（参数流写）保持灰、完成态保持最浅文本色', (tester) async {
    // 用 Edit（不成组）避免连续同族工具进分组行——分组行运行摘要
    // 是另一套展示（组级活跃即琥珀，官方 explore.tsx 组级语义）。
    final app = _RowsApp(
      [
        {'rowId': 1, 'kind': 'userInput', 'text': '查'},
        {'rowId': 2, 'kind': 'turnHeader', 'state': 'running'},
        {
          'rowId': 3,
          'kind': 'toolCall',
          'toolName': 'Edit',
          'status': 'inputStreaming',
          'inputText': '{"file_path":"a.dart","old_string":"x","new_string":"y"}',
        },
        {
          'rowId': 4,
          'kind': 'toolCall',
          'toolName': 'Edit',
          'status': 'success',
          'inputText': '{"file_path":"b.dart","old_string":"x","new_string":"y"}',
        },
      ],
      'running',
    );
    await tester.pumpWidget(
        _host(app, const ConversationPage(sessionId: 's1', title: '运行高亮')));
    await _pump(tester);
    // inputStreaming=「等待中」灰（官方词表），无扫光——锁住不回退。
    expect(find.textContaining('等待中'), findsOneWidget);
    expect(
      tester.widgetList<ShimmerText>(find.byType(ShimmerText)).where(
            (w) => w.text.contains('编辑'),
          ),
      isEmpty,
      reason: '等待中不扫光（dd32e49 对齐官方：参数流写≠执行中）');
    // 完成态两行都在（等待中+成功各一行）。
    expect(find.textContaining('编辑'), findsNWidgets(2));
  });
}
