// 1.0.1 真机验收⑤A（用户拍板拆两段）：跨工作区点任务卡→**立即**推入
// 会话页（转圈「正在打开工作区…」），后台完成工作区切换，桥就绪后
// 自动加载。红=旧实现（先 await 切换再 push，慢切换期间无会话页）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/state/draft_store.dart';
import 'package:zcode_pocket/state/send_queue_store.dart';
import 'package:zcode_pocket/transport/companion_client.dart';
import 'package:zcode_pocket/transport/conversation.dart';
import 'package:zcode_pocket/transport/z_transport.dart';
import 'package:zcode_pocket/ui/conversation_page.dart';
import 'package:zcode_pocket/ui/task_center_page.dart';

class _FakeConv implements ConversationTransport {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeBridge implements BridgeSession {
  @override
  Map<String, dynamic>? get projectIntent => null;
  @override
  Map<String, dynamic>? get taskIntent => null;
  @override
  final ValueNotifier<String?> degraded = ValueNotifier(null);
  @override
  final ValueNotifier<int> recovered = ValueNotifier(0);
  @override
  Future<void> waitHealthy({Duration timeout = const Duration(seconds: 45)}) async {}
  @override
  Map<String, dynamic> get bridge => const {};
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 可观测草稿库（#2 高：断言等待期输入落在目标工作区桶）。
class _MemoryDraftStore extends DraftStore {
  _MemoryDraftStore() : super(Directory.systemTemp);
  final Map<String, ComposerDraft> data = {};
  @override
  Future<ComposerDraft?> read(DraftIdentity identity) async =>
      data[identity.key];
  @override
  Future<void> save(ComposerDraft draft) async {
    if (draft.hasRecoverableContent) {
      data[draft.identity.key] = draft;
    } else {
      data.remove(draft.identity.key);
    }
  }

  @override
  Future<void> delete(DraftIdentity identity, {int? expectedRevision}) async {
    if (expectedRevision != null &&
        data[identity.key]?.revision != expectedRevision) {
      return;
    }
    data.remove(identity.key);
  }

  @override
  Future<void> flush() async {}
}

/// 可观测离线队列（#2 高：断言等待期入队桶键=目标工作区）。
class _MemoryQueueStore extends SendQueueStore {
  _MemoryQueueStore() : super(File('nul'));
  final Map<String, List<SendQueueEntry>> data = {};
  @override
  Future<List<SendQueueEntry>> entries(SendQueueBucket bucket) async =>
      List.unmodifiable(data[bucket.key] ?? const []);
  @override
  Future<void> add(SendQueueBucket bucket, SendQueueEntry entry) async {
    data.putIfAbsent(bucket.key, () => []).add(entry);
  }

  @override
  Future<void> remove(SendQueueBucket bucket, String id) async {
    data[bucket.key]?.removeWhere((e) => e.id == id);
  }

  @override
  Future<void> flush() async {}
}

class _SlowSwitchApp extends AppState {
  _SlowSwitchApp(this.drafts, this.queue)
    : super(draftStore: drafts) {
    activeProfile = AccountV2Profile(
      deviceSid: 'device-q',
      accountId: 'account-q',
      label: '测试电脑',
      addedAt: DateTime.fromMillisecondsSinceEpoch(0),
    );
    sendQueue = queue;
  }

  final _MemoryDraftStore drafts;
  final _MemoryQueueStore queue;
  final Completer<void> switchDone = Completer<void>();
  bool switchStarted = false;
  // 对抗审查遗留核实修（2026-11-07）测试缝：等待失败时清首页残留预览。
  String? wsError;
  int previewClears = 0;
  Map<String, dynamic>? _active = const {
    'workspacePath': 'G:/Other',
    'workspaceIdentity': 'ws-other',
  };

  @override
  bool get loaded => true;
  @override
  LinkPhase get phase => LinkPhase.online;
  @override
  ConversationTransport get conversation => _FakeConv();
  @override
  Map<String, dynamic>? get activeWorkspace => _active;
  @override
  String? get workspaceError => wsError;
  @override
  void clearStaleHomePreview() => previewClears++;

  /// 桥随切换完成出现（等待循环的第二个条件）。
  final _fakeBridge = _FakeBridge();
  @override
  BridgeSession? get bridge =>
      _active?['workspaceIdentity'] == 'ws-target' ? _fakeBridge : null;

  @override
  List<Map<String, dynamic>> get workspaces => const [
    {'workspacePath': 'G:/Demo App', 'workspaceIdentity': 'ws-target'},
  ];

  List<Map<String, dynamic>> tasks = const [
    {
      'taskId': 't-cross',
      'title': '跨区任务',
      'workspaceIdentity': 'ws-target',
      'workspacePath': 'G:/Demo App',
      'updatedAt': 1700000000000,
    },
  ];
  @override
  List<Map<String, dynamic>> get workspaceTasks => tasks;
  @override
  List<Map<String, dynamic>> get projectTasks => tasks;
  @override
  List<Map<String, dynamic>> get unclassifiedTasks => tasks;

  @override
  Future<void> switchWorkspace(
    Map<String, dynamic> workspace, {
    bool keepHomePreview = false,
  }) async {
    switchStarted = true;
    await switchDone.future; // 模拟慢开桥
    _active = workspace;
    notifyListeners();
  }
}

Widget _host(AppState app) => AppStateScope(
  app: app,
  child: MaterialApp(theme: buildAppTheme(), home: const TaskCenterPage()),
);

void main() {
  testWidgets('push-first：慢切换期间会话页已在场转圈，桥就绪后加载', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    final app = _SlowSwitchApp(_MemoryDraftStore(), _MemoryQueueStore());
    await tester.pumpWidget(_host(app));
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.text('跨区任务'));
    await tester.pump(const Duration(milliseconds: 300));

    // 红点：切换仍挂起（switchStarted 且未完成）时会话页已推入。
    expect(app.switchStarted, isTrue, reason: '点卡即发起切换');
    expect(
      find.byType(ConversationPage, skipOffstage: false),
      findsOneWidget,
      reason: '⑤A：切换在途即推入会话页（旧实现等切换完才有）',
    );
    expect(
      find.text('正在打开工作区…', skipOffstage: false),
      findsOneWidget,
      reason: '等待期副文案',
    );

    // 桥就绪（切换完成）→ 等待循环退出 → 进入正常订阅/缓存路径。
    app.switchDone.complete();
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }
    expect(find.text('正在打开工作区…'), findsNothing,
        reason: '就绪后退出等待文案');
    expect(tester.takeException(), isNull);
  });

  // 对抗审查遗留核实修（2026-11-07）：等待失败（切换报错/超时）时，
  // 首页 keepHomePreview 保住的旧列表不能再以可用状态示人——页面
  // 错误态就位的同时必须清残留预览（与 task_center 失败路径同语义）。
  testWidgets('等待失败：错误态就位+首页残留预览被清', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    final app = _SlowSwitchApp(_MemoryDraftStore(), _MemoryQueueStore())
      ..wsError = '工作区切换未完成';
    await tester.pumpWidget(_host(app));
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.text('跨区任务'));
    // 两段 pump：先让路由首帧落地（等待循环才能开始观测错误），再走
    // 完 150ms 等待节拍与失败收口。
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 250));
    // 修复前红：页面进了等待但失败后 previewClears 恒 0（旧列表残留）。
    expect(app.previewClears, greaterThan(0), reason: '等待失败清残留预览');
    expect(find.text('正在打开工作区…'), findsNothing,
        reason: '失败后退出等待文案（不再转圈）');
    // #5：失败必须可见（旧实现只写 _syncError，loading 视图只认 _error
    // ——用户停在「正在载入对话历史…」且没有重试钮）。
    expect(find.textContaining('工作区切换未完成'), findsOneWidget,
        reason: '错误文案进入 loading 态 _error');
    expect(find.text('重试'), findsOneWidget, reason: '重试按钮生效');
    expect(tester.takeException(), isNull);
  });

  // #2 高（2026-11-08 对抗审查）：草稿身份旧实现是首帧一次性闩锁——
  // push-first 等待期 activeWorkspace 仍是旧工作区，输入/入队全记错桶。
  testWidgets('等待期输入：草稿键=目标工作区（#2 高）', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    final drafts = _MemoryDraftStore();
    final app = _SlowSwitchApp(drafts, _MemoryQueueStore());
    await tester.pumpWidget(_host(app));
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.text('跨区任务'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byType(ConversationPage, skipOffstage: false), findsOneWidget);

    // 切换仍在途（activeWorkspace 还是旧区）时输入草稿。
    await tester.enterText(find.byKey(const ValueKey('chat-input')), '等待期输入');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final expected = DraftIdentity.session(
      deviceSid: 'device-q',
      accountId: 'account-q',
      workspaceKey: 'ws-target',
      sessionId: 't-cross',
    );
    final wrong = DraftIdentity.session(
      deviceSid: 'device-q',
      accountId: 'account-q',
      workspaceKey: 'ws-other',
      sessionId: 't-cross',
    );
    expect(drafts.data[expected.key]?.text, '等待期输入',
        reason: '身份键必须用目标工作区（waitForWorkspace）');
    expect(drafts.data.containsKey(wrong.key), isFalse,
        reason: '旧实现把等待期输入写进旧工作区桶');

    app.switchDone.complete();
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('等待期断网入队：桶键=目标工作区（#2 高）', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    final queue = _MemoryQueueStore();
    final app = _SlowSwitchApp(_MemoryDraftStore(), queue);
    await tester.pumpWidget(_host(app));
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.text('跨区任务'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 250));
    // 等待期桥未就绪=断连 → 发送入队（不进注定失败的 RPC）。
    await tester.enterText(
      find.byKey(const ValueKey('chat-input')),
      '等待期排队',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('send-button')));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(queue.data, hasLength(1), reason: '一条入队');
    final parts = (jsonDecode(queue.data.keys.single) as List)
        .map((e) => '$e')
        .toList();
    expect(parts[0], 'device-q');
    expect(parts[1], 'account-q');
    expect(parts[2], 'ws-target', reason: '桶键工作区=目标工作区（旧实现=ws-other/null）');
    expect(parts[3], 'session:t-cross');

    app.switchDone.complete();
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }
    expect(tester.takeException(), isNull);
  });
}
