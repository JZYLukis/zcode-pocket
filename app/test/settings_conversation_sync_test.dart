import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/state/ui_prefs.dart';
import 'package:zcode_pocket/transport/channel_client.dart';
import 'package:zcode_pocket/transport/companion_client.dart';
import 'package:zcode_pocket/ui/settings_conversation_page.dart';

/// 「提问自动采纳」开关下发载荷（开源审查 M1-P1-2/M2-P3-2/M3-P2-3 三路
/// 同报）：官方契约 ZCodeAgentAppRuntimePreferences 的
/// modelIoFullRetentionEnabled 为 **optional**（refs/snapshot-3171
/// zcodeAgent.ts:634），官方桌面 UI 下发的是 setting.json 当前值；手机端
/// 不拥有该偏好，硬编码 false 会在拨动开关时静默覆写桌面端已开启的
/// 「完整保留模型 I/O」。钉死：手机端载荷只含自己拥有的键。
/// 存储注入（locale_settings_test 同款）：真 secure storage 在测试环境
/// 的通道调用不落定，会把 onChanged 的 await 卡死在 _persist。
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
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    data[key] = value ?? '';
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
  }) async {
    data.remove(key);
  }
}

class _RecordingChannels extends ChannelClient {
  _RecordingChannels() : super(sendBody: (_) {});

  final calls = <(String, String, List<Object?>)>[];

  @override
  Future<dynamic> call(
    String channel,
    String method,
    List<Object?> args, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    calls.add((channel, method, args));
    return null;
  }
}

class _SyncBridge implements BridgeSession {
  _SyncBridge(this.channels);
  @override
  final ChannelClient channels;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _SyncApp extends AppState {
  _SyncApp(this.recorder) : uiPrefs = UiPrefs(storage: _MemStorage());
  final _RecordingChannels recorder;
  @override
  final UiPrefs uiPrefs;
  @override
  BridgeSession? get bridge => _SyncBridge(recorder);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('下发载荷只含自动采纳键，不含 modelIoFullRetentionEnabled', (tester) async {
    final recorder = _RecordingChannels();
    final app = _SyncApp(recorder);
    await tester.pumpWidget(
      AppStateScope(
        app: app,
        child: const MaterialApp(home: SettingsConversationPage()),
      ),
    );

    // 默认开——点击即切到 false 并触发一次 syncAppRuntimePreferences。
    await tester.tap(find.text('提问自动采纳'));
    await tester.pumpAndSettle();

    expect(recorder.calls, hasLength(1), reason: '开关拨动恰好下发一次');
    final (channel, method, args) = recorder.calls.single;
    expect(channel, 'zcode-agent');
    expect(method, 'syncAppRuntimePreferences');
    final payload = (args.single as Map).cast<String, Object?>();
    expect(payload['askUserQuestionAutoResolutionEnabled'], isFalse);
    expect(
      payload.containsKey('modelIoFullRetentionEnabled'),
      isFalse,
      reason: '该键官方契约为 optional 且手机端不拥有——不得硬编码 false '
          '静默覆写桌面端「完整保留模型 I/O」全局偏好',
    );
  });
}
