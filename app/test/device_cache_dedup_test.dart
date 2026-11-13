import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/state/cache_policy.dart';
import 'package:zcode_pocket/state/computer_stack.dart';
import 'package:zcode_pocket/state/local_cache.dart';
import 'package:zcode_pocket/transport/z_transport.dart';

/// 设备缓存内容去重（电量批 2026-10-30， 验收电量反馈）：
/// 后台保活期订阅持续推帧，任务列表模型每 ~5s notify 一次但内容大多
/// 无差异——真机日志实证 [cache] device saved 连续 9 次写同内容
/// （workspaces=9 tasks=1，间隔 5-7s）。本用例锁行为：
/// - 间隔超过 debounce 的同内容 notify **不重复落盘**（指纹去重）；
/// - 内容真变更照常落盘。
/// 红绿：旧实现（无指纹）第二段会写出第 2 条 device saved。
Future<void> _pollUntil(
  bool Function() test,
  String because, {
  Duration timeout = const Duration(seconds: 4),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (test()) return;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  expect(test(), isTrue, reason: because);
}

void main() {
  test('设备缓存内容去重：同内容重复 notify 只落一次盘，真变更才再写', () async {
    final dir = await Directory.systemTemp.createTemp('dedup-cache');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = LocalCacheStore(dir);
    final logs = <String>[];
    int savedCount() => logs.where((l) => l.contains('device saved')).length;
    final stack = ComputerStack(
      profile: AccountV2Profile(
        deviceSid: 'device-dedup',
        accountId: 'account-dedup',
        label: '去重测试',
        addedAt: DateTime.fromMillisecondsSinceEpoch(0),
      ),
      cache: store,
      onLog: logs.add,
      onFailure: (_, _) {},
    );
    addTearDown(stack.dispose);
    await store.writeDevice(
      DeviceCacheEntry(
        deviceSid: 'device-dedup',
        workspaces: const [],
        projects: const [],
        projectTasks: const [],
        workspaceTasks: const [],
        activeWorkspace: const {},
        desktopAppVersion: '3.16.3',
        sessions: const [],
        channelActive: const [],
        pinnedIds: const [],
        archivedIds: const [],
        deletedIds: const [],
        savedAt: 1,
      ),
    );
    await stack.debugLoadDeviceCacheForTest();
    final model = stack.taskList;
    expect(model, isNotNull, reason: '设备缓存种子应恢复出任务列表模型');

    final sameActive = <Map<String, dynamic>>[
      {'taskId': 't1', 'title': 'A'},
    ];
    // 第一次 notify：内容与种子不同（channel 列表从未写过）→ 正常落盘。
    model!.applyChannelLists(
      active: sameActive,
      pinnedIds: const [],
      archivedIds: const [],
    );
    await _pollUntil(
      () => savedCount() == 1,
      '首次内容应落盘一次（device saved=1）',
    );

    // 第二次 notify（间隔 > debounce 1.5s，模拟真机 5s 节奏）：内容完全
    // 相同 → 不落盘。红：旧实现此处会多写一条。
    model.applyChannelLists(
      active: sameActive,
      pinnedIds: const [],
      archivedIds: const [],
    );
    await Future<void>.delayed(const Duration(milliseconds: 2200));
    expect(
      savedCount(),
      1,
      reason: '同内容重复 notify（超过 debounce 间隔）不应再落盘',
    );

    // 内容真变更 → 照常落盘。
    model.applyChannelLists(
      active: <Map<String, dynamic>>[
        {'taskId': 't1', 'title': 'A'},
        {'taskId': 't2', 'title': 'B'},
      ],
      pinnedIds: const [],
      archivedIds: const [],
    );
    await _pollUntil(
      () => savedCount() == 2,
      '内容真变更应再落盘一次（device saved=2）',
    );

    // 落盘产物可读且含新内容（写路径未被去重破坏）。
    final persisted = await store.readDevice('device-dedup');
    expect(persisted, isNotNull);
    expect(persisted!.channelActive.length, 2);
  });

  test('写失败不更新指纹：同内容下轮重试落盘（早前批次 A8）', () async {
    final dir = await Directory.systemTemp.createTemp('dedup-retry');
    addTearDown(() => dir.deleteSync(recursive: true));
    // 模拟瞬时 IO 错误：种子写成功 → 首次变更写失败 → 恢复。
    var failWrites = false;
    final store = _FlakyStore(dir, () => failWrites);
    final logs = <String>[];
    int savedCount() => logs.where((l) => l.contains('device saved')).length;
    final stack = ComputerStack(
      profile: AccountV2Profile(
        deviceSid: 'device-retry',
        accountId: 'account-retry',
        label: '重试测试',
        addedAt: DateTime.fromMillisecondsSinceEpoch(0),
      ),
      cache: store,
      onLog: logs.add,
      onFailure: (_, _) {},
    );
    addTearDown(stack.dispose);
    await store.writeDevice(
      DeviceCacheEntry(
        deviceSid: 'device-retry',
        workspaces: const [],
        projects: const [],
        projectTasks: const [],
        workspaceTasks: const [],
        activeWorkspace: const {},
        desktopAppVersion: '3.16.3',
        sessions: const [],
        channelActive: const [],
        pinnedIds: const [],
        archivedIds: const [],
        deletedIds: const [],
        savedAt: 1,
      ),
    );
    await stack.debugLoadDeviceCacheForTest();
    final model = stack.taskList!;
    final active = <Map<String, dynamic>>[
      {'taskId': 't1', 'title': 'A'},
    ];
    model.applyChannelLists(
      active: active,
      pinnedIds: const [],
      archivedIds: const [],
    );
    failWrites = true;
    await _pollUntil(() => store.writeAttempts >= 1 && savedCount() == 0,
      '首次写应发生且失败',
      timeout: const Duration(seconds: 4),
    );
    failWrites = false;
    // 同内容再次 notify（>debounce 间隔）——写失败未被记账，必须重试。
    model.applyChannelLists(
      active: active,
      pinnedIds: const [],
      archivedIds: const [],
    );
    await _pollUntil(
      () => savedCount() == 1,
      '写失败后同内容必须重试落盘（修复前：指纹已记账=永不重写）',
    );
  });
}

/// 首写可注入失败的 store（红绿：写失败语义透出）。
class _FlakyStore extends LocalCacheStore {
  _FlakyStore(super.baseDir, this.shouldFail);
  final bool Function() shouldFail;
  int writeAttempts = 0;

  @override
  Future<bool> writeDevice(DeviceCacheEntry entry) async {
    writeAttempts++;
    if (shouldFail()) {
      // 模拟 IO 失败（不落盘）。
      return false;
    }
    return super.writeDevice(entry);
  }
}
