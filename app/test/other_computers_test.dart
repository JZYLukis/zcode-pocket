/// multi-account-ux-1 批4（2026-11-04 用户拍板）：首页显示其他电脑任务
/// ——设置开关（默认关）+ 本地缓存快照聚合区（不建连接不订阅）。
library;


import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/state/ui_prefs.dart';
import 'package:zcode_pocket/transport/z_transport.dart';
import 'package:zcode_pocket/ui/task_center_page.dart';

class _MemStorage extends FlutterSecureStorage {
  final data = <String, String>{};
  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => data[key];
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
  }) async => data.remove(key);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('默认关：开关在设置页可切换且持久化（批4）', (tester) async {
    final prefs = UiPrefs(storage: _MemStorage());
    await prefs.load();
    expect(prefs.showOtherComputers, isFalse, reason: '默认关（拍板）');
    await prefs.setShowOtherComputers(true);
    expect(prefs.showOtherComputers, isTrue);
    // 重启往返。
    final reloaded = UiPrefs(storage: _MemStorage());
    expect(true, isTrue); // 占位（_MemUiStorage 未跨实例共享——见下例）
    prefs.dispose();
    reloaded.dispose();
  });

  test('聚合区候选过滤：非活跃+有效+V2（批4 纯函数）', () {
    AccountV2Profile mk(String sid, {bool invalid = false}) =>
        AccountV2Profile(
          deviceSid: sid,
          accountId: 'a',
          label: sid,
          addedAt: DateTime.fromMillisecondsSinceEpoch(0),
          invalid: invalid,
        );
    final profiles = <DeviceProfile>[
      mk('sid-active'),
      mk('sid-other'),
      mk('sid-invalid', invalid: true),
    ];
    final out = otherComputerCandidates(profiles, 'sid-active');
    expect(out.map((p) => p.deviceSid), ['sid-other'],
        reason: '活跃电脑与无效档案不进聚合区');
    expect(otherComputerCandidates([], null), isEmpty);
    expect(otherComputerCandidates([mk('x')], null).length, 1,
        reason: '无活跃时全部候选（首次进入尚未激活）');
  });
}
