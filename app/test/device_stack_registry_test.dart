import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/state/account_store.dart';
import 'package:zcode_pocket/state/computer_stack.dart';
import 'package:zcode_pocket/state/device_stack_registry.dart';
import 'package:zcode_pocket/state/link_phase.dart';
import 'package:zcode_pocket/state/profile_store.dart';
import 'package:zcode_pocket/transport/connection_params.dart';
import 'package:zcode_pocket/transport/relay_client.dart';
import 'package:zcode_pocket/transport/z_transport.dart';

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
  Future<void> removeProfile(String deviceSid) async {
    items = items.where((p) => p.deviceSid != deviceSid).toList();
    if (active == deviceSid) active = null;
  }

  @override
  Future<void> setActiveDeviceSid(String? deviceSid) async {
    active = deviceSid;
  }
}

class _FakeAccounts extends AccountStore {
  final cleared = <String?>[];
  final tokens = <String, String>{};

  /// 可按用例覆写（默认保持既有用例期望的 acc-new）。
  String? lastUsed = 'acc-new';

  @override
  Future<String?> get lastUsedAccountId async => lastUsed;

  @override
  Future<String?> readJwtFor(String? accountId) async => tokens[accountId];

  @override
  Future<void> clearAccount(String? accountId) async {
    cleared.add(accountId);
    tokens.remove(accountId);
  }
}

AccountV2Profile _profile(String sid, {String? accountId = 'acc-a', bool invalid = false}) =>
    AccountV2Profile(
      deviceSid: sid,
      accountId: accountId,
      label: '测试桌面-$sid',
      addedAt: DateTime(2026),
      invalid: invalid,
    );

class _FrozenStack extends ComputerStack {
  _FrozenStack(DeviceProfile profile)
    : super(profile: profile, onLog: (_) {}, onFailure: (_, _) {});
  int startCalls = 0;
  int resumeCalls = 0;
  int demoteCalls = 0;
  int disposeCalls = 0;
  int tasksIndexResumeCalls = 0;

  //可选闸门/错误（制造 dispose await 窗口/单栈抛出）。
  Completer<void>? disposeGate;
  Object? disposeError;

  @override
  Future<void> start() async {
    startCalls++;
  }

  @override
  Future<void> pokeOrResume() async {
    resumeCalls++;
  }

  @override
  Future<void> resumeTasksIndexFromBackground() async {
    tasksIndexResumeCalls++;
  }

  @override
  Future<void> demote() async {
    demoteCalls++;
  }

  @override
  Future<void> disposeStack() async {
    disposeCalls++;
    final gate = disposeGate;
    if (gate != null) await gate.future;
    final err = disposeError;
    if (err != null) throw err;
  }
}

class _Harness {
  _Harness(List<DeviceProfile> profiles) : store = _MemoryProfiles(profiles) {
    registry = DeviceStackRegistry(
      store: store,
      accountStore: accounts,
      cacheProvider: () => null,
      notifyCoordinatorProvider: () => null,
      phaseProvider: () => phase,
      onLog: (_) {},
      onNotify: () => notifyCount++,
      onStackChanged: () {},
      onPersistProfile: store.updateProfile,
      onRemoveDeviceData: (sid) async => removedDeviceData.add(sid),
      stackFactory: (profile, onFailure) {
        final stack = _FrozenStack(profile);
        created.add(stack);
        return stack;
      },
    );
    registry.profiles = List.of(profiles);
  }

  final _MemoryProfiles store;
  final accounts = _FakeAccounts();
  final created = <_FrozenStack>[];
  final removedDeviceData = <String>[];
  late final DeviceStackRegistry registry;
  LinkPhase phase = LinkPhase.reconnecting;
  int notifyCount = 0;
}

void main() {
  test('activate 复用栈且只恢复一次；无效档案不建栈', () async {
    final h = _Harness([_profile('sid-a')]);
    await h.registry.activate(_profile('sid-a'));
    expect(h.created, hasLength(1));
    expect(h.created.single.startCalls, 1);

    await h.registry.activate(_profile('sid-a'));
    expect(h.created, hasLength(1));
    expect(h.created.single.resumeCalls, 1);

    await h.registry.activate(_profile('sid-invalid', invalid: true));
    expect(h.created, hasLength(1));
    expect(h.registry.activeProfile?.invalid, isTrue);
    h.registry.dispose();
  });

  // 遗留核实修（2026-11-07）：keepAlive 后台全栈退订
  // tasks-index、回前台只恢复活跃栈——切回保活中的另一栈（连接在、
  // pokeOrResume→poke 不重开工作区）必须就地补订，否则首页停更。
  test('activate 复用栈时补订 tasks-index（保活切换停更修复）', () async {
    final h = _Harness([_profile('sid-a'), _profile('sid-b')]);
    await h.registry.activate(_profile('sid-a'));
    await h.registry.activate(_profile('sid-b'));
    final stackA = h.created[0];
    expect(stackA.tasksIndexResumeCalls, 0,
        reason: '新建栈路径走 start→开工作区自然订阅，无需补订');

    // 切回 A（复用分支）——修复前零调用=停更。
    await h.registry.activate(_profile('sid-a'));
    expect(stackA.tasksIndexResumeCalls, 1,
        reason: '复用栈激活须补订 tasks-index（poke 路径不重开工作区）');
    h.registry.dispose();
  });

  test('删除当前电脑后按现状选择剩余可用档案', () async {
    final h = _Harness([_profile('sid-a'), _profile('sid-b')]);
    await h.registry.activate(_profile('sid-b'));
    await h.registry.removeComputer(_profile('sid-b'));
    expect(h.registry.activeSid, 'sid-a');
    expect(h.store.items.map((p) => p.deviceSid), ['sid-a']);
    h.registry.dispose();
  });

  test('删除活跃电脑：先 reload 再挑下一台——幽灵条目不残留（I1 P2-3/I3 P2-3）', () async {
    final h = _Harness([_profile('sid-a'), _profile('sid-b')]);
    await h.registry.activate(_profile('sid-b'));
    await h.registry.removeComputer(_profile('sid-b'));
    expect(h.registry.activeSid, 'sid-a');
    expect(
      h.registry.profiles.map((p) => p.deviceSid),
      ['sid-a'],
      reason: '修复前：早退路径跳过 reloadProfiles，内存 profiles 滞留已删'
          '档案（点按幽灵条目会为已删设备重建栈并持久化 activeDeviceSid）',
    );
    expect(h.registry.profileOf('sid-b'), isNull);
    h.registry.dispose();
  });

  test('删除排首的活跃电脑不再自复活（reload 后挑 next 排除已删 sid）', () async {
    final h = _Harness([_profile('sid-a'), _profile('sid-b')]);
    await h.registry.activate(_profile('sid-a'));
    final createdBeforeRemove = h.created.length;
    await h.registry.removeComputer(_profile('sid-a'));
    expect(
      h.registry.activeSid,
      'sid-b',
      reason: '修复前：next 从删除前的陈旧列表选出，命中排首的被删档案自身'
          '（自复活面）',
    );
    expect(
      h.created
          .skip(createdBeforeRemove)
          .any((s) => s.profile.deviceSid == 'sid-a'),
      isFalse,
      reason: '删除后不得为已删档案重建栈',
    );
    h.registry.dispose();
  });

  test('后台失败不顶替展示，切回两分钟窗内回捞', () async {
    final h = _Harness([_profile('sid-a'), _profile('sid-b')]);
    h.registry.activeSid = 'sid-a';
    final b = _FrozenStack(_profile('sid-b'));
    h.registry.debugRegisterStackForTest(b);
    await h.registry.debugStackFailure(b, const RelayFailure('network-dns'));
    expect(h.registry.lastRelayFailReason, isNull);

    await h.registry.activate(_profile('sid-b'));
    expect(h.registry.lastRelayFailReason, 'network-dns');
    h.registry.debugAgeStackFailureForTest('sid-b', const Duration(minutes: 3));
    h.registry.updateRelayFailure(null, null);
    await h.registry.activate(_profile('sid-b'));
    expect(h.registry.lastRelayFailReason, isNull);
    h.registry.dispose();
  });

  test('auth-required 只清对应账号的栈与凭据', () async {
    final h = _Harness([
      _profile('sid-a'),
      _profile('sid-b', accountId: 'acc-b'),
    ]);
    h.registry.activeSid = 'sid-a';
    final a = _FrozenStack(_profile('sid-a'));
    final b = _FrozenStack(_profile('sid-b', accountId: 'acc-b'));
    h.registry
      ..debugRegisterStackForTest(a)
      ..debugRegisterStackForTest(b);
    h.accounts.tokens['acc-a'] = 'jwt-a';
    h.accounts.tokens['acc-b'] = 'jwt-b';

    await h.registry.debugStackFailure(a, const RelayFailure('auth-required'));
    expect(h.accounts.cleared, ['acc-a']);
    expect(h.accounts.tokens.containsKey('acc-a'), isFalse);
    expect(h.accounts.tokens['acc-b'], 'jwt-b');
    expect(h.registry.stacks.containsKey('sid-a'), isFalse);
    expect(h.registry.stacks.containsKey('sid-b'), isTrue);
    expect(a.disposeCalls, 1);
    expect(b.disposeCalls, 0);
    h.registry.dispose();
  });

  test('按账号拆栈（反馈②）：只拆该账号名下，其他账号与档案保留', () async {
    final h = _Harness([
      _profile('sid-a1', accountId: 'acc-a'),
      _profile('sid-a2', accountId: 'acc-a'),
      _profile('sid-b', accountId: 'acc-b'),
    ]);
    final a1 = _FrozenStack(_profile('sid-a1', accountId: 'acc-a'));
    final a2 = _FrozenStack(_profile('sid-a2', accountId: 'acc-a'));
    final b = _FrozenStack(_profile('sid-b', accountId: 'acc-b'));
    h.registry
      ..debugRegisterStackForTest(a1)
      ..debugRegisterStackForTest(a2)
      ..debugRegisterStackForTest(b);

    await h.registry.disposeStacksForAccount('acc-a');

    expect(a1.disposeCalls, 1);
    expect(a2.disposeCalls, 1);
    expect(b.disposeCalls, 0, reason: '其他账号的栈不受牵连');
    expect(h.registry.stacks.keys, ['sid-b'], reason: '档案保留（重登即恢复）');
    expect(h.registry.profiles, hasLength(3),
        reason: '档案按删除对话框明示保留，不随账号删除清除');
    expect(
      h.removedDeviceData,
      unorderedEquals(['sid-a1', 'sid-a2']),
      reason: '设备缓存/草稿/排队随账号删除清理（跨账号数据不残留）',
    );
  });

  test('删活跃账号（审查 H1/H2 红绿）：无其他账号档案→活跃指针与持久 sid 显式收尾', () async {
    final h = _Harness([_profile('sid-a1', accountId: 'acc-a')]);
    final a1 = _FrozenStack(_profile('sid-a1', accountId: 'acc-a'));
    h.registry.debugRegisterStackForTest(a1);
    await h.registry.activate(_profile('sid-a1', accountId: 'acc-a'));
    expect(h.registry.activeSid, 'sid-a1');

    await h.registry.disposeStacksForAccount('acc-a');

    // 红：修复前 activeSid/activeProfile 悬空（仍指向已拆栈的档案），
    // phase 掉 offline 但 AppBar 还显示已删账号的电脑——且无任何重连
    // 路径，用户只能大退 app（反馈②「须大退才能恢复」根因）。
    expect(h.registry.activeSid, isNull, reason: '活跃指针显式清空');
    expect(h.registry.activeProfile, isNull);
    expect(h.store.active, isNull, reason: '持久 activeDeviceSid 同步清（防冷启自动激活已删凭据档案）');
    expect(h.registry.stacks, isEmpty);
    expect(h.created, isEmpty,
        reason: '本账号档案虽保留但凭据已删——不得自动激活它（吃 auth-required）');
  });

  test('删活跃账号但有其他账号档案→自动切到另一账号（对齐 removeComputer）', () async {
    final h = _Harness([
      _profile('sid-a1', accountId: 'acc-a'),
      _profile('sid-b', accountId: 'acc-b'),
    ]);
    final a1 = _FrozenStack(_profile('sid-a1', accountId: 'acc-a'));
    h.registry.debugRegisterStackForTest(a1);
    await h.registry.activate(_profile('sid-a1', accountId: 'acc-a'));

    await h.registry.disposeStacksForAccount('acc-a');

    expect(h.registry.activeSid, 'sid-b', reason: '其他账号的可用档案自动接管');
    expect(h.registry.activeProfile?.deviceSid, 'sid-b');
    expect(h.store.active, 'sid-b');
    expect(
      h.created.any((s) => s.profile.deviceSid == 'sid-b'),
      isTrue,
      reason: '为新档案建栈',
    );
  });

  test('legacy 档案 accountId==null：删除其取凭据的 lastUsed 账号时同样拆栈', () async {
    final h = _Harness([
      _profile('sid-legacy', accountId: null),
      _profile('sid-b', accountId: 'acc-b'),
    ]);
    final legacy = _FrozenStack(_profile('sid-legacy', accountId: null));
    h.registry.debugRegisterStackForTest(legacy);

    // lastUsedBefore=删除前捕获（store 内 lastUsed 已被 removeAccount
    // 改写，直接读会漏拆）。
    await h.registry.disposeStacksForAccount('acc-a', lastUsedBefore: 'acc-a');

    expect(legacy.disposeCalls, 1,
        reason: 'legacy 档案的凭据来自 lastUsed（=被删账号）——栈要拆');
    expect(h.registry.stacks, isEmpty);
  });

  test('auth-required 对未绑定档案（accountId=null）回落 lastUsed：只清该账号（开源审查 I1/I3/K1 三路）', () async {
    final h = _Harness([
      _profile('sid-legacy', accountId: null),
      _profile('sid-b', accountId: 'acc-b'),
    ]);
    h.accounts.lastUsed = 'acc-x';
    h.accounts.tokens['acc-x'] = 'jwt-x';
    h.accounts.tokens['acc-b'] = 'jwt-b';
    final legacy = _FrozenStack(_profile('sid-legacy', accountId: null));
    final b = _FrozenStack(_profile('sid-b', accountId: 'acc-b'));
    h.registry
      ..debugRegisterStackForTest(legacy)
      ..debugRegisterStackForTest(b);

    await h.registry
        .debugStackFailure(legacy, const RelayFailure('auth-required'));

    // 红：旧实现传 null 给 clearAccount（全清契约，cleared=[null]）且
    // 谓词 failedAccount==null 匹配全部 V2 栈——一次 401 清光全部账号。
    expect(h.accounts.cleared, ['acc-x'],
        reason: 'null 档案凭据实际取 lastUsed——按其精确点名');
    expect(h.accounts.tokens['acc-b'], 'jwt-b', reason: '其他账号凭据不受牵连');
    expect(legacy.disposeCalls, 1);
    expect(b.disposeCalls, 0, reason: '其他账号的栈不被误拆');
    expect(h.registry.stacks.containsKey('sid-b'), isTrue);
    h.registry.dispose();
  });

  test('auth-required 零账号兜底仍失败：不动凭据库，只拆本栈', () async {
    final h = _Harness([
      _profile('sid-x', accountId: null),
      _profile('sid-b', accountId: 'acc-b'),
    ]);
    h.accounts.lastUsed = null;
    final x = _FrozenStack(_profile('sid-x', accountId: null));
    final b = _FrozenStack(_profile('sid-b', accountId: 'acc-b'));
    h.registry
      ..debugRegisterStackForTest(x)
      ..debugRegisterStackForTest(b);

    await h.registry.debugStackFailure(x, const RelayFailure('auth-required'));

    expect(h.accounts.cleared, isEmpty, reason: '无账号可点名时不得触碰凭据库');
    expect(x.disposeCalls, 1, reason: '本栈恒拆（identical 兜底）');
    expect(b.disposeCalls, 0);
    h.registry.dispose();
  });

  test('auth-required 拆栈 M5 竞态：dispose 窗口内新建的替换栈不被摘表成孤儿（开源审查 I1 P2-1/I2 P2-3）', () async {
    final h = _Harness([_profile('sid-a')]);
    h.registry.activeSid = 'sid-a';
    final a = _FrozenStack(_profile('sid-a'));
    a.disposeGate = Completer<void>();
    h.registry.debugRegisterStackForTest(a);

    final failing = h.registry
        .debugStackFailure(a, const RelayFailure('auth-required'));
    await Future<void>.delayed(Duration.zero); // 挂进 dispose await 窗口
    // 窗口内同账号重登（诊断引导的官方恢复流）→ activate 新栈入表。
    final replacement = _FrozenStack(_profile('sid-a'));
    h.registry.debugRegisterStackForTest(replacement);

    a.disposeGate!.complete();
    await failing;
    // 红：旧实现尾部 removeWhere 按谓词摘新栈表——连接活着但注册表查不
    // 到（孤儿），activeSid 悬空且永远拆不掉。
    expect(h.registry.stacks.containsKey('sid-a'), isTrue,
        reason: '同步摘表先行后，窗口内新建的栈不被误删');
    expect(replacement.disposeCalls, 0);
    h.registry.dispose();
  });

  test('auth-required 单栈 dispose 抛出不中断其余拆除（开源审查 I3 P2-2：逐栈容错）', () async {
    final h = _Harness([
      _profile('sid-a1'),
      _profile('sid-a2'),
    ]);
    final a1 = _FrozenStack(_profile('sid-a1'));
    a1.disposeError = StateError('dispose boom');
    final a2 = _FrozenStack(_profile('sid-a2'));
    h.registry
      ..debugRegisterStackForTest(a1)
      ..debugRegisterStackForTest(a2);

    await h.registry.debugStackFailure(a1, const RelayFailure('auth-required'));

    // 红：旧实现单栈抛出中断整个循环——a2 变僵尸栈带着已清凭据重连。
    expect(a1.disposeCalls, 1);
    expect(a2.disposeCalls, 1, reason: '逐栈 try/catch contained，其余照拆');
    h.registry.dispose();
  });

  test('auth-required 拆活跃栈：指针收尾 + offline 档诊断可达（开源审查 I2 P1-1/I3 P2-1）', () async {
    final h = _Harness([_profile('sid-a')]);
    h.phase = LinkPhase.offline;
    final a = _FrozenStack(_profile('sid-a'));
    h.registry.debugRegisterStackForTest(a);
    await h.registry.activate(_profile('sid-a'));
    expect(h.registry.activeSid, 'sid-a');

    await h.registry.debugStackFailure(a, const RelayFailure('auth-required'));

    // 指针收尾（红：旧实现 activeSid 悬空+持久 sid 未清，冷启重复
    // "连→401→拆"循环）。
    expect(h.registry.activeSid, isNull);
    expect(h.registry.activeProfile, isNull);
    expect(h.store.active, isNull, reason: '持久 activeDeviceSid 同步清');
    // 诊断可达（红：旧相位门只放行 reconnecting/error，拆栈后 phase=offline
    // 恒 null——重登引导在唯一真实触发场景永不可达）。
    final diag = h.registry.relayDiagnosis;
    expect(diag, isNotNull);
    expect(diag!.title, contains('凭据已失效'));
    h.registry.dispose();
  });

  test('换账号重扫同一电脑需确认：已绑定且账号将变 → AccountRebindRequired（批2）',
      () async {
    final h = _Harness([_profile('sid-rebind', accountId: 'acc-old')]);
    h.accounts.lastUsed = 'acc-new';
    const params = CompanionV2Params(
      deviceSid: 'sid-rebind',
      deviceMid: 'm',
      deviceName: '工作机',
    );
    // 同账号重扫：不拦（幂等）。
    await h.registry.addV2Profile(params, accountId: 'acc-old');
    // 改绑另一个账号：必须抛确认需求（旧账号连接将失效）。
    await expectLater(
      () => h.registry.addV2Profile(params, accountId: 'acc-new'),
      throwsA(isA<AccountRebindRequired>()),
    );
    // forceRebind 后才真正改绑。
    await h.registry.addV2Profile(params, accountId: 'acc-new',
        forceRebind: true);
    final after = h.registry.profileOf('sid-rebind');
    expect(after, isA<AccountV2Profile>());
    expect((after as AccountV2Profile).accountId, 'acc-new');
    h.registry.dispose();
  });

  test('改绑账号（forceRebind）：旧栈拆除、新栈按新账号重建（凭据归属校验）', () async {
    final h = _Harness([_profile('sid-rebind', accountId: 'acc-old')]);
    h.accounts.lastUsed = 'acc-new';
    h.accounts.tokens['acc-old'] = 'jwt-old';
    h.accounts.tokens['acc-new'] = 'jwt-new';
    await h.registry.activate(_profile('sid-rebind', accountId: 'acc-old'));
    expect(h.created, hasLength(1));
    final oldStack = h.created.single;
    expect((oldStack.profile as AccountV2Profile).accountId, 'acc-old');

    const params = CompanionV2Params(
      deviceSid: 'sid-rebind',
      deviceMid: 'm',
      deviceName: '工作机',
    );
    await h.registry.addV2Profile(params, accountId: 'acc-new',
        forceRebind: true);

    // 红：修复前复用分支只换 profile 标签不重建——accountJwtProvider 闭包
    // 仍持旧账号 id，改绑后 401/串号。
    expect(oldStack.disposeCalls, 1, reason: '旧栈必须拆除（闭包捕获旧账号 JWT）');
    expect(h.created, hasLength(2), reason: '按新账号重建一条栈');
    expect(
      (h.created[1].profile as AccountV2Profile).accountId,
      'acc-new',
      reason: '新栈档案=新账号',
    );
    expect(h.registry.activeSid, 'sid-rebind');
    h.registry.dispose();
  });

  test('生产建栈工厂：新账号档案的 JWT 读取器读新账号（不 start 不连网）', () async {
    final store = _MemoryProfiles([_profile('sid-jwt', accountId: 'acc-old')]);
    final accounts = _FakeAccounts()
      ..tokens['acc-old'] = 'jwt-old'
      ..tokens['acc-new'] = 'jwt-new';
    final registry = DeviceStackRegistry(
      store: store,
      accountStore: accounts,
      cacheProvider: () => null,
      notifyCoordinatorProvider: () => null,
      phaseProvider: () => LinkPhase.offline,
      onLog: (_) {},
      onNotify: () {},
      onStackChanged: () {},
      onPersistProfile: store.updateProfile,
    );
    addTearDown(registry.dispose);
    final stack = registry.debugCreateStackForTest(
      _profile('sid-jwt', accountId: 'acc-new'),
    );
    addTearDown(stack.dispose);
    expect(await stack.accountJwtProvider!(), 'jwt-new',
        reason: '闭包按建栈时档案账号读取——改绑后重建即读新账号');
  });

  test('拆栈 dispose 窗口内 activate 同 sid 被拒绝：不留僵尸栈（状态层批）', () async {
    final h = _Harness([_profile('sid-a'), _profile('sid-b')]);
    await h.registry.activate(_profile('sid-a'));
    final stackA = h.created.single;
    stackA.disposeGate = Completer<void>();

    final removing = h.registry.removeComputer(_profile('sid-a'));
    await Future<void>.delayed(Duration.zero); // 挂进 dispose await 窗口
    // 红：修复前此处为同 sid 建新活栈，随后 removeComputer 收尾把新栈从
    // 协调器摘掉/指针清空——连接活着但注册表查不到（僵尸栈）。
    await expectLater(
      h.registry.activate(_profile('sid-a')),
      throwsA(isA<StateError>()),
    );
    stackA.disposeGate!.complete();
    await removing;
    expect(h.registry.stacks.containsKey('sid-a'), isFalse);
    h.registry.dispose();
  });

  test('removeComputer 单栈 dispose 抛出不阻断档案/设备数据清理（逐栈容错）', () async {
    final h = _Harness([_profile('sid-a'), _profile('sid-b')]);
    await h.registry.activate(_profile('sid-a'));
    h.created.first.disposeError = StateError('dispose boom');

    await h.registry.removeComputer(_profile('sid-a'));

    // 红：修复前 dispose 抛出中断后续 store.removeProfile/_onRemoveDeviceData。
    expect(h.store.items.map((p) => p.deviceSid), ['sid-b'],
        reason: '档案删除照常完成');
    expect(h.removedDeviceData, contains('sid-a'), reason: '设备数据清理照常');
    expect(h.registry.stacks.containsKey('sid-a'), isFalse);
    h.registry.dispose();
  });

  test('删除活跃电脑清全局失败横幅（对齐 disposeStacksForAccount）', () async {
    final h = _Harness([_profile('sid-a'), _profile('sid-b')]);
    await h.registry.activate(_profile('sid-a'));
    h.registry.updateRelayFailure('network-dns', '解析失败');
    expect(h.registry.lastRelayFailReason, isNotNull);

    await h.registry.removeComputer(_profile('sid-a'));

    // 红：修复前旧诊断留到 2 分钟窗（横幅挂在一台已不存在的电脑上）。
    expect(h.registry.lastRelayFailReason, isNull);
    expect(h.registry.lastRelayFailMessage, isNull);
    h.registry.dispose();
  });

  test('dispose 释放全部栈并清空注册表', () async {
    final h = _Harness([_profile('sid-a'), _profile('sid-b')]);
    final a = _FrozenStack(_profile('sid-a'));
    final b = _FrozenStack(_profile('sid-b'));
    h.registry
      ..debugRegisterStackForTest(a)
      ..debugRegisterStackForTest(b)
      ..dispose();
    expect(a.disposeCalls, 1);
    expect(b.disposeCalls, 1);
    expect(h.registry.stacks, isEmpty);
  });
}
