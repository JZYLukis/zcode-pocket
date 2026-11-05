import 'dart:io';

import 'dart:convert';
import 'dart:io' show Directory, Platform;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/state/profile_store.dart';
import 'package:zcode_pocket/transport/connection_params.dart';
import 'package:zcode_pocket/transport/z_transport.dart';

/// 内存 secure storage 替身（ProfileStore 测试缝，批次 2 注入）。
class FakeSecureStorage extends FlutterSecureStorage {
  FakeSecureStorage({this.latency = Duration.zero});

 /// 每操作固定延迟：模拟真实 IO 的 await 边界（交错窗口）。
  final Duration latency;
  final Map<String, String> data = {};

  Future<void> _delay() async {
    if (latency > Duration.zero) await Future<void>.delayed(latency);
  }

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    await _delay();
    return data[key];
  }

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
    await _delay();
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
  }) async {
    await _delay();
    data.remove(key);
  }
}

Uri _url(String sid) => Uri.parse(
      'https://zcode.z.ai/remote/v4?sid=$sid&hash=h&'
      't=${DateTime.now().millisecondsSinceEpoch ~/ 1000}',
    );

RelayProfile _profile(String sid, {String label = '桌面'}) => RelayProfile(
      params: CompanionConnectionParams.parse(_url(sid).toString())!,
      label: label,
      addedAt: DateTime.now(),
    );

void main() {
  group('B1 档案逐条容错', () {
    test('坏条目跳过+计数，好条目保留（原实现整体抛→全清空）', () {
      final store = ProfileStore(storage: FakeSecureStorage());
      final good = _profile('sid-ok', label: '好档案');
 // 一好一坏：url 非法 + 一条非 Map
      final json = '[${_encJson(good)},{"url":"not-a-url"},'
          '"garbage"]';
      final r = store.decodeProfileList(json);
      expect(r.profiles.length, 1);
      expect(r.profiles.first.label, '好档案');
      expect(r.skipped, 2);
    });

    test('全部好条目：skipped=0', () {
      final store = ProfileStore(storage: FakeSecureStorage());
      final json = '[${_encJson(_profile('a'))},${_encJson(_profile('b'))}]';
      final r = store.decodeProfileList(json);
      expect(r.profiles.length, 2);
      expect(r.skipped, 0);
    });

    test('端到端：listRelayProfilesDetailed 不再因单条坏数据全量失败', () async {
      final storage = FakeSecureStorage();
      final store = ProfileStore(storage: storage);
      await store.upsertProfile(_profile('sid-ok', label: '好档案'));
 // 手工塞入坏条目（模拟历史版本写入的坏数据）
      final raw = storage.data['profile.relay.list']!;
      storage.data['profile.relay.list'] =
          '${raw.substring(0, raw.length - 1)},{"url":"not-a-url"}]';
      final r = await store.listProfilesDetailed();
      expect(r.profiles.length, 1);
      expect(r.skipped, 1);
    });
  });

  group('B3 读写串行化', () {
    test('并发 upsert 不丢档案（旧读-改-写交错窗口丢更新）', () async {
      final storage = FakeSecureStorage(
        latency: const Duration(milliseconds: 5),
      );
      final store = ProfileStore(storage: storage);
 // 两个 upsert 同时在途：旧实现两者都先 read 到空表，后写者覆盖
 // 先写者（丢一台电脑）。串行化后必须都在。
      final a = store.upsertProfile(_profile('sid-a', label: 'A'));
      final b = store.upsertProfile(_profile('sid-b', label: 'B'));
      await a;
      await b;
      final r = await store.listProfilesDetailed();
      expect(r.profiles.length, 2, reason: '并发 upsert 丢了一台');
      expect(r.profiles.map((p) => p.label).toSet(), {'A', 'B'});
      expect(r.skipped, 0);
    });

    test('remove 与 upsert 并发：终态一致', () async {
      final storage = FakeSecureStorage(
        latency: const Duration(milliseconds: 3),
      );
      final store = ProfileStore(storage: storage);
      await store.upsertProfile(_profile('sid-a', label: 'A'));
      await store.upsertProfile(_profile('sid-b', label: 'B'));
      final rm = store.removeProfile('sid-a');
      final up = store.upsertProfile(_profile('sid-c', label: 'C'));
      await rm;
      await up;
      final r = await store.listProfilesDetailed();
      expect(r.profiles.map((p) => p.label).toSet(), {'B', 'C'});
    });
  });

  group('18088 自救：加密列表顶层畸形（K1 P2-4/K2 P2-1）', () {
    test('relay.list JSON 整体畸形 → 明文备份回补接管（修复前=jsonDecode 抛出短路 rescue）', () async {
      final storage = FakeSecureStorage();
      final backupPath = _tempBackupPath();
      addTearDown(() {
        final f = File(backupPath);
        if (f.existsSync()) f.deleteSync();
      });
      final store = ProfileStore(
        storage: storage,
        debugBackupPath: backupPath,
      );
      final v2 = AccountV2Profile(
        deviceSid: 'sid-v2',
        deviceMid: 'mid-v2',
        deviceName: '桌面',
        appVersion: '3.16',
        accountId: 'acc-1',
        label: '桌面',
        addedAt: DateTime.now(),
      );
      await store.upsertProfile(v2);
      expect(storage.data['profile.relay.list'], contains('sid-v2'));

 // 模拟加密层损坏出非 JSON 串（同类故障的相邻形态：值在但坏了）。
      storage.data['profile.relay.list'] = '{"kind":"v2","sid":"sid-v2"';
      final r = await store.listProfilesDetailed();
      expect(
        r.profiles.map((p) => p.deviceSid),
        ['sid-v2'],
        reason: '修复前：decodeProfileList 的 jsonDecode 抛出直接冲出 '
            '_readRaw，18088 明文备份自救层被整体短路（合法备份在旁边不参与）',
      );
      expect(
        storage.data['profile.relay.list'],
        contains('sid-v2'),
        reason: 'rescue 回补重写合法 blob（损坏值顺带自愈）',
      );
    });
  });
}

String _tempBackupPath() => '${Directory.systemTemp.path}'
    '${Platform.pathSeparator}'
    'profile-rescue-${DateTime.now().microsecondsSinceEpoch}.json';

String _encJson(RelayProfile p) => jsonEncode({
      'url': p.params.source.toString(),
      'label': p.label,
      'addedAt': p.addedAt.millisecondsSinceEpoch,
      'invalid': p.invalid,
    });
