import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/computer_stack.dart';
import 'package:zcode_pocket/state/profile_store.dart';
import 'package:zcode_pocket/transport/relay_client.dart';
import 'package:zcode_pocket/transport/z_transport.dart';

/// backlog 36 红绿（2026-10-29 批次）：后台栈失败被 过滤门拦下
/// 不顶替展示（多电脑防串台），但切回该电脑时必须回捞这条近期失败
/// 重放给诊断状态——修复前 relayDiagnosis 无数据，横幅只剩通用
/// "重连中"。单电脑场景（activate 同一活跃栈）行为无变化。

class _NoopProfileStore extends ProfileStore {
  @override
  Future<void> setActiveDeviceSid(String? sid) async {}
}

AccountV2Profile _profileOf(String sid) => AccountV2Profile(
  deviceSid: sid,
  deviceMid: 'mid-$sid',
  deviceName: '测试桌面-$sid',
  appVersion: 'test',
  label: '测试桌面-$sid',
  addedAt: DateTime.now(),
);

/// 冻结栈：start/pokeOrResume 空实现——activate 走到 pokeOrResume 时不
/// 发起真实连接（离线端点会让重连计时器越过测试结束，与 dispose 竞态）。
class _FrozenStack extends ComputerStack {
  _FrozenStack(AccountV2Profile profile)
    : super(profile: profile, onLog: (_) {}, onFailure: (_, _) {});
  @override
  Future<void> start() async {}
  @override
  Future<void> pokeOrResume() async {}
}

_FrozenStack _frozenStack(String sid) => _FrozenStack(_profileOf(sid));

void main() {
  test('后台栈失败不顶替展示；切回回捞重放诊断', () async {
    final app = AppState(store: _NoopProfileStore());
    final stackB = _frozenStack('sid-b');
    app.debugRegisterStackForTest(stackB);

    // 后台栈失败 → 过滤门拦下（不顶替展示）。
    await app.debugStackFailure(stackB, const RelayFailure('network-dns'));
    expect(
      app.lastRelayFailReason,
      isNull,
      reason: 'A6②：后台栈失败不得顶替活跃栈的诊断状态',
    );

    // 切回该电脑 → 回捞重放，诊断状态有内容。
    await app.activate(_profileOf('sid-b'));
    expect(
      app.lastRelayFailReason,
      'network-dns',
      reason: 'backlog 36：切回须回捞该栈近期失败，否则横幅只剩"重连中"',
    );
    stackB.dispose();
  });

  test('超过 2 分钟的旧失败不回捞（对齐 relayDiagnosis 时效）', () async {
    final app = AppState(store: _NoopProfileStore());
    final stackC = _frozenStack('sid-c');
    app.debugRegisterStackForTest(stackC);

    await app.debugStackFailure(stackC, const RelayFailure('network-dns'));
    expect(
      app.debugFailureRecordForTest('sid-c'),
      isNotNull,
      reason: '前置：失败已按栈记录',
    );
    app.debugAgeStackFailureForTest('sid-c', const Duration(minutes: 3));

    await app.activate(_profileOf('sid-c'));
    expect(
      app.lastRelayFailReason,
      isNull,
      reason: '过期失败不重放（人话诊断有时效，过期只剩重连中属预期）',
    );
    stackC.dispose();
  });
}
