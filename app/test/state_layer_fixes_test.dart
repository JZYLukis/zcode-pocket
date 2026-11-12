// 状态层修复批（2026-11-09，14 路后的全量修复）红绿用例：
// 冷启动通知认目标电脑 / 保活掉线对账水位 / 乐观墓碑撤销与失败清位 /
// 批量删归档按 skipped 清草稿 / 通知权限被拒回弹 / 回前台重报查看态 /
// dispose 收尾 / 账号标签缓存代际 / 常驻文案含置顶运行任务 /
// 契约 clearPendingDeepLink + sidebarProjects 稳定 identity。
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/notify/notification_service.dart';
import 'package:zcode_pocket/state/account_store.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/battery_journal.dart';
import 'package:zcode_pocket/state/computer_stack.dart';
import 'package:zcode_pocket/state/draft_store.dart';
import 'package:zcode_pocket/state/link_phase.dart';
import 'package:zcode_pocket/state/notify_coordinator.dart';
import 'package:zcode_pocket/state/notify_store.dart';
import 'package:zcode_pocket/state/profile_store.dart';
import 'package:zcode_pocket/state/task_list.dart';
import 'package:zcode_pocket/transport/z_transport.dart';
import 'package:zcode_pocket/transport/conversation.dart';

class _ProbeStack extends ComputerStack {
  _ProbeStack(String sid)
    : probeSid = sid,
      super(
        profile: AccountV2Profile(
          deviceSid: sid,
          label: '探针电脑',
          addedAt: DateTime(2026),
        ),
        onLog: (_) {},
        onFailure: (_, _) {},
      );

  final String probeSid;
  List<Map<String, dynamic>> entries = const [];
  TaskListModel? model;
  LinkPhase status = LinkPhase.online;
  Object? archiveError;
  Map<String, dynamic>? deleteArchivedResult;
  final viewReports = <String?>[];

  @override
  List<Map<String, dynamic>> sidebarEntries() => entries;

  @override
  TaskListModel? get taskList => model;

  @override
  LinkPhase computeStatus() => status;

  @override
  Future<void> pokeOrResume() async {}

  @override
  Future<void> resumeTasksIndexFromBackground() async {}

  @override
  Future<void> demote() async {}

  @override
  Future<void> disposeStack() async {}

  @override
  void reportViewState({String? taskId}) {
    viewReports.add(taskId);
  }

  @override
  Future<dynamic> archiveTask(String taskId) async {
    final err = archiveError;
    if (err != null) throw err;
    return const <String, dynamic>{};
  }

  @override
  Future<dynamic> unarchiveTask(String taskId) async =>
      const <String, dynamic>{};

  @override
  Future<dynamic> deleteTask(String taskId) async => const <String, dynamic>{};

  @override
  Future<dynamic> deleteArchivedTasks(List<String> taskIds) async =>
      deleteArchivedResult ?? const <String, dynamic>{};

  void debugPing() => notifyListeners();
}

TaskListModel _readyModel(List<Map<String, dynamic>> active) {
  final model = TaskListModel(
    sessions: SessionsIndexState()..ready = true,
    workspaceKey: 'ws',
  );
  model.applyChannelLists(
    active: active,
    pinnedIds: const [],
    archivedIds: const [],
  );
  return model;
}

class _MemoryProfiles extends ProfileStore {
  _MemoryProfiles(this.items);
  List<DeviceProfile> items;
  String? active;

  @override
  Future<({List<DeviceProfile> profiles, int skipped})>
  listProfilesDetailed() async => (profiles: List.of(items), skipped: 0);

  @override
  Future<DeviceProfile> upsertProfile(DeviceProfile profile) async {
    items = [
      for (final p in items)
        if (p.deviceSid != profile.deviceSid) p,
      profile,
    ];
    return profile;
  }

  @override
  Future<void> updateProfile(DeviceProfile profile) async {
    items = [
      for (final p in items)
        if (p.deviceSid == profile.deviceSid) profile else p,
    ];
  }

  @override
  Future<String?> activeDeviceSid() async => active;

  @override
  Future<void> setActiveDeviceSid(String? deviceSid) async {
    active = deviceSid;
  }
}

class _FakeAccountStore extends AccountStore {
  List<StoredAccount> accounts = const [];

  @override
  Future<List<StoredAccount>> listAccounts() async => accounts;

  @override
  Future<String?> get lastUsedAccountId async =>
      accounts.isEmpty ? null : accounts.first.id;

  @override
  Future<String?> get mostRecentAccountId async =>
      accounts.isEmpty ? null : accounts.first.id;

  @override
  Future<String?> readJwtFor(String? accountId) async => null;
}

/// 冷启动通知用例：activate 只记录不建栈（避免真实连接）。
class _LoadApp extends AppState {
  _LoadApp({
    required super.store,
    super.notifyService,
    super.notifyStore,
    super.accountStore,
  });

  final activated = <String>[];

  @override
  Future<void> activate(DeviceProfile profile) async {
    activated.add(profile.deviceSid);
    activeProfile = profile;
  }
}

class _FakeNotifyService extends NotificationService {
  _FakeNotifyService({this.launch, this.permissionGranted = true})
    : super(backend: _NullBackend());

  final NotifyTapPayload? launch;
  final bool permissionGranted;

  @override
  NotifyTapPayload? consumePendingLaunch() => launch;

  @override
  Future<bool> ensurePermission() async => permissionGranted;
}

class _NullBackend implements NotificationBackend {
  @override
  Future<bool> initialize() async => true;

  @override
  void setTapHandler(void Function(NotifyTapPayload payload)? handler) {}

  @override
  Future<bool> requestPermission() async => true;

  @override
  Future<void> show(
    int id,
    String title,
    String body,
    String channel,
    String payload,
  ) async {}

  @override
  Future<void> cancel(int id) async {}

  @override
  Future<void> cancelAll() async {}

  @override
  Future<List<NotifyActiveEntry>> activeNotifications() async => const [];

  @override
  Future<String?> launchPayload() async => null;
}

class _MemNotifyStore extends NotifyStore {
  _MemNotifyStore(super.baseDir);
  final clicked = <String>[];

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  Future<void> markClicked(String taskId, int atMs) async {
    clicked.add(taskId);
  }
}

class _RecordingDraftStore extends DraftStore {
  _RecordingDraftStore(super.baseDir);
  final removed = <String>[];

  @override
  Future<void> removeSession(String deviceSid, String sessionId) async {
    removed.add(sessionId);
  }

  @override
  Future<void> close() async {}
}

class _ProbeJournal extends BatteryJournal {
  int stopCalls = 0;

  @override
  void stop() {
    stopCalls++;
  }
}

class _GatedAccounts extends AccountStore {
  final completers = <Completer<List<StoredAccount>>>[];

  @override
  Future<List<StoredAccount>> listAccounts() {
    final c = Completer<List<StoredAccount>>();
    completers.add(c);
    return c.future;
  }
}

Future<void> _settle() async {
  for (var i = 0; i < 4; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

AccountV2Profile _v2(String sid, {String? accountId = 'acc-1'}) =>
    AccountV2Profile(
      deviceSid: sid,
      accountId: accountId,
      label: '电脑-$sid',
      addedAt: DateTime(2026),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('契约 API', () {
    test('clearPendingDeepLink 清两字段并通知；已清态幂等零通知', () {
      final app = AppState();
      addTearDown(app.dispose);
      app.pendingDeepLinkAt = 123;
      app.pendingDeepLinkTaskId = 't1';
      var notifications = 0;
      app.addListener(() => notifications++);

      app.clearPendingDeepLink();
      expect(app.pendingDeepLinkAt, isNull);
      expect(app.pendingDeepLinkTaskId, isNull);
      expect(notifications, 1);

      app.clearPendingDeepLink();
      expect(notifications, 1, reason: '幂等：已清态不再通知');
    });

    test('lastCommandIdForDraftRecheck：无活跃传输返回 null', () {
      final app = AppState();
      addTearDown(app.dispose);
      expect(app.lastCommandIdForDraftRecheck(), isNull);
    });

    test('sidebarProjects：源不变返回同一 List 实例；内容变化才换新', () async {
      final app = AppState();
      final stack = _ProbeStack('sid-side');
      stack.entries = [
        {'id': 'p1', 'name': '项目一'},
        {'id': 'p2', 'name': '项目二'},
      ];
      app.debugRegisterStackForTest(stack);
      addTearDown(app.dispose);
      await app.activate(stack.profile);

      final first = app.sidebarProjects;
      final second = app.sidebarProjects;
      // 红：修复前 getter 每次现建 List——任务主页 memo 的 record 判等
      // （List 按 identity）永不命中。
      expect(identical(first, second), isTrue,
          reason: '源未变必须返回同一 List 实例');

      stack.entries = [
        {'id': 'p1', 'name': '改名后'},
        {'id': 'p2', 'name': '项目二'},
      ];
      final third = app.sidebarProjects;
      expect(identical(third, first), isFalse, reason: '内容变化换新实例');
      expect(third.first['name'], '改名后');
    });
  });

  group('冷启动通知', () {
    test('profiles 加载后消费 pendingLaunch：激活目标电脑并补记 markClicked', () async {
      final tmp = await Directory.systemTemp.createTemp('pending-launch');
      addTearDown(() => tmp.delete(recursive: true));
      final profiles = _MemoryProfiles([_v2('sid-a'), _v2('sid-b')])
        ..active = 'sid-a';
      final store = _MemNotifyStore(tmp);
      final service = _FakeNotifyService(
        launch: const NotifyTapPayload('sid-b', 'task-1', 'taskCompleted'),
      );
      final app = _LoadApp(
        store: profiles,
        notifyService: service,
        notifyStore: store,
        accountStore: _FakeAccountStore(),
      );
      addTearDown(app.dispose);

      await app.load();

      expect(app.activated, contains('sid-a'), reason: '上次活跃电脑照常恢复');
      // 红：修复前 pendingLaunch 在 _initNotify 就消费（profiles 未加载
      // → profileOf 恒空），目标电脑永不激活，用户停在错误电脑上。
      expect(app.activated.last, 'sid-b',
          reason: '冷启动通知目标电脑在 profiles 就绪后被激活');
      expect(app.pendingOpenTask?.deviceSid, 'sid-b');
      expect(app.pendingOpenTask?.taskId, 'task-1');
      // 红：修复前协调器未建，markClicked 静默丢失（点击回填恒 false）。
      expect(store.clicked, contains('task-1'),
          reason: 'markClicked 延迟到协调器就绪后补记');
    });
  });

  group('后台生命周期（状态层批）', () {
    const channel = MethodChannel('companion/notify');
    late List<MethodCall> fgCalls;

    setUp(() {
      fgCalls = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            fgCalls.add(call);
            return null;
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('保活后台掉线记对账水位；未掉线不写（不吞实时通知）', () async {
      final tmp = await Directory.systemTemp.createTemp('bg-reconcile');
      addTearDown(() => tmp.delete(recursive: true));
      final app = AppState();
      final stack = _ProbeStack('sid-bg');
      app.debugRegisterStackForTest(stack);
      final coordinator = NotifyCoordinator(
        store: _MemNotifyStore(tmp),
        onPost: (_) async => false,
      );
      app.notifyCoordinator = coordinator;
      coordinator.attachStack(stack);
      addTearDown(app.dispose);

      await app.setAlertsEnabled(true);
      app.onAppPaused();

      // 未掉线：不得写水位（否则后台实时通知进聚合缓冲）。
      expect(coordinator.debugPendingReconcile.containsKey('sid-bg'), isFalse);

      stack.status = LinkPhase.reconnecting;
      stack.debugPing();
      expect(coordinator.debugPendingReconcile.containsKey('sid-bg'), isTrue,
          reason: '保活期 relay 实际掉线 → 恢复后按设备走对账');
      expect(coordinator.debugPendingReconcile['sid-bg'], isNotNull);

      app.onAppResumed();
    });

    test('回前台重报查看态（退后台取消后桌面未读漂移）', () async {
      final app = AppState();
      final stack = _ProbeStack('sid-view');
      app.debugRegisterStackForTest(stack);
      addTearDown(app.dispose);
      await app.activate(stack.profile);
      app.viewingSessionId = 's-open';

      app.onAppResumed();

      // 红：修复前回前台不补报——查看中的会话在桌面上一直显示未读。
      expect(stack.viewReports, contains('s-open'));
    });
  });

  group('任务乐观更新（状态层批）', () {
    test('归档 RPC 失败清墓碑：卡片立即可见；unarchive 成功同样清位', () async {
      final app = AppState();
      final stack = _ProbeStack('sid-task')
        ..model = _readyModel([
          {'taskId': 't1', 'title': 'A'},
        ]);
      app.debugRegisterStackForTest(stack);
      addTearDown(app.dispose);
      await app.activate(stack.profile);
      final model = app.taskList!;
      expect(model.cards.map((c) => c.sessionId), contains('t1'));

      stack.archiveError = StateError('boom');
      await expectLater(app.archiveTask('t1'), throwsStateError);
      // 红：修复前墓碑留 60s——归档失败后卡片消失一分钟。
      expect(model.cards.map((c) => c.sessionId), contains('t1'),
          reason: '归档失败立即清墓碑');

      model.markRemovedLocally('t1');
      expect(model.cards.map((c) => c.sessionId), isNot(contains('t1')));
      await app.unarchiveTask('t1');
      expect(model.cards.map((c) => c.sessionId), contains('t1'),
          reason: '取消归档成功清本地墓碑（不等 60s 过期）');
    });

    test('setPinLocally 幂等：重复目标值不翻转', () {
      final model = _readyModel([
        {'taskId': 't1', 'title': 'A'},
      ]);
      model.setPinLocally('t1', true);
      model.setPinLocally('t1', true);
      expect(model.pinnedIdsForCache, ['t1']);
      model.setPinLocally('t1', false);
      model.setPinLocally('t1', false);
      expect(model.pinnedIdsForCache, isEmpty);
      model.dispose();
    });

    test('批量删归档：按 requested - skipped 清草稿（跳过任务保留）', () async {
      final app = AppState();
      final stack = _ProbeStack('sid-arch')
        ..model = _readyModel(const [])
        ..deleteArchivedResult = {
          'skippedTaskIds': ['t2'],
        };
      app.debugRegisterStackForTest(stack);
      final drafts = _RecordingDraftStore(Directory.systemTemp);
      app.draftStore = drafts;
      addTearDown(app.dispose);
      await app.activate(stack.profile);

      await app.deleteArchivedTasks(['t1', 't2']);

      // 红：修复前全量清——被跳过（仍在归档态/未删）的 t2 草稿被误删。
      expect(drafts.removed, ['t1'], reason: '只清真正删除的任务');
    });

    test('F11：批量删归档按三分清理——failed（删除失败、任务仍在）的草稿不误清', () async {
      final app = AppState();
      final stack = _ProbeStack('sid-arch2')
        ..model = _readyModel(const [])
        ..deleteArchivedResult = {
          'deletedTaskIds': ['t1'],
          'skippedTaskIds': ['t2'],
          'failedTaskIds': ['t3'],
        };
      app.debugRegisterStackForTest(stack);
      final drafts = _RecordingDraftStore(Directory.systemTemp);
      app.draftStore = drafts;
      addTearDown(app.dispose);
      await app.activate(stack.profile);

      await app.deleteArchivedTasks(['t1', 't2', 't3']);

      // 修复前（requested - skipped）会把 failed 的 t3 也当删除清掉。
      expect(drafts.removed, ['t1'], reason: '只清 deleted；skipped/failed 均保留');
    });
  });

  group('通知权限与前台服务（状态层批）', () {
    test('ensurePermission=false：开关回弹、不启动 FGS、置提示文案', () async {
      final calls = <MethodCall>[];
      const channel = MethodChannel('companion/notify');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return null;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      final app = AppState();
      app.notifyService = _FakeNotifyService(permissionGranted: false);
      addTearDown(app.dispose);

      await app.setAlertsEnabled(true);

      // 红：修复前 ensurePermission 返回值被丢弃——开关显示开、FGS 起来，
      // 但系统丢弃全部通知（用户以为在监控实际全漏）。
      expect(app.uiPrefs.alertsEnabled, isFalse, reason: '开关回弹');
      expect(calls.where((c) => c.method == 'startForeground'), isEmpty,
          reason: '未授权不启动 FGS');
      expect(app.alertsError, isNotNull, reason: '置人话提示（l10n 需求）');
    });

    test('常驻文案含置顶运行任务（running 视图排除置顶的缺口）', () async {
      final calls = <MethodCall>[];
      const channel = MethodChannel('companion/notify');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return null;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      final app = AppState();
      final stack = _ProbeStack('sid-fg')
        ..model = _readyModel([
          {'taskId': 't1', 'title': '置顶运行', 'status': 'running'},
        ]);
      // 置顶这条运行任务（pinnedIds 落集）。
      stack.model!.applyChannelLists(
        active: [
          {'taskId': 't1', 'title': '置顶运行', 'status': 'running'},
        ],
        pinnedIds: const ['t1'],
        archivedIds: const [],
      );
      app.debugRegisterStackForTest(stack);
      addTearDown(app.dispose);

      await app.setAlertsEnabled(true);
      final updates =
          calls.where((c) => c.method == 'updateForeground').toList();
      expect(updates, isNotEmpty);
      final text = '${(updates.last.arguments as Map)['text']}';
      // 红：修复前只数 taskList.running（排除置顶）→ 文案"无任务运行"。
      expect(text, contains('1 个任务运行中'));
      expect(text, contains('置顶运行'));
    });
  });

  group('收尾与缓存', () {
    test('dispose 停电量日志（观察者/定时器不跨 dispose 残留）', () {
      final app = AppState();
      final journal = _ProbeJournal();
      app.batteryJournal = journal;

      app.dispose();

      // 红：修复前 dispose 不停 journal——WidgetsBinding 观察者泄漏。
      expect(journal.stopCalls, 1);
      expect(app.batteryJournal, isNull);
    });

    test('账号标签：同键短路不重复读存储；force 强制刷新', () async {
      final accounts = _FakeAccountStore()
        ..accounts = const [
          StoredAccount(id: 'acc-1', provider: 'zai', label: '工作号'),
        ];
      var reads = 0;
      final counting = _CountingAccounts(accounts, () => reads++);
      final app2 = AppState(accountStore: counting);
      addTearDown(app2.dispose);
      app2.activeProfile = _v2('sid-label', accountId: 'acc-1');

      app2.refreshActiveAccountLabel();
      await _settle();
      app2.refreshActiveAccountLabel();
      await _settle();
      expect(app2.activeAccountLabel, '工作号');
      expect(reads, 1, reason: '同 sid+accountId 命中缓存，不重复读安全存储');

      app2.refreshActiveAccountLabel(force: true);
      await _settle();
      expect(reads, 2, reason: '设置页改名后可强制刷新');
    });

    test('账号标签：旧代际慢查询不覆盖新标签', () async {
      final accounts = _GatedAccounts();
      final app = AppState(accountStore: accounts);
      addTearDown(app.dispose);

      app.activeProfile = _v2('sid-gen', accountId: 'acc-1');
      app.refreshActiveAccountLabel();
      await Future<void>.delayed(Duration.zero);

      app.activeProfile = _v2('sid-gen', accountId: 'acc-2');
      app.refreshActiveAccountLabel();
      await Future<void>.delayed(Duration.zero);
      expect(accounts.completers, hasLength(2));

      accounts.completers[1].complete(const [
        StoredAccount(id: 'acc-1', provider: 'zai', label: '旧号'),
        StoredAccount(id: 'acc-2', provider: 'zai', label: '新号'),
      ]);
      await _settle();
      expect(app.activeAccountLabel, '新号');

      // 旧代际（acc-1）后到：丢弃，不得把标签覆盖回旧号。
      accounts.completers[0].complete(const [
        StoredAccount(id: 'acc-1', provider: 'zai', label: '旧号'),
        StoredAccount(id: 'acc-2', provider: 'zai', label: '新号'),
      ]);
      await _settle();
      expect(app.activeAccountLabel, '新号', reason: '旧代际结果丢弃');
    });
  });
}

/// 计数 listAccounts 的账号存储（装饰既有 fake）。
class _CountingAccounts extends AccountStore {
  _CountingAccounts(this.inner, this.onRead);
  final _FakeAccountStore inner;
  final void Function() onRead;

  @override
  Future<List<StoredAccount>> listAccounts() async {
    onRead();
    return inner.accounts;
  }

  @override
  Future<String?> readJwtFor(String? accountId) async => null;
}
