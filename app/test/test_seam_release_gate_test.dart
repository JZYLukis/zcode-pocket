import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/state/account_store.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/profile_store.dart';
import 'package:zcode_pocket/transport/relay_v2.dart';

/// 正式包测试缝闸门红绿：release 模式下 intent extra 的
/// 连接地址覆盖/账号凭据注入被忽略、非官方域配对链接被拒；debug 行为
/// 不回归。修复前=闸门机制不存在、load() 无条件应用三条注入（对应账号
/// 令牌外发面，静态调用链见

/// 内存 secure storage 替身（ProfileStore 测试缝同款，profile_store_test）。
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

/// 返回 (app, storage)：测试须直接断言凭据未写进存储。
(AppState, _MemStorage) _app() {
  final storage = _MemStorage();
  return (
    AppState(
      store: ProfileStore(storage: storage),
      accountStore: AccountStore(storage: storage),
    ),
    storage,
  );
}

void main() {
  tearDown(() {
    AppState.releaseSeamForTest = false;
    relayV2EndpointOverride = null;
  });

  test('release 闸门：origin 覆盖/凭据注入被忽略，非官方配对域被拒', () async {
    final (app, storage) = _app();
    AppState.releaseSeamForTest = true;
    app.testLaunchArgsReader = () async => {
      'relay_v2_origin': 'https://rogue.example.org',
      'account_jwt': 'fake-jwt-should-never-land',
      'url': 'https://rogue.example.org/remote/v4?sid=s&hash=h&t=1',
      'name': 'rogue',
    };
    await app.load();
    expect(relayV2EndpointOverride, isNull, reason: 'origin 覆盖不得生效');
    expect(
      storage.data,
      isEmpty,
      reason: '凭据注入被忽略（不落 Keystore）且不新增档案',
    );
    expect(app.profiles, isEmpty, reason: '非官方域配对链接必须被拒');
    expect(
      app.log.any((l) => l.contains('release seam gate')),
      isTrue,
      reason: '拦截须留日志证据',
    );
    app.dispose();
  });

  test('release 闸门：官方域配对链接放行（冒烟工作流不回归）', () async {
    final (app, _) = _app();
    AppState.releaseSeamForTest = true;
    app.testLaunchArgsReader = () async => {
      // 官方域但缺 sid/hash/t——过闸门后 addComputer 解析失败为预期，
      // 用日志证明"抵达了 addComputer"（真链接会走网络，不适合单测）。
      'url': 'https://zcode.z.ai/remote/v4',
      'name': 'official-host',
    };
    await app.load();
    expect(app.profiles, isEmpty);
    expect(
      app.log.any((l) => l.contains('test pairing via intent extra')),
      isTrue,
      reason: '官方域必须过闸门抵达配对路径（release 冷启动验证依赖）',
    );
    expect(
      app.log.any((l) => l.contains('test pairing failed')),
      isTrue,
      reason: '缺参数链接在 addComputer 解析失败（预期收尾）',
    );
    app.dispose();
  });

  test('debug 不回归：origin 覆盖照常生效（既有测试缝行为）', () async {
    final (app, _) = _app();
    app.testLaunchArgsReader = () async => {
      'relay_v2_origin': 'http://127.0.0.1:8787',
    };
    await app.load();
    expect(relayV2EndpointOverride, 'http://127.0.0.1:8787');
    app.dispose();
  });

  test('配对域白名单纯函数：官方/本机放行，公网杂域与前后缀伪装拒绝', () {
    expect(
      AppState.releasePairingHostAllowed(
          'https://zcode.z.ai/remote/v4?sid=s&hash=h&t=1'),
      isTrue,
    );
    expect(AppState.releasePairingHostAllowed('http://127.0.0.1:9/'), isTrue);
    expect(
      AppState.releasePairingHostAllowed('https://ROGUE.example.org'),
      isFalse,
    );
    expect(
      AppState.releasePairingHostAllowed('https://zcode.z.ai.evil.org'),
      isFalse,
    );
    expect(AppState.releasePairingHostAllowed('not a url'), isFalse);
  });
}
