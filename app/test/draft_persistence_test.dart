import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:zcode_pocket/transport/channel_client.dart';
import 'package:zcode_pocket/transport/companion_client.dart';
import 'package:zcode_pocket/transport/rpc_frame_transport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/state/draft_store.dart';
import 'package:zcode_pocket/transport/conversation.dart';
import 'package:zcode_pocket/transport/z_transport.dart';

import 'dart:ui' as ui;

import 'package:zcode_pocket/ui/attachment_annotate_page.dart';
import 'package:zcode_pocket/ui/attachments_compose.dart';
import 'package:zcode_pocket/ui/conversation_page.dart';

class _MemoryDraftStore extends DraftStore {
  _MemoryDraftStore([Map<String, ComposerDraft>? initial])
    : _data = {...?initial},
      super(Directory.systemTemp);

  final Map<String, ComposerDraft> _data;

  _MemoryDraftStore fork() => _MemoryDraftStore(_data);

  @override
  Future<ComposerDraft?> read(DraftIdentity identity) async =>
      _data[identity.key];

  @override
  Future<void> save(ComposerDraft draft) async {
    final current = _data[draft.identity.key];
    if (current != null && draft.revision < current.revision) return;
    if (draft.hasRecoverableContent) {
      _data[draft.identity.key] = draft;
    } else {
      _data.remove(draft.identity.key);
    }
  }

  @override
  Future<void> delete(DraftIdentity identity, {int? expectedRevision}) async {
    if (expectedRevision != null &&
        _data[identity.key]?.revision != expectedRevision) {
      return;
    }
    _data.remove(identity.key);
  }

  @override
  Future<void> removeDevice(String deviceSid) async {
    _data.removeWhere((_, draft) => draft.identity.deviceSid == deviceSid);
  }

  @override
  Future<void> removeSession(String deviceSid, String sessionId) async {
    _data.removeWhere(
      (_, draft) =>
          draft.identity.deviceSid == deviceSid &&
          draft.identity.scopeId == 'session:$sessionId',
    );
  }

  @override
  Future<void> flush() async {}

  @override
  Future<void> close() async {}
}

class _CountingDraftStore extends _MemoryDraftStore {
  int flushCalls = 0;
  @override
  Future<void> flush() async {
    flushCalls++;
  }
}

class _GatedReadDraftStore extends _MemoryDraftStore {
  Completer<void>? readGate;

  @override
  Future<ComposerDraft?> read(DraftIdentity identity) async {
    await readGate?.future;
    return super.read(identity);
  }
}

class _DraftSub implements ConversationSubscription {
  _DraftSub(this.sessionId);
  @override
  final String sessionId;
  @override
  final ConversationState state = ConversationState();
  @override
  bool get hasLiveFrames => true;
  @override
  String? get subscriptionId => 'sub-$sessionId';
  @override
  bool get isDisposed => false;
  @override
  String get topic => 'conversation/$sessionId';
  @override
  Future<void> dispose() async {}
}

class _SendTestBridge implements BridgeSession {
  @override
  Map<String, dynamic>? get projectIntent => null;
  @override
  Map<String, dynamic>? get taskIntent => null;
  @override
  final ValueNotifier<String?> degraded = ValueNotifier(null);
  @override
  final ValueNotifier<int> recovered = ValueNotifier(0);
  @override
  Future<void> waitHealthy({
    Duration timeout = const Duration(seconds: 45),
  }) async {}
  @override
  Map<String, dynamic> get bridge => const {};
  @override
  RpcFrameTransport get transport => throw UnimplementedError();
  @override
  ChannelClient get channels => throw UnimplementedError();
  @override
  String? get workspaceKey => 'ws-send-test';
  @override
  String? get initialTaskId => null;
  @override
  ConversationTransport conversation(
    Map<String, dynamic> scope, {
    void Function(String line)? onLog,
  }) => throw UnimplementedError();
  @override
  void dispose() {}
}

class _DraftApp extends AppState {
  // 断网排队批（2026-10-29）：无桥发送会改道入队——这些用例的语义是
  // 「已连接但发送失败/在途」，补桥保持原路径。
  @override
  BridgeSession? get bridge => _SendTestBridge();

  _DraftApp(
    DraftStore store, {
    this.createdSessionId = 's-created',
    this.createGate,
    this.createError,
    this.sendGate,
    this.sendResult = const {'status': 'accepted'},
    this.accountGate,
    this.attachmentReadError,
    this.attachmentBytes,
    String account = 'account-a',
    String device = 'device-a',
    this.project = 'project-a',
  }) : super(draftStore: store) {
    activeProfile = AccountV2Profile(
      deviceSid: device,
      accountId: account,
      label: '测试电脑',
      addedAt: DateTime.fromMillisecondsSinceEpoch(0),
    );
  }

  final String createdSessionId;
  final Completer<String>? createGate;
  final Object? createError;
  Completer<dynamic>? sendGate;
  dynamic sendResult;
  final Completer<String?>? accountGate;
  Object? attachmentReadError;
  List<int>? attachmentBytes;
  final String project;
  late final sub = _DraftSub('s1');
  int createCalls = 0;
  final sendCalls = <List<Map<String, dynamic>>?>[];
  final sendTexts = <String>[];

  /// #8：确权回捞桩（hasLastCommandRecord/queryLastSentCommand）。
  bool lastCommandRecord = true;
  dynamic lastCommandQueryResult;

  /// #9：held 二选一弹层所需的 inputRouting/queue 等快照字段。
  Map<String, dynamic> extraSnapshot = const {};

  @override
  Map<String, dynamic>? get activeWorkspace => const {
    'workspaceIdentity': 'workspace-test',
    'workspacePath': '/example-workspace',
  };

  @override
  String? get activeProjectId => project;

  @override
  Future<String?> activeDraftAccountId() {
    if (accountGate != null) return accountGate!.future;
    return super.activeDraftAccountId();
  }

  @override
  Future<({List<int> bytes, String? mediaType})> attachmentRead(
    String sessionId,
    String ref, {
    Map<String, dynamic>? target,
    int? attachmentIndex,
  }) async {
    if (attachmentReadError != null) throw attachmentReadError!;
    return (bytes: attachmentBytes ?? const <int>[], mediaType: null);
  }

  @override
  Future<ConversationSubscription> ensureConversation(String sessionId,
      {Object? seedCacheEntry}) async {
    sub.state.applySeed(
      ConversationSeed(
        rows: const [],
        logEpoch: 'e1',
        seq: 0,
        firstRowId: null,
        totalCount: 0,
        snapshot: {
          'title': '草稿测试',
          'control': {'phase': 'completed'},
          ...extraSnapshot,
        },
      ),
    );
    return sub;
  }

  @override
  Future<String> createSession(
    String? firstText, {
    Map<String, dynamic>? config,
  }) async {
    createCalls++;
    if (createGate != null) return createGate!.future;
    if (createError != null) throw createError!;
    return createdSessionId;
  }

  @override
  Future<dynamic> sendText(
    String sessionId,
    String text, {
    Map<String, dynamic>? modelSelection,
    String? mode,
    bool? planEnabled,
    List<Map<String, dynamic>>? attachments,
    String? heldQueueDisposition,
    List<String>? expectedHeldQueueItemIds,
    String? replayCommandId,
  }) async {
    sendCalls.add(attachments);
    sendTexts.add(text);
    if (sendGate != null) return sendGate!.future;
    return sendResult;
  }

  @override
  bool hasLastCommandRecord(String sessionId) => lastCommandRecord;

  @override
  Future<dynamic> queryLastSentCommand(String sessionId) async =>
      lastCommandQueryResult;
}

Widget _host(_DraftApp app, String? sessionId) => AppStateScope(
  app: app,
  child: MaterialApp(
    theme: buildAppTheme(),
    home: ConversationPage(
      key: ValueKey('${identityHashCode(app)}-${sessionId ?? 'draft'}'),
      sessionId: sessionId,
      title: '草稿测试',
    ),
  ),
);

Future<void> _pump(WidgetTester tester, [int frames = 10]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

String _input(WidgetTester tester) => tester
    .widget<TextField>(find.byKey(const ValueKey('chat-input')))
    .controller!
    .text;

DraftIdentity _id({
  String device = 'device-a',
  String account = 'account-a',
  String session = 's1',
}) => DraftIdentity.session(
  deviceSid: device,
  accountId: account,
  workspaceKey: 'workspace-test',
  sessionId: session,
);

DraftIdentity _newDraft({String project = 'project-a'}) =>
    DraftIdentity.newDraft(
      deviceSid: 'device-a',
      accountId: 'account-a',
      workspaceKey: 'workspace-test',
      projectId: project,
    );

void main() {
  test('退后台立即 flush 草稿，不等 90 秒断连定时器', () {
    final store = _CountingDraftStore();
    final app = _DraftApp(store);
    app.onAppPaused();
    expect(store.flushCalls, 1);
    app.dispose();
  });

  testWidgets('杀进程式重建恢复正文，会话与账号不串稿', (tester) async {
    final firstStore = _MemoryDraftStore();
    final first = _DraftApp(firstStore);
    await tester.pumpWidget(_host(first, 's1'));
    await _pump(tester);
    await tester.enterText(find.byKey(const ValueKey('chat-input')), '会话 A 草稿');
    await _pump(tester);
    await firstStore.flush();
    expect((await firstStore.read(_id()))?.text, '会话 A 草稿');
    await tester.pumpWidget(const SizedBox());

    final restartedStore = firstStore.fork();
    final restarted = _DraftApp(restartedStore);
    await tester.pumpWidget(_host(restarted, 's1'));
    await _pump(tester);
    expect(_input(tester), '会话 A 草稿');

    await tester.pumpWidget(_host(restarted, 's2'));
    await _pump(tester);
    expect(_input(tester), isEmpty);

    final otherAccount = _DraftApp(restartedStore, account: 'account-b');
    await tester.pumpWidget(_host(otherAccount, 's1'));
    await _pump(tester);
    expect(_input(tester), isEmpty);
    await restartedStore.close();
  });

  testWidgets('新建草稿跨重建恢复且不同项目不串稿', (tester) async {
    final store = _MemoryDraftStore();
    final app = _DraftApp(store);
    await tester.pumpWidget(_host(app, null));
    await _pump(tester);
    await tester.enterText(find.byKey(const ValueKey('chat-input')), '项目草稿');
    await _pump(tester);
    await store.flush();
    await tester.pumpWidget(const SizedBox());

    final restartedStore = store.fork();
    await tester.pumpWidget(_host(_DraftApp(restartedStore), null));
    await _pump(tester);
    expect(_input(tester), '项目草稿');

    await tester.pumpWidget(
      _host(_DraftApp(restartedStore, project: 'project-b'), null),
    );
    await _pump(tester);
    expect(_input(tester), isEmpty);
  });

  testWidgets('新建发送等待期新输入迁移到正式会话', (tester) async {
    final gate = Completer<String>();
    final store = _MemoryDraftStore();
    final app = _DraftApp(store, createGate: gate, createdSessionId: 's-new');
    await tester.pumpWidget(_host(app, null));
    await _pump(tester);
    await tester.enterText(find.byKey(const ValueKey('chat-input')), '首条原文');
    await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('send-button')));
    await tester.pump();
    await tester.enterText(find.byKey(const ValueKey('chat-input')), '等待期新输入');
    await _pump(tester);
    gate.complete('s-new');
    await _pump(tester, 15);

    expect(_input(tester), '等待期新输入');
    expect(await store.read(_newDraft()), isNull);
    expect((await store.read(_id(session: 's-new')))?.text, '等待期新输入');

    await store.flush();
    await tester.pumpWidget(const SizedBox());
    final restartedStore = store.fork();
    final restarted = _DraftApp(restartedStore);
    await tester.pumpWidget(_host(restarted, 's-new'));
    await _pump(tester);
    expect(_input(tester), '等待期新输入');
    await restartedStore.close();
  });

  testWidgets('发送明确接受后清稿，失败则原文与新输入都跨重启保留', (tester) async {
    final store = _MemoryDraftStore();
    final success = _DraftApp(store);
    await tester.pumpWidget(_host(success, 's1'));
    await _pump(tester);
    await tester.enterText(find.byKey(const ValueKey('chat-input')), '会被接受');
    await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('send-button')));
    await _pump(tester, 12);
    expect(await store.read(_id()), isNull);

    final gate = Completer<String>();
    final failure = _DraftApp(store, createGate: gate);
    await tester.pumpWidget(_host(failure, null));
    await _pump(tester);
    await tester.enterText(find.byKey(const ValueKey('chat-input')), '失败原文');
    await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('send-button')));
    await tester.pump();
    await tester.enterText(find.byKey(const ValueKey('chat-input')), '失败后的新输入');
    await _pump(tester);
    gate.completeError(StateError('injected'));
    await _pump(tester, 12);
    expect(_input(tester), '失败后的新输入');
    expect(find.byKey(const ValueKey('restore-unsent')), findsOneWidget);
    await store.flush();

    await tester.pumpWidget(const SizedBox());
    final restartedStore = store.fork();
    final restarted = _DraftApp(restartedStore);
    await tester.pumpWidget(_host(restarted, null));
    await _pump(tester);
    expect(_input(tester), '失败后的新输入');
    expect(find.byKey(const ValueKey('restore-unsent')), findsOneWidget);
    final saved = await restartedStore.read(_newDraft());
    expect(saved?.unsentText, '失败原文');
    await restartedStore.close();
  });

  testWidgets('恢复附件：上传引用可发，失效本地附件明确拦截并可移除', (tester) async {
    final store = _MemoryDraftStore();
    final id = _id();
    await store.save(
      ComposerDraft(
        identity: id,
        text: '带附件',
        attachments: const [
          DraftAttachment(
            fileName: 'ready.txt',
            mime: 'text/plain',
            byteSize: 12,
            reference: {
              'ref': 'att-ready',
              'fileName': 'ready.txt',
              'mime': 'text/plain',
              'bytes': 12,
            },
          ),
          DraftAttachment(
            fileName: 'local.txt',
            mime: 'text/plain',
            byteSize: 20,
          ),
        ],
        updatedAt: 1,
        revision: 1,
      ),
    );
    await store.flush();
    final app = _DraftApp(store);
    await tester.pumpWidget(_host(app, 's1'));
    await _pump(tester);
    expect(find.textContaining('ready.txt'), findsOneWidget);
    expect(find.textContaining('源文件已失效，请重新选择'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('send-button')));
    await _pump(tester);
    expect(app.sendCalls, isEmpty);
    expect(find.textContaining('附件需重新选择'), findsOneWidget);
    expect(_input(tester), '带附件');

    await tester.tap(
      find.byKey(const ValueKey('pending-attachment-remove-restored-1-1')),
    );
    await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('send-button')));
    await _pump(tester, 12);
    expect(app.sendCalls, hasLength(1));
    expect(app.sendCalls.single?.single['ref'], 'att-ready');
    expect(await store.read(id), isNull);
  });

  testWidgets('旧页面迟到 accepted 不得删除重开页面的新草稿', (tester) async {
    final store = _MemoryDraftStore();
    final gate = Completer<dynamic>();
    final oldApp = _DraftApp(store, sendGate: gate);
    await tester.pumpWidget(_host(oldApp, 's1'));
    await _pump(tester);
    await tester.enterText(find.byKey(const ValueKey('chat-input')), '旧提交');
    await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('send-button')));
    await tester.pump();
    expect(
      tester
          .widget<IconButton>(find.byKey(const ValueKey('add-trigger')))
          .onPressed,
      isNull,
    );
    await tester.pumpWidget(const SizedBox());

    final newApp = _DraftApp(store);
    await tester.pumpWidget(_host(newApp, 's1'));
    await _pump(tester);
    expect(_input(tester), '旧提交');
    await tester.enterText(find.byKey(const ValueKey('chat-input')), '重开后的新草稿');
    await _pump(tester);
    gate.complete({'status': 'accepted'});
    await _pump(tester, 12);
    expect((await store.read(_id()))?.text, '重开后的新草稿');
  });

  testWidgets('恢复读取期间的输入与旧正文/失败暂存/附件合并而非覆盖', (tester) async {
    final store = _GatedReadDraftStore();
    await store.save(
      ComposerDraft(
        identity: _id(),
        text: '旧正文',
        unsentText: '旧失败暂存',
        attachments: const [
          DraftAttachment(
            fileName: 'old.txt',
            mime: 'text/plain',
            byteSize: 4,
            reference: {'ref': 'old-ref'},
          ),
        ],
        updatedAt: 1,
        revision: 4,
      ),
    );
    store.readGate = Completer<void>();
    final app = _DraftApp(store);
    await tester.pumpWidget(_host(app, 's1'));
    await tester.pump();
    await tester.enterText(find.byKey(const ValueKey('chat-input')), '恢复期间新输入');
    store.readGate!.complete();
    await _pump(tester);
    expect(_input(tester), contains('旧正文'));
    expect(_input(tester), contains('恢复期间新输入'));
    expect(find.byKey(const ValueKey('restore-unsent')), findsOneWidget);
    expect(find.textContaining('old.txt'), findsOneWidget);
    final saved = await store.read(_id());
    expect(saved?.text, contains('旧正文'));
    expect(saved?.text, contains('恢复期间新输入'));
    expect(saved?.unsentText, '旧失败暂存');
    expect(saved?.attachments.single.reference?['ref'], 'old-ref');
  });

  testWidgets('畸形 ACK 不清稿，明确显示发送失败', (tester) async {
    final store = _MemoryDraftStore();
    final app = _DraftApp(store, sendResult: null);
    await tester.pumpWidget(_host(app, 's1'));
    await _pump(tester);
    await tester.enterText(find.byKey(const ValueKey('chat-input')), '不能丢');
    await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('send-button')));
    await _pump(tester, 12);
    expect(find.textContaining('发送结果缺少有效状态'), findsOneWidget);
    expect((await store.read(_id()))?.text, '不能丢');
  });

  testWidgets('create 已接受但预订阅失败保留 sessionId，不重复创建', (tester) async {
    final store = _MemoryDraftStore();
    final app = _DraftApp(
      store,
      createError: SessionCreatedSubscriptionError(
        's-created',
        StateError('subscribe failed'),
      ),
    );
    await tester.pumpWidget(_host(app, null));
    await _pump(tester);
    await tester.enterText(find.byKey(const ValueKey('chat-input')), '只发一次');
    await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('send-button')));
    await _pump(tester, 15);
    expect(app.createCalls, 1);
    expect(app.sendTexts, isEmpty);
    expect(_input(tester), isEmpty);
    expect(await store.read(_id(session: 's-created')), isNull);
    expect(await store.read(_newDraft()), isNull);
  });

  testWidgets('连续失败不覆盖更早暂存，结果未知与附件-only 也能恢复', (tester) async {
    final store = _MemoryDraftStore();
    final firstGate = Completer<dynamic>();
    final app = _DraftApp(store, sendGate: firstGate);
    await tester.pumpWidget(_host(app, 's1'));
    await _pump(tester);
    await tester.enterText(find.byKey(const ValueKey('chat-input')), 'A');
    await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('send-button')));
    await tester.pump();
    await tester.enterText(find.byKey(const ValueKey('chat-input')), 'B');
    firstGate.completeError(StateError('first'));
    await _pump(tester, 12);

    final secondGate = Completer<dynamic>();
    app.sendGate = secondGate;
    await tester.tap(find.byKey(const ValueKey('send-button')));
    await tester.pump();
    await tester.enterText(find.byKey(const ValueKey('chat-input')), 'C');
    secondGate.completeError(StateError('second'));
    await _pump(tester, 12);
    final saved = await store.read(_id());
    expect(saved?.text, 'C');
    expect(saved?.unsentText, contains('A'));
    expect(saved?.unsentText, contains('B'));

    final unknownStore = _MemoryDraftStore();
    await unknownStore.save(
      ComposerDraft(
        identity: _id(),
        text: '',
        attachments: const [
          DraftAttachment(
            fileName: 'only.txt',
            mime: 'text/plain',
            byteSize: 1,
            reference: {'ref': 'only-ref'},
          ),
        ],
        updatedAt: 1,
        revision: 1,
        submissionInFlight: true,
      ),
    );
    await tester.pumpWidget(_host(_DraftApp(unknownStore), 's1'));
    await _pump(tester);
    expect(find.textContaining('only.txt'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('draft-submission-unknown')),
      findsOneWidget,
    );
  });

  testWidgets('账号身份晚解析时离页，离开前正文仍完成保存', (tester) async {
    final store = _MemoryDraftStore();
    final accountGate = Completer<String?>();
    final app = _DraftApp(store, accountGate: accountGate);
    await tester.pumpWidget(_host(app, 's1'));
    await tester.pump();
    await tester.enterText(find.byKey(const ValueKey('chat-input')), '离页前输入');
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    accountGate.complete('account-a');
    await _pump(tester);
    expect((await store.read(_id()))?.text, '离页前输入');
  });

  testWidgets('服务端确认附件引用失效后转为明确重选状态并拦截发送', (tester) async {
    final store = _MemoryDraftStore();
    await store.save(
      ComposerDraft(
        identity: _id(),
        text: '带失效引用',
        attachments: const [
          DraftAttachment(
            fileName: 'stale.txt',
            mime: 'text/plain',
            byteSize: 10,
            reference: {'ref': 'stale-ref'},
          ),
        ],
        updatedAt: 1,
        revision: 1,
      ),
    );
    final app = _DraftApp(
      store,
      attachmentReadError: StateError('attachment not found'),
    );
    await tester.pumpWidget(_host(app, 's1'));
    await _pump(tester);
    expect(find.textContaining('附件引用已失效，请重新选择'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('send-button')));
    await _pump(tester);
    expect(app.sendCalls, isEmpty);
    expect(_input(tester), '带失效引用');
  });

  testWidgets('恢复图片附件：订阅就绪后取回缩略图，失败占位保留文件名', (tester) async {
    const png =
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';
    Future<_MemoryDraftStore> seed() async {
      final store = _MemoryDraftStore();
      await store.save(
        ComposerDraft(
          identity: _id(),
          text: '图片草稿',
          attachments: const [
            DraftAttachment(
              fileName: 'preview.png',
              mime: 'image/png',
              byteSize: 68,
              reference: {'ref': 'preview-ref'},
            ),
          ],
          updatedAt: 1,
          revision: 1,
        ),
      );
      return store;
    }

    final okStore = await seed();
    await tester.pumpWidget(
      _host(_DraftApp(okStore, attachmentBytes: base64Decode(png)), 's1'),
    );
    await _pump(tester);
    expect(find.byType(Image), findsWidgets);

    final failStore = await seed();
    await tester.pumpWidget(
      _host(
        _DraftApp(
          failStore,
          attachmentReadError: StateError('network unavailable'),
        ),
        's1',
      ),
    );
    await _pump(tester, 20);
    expect(find.textContaining('preview.png'), findsWidgets,
        reason: '入口 chip 与（可能的）展开预览各一份，≥1 即可');
    expect(find.textContaining('已上传'), findsWidgets,
        reason: '附件行状态标记，≥1 即可');
  });

  testWidgets('附件读取前几次失败后，后续状态帧恢复仍能取回预览', (tester) async {
    const png =
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';
    final store = _MemoryDraftStore();
    await store.save(
      ComposerDraft(
        identity: _id(),
        text: '图片草稿',
        attachments: const [
          DraftAttachment(
            fileName: 'retry.png',
            mime: 'image/png',
            byteSize: 68,
            reference: {'ref': 'retry-ref'},
          ),
        ],
        updatedAt: 1,
        revision: 1,
      ),
    );
    final app = _DraftApp(
      store,
      attachmentReadError: StateError('network unavailable'),
    );
    await tester.pumpWidget(_host(app, 's1'));
    await _pump(tester);
    expect(find.byType(Image), findsNothing);

    app.attachmentReadError = null;
    app.attachmentBytes = base64Decode(png);
    for (var i = 0; i < 5; i++) {
      app.sub.state.dataVersion++;
      app.sub.state.notifyListeners();
      await tester.pump(const Duration(milliseconds: 100));
    }
    await _pump(tester);
    expect(find.byType(Image), findsWidgets);
  });

  testWidgets('标注入口→编辑器→保存：替换字节并作废上传引用', (tester) async {
    const png =
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';
    final store = _MemoryDraftStore();
    await store.save(
      ComposerDraft(
        identity: _id(),
        text: '标注草稿',
        attachments: const [
          DraftAttachment(
            fileName: 'shot.png',
            mime: 'image/png',
            byteSize: 68,
            reference: {'ref': 'shot-ref'},
          ),
        ],
        updatedAt: 1,
        revision: 1,
      ),
    );
    final app = _DraftApp(store, attachmentBytes: base64Decode(png));
    await tester.pumpWidget(_host(app, 's1'));
    await _pump(tester);
    // 取回字节后入口出现（恢复图无字节时不出现）。
    final entry = find.byKey(
      const ValueKey('pending-attachment-annotate-restored-1-0'),
    );
    expect(entry, findsOneWidget);

    await tester.runAsync(() async {
      AttachmentAnnotatePage.debugImage = await _decodePng(base64Decode(png));
    });
    // 静态缝复位：与 attachment_annotate_test/游览
    // S28 两处既有写法对齐——此前未复位且恰因本用例是文件最后一个 test
    // 被位置掩盖，其后新增用例会继承预置底图/笔迹，出现"只在加测试后
    // 出现"的诡异失败。
    addTearDown(() {
      AttachmentAnnotatePage.debugImage = null;
      AttachmentAnnotatePage.debugInitialStrokes = null;
    });
    AttachmentAnnotatePage.debugInitialStrokes = const [
      AnnotateStroke(
        color: Color(0xFFE5484D),
        width: 3,
        points: [Offset(10, 10), Offset(50, 40)],
      ),
    ];
    await tester.tap(entry);
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byKey(const ValueKey('annotate-canvas')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('annotate-save')));
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 600));
    });
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final chips = tester.widget<PendingAttachmentChips>(
      find.byType(PendingAttachmentChips),
    );
    final att = chips.attachments.single;
    expect(att.uploaded, isNull, reason: '保存后旧引用必须作废');
    expect(att.progress, -1, reason: '重传排队态');
    expect(att.bytes.length, greaterThan(8), reason: '字节已替换为合成图');
    final saved = await store.read(_id());
    expect(
      saved?.attachments.single.reference,
      isNull,
      reason: '草稿库同步作废引用（重传后才有新引用）',
    );
  });

  // 2026-11-08 对抗审查批 #8（中）：结果未知确权两分支——accepted 后
  // 原文仍留输入框/草稿（再点即重发已送达消息）；failed 后正文不在框、
  // 盘上仍 in-flight。
  testWidgets('确权 accepted：清空输入框并按恢复 revision 删草稿', (tester) async {
    final store = _MemoryDraftStore();
    await store.save(
      ComposerDraft(
        identity: _id(),
        text: '已送达正文',
        attachments: const [],
        updatedAt: 1,
        revision: 1,
        submissionInFlight: true,
      ),
    );
    final app = _DraftApp(store)
      ..lastCommandQueryResult = const {'status': 'accepted'};
    await tester.pumpWidget(_host(app, 's1'));
    await _pump(tester);
    expect(_input(tester), '已送达正文', reason: '恢复 in-flight 稿先把原文放回输入框');
    expect(
      find.byKey(const ValueKey('draft-submission-unknown')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('draft-unknown-recheck')));
    await _pump(tester, 12);

    expect(_input(tester), isEmpty, reason: '已确认送达→原文不得留在输入框');
    expect(await store.read(_id()), isNull,
        reason: '按恢复时 revision 删除草稿（再点发送不会重发已送达消息）');
    // 6s 后横幅自复位的延时器走完（防 pending timer 干扰用例收尾）。
    await tester.pump(const Duration(seconds: 7));
  });

  testWidgets('确权 failed：原文回填输入框，草稿 submissionInFlight=false',
      (tester) async {
    final store = _MemoryDraftStore();
    await store.save(
      ComposerDraft(
        identity: _id(),
        text: '未送达正文',
        attachments: const [],
        updatedAt: 1,
        revision: 1,
        submissionInFlight: true,
      ),
    );
    final app = _DraftApp(store)
      ..lastCommandQueryResult = const {'status': 'failed'};
    await tester.pumpWidget(_host(app, 's1'));
    await _pump(tester);
    // 用户先把输入框清空（正文只剩在草稿/提交态里）。
    await tester.enterText(find.byKey(const ValueKey('chat-input')), '');
    await tester.pump();
    await _pump(tester);
    expect(_input(tester), isEmpty);

    await tester.tap(find.byKey(const ValueKey('draft-unknown-recheck')));
    await _pump(tester, 12);

    expect(_input(tester), '未送达正文', reason: '确认未送达→原文回填可重发');
    final saved = await store.read(_id());
    expect(saved?.text, '未送达正文');
    expect(saved?.submissionInFlight, isFalse,
        reason: '确定性未送达不再标 in-flight');
    expect(
      find.byKey(const ValueKey('draft-submission-unknown')),
      findsNothing,
    );
  });

  // #9（中）：held 二选一被取消曾抛 StateError 落通用 catch——红条
  // 「发送失败：Bad state: 已取消发送」；取消应按和气路径收尾。
  testWidgets('held 二选一点取消=和气取消（不报发送失败、正文回填）',
      (tester) async {
    final store = _MemoryDraftStore();
    final app = _DraftApp(store)
      ..extraSnapshot = {
        'inputRouting': {'mode': 'choice'},
        'queue': {
          'items': [
            {'queueItemId': 'q1'},
          ],
        },
      };
    await tester.pumpWidget(_host(app, 's1'));
    await _pump(tester);
    await tester.enterText(
      find.byKey(const ValueKey('chat-input')),
      '取消的消息',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('send-button')));
    await _pump(tester, 8);
    expect(
      find.byKey(const ValueKey('held-queue-disposition')),
      findsOneWidget,
      reason: 'choice 档先弹二选一',
    );

    // 点遮罩关闭弹层（picked=null）＝用户取消。
    await tester.tapAt(const Offset(10, 10));
    await _pump(tester, 12);

    expect(app.sendCalls, isEmpty, reason: '取消不得发起发送');
    expect(find.textContaining('发送失败'), findsNothing,
        reason: '取消不是发送失败（旧实现红条 Bad state: 已取消发送）');
    expect(find.text('已取消发送'), findsOneWidget, reason: '轻提示');
    expect(_input(tester), '取消的消息', reason: '取消后正文回填输入框');
    final saved = await store.read(_id());
    expect(saved?.text, '取消的消息');
    expect(saved?.submissionInFlight, isFalse,
        reason: '取消后草稿不标 in-flight');
  });
}

Future<ui.Image> _decodePng(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  return (await codec.getNextFrame()).image;
}
