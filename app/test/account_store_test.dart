// 多账号凭据核心回归（multi-account-plan.md /4.2，2026-10-25）：
// 迁移（旧单账号键→账号记录）、id 派生三层（claim > user_info.id > 哈希
// 兜底；同 provider 覆盖启发式已废除—— 事故）、多账号并存读写
// 的存储面）、档案 accountId 序列化往返。
import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/state/account_store.dart';
import 'package:zcode_pocket/state/profile_store.dart';
import 'package:zcode_pocket/transport/z_transport.dart';

class _MemStorage extends FlutterSecureStorage {
  final Map<String, String> data = {};

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async =>
      data[key];

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      data.remove(key);
    } else {
      data[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async =>
      data.remove(key);
}

class _GatedMemStorage extends _MemStorage {
  _GatedMemStorage();

  /// 下一次 account.list 写入挂起（制造读-改-写交错窗口）。
  Completer<void>? holdNextListWrite;

  /// 已推进到 list 写入点（save 写序为列表先行、凭据后写——
  /// 防孤儿凭据键——故前置判定看此标记而非凭据键存在）。
  bool listWriteEntered = false;

  @override
  Future<void> write({
    required String key,
    String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (key == 'account.list' && holdNextListWrite != null) {
      final gate = holdNextListWrite;
      holdNextListWrite = null;
      listWriteEntered = true;
      await gate!.future;
    }
    await super.write(
      key: key,
      value: value,
      iOptions: iOptions,
      aOptions: aOptions,
      lOptions: lOptions,
      webOptions: webOptions,
      mOptions: mOptions,
      wOptions: wOptions,
    );
  }
}

/// 造一个三段式 JWT（payload 可控）。
String _jwt({Map<String, dynamic> payload = const {}}) {
  String b64(Map m) =>
      base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  return '${b64({'alg': 'none'})}.${b64(payload)}.${b64({'sig': 1})}';
}

AccountV2Profile _v2Profile({
  required String sid,
  String? accountId,
  String label = '桌面',
}) =>
    AccountV2Profile(
      deviceSid: sid,
      accountId: accountId,
      label: label,
      addedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
    );

void main() {
  test('deriveAccountId：标准 claim 优先（sub>uid>user_id>open_id）', () {
    expect(deriveAccountId(_jwt(payload: {'sub': 'user-1'})), 'user-1');
    expect(deriveAccountId(_jwt(payload: {'uid': 'u2', 'open_id': 'o'})), 'u2');
    expect(deriveAccountId(_jwt(payload: {'open_id': 'o3'})), 'o3');
    // 无 claim → 16 hex 兜底；同 jwt 稳定、异 jwt 不同。
    final a = deriveAccountId(_jwt());
    final b = deriveAccountId(_jwt(payload: {'x': 1}));
    expect(RegExp(r'^[0-9a-f]{16}$').hasMatch(a), isTrue);
    expect(a, deriveAccountId(_jwt()));
    expect(a, isNot(b));
  });

  test('旧单账号键迁移：变一条账号记录，旧键清除，幂等', () async {
    final mem = _MemStorage();
    final jwtA = _jwt(payload: {'sub': 'acc-a'});
    mem.data['account.jwt'] = jwtA;
    mem.data['account.provider'] = 'bigmodel';
    final store = AccountStore(storage: mem);

    final accounts = await store.listAccounts();
    expect(accounts, hasLength(1));
    expect(accounts.first.id, 'acc-a');
    expect(accounts.first.provider, 'bigmodel');
    expect(mem.data.containsKey('account.jwt'), isFalse, reason: '旧键已删');
    expect(await store.readJwt(), jwtA);
    expect(await store.lastUsedAccountId, 'acc-a');

    // 幂等：再访问不重复不报错。
    expect(await store.listAccounts(), hasLength(1));
  });

  test('多账号并存：save 去重/最近使用/按账号读/按账号清', () async {
    final mem = _MemStorage();
    final store = AccountStore(storage: mem);
    final jwtA = _jwt(payload: {'sub': 'acc-a'});
    final jwtB = _jwt(payload: {'sub': 'acc-b'});

    await store.save(jwt: jwtA, provider: 'bigmodel');
    await store.save(jwt: jwtB, provider: 'zai');
    expect(await store.listAccounts(), hasLength(2));
    // multi-account-ux-1 批2：添加不再抢当前（首账号 acc-a 保持当前）；
    // 切默认账号走「设为当前」。
    expect(await store.lastUsedAccountId, 'acc-a',
        reason: '添加第二账号不改当前账号');
    await store.setLastUsed('acc-b');
    expect(await store.lastUsedAccountId, 'acc-b', reason: '设为当前生效');

    // 同 id 重新登录=续期不新增。
    final jwtA2 = _jwt(payload: {'sub': 'acc-a'});
    await store.save(jwt: jwtA2, provider: 'bigmodel');
    expect(await store.listAccounts(), hasLength(2));
    expect(await store.readJwtFor('acc-a'), jwtA2);
    expect(await store.readJwtFor('acc-b'), jwtB);

    // 按账号清（auth-required 收窄）：只清 acc-b。
    await store.clearAccount('acc-b');
    expect(await store.listAccounts(), hasLength(1));
    expect((await store.listAccounts()).first.id, 'acc-a');
    expect(await store.readJwtFor('acc-b'), isNull);
    expect(await store.readJwtFor('acc-a'), jwtA2);
  });

  test('identity 修复（事故红绿）：无 claim 的两个不同账号并存不被覆盖', () async {
    final mem = _MemStorage();
    final store = AccountStore(storage: mem);
    // bigmodel 实测形态：JWT 零标准 claim，身份来自官方 user_info.id。
    await store.save(
        jwt: _jwt(payload: {'i': 1}), provider: 'bigmodel', identity: 'bm-user-a');
    expect(await store.listAccounts(), hasLength(1));
    await store.save(
        jwt: _jwt(payload: {'i': 2}), provider: 'bigmodel', identity: 'bm-user-b');
    // 红：旧版"同 provider 唯一兜底账号覆盖"启发式这里只剩 1 条（A 被删
    // 换 B=凭据键被清→活跃连接 auth-required→黑屏/转圈全链条， 真机）。
    expect(await store.listAccounts(), hasLength(2),
        reason: '不同 identity 的同 provider 账号必须并存');
    expect(await store.readJwtFor('bm-user-a'), isNotNull,
        reason: '原账号凭据不得被删除');
    expect(await store.readJwtFor('bm-user-b'), isNotNull);
    // 批2：第二个账号加入不改变当前账号（首账号 bm-user-a 保持）。
    expect(await store.lastUsedAccountId, 'bm-user-a');

    // 同 identity 重登=同 id 天然去重（替代被废除的启发式）。
    await store.save(
        jwt: _jwt(payload: {'i': 3}), provider: 'bigmodel', identity: 'bm-user-a');
    expect(await store.listAccounts(), hasLength(2));
  });

  test('identity 优先级：claim > user_info.id > 内容哈希', () {
    expect(deriveAccountId(_jwt(payload: {'sub': 's1'}), identity: 'u1'), 's1',
        reason: 'JWT 标准 claim 仍最高优先');
    expect(deriveAccountId(_jwt(), identity: 'u1'), 'u1',
        reason: '无 claim 时 user_info.id 优于哈希兜底');
    expect(
        RegExp(r'^[0-9a-f]{16}$').hasMatch(deriveAccountId(_jwt())), isTrue,
        reason: '两者皆无才落内容哈希');
  });

  test('无 identity 的同 provider 兜底形态并存（启发式废除后的边界）', () async {
    final mem = _MemStorage();
    final store = AccountStore(storage: mem);
    await store.save(jwt: _jwt(payload: {'i': 1}), provider: 'bigmodel');
    await store.save(jwt: _jwt(payload: {'i': 2}), provider: 'bigmodel');
    // 宁可并存重复（旧账号凭据完好可继续用），绝不删号换号（事故）。
    expect(await store.listAccounts(), hasLength(2));
    expect(await store.hasAccount, isTrue);
  });

  test('全清回登录门', () async {
    final mem = _MemStorage();
    final store = AccountStore(storage: mem);
    await store.save(jwt: _jwt(payload: {'sub': 'a'}), provider: 'p1');
    await store.save(jwt: _jwt(payload: {'sub': 'b'}), provider: 'p2');
    await store.clear();
    expect(await store.hasAccount, isFalse);
    expect(mem.data.keys.where((k) => k.startsWith('account')), isEmpty);
  });

  test('并发读改写串行化（开源审查 K1 P2-1/K2 P2-2）：save 与 removeAccount 交错不复活已删账号', () async {
    final mem = _GatedMemStorage();
    final store = AccountStore(storage: mem);
    await store.save(jwt: _jwt(payload: {'sub': 'acc-a'}), provider: 'p1');

    // save(B) 挂在列表写入（读列表+写凭据键已完成）——此刻后台
    // auth-required 自动 removeAccount(A) 并发到达。
    final gate = Completer<void>();
    mem.holdNextListWrite = gate;
    final saving = store.save(jwt: _jwt(payload: {'sub': 'acc-b'}), provider: 'p2');
    for (var i = 0; i < 500 && !mem.listWriteEntered; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(mem.listWriteEntered, isTrue, reason: '前置：save(B) 已推进到列表写入前');
    final removing = store.removeAccount('acc-a');

    gate.complete();
    await saving;
    await removing;

    // 红：旧实现无串行队列——removeAccount 读到 save 写入前的旧列表
    // [A]，save 恢复后写回含已删 A 的陈旧列表（幽灵账号：列表在、凭据
    // 键已删，后续选它连接必败回 auth-required 循环）。
    final accounts = await store.listAccounts();
    expect(accounts.map((a) => a.id), ['acc-b']);
    expect(await store.readJwtFor('acc-a'), isNull);
  });

  test('添加账号不切换当前账号（multi-account-ux-1 批2）', () async {
    final mem = _MemStorage();
    final store = AccountStore(storage: mem);
    // 首账号：lastUsed 尚空 → 自动设为当前（登录可用）。
    final a = await store.save(
        jwt: _jwt(payload: {'sub': 'acc-first'}), provider: 'p1');
    expect(await store.lastUsedAccountId, a, reason: '首账号自动成为当前');
    // 第二/三账号：不抢当前（旧行为=加账号即换账号，批2 收敛）。
    final b = await store.save(
        jwt: _jwt(payload: {'sub': 'acc-second'}), provider: 'p1');
    expect(await store.lastUsedAccountId, a, reason: '添加第二账号不切当前');
    await store.save(jwt: _jwt(payload: {'sub': 'acc-third'}), provider: 'p1');
    expect(await store.lastUsedAccountId, a);
    // 登录页显式 setActive:false 同款（不改 lastUsed）。
    final c = await store.save(
        jwt: _jwt(payload: {'sub': 'acc-fourth'}),
        provider: 'p1',
        setActive: false);
    expect(await store.lastUsedAccountId, a);
    expect((await store.listAccounts()).map((e) => e.id), contains(c));
    // 显式 setActive:true 才切。
    await store.save(
        jwt: _jwt(payload: {'sub': 'acc-second'}),
        provider: 'p1',
        setActive: true);
    expect(await store.lastUsedAccountId, b);
  });

  test('默认登录语义：首账号自动设当前，第二账号不切（回测组3 P1-1 修正锁）',
      () async {
    final mem = _MemStorage();
    final store = AccountStore(storage: mem);
    // 全新安装：默认 save（登录页现行为）→ 首账号成为当前。
    final a = await store.save(
        jwt: _jwt(payload: {'sub': 'acc-first'}), provider: 'p1');
    expect(await store.lastUsedAccountId, a,
        reason: '首账号（lastUsed 空）默认自动设当前');
    // 第二账号（默认）→ 不抢当前。
    await store.save(
        jwt: _jwt(payload: {'sub': 'acc-second'}), provider: 'p1');
    expect(await store.lastUsedAccountId, a);
    // 删空重登（删号清了 lastUsed）→ 新登录自动成为当前。
    await store.removeAccount(a);
    await store.removeAccount('acc-second');
    final c = await store.save(
        jwt: _jwt(payload: {'sub': 'acc-third'}), provider: 'p1');
    expect(await store.lastUsedAccountId, c,
        reason: '删空后重登=事实首账号，自动设当前（修复前 setActive:false 路径会漏）');
  });

  test('备注名持久化 + 显示名优先级（multi-account-ux-1 批1）', () async {
    final mem = _MemStorage();
    final store = AccountStore(storage: mem);
    final id = await store.save(
        jwt: _jwt(payload: {'sub': 'acc-lab'}), provider: 'bigmodel');
    var list = await store.listAccounts();
    expect(list.single.displayName, list.single.shortLabel,
        reason: '未设置备注名回退短码');
    await store.renameAccount(id, '  公司订阅  ');
    list = await store.listAccounts();
    expect(list.single.label, '公司订阅', reason: '构造期 trim');
    expect(list.single.displayName, '公司订阅');
    final reloaded = AccountStore(storage: mem);
    expect((await reloaded.listAccounts()).single.label, '公司订阅',
        reason: '落盘往返');
    await store.save(
        jwt: _jwt(payload: {'sub': 'acc-lab'}), provider: 'bigmodel');
    expect((await store.listAccounts()).single.label, '公司订阅',
        reason: '续期保留备注名');
    await store.renameAccount(id, '');
    list = await store.listAccounts();
    expect(list.single.label, isEmpty);
    expect(list.single.displayName, list.single.shortLabel,
        reason: '清空回退短码');
  });

  test('备注名不改 lastUsed / 不动凭据（批1 语义约束）', () async {
    final mem = _MemStorage();
    final store = AccountStore(storage: mem);
    final a = await store.save(
        jwt: _jwt(payload: {'sub': 'acc-a'}), provider: 'p1');
    final b = await store.save(
        jwt: _jwt(payload: {'sub': 'acc-b'}), provider: 'p2');
    final lastBefore = await store.lastUsedAccountId;
    await store.renameAccount(a, 'A 号');
    expect(await store.lastUsedAccountId, lastBefore,
        reason: '重命名不切当前账号');
    expect(await store.readJwtFor(a), isNotNull, reason: '凭据不受影响');
    expect((await store.listAccounts()).map((e) => e.id), containsAll([a, b]));
  });

  test('clearAccount(null) 不再隐式全清（开源审查 K1 P2-3/I1 P1-1：防"未绑定档案 401"清光全部账号）', () async {
    final mem = _MemStorage();
    final store = AccountStore(storage: mem);
    await store.save(jwt: _jwt(payload: {'sub': 'a'}), provider: 'p1');
    await store.save(jwt: _jwt(payload: {'sub': 'b'}), provider: 'p2');

    await store.clearAccount(null);

    // 红：旧契约 null=clear() 全清（一次未绑定档案的 401 清光全部账号）。
    expect(await store.hasAccount, isTrue);
    expect((await store.listAccounts()).map((a) => a.id),
        unorderedEquals(['a', 'b']));
  });

  test('档案 accountId 序列化往返（null 与非空）', () async {
    final mem = _MemStorage();
    final ps = ProfileStore(storage: mem);
    await ps.upsertProfile(_v2Profile(sid: 'sid-1', accountId: 'acc-a'));
    final list = await ps.listProfiles();
    expect(list, hasLength(1));
    expect((list.first as AccountV2Profile).accountId, 'acc-a');

    // 旧数据（无 accountId 字段）读出=null（连接方退最近使用）。档案存
    // 单键数组（profile.relay.list）——先正规入库再把数组内条目改回旧
    // 形态（去掉 accountId 字段）。
    await ps.upsertProfile(_v2Profile(sid: 'sid-2', accountId: 'x'));
    final rawList =
        (jsonDecode(mem.data['profile.relay.list']!) as List).toList();
    final idx = rawList.indexWhere((e) => e['sid'] == 'sid-2');
    rawList[idx] = {
      'kind': 'v2',
      'sid': 'sid-2',
      'label': '旧机',
      'addedAt': 1700000000000,
    };
    mem.data['profile.relay.list'] = jsonEncode(rawList);
    final list2 = await ps.listProfiles();
    final legacy =
        list2.firstWhere((p) => p.deviceSid == 'sid-2') as AccountV2Profile;
    expect(legacy.accountId, isNull);
  });
}
