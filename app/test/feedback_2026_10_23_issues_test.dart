// 2026-10-23 用户真机四问题回填（回填律）：
// ① 新建会话归属：手机选了工作区、桌面落「任务」默认区——根因是
//   createSession RPC params 缺 projectId。锁两个协议形状：params 顶层
//   带 projectId（绝不能进 envelope payload，官方 zcodeAgent.ts:498-504
//   只认 params 顶层）+ 仅 project intent 桥携带（普通桥带会被桌面
//   cwd-not-in-roots 拒绝）。
// ③ diff 语法高亮：官方 diff 三表面全带 shiki 高亮（欠账
//   清偿）——锁 marker 剥离/行对齐/跨行 token 不断色/未知语言回落。
// ④ ±N 先行值：replayable 档 inputText 定稿才到，结构化 input 进入
//   running 即随 upsert 到达（协议 rows.ts input 字段）——锁"优先读
//   结构化 input"使 ±N 出现在协议最早时刻。
// ②（列表卡死）为行为级状态机修复，无轻量夹具，模拟器/真机验证覆盖。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/code_highlight.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/state/cache_policy.dart';
import 'package:zcode_pocket/state/computer_stack.dart';
import 'package:zcode_pocket/transport/conversation.dart';
import 'package:zcode_pocket/ui/conversation_page.dart';
import 'package:zcode_pocket/ui/turn_model.dart';

void main() {
  group('① createSession 归属：commandParams 协议形状', () {
    test('projectId 落 params 顶层（envelope 不污染）', () {
      final envelope = {
        'type': 'createSession',
        'payload': {'workspaceId': 'w1'},
      };
      final params = commandParams(
        {'workspacePath': 'G:/x', 'workspaceIdentity': 'id1'},
        envelope,
        'proj_123',
      );
      expect(params['projectId'], 'proj_123',
          reason: '官方 host 只认 params.projectId（agentConversationTransport'
              '.ts:371 的 {...workspace, ...context} 平级注入）');
      expect(params['workspacePath'], 'G:/x');
      expect(params['envelope'], same(envelope));
      expect(envelope.containsKey('projectId'), isFalse,
          reason: 'v4 信封 schema 无 projectId 字段，进 envelope 会被 '
              'proto.strict 拒');
    });

    test('projectId 缺省：不带键（官方 null=桌面「任务」区语义）', () {
      final params = commandParams({'workspacePath': 'w'}, {'type': 'x'}, null);
      expect(params.containsKey('projectId'), isFalse);
    });
  });

  group('① createSessionProjectId 取值（仅 project intent 桥）', () {
    test('project intent 桥 → 携带', () {
      expect(
        createSessionProjectId({'projectId': 'p1', 'hostId': 'local'}),
        'p1',
      );
    });

    test('普通 tab 桥/任务桥（intent=null）→ 不带', () {
      expect(createSessionProjectId(null), isNull,
          reason: '官方 cwd-not-in-roots：非项目根 workspacePath 带 '
              'projectId 会被拒绝，普通桥必须缺省');
    });

    test('空串/非字符串 → 不带', () {
      expect(createSessionProjectId({'projectId': '  '}), isNull);
      expect(createSessionProjectId({'projectId': 42}), isNull);
    });

    test('回落（B1）：tab 桥落在项目根（suspend 恢复路径）→ 携带',
        () {
      final projects = [
        {
          'id': 'p1',
          'roots': [
            {'rootPath': 'G:/demo'},
          ],
        },
        {'id': '', 'roots': []},
      ];
      expect(rootMatchedProjectId('G:/demo', projects), 'p1',
          reason: '恢复路径按 workspace-list 恢复开 tab 桥（无 intent），'
              '键=rootPath 直配时归属不能丢');
      // 非根路径不回落（cwd-not-in-roots 防线）。
      expect(rootMatchedProjectId('G:/other', projects), isNull);
      expect(rootMatchedProjectId(null, projects), isNull);
    });
  });

  group('④ toolInputArgs（结构化 input 优先）', () {
    test('row.input 优先（running upsert 即携带，免解析）', () {
      final args = toolInputArgs({
        'input': {'file_path': 'a.dart', 'old_string': 'x'},
      });
      expect(args?['file_path'], 'a.dart');
    });

    test('input 缺席退 inputText 解析', () {
      final args = toolInputArgs({
        'inputText': '{"file_path":"b.dart"}',
      });
      expect(args?['file_path'], 'b.dart');
    });

    test('input 优先于 inputText（官方 toolCallRowAdapter.ts:37-44 优先级）',
        () {
      final args = toolInputArgs({
        'input': {'file_path': 'structured.dart'},
        'inputText': '{"file_path":"stale.dart"}',
      });
      expect(args?['file_path'], 'structured.dart');
    });

    test('半截 JSON → null（replayable 档打字期拿不到增量=档位天花板）',
        () {
      expect(toolInputArgs({'inputText': '{"file_path":"a.da'}), isNull);
    });
  });

  group('③ highlightDiffLines（marker 剥离+行对齐+跨行 token）', () {
    test('kind 分类与 marker 剥离（+/-/空格 是协议 marker 非代码）', () {
      final views = highlightDiffLines(
        [
          '@@ -1,2 +1,3 @@',
          ' context',
          '+final a = 1;',
          '-final b = 2;',
        ],
        'dart',
        brightness: Brightness.light,
      );
      expect(views.map((v) => v.kind), [
        DiffLineKind.hunk,
        DiffLineKind.context,
        DiffLineKind.add,
        DiffLineKind.del,
      ]);
      // 文本已剥 marker（官方 lightweight-diff-preview.ts:37-71：marker
      // 不作为代码内容显示）。
      expect(views[1].text, 'context');
      expect(views[2].text, 'final a = 1;');
      expect(views[3].text, 'final b = 2;');
      // hunk 行保留原始 @@ 行。
      expect(views[0].text, '@@ -1,2 +1,3 @@');
    });

    test('行对齐：hunk 占位行不挤占内容行 spans', () {
      final views = highlightDiffLines(
        ['@@ -1,1 +1,1 @@', '-old', '+void main() {}'],
        'dart',
        brightness: Brightness.light,
      );
      // del 行（index 1）与 add 行（index 2）的 spans 是各自内容的
      // 着色——若 hunk 占位未加会导致错行。
      final addSpans = views[2].spans!;
      expect(addSpans, isNotEmpty);
    });

    test('跨行块注释不断色（整文 tokenize 的核心价值）', () {
      final views = highlightDiffLines(
        [
          '+/* header',
          '+   rest */',
        ],
        'dart',
        brightness: Brightness.light,
      );
      final c1 = (views[0].spans!.first as TextSpan).style!.color;
      final c2 = (views[1].spans!.first as TextSpan).style!.color;
      // 逐行单独 tokenize 会把 "   rest */" 当代码染默认前景；整文
      // tokenize 后两行同属 comment 节点（0xFF6A737D，github-light）。
      expect(c1, const Color(0xFF6A737D));
      expect(c2, c1, reason: '跨行注释第二行必须延续注释色');
    });

    test('未知语言（.md/.txt/无扩展名）→ spans null 回落纯色呈现', () {
      final views = highlightDiffLines(
        ['+# 标题', '-正文'],
        null,
        brightness: Brightness.light,
      );
      expect(views[0].kind, DiffLineKind.add);
      expect(views[0].spans, isNull);
      expect(views[1].kind, DiffLineKind.del);
    });

    test('空 context 行（单空格 marker）→ 空内容 context', () {
      final views = highlightDiffLines(
        [' ', '+x'],
        'dart',
        brightness: Brightness.dark,
      );
      expect(views[0].kind, DiffLineKind.context);
      expect(views[0].text, '');
    });

    test('CRLF 尾 \\r 剥除（B4：等宽下占一格宽的豆腐块）', () {
      final views = highlightDiffLines(
        ['+a\r', '-b\r'],
        'dart',
        brightness: Brightness.light,
      );
      expect(views[0].text, 'a');
      expect(views[1].text, 'b');
    });

    test('超尺寸护栏（B1）：>120k 官方同款 cap → 回落纯文本', () {
      final long = List.generate(15000, (i) => '+final v$i = $i;').join('\n');
      expect(
        highlightCode(long, 'dart', brightness: Brightness.light),
        isNull,
        reason: '服务端 patches 无界，超限必须回落防主线程秒级 tokenize',
      );
      expect(
        highlightCodeLines(long, 'dart', brightness: Brightness.light),
        isNull,
      );
    });
  });

  group('④ 工具行 ±N：结构化 input 随 running upsert 即显示', () {
    testWidgets('Edit 行只有 row.input（无 inputText）→ +4 -2', (tester) async {
      final app = _RowsApp(
        [
          {'rowId': 1, 'kind': 'userInput', 'text': '改一下'},
          {'rowId': 2, 'kind': 'turnHeader', 'state': 'running'},
          {
            'rowId': 3,
            'kind': 'toolCall',
            'toolName': 'Edit',
            'status': 'running',
            // replayable 档真实时序：inputText 尚未定稿到达，结构化
            // input 已随 running upsert 到场（协议 rows.ts:989）。
            'input': {
              'file_path': 'a.dart',
              'old_string': 'l1\nl2',
              'new_string': 'l1\nl2\nl3\nl4',
            },
          },
        ],
        'running',
      );
      await tester.pumpWidget(_host(
          app, const ConversationPage(sessionId: 's1', title: '回填④')));
      for (var i = 0; i < 15; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.textContaining('+4'), findsOneWidget,
          reason: '结构化 input 到场即显示先行值（协议最早时刻）');
      expect(find.textContaining('-2'), findsOneWidget);
    });
  });
}

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
          'title': '回填',
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
      child: MaterialApp(
        theme: buildAppTheme(),
        home: page,
      ),
    );
