// 多账号行为红绿（multi-account-plan.md §4.2，2026-10-25）：
// ①auth-required 收窄——只清失败账号，另一账号凭据/档案原样；②device
// -not-owned 不再标档案失效（引导而非死路）；③换账号重连改绑最近使用
// 账号并重建栈。
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/state/account_store.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/computer_stack.dart';
import 'package:zcode_pocket/state/profile_store.dart';
import 'package:zcode_pocket/transport/relay_client.dart';
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

String _jwt(String sub) {
  String b64(Map m) =>
      base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  return '${b64({'alg': 'none'})}.${b64({'sub': sub})}.${b64({'s': 1})}';
}

AccountV2Profile _v2(String sid, String accountId) => AccountV2Profile(
      deviceSid: sid,
      accountId: accountId,
      label: '桌面-$sid',
      addedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
    );

ComputerStack _stackOf(AccountV2Profile p) => ComputerStack(
      profile: p,
      onLog: (_) {},
      onFailure: (_, _) {},
    );

Future<(AppState, AccountStore, ProfileStore)> _boot(
  _MemStorage mem, {
  List<AccountV2Profile> profiles = const [],
}) async {
  final accounts = AccountStore(storage: mem);
  final ps = ProfileStore(storage: mem);
  for (final p in profiles) {
    await ps.upsertProfile(p);
  }
  final app = AppState(store: ps, accountStore: accounts);
  return (app, accounts, ps);
}

void main() {
  test('auth-required 收窄：只清失败账号，另一账号凭据与档案完好', () async {
    final mem = _MemStorage();
    final (app, accounts, ps) = await _boot(
      mem,
      profiles: [_v2('sid-a', 'acc-a'), _v2('sid-b', 'acc-b')],
    );
    await accounts.save(jwt: _jwt('acc-a'), provider: 'bigmodel');
    await accounts.save(jwt: _jwt('acc-b'), provider: 'zai');

    // acc-b 的栈报 401。
    final stackB = _stackOf(_v2('sid-b', 'acc-b'));
    await app.debugStackFailure(
      stackB,
      const RelayFailure('auth-required', 'jwt rejected'),
    );

    expect(await accounts.readJwtFor('acc-b'), isNull, reason: '失败账号被清');
    expect(await accounts.readJwtFor('acc-a'), _jwt('acc-a'),
        reason: '另一账号凭据不受牵连（收窄核心）');
    // 档案两个都保留（重登后直接可用——官方语义不变）。
    final profiles = await ps.listProfiles();
    expect(profiles, hasLength(2));
    final bAfter = profiles.firstWhere((p) => p.deviceSid == 'sid-b');
    expect(bAfter.invalid, isFalse, reason: 'auth-required 从不标失效');
  });

  test('device-not-owned：不标档案失效（引导而非死路）', () async {
    final mem = _MemStorage();
    final (app, accounts, ps) = await _boot(
      mem,
      profiles: [_v2('sid-a', 'acc-a')],
    );
    await accounts.save(jwt: _jwt('acc-a'), provider: 'bigmodel');

    final stackA = _stackOf(_v2('sid-a', 'acc-a'));
    await app.debugStackFailure(
      stackA,
      const RelayFailure('device-not-owned', '该电脑不属于当前账号'),
    );

    final profiles = await ps.listProfiles();
    expect(profiles.firstWhere((p) => p.deviceSid == 'sid-a').invalid, isFalse,
        reason: '账号归属问题≠档案失效（2026-10-25 多账号批语义）');
    // 账号凭据不动（归属问题≠凭据失效）。
    expect(await accounts.readJwtFor('acc-a'), _jwt('acc-a'));
  });

  test('换账号重连：活跃档案改绑最近使用账号', () async {
    final mem = _MemStorage();
    final (app, accounts, ps) = await _boot(
      mem,
      profiles: [_v2('sid-a', 'acc-a')],
    );
    await accounts.save(jwt: _jwt('acc-a'), provider: 'bigmodel');
    await accounts.save(jwt: _jwt('acc-b'), provider: 'zai');

    // 活跃档案= sid-a（绑 acc-a）；用户在引导里登录了 acc-b（=最近使用）。
    final profileA = (await ps.listProfiles()).first;
    await app.activate(profileA);
    await app.retryActiveProfileWithNewAccount();

    final profiles = await ps.listProfiles();
    expect(
      (profiles.first as AccountV2Profile).accountId,
      'acc-b',
      reason: '改绑到刚登录的账号',
    );
  });
}
