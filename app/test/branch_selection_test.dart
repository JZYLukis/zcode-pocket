// 阶段 6.2 选分支回填：纯函数（概览解析/阻塞码人话映射）、调用缝
// （非仓库短路不拉分支）、分支弹层旅程（列表/当前标记/切换成功/运行中
// 任务确认门/阻塞码人话/新建分支/非仓库态）——全部 fixture 注入，不打
// 真桥。通道放行由 tools/git-channel-probe.mjs 对真桌面实证（2026-10-24）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/state/git_branch_service.dart';
import 'package:zcode_pocket/ui/branch_sheet.dart';
import 'package:zcode_pocket/ui/conversation_page.dart';

Map<String, dynamic> _repoInfo({String kind = 'main-tree', bool gitOk = true}) =>
    {'workspacePath': r'G:\demo', 'kind': kind, 'isGitAvailable': gitOk};

Map<String, dynamic> _branchList({String? current = 'main'}) => {
      'headRefType': 'branch',
      'currentBranchName': current,
      'branches': [
        {'name': 'main', 'isCurrent': current == 'main', 'upstreamName': 'origin/main'},
        {'name': 'dev', 'isCurrent': current == 'dev', 'upstreamName': null},
        {'name': 'feature/x', 'isCurrent': current == 'feature/x', 'upstreamName': 'origin/feature/x'},
      ],
    };

/// 可编排的 git 调用桩：按 method 返回 fixture，记录调用形状。
class _StubGit {
  final calls = <(String, Map<String, dynamic>)>[];
  Map<String, dynamic> repoInfo = _repoInfo();
  Map<String, dynamic> branches = _branchList();
  Object? throwOn;
  // switchBranch / createBranchAndSwitch 的脚本化结果（默认成功）。
  Map<String, dynamic> mutationResult = {'ok': true, 'didChange': true};

  Future<dynamic> call(String method, List<Object?> args) async {
    if (throwOn != null) throw throwOn!;
    calls.add((method, args.first is Map ? Map<String, dynamic>.from(args.first as Map) : {}));
    switch (method) {
      case 'getWorkspaceRepositoryInfo':
        return repoInfo;
      case 'getLocalBranches':
        return branches;
      case 'switchBranch':
        if ((mutationResult['ok'] == true) && mutationResult['didChange'] == true) {
          // 成功切换后列表同步翻当前（对齐真实服务行为）。
          final target = '${(args.first as Map)['targetBranchName']}';
          branches = _branchList(current: target);
        }
        return mutationResult;
      case 'createBranchAndSwitch':
        if (mutationResult['ok'] == true) {
          final name = '${(args.first as Map)['branchName']}';
          branches = _branchList(current: name);
        }
        return mutationResult;
    }
    throw StateError('unexpected method $method');
  }
}

Widget _host(_StubGit stub, {int runningTaskCount = 0}) => MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => TextButton(
            key: const ValueKey('open'),
            onPressed: () => showBranchSheet(
              ctx,
              call: stub.call,
              workspacePath: r'G:\demo',
              workspaceLabel: '示例工作区',
              runningTaskCount: runningTaskCount,
            ),
            child: const Text('打开'),
          ),
        ),
      ),
    );

Future<void> _openSheet(WidgetTester tester, _StubGit stub, {int running = 0}) async {
  await tester.pumpWidget(_host(stub, runningTaskCount: running));
  await tester.tap(find.byKey(const ValueKey('open')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  group('parseGitOverview（纯解析）', () {
    test('非 git 仓库 → isRepository=false（降级门）', () {
      final o = parseGitOverview(_repoInfo(kind: 'not-repository'), null);
      expect(o.isRepository, isFalse);
      final o2 = parseGitOverview(_repoInfo(gitOk: false), null);
      expect(o2.isRepository, isFalse);
    });

    test('正常仓库 → 分支列表+当前权威=currentBranchName', () {
      final o = parseGitOverview(_repoInfo(), _branchList(current: 'dev'));
      expect(o.isRepository, isTrue);
      expect(o.currentBranch, 'dev');
      expect(o.branches.length, 3);
      expect(o.branches.firstWhere((b) => b.name == 'dev').isCurrent, isTrue);
      expect(o.branches.first.upstreamName, 'origin/main');
    });

    test('detached HEAD → currentBranchName=null 标签不炸', () {
      final o = parseGitOverview(_repoInfo(), _branchList(current: null));
      expect(o.currentBranch, isNull);
      expect(o.branches, isNotEmpty);
    });
  });

  group('branchIssuesMessage（阻塞码→人话，官方 shared/git.ts 全集）', () {
    test('未提交改动会被覆盖 → 指路桌面端', () {
      final m = branchIssuesMessage([
        {'code': 'tracked-changes-would-be-overwritten', 'message': 'raw'},
      ]);
      expect(m, contains('未提交改动'));
      expect(m, contains('桌面端'));
    });

    test('全码表有映射（无一条漏到 raw）', () {
      const codes = [
        'tracked-changes-would-be-overwritten',
        'untracked-changes-would-be-overwritten',
        'conflicts-present',
        'operation-in-progress',
        'branch-in-other-worktree',
        'target-branch-not-found',
        'branch-already-exists',
        'invalid-branch-name',
      ];
      for (final c in codes) {
        final m = branchIssuesMessage([
          {'code': c, 'message': 'SHOULD_NOT_APPEAR'},
        ]);
        expect(m.contains('SHOULD_NOT_APPEAR'), isFalse, reason: c);
        expect(m.trim().isNotEmpty, isTrue, reason: c);
      }
    });

    test('未知码 → 官方 message 原文兜底', () {
      final m = branchIssuesMessage([
        {'code': 'brand-new-code', 'message': '官方新阻塞原因'},
      ]);
      expect(m, '官方新阻塞原因');
    });

    test('空 issues → 通用失败文案', () {
      expect(branchIssuesMessage(const []).contains('失败'), isTrue);
    });
  });

  group('fetchGitOverview（调用缝）', () {
    test('非仓库短路：不拉分支列表', () async {
      final stub = _StubGit()..repoInfo = _repoInfo(kind: 'not-repository');
      final o = await fetchGitOverview(stub.call, r'G:\demo');
      expect(o.isRepository, isFalse);
      expect(stub.calls.map((c) => c.$1), ['getWorkspaceRepositoryInfo']);
    });

    test('仓库 → 两步调用，workspacePath 逐字传对（官方按路径寻址）', () async {
      final stub = _StubGit();
      final o = await fetchGitOverview(stub.call, r'G:\demo');
      expect(o.isRepository, isTrue);
      expect(o.currentBranch, 'main');
      expect(stub.calls.map((c) => c.$1), [
        'getWorkspaceRepositoryInfo',
        'getLocalBranches',
      ]);
      for (final c in stub.calls) {
        expect(c.$2['workspacePath'], r'G:\demo');
      }
    });
  });

  group('分支弹层旅程（widget，fixture 注入）', () {
    testWidgets('列表+当前标记+upstream 副行', (tester) async {
      final stub = _StubGit();
      await _openSheet(tester, stub);
      expect(find.byKey(const ValueKey('branch-list')), findsOneWidget);
      expect(find.text('main'), findsOneWidget);
      expect(find.text('dev'), findsOneWidget);
      expect(find.text('feature/x'), findsOneWidget);
      expect(find.text('当前'), findsOneWidget);
      expect(find.text('origin/feature/x'), findsOneWidget);
    });

    testWidgets('点非当前分支 → 切换调用形状+成功提示+列表翻新', (tester) async {
      final stub = _StubGit();
      await _openSheet(tester, stub);
      await tester.tap(find.byKey(const ValueKey('branch-item-dev')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      // SnackBar 断言教训：固定时长泵，禁 pumpAndSettle。
      expect(find.textContaining('已切换到 dev'), findsOneWidget);
      final sw = stub.calls.where((c) => c.$1 == 'switchBranch').toList();
      expect(sw.length, 1);
      expect(sw.first.$2['targetBranchName'], 'dev');
      expect(sw.first.$2['workspacePath'], r'G:\demo');
      // 重新加载后的列表：dev 现为当前。
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('branch-item-dev')), findsOneWidget);
      expect(stub.branches['currentBranchName'], 'dev');
    });

    testWidgets('运行中任务>0 → 先二次确认；取消不发调用', (tester) async {
      final stub = _StubGit();
      await _openSheet(tester, stub, running: 2);
      await tester.tap(find.byKey(const ValueKey('branch-item-dev')));
      await tester.pump();
      expect(find.textContaining('2 个运行中任务'), findsOneWidget);
      expect(find.byKey(const ValueKey('branch-confirm-cancel')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('branch-confirm-cancel')));
      await tester.pump();
      expect(stub.calls.where((c) => c.$1 == 'switchBranch'), isEmpty);
    });

    testWidgets('确认门放行 → 切换照常', (tester) async {
      final stub = _StubGit();
      await _openSheet(tester, stub, running: 1);
      await tester.tap(find.byKey(const ValueKey('branch-item-dev')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('branch-confirm-ok')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(stub.calls.where((c) => c.$1 == 'switchBranch').length, 1);
      expect(find.textContaining('已切换到 dev'), findsOneWidget);
    });

    testWidgets('阻塞码（未提交改动）→ 人话弹窗不出现成功提示', (tester) async {
      final stub = _StubGit()
        ..mutationResult = {
          'ok': false,
          'didChange': false,
          'issues': [
            {'code': 'tracked-changes-would-be-overwritten', 'message': 'raw'},
          ],
        };
      await _openSheet(tester, stub);
      await tester.tap(find.byKey(const ValueKey('branch-item-dev')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('branch-issue-ok')), findsOneWidget);
      expect(find.textContaining('未提交改动'), findsOneWidget);
      expect(find.textContaining('已切换到'), findsNothing);
    });

    testWidgets('新建分支并切换：输入名→调用形状+成功', (tester) async {
      final stub = _StubGit();
      await _openSheet(tester, stub);
      await tester.tap(find.byKey(const ValueKey('branch-create-entry')));
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('branch-create-input')),
        'feature/new',
      );
      await tester.tap(find.byKey(const ValueKey('branch-create-ok')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final cr = stub.calls.where((c) => c.$1 == 'createBranchAndSwitch').toList();
      expect(cr.length, 1);
      expect(cr.first.$2['branchName'], 'feature/new');
      expect(cr.first.$2['workspacePath'], r'G:\demo');
      expect(find.textContaining('已切换到 feature/new'), findsOneWidget);
    });

    testWidgets('新建分支名已存在 → 映射人话', (tester) async {
      final stub = _StubGit()
        ..mutationResult = {
          'ok': false,
          'didChange': false,
          'issues': [
            {'code': 'branch-already-exists', 'message': 'raw'},
          ],
        };
      await _openSheet(tester, stub);
      await tester.tap(find.byKey(const ValueKey('branch-create-entry')));
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('branch-create-input')),
        'main',
      );
      await tester.tap(find.byKey(const ValueKey('branch-create-ok')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('分支名已存在'), findsOneWidget);
    });

    testWidgets('非 git 仓库 → 降级态文案', (tester) async {
      final stub = _StubGit()..repoInfo = _repoInfo(kind: 'not-repository');
      await _openSheet(tester, stub);
      expect(find.textContaining('不是 git 仓库'), findsOneWidget);
      // 新建入口随之禁用（非仓库无分支可建）。
      expect(
        tester.widget<IconButton>(
          find.byKey(const ValueKey('branch-create-entry')),
        ).onPressed,
        isNull,
      );
    });

    testWidgets('加载失败 → 错误态+重试', (tester) async {
      final stub = _StubGit()..throwOn = StateError('桥降级');
      await _openSheet(tester, stub);
      expect(find.textContaining('加载失败'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
      stub.throwOn = null;
      await tester.tap(find.text('重试'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('branch-list')), findsOneWidget);
    });

    testWidgets('点当前分支 → 无切换调用（幂等防误触）', (tester) async {
      final stub = _StubGit();
      await _openSheet(tester, stub);
      await tester.tap(find.byKey(const ValueKey('branch-item-main')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(stub.calls.where((c) => c.$1 == 'switchBranch'), isEmpty);
    });
  });

  group('会话页顶栏入口（draft 页真实旅程）', () {
    testWidgets('chip 懒加载→点按开弹层→确认门→切换后 chip 翻新', (tester) async {
      final app = _EntryApp();
      await tester.pumpWidget(
        AppStateScope(
          app: app,
          child: const MaterialApp(
            home: ConversationPage(sessionId: null, title: '新会话'),
          ),
        ),
      );
      // 懒加载完成（固定时长泵，draft 页有常驻动效不走 pumpAndSettle）。
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('branch-entry')), findsOneWidget);
      expect(find.descendant(
        of: find.byKey(const ValueKey('branch-entry')),
        matching: find.text('main'),
      ), findsOneWidget);

      // 点 chip 开弹层（用户入口 finder 真实命中）。
      await tester.tap(find.byKey(const ValueKey('branch-entry')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('branch-list')), findsOneWidget);

      // 该工作区有 1 个运行中任务 → 切换先过确认门。
      await tester.tap(find.byKey(const ValueKey('branch-item-dev')));
      await tester.pump();
      expect(find.textContaining('1 个运行中任务'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('branch-confirm-ok')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('已切换到 dev'), findsOneWidget);

      // 关掉弹层：顶栏 chip 已翻新为 dev（onChanged 回写）。
      Navigator.of(tester.element(find.byKey(const ValueKey('branch-list'))))
          .pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('branch-entry')),
          matching: find.text('dev'),
        ),
        findsOneWidget,
      );
    });
  });
}

/// 会话页入口旅程的 AppState 覆写（git 通道缝+活跃工作区+readTree 全集）。
class _EntryApp extends AppState {
  final _StubGit stub = _StubGit();

  @override
  Map<String, dynamic>? get activeWorkspace => {
        'workspacePath': r'G:\demo',
        'workspaceIdentity': r'G:\demo',
        'label': '示例工作区',
      };

  @override
  Future<dynamic> gitChannelCall(String method, List<Object?> args) =>
      stub.call(method, args);

  @override
  List<Map<String, dynamic>> get projectTasks => [
        {
          'taskId': 'r1',
          'title': '运行中任务',
          'workspaceIdentity': r'G:\demo',
          'displayStatus': 'running',
        },
        {
          'taskId': 'i1',
          'title': '空闲任务',
          'workspaceIdentity': r'G:\demo',
          'displayStatus': 'completed',
        },
      ];
}
