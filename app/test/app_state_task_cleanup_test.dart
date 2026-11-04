import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/computer_stack.dart';
import 'package:zcode_pocket/state/draft_store.dart';
import 'package:zcode_pocket/state/profile_store.dart';
import 'package:zcode_pocket/state/send_queue_store.dart';
import 'package:zcode_pocket/transport/z_transport.dart';

/// 开源审查 E1 P2-2：归档任务必须联动清理草稿与离线排队（ADR 0059:30
/// 明文"删除任务/归档任务/电脑时清理对应草稿"）——deleteTask 链有清，
/// archiveTask 三个 UI 入口（会话内/批量/单卡）全漏。不清理的实害：
/// 断网排队中发给该会话的消息会在重连后被 drain 自动发给已归档会话。

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

class _ArchiveProbeStack extends ComputerStack {
  _ArchiveProbeStack(DeviceProfile profile)
    : super(profile: profile, onLog: (_) {}, onFailure: (_, _) {});

  @override
  Future<void> start() async {}

  @override
  Future<void> pokeOrResume() async {}

  @override
  Future<dynamic> archiveTask(String taskId) async => const {'ok': true};
}

class _ProbeDraftStore extends DraftStore {
  _ProbeDraftStore() : super(Directory.systemTemp);
  final sessionsRemoved = <String>[];

  @override
  Future<void> removeSession(String deviceSid, String sessionId) async {
    sessionsRemoved.add('$deviceSid/$sessionId');
  }
}

class _ProbeSendQueue extends SendQueueStore {
  _ProbeSendQueue()
    : super(
        File(
          '${Directory.systemTemp.path}${Platform.pathSeparator}'
          'probe-send-queue-${DateTime.now().microsecondsSinceEpoch}.json',
        ),
      );
  final sessionsRemoved = <String>[];

  @override
  Future<void> removeSession(String deviceSid, String sessionId) async {
    sessionsRemoved.add('$deviceSid/$sessionId');
  }
}

void main() {
  test('archiveTask 联动清理草稿与离线排队（修复前=RPC 后无任何清理）', () async {
    final profile = AccountV2Profile(
      deviceSid: 'device-x',
      accountId: 'acc-1',
      label: '测试桌面',
      addedAt: DateTime.fromMillisecondsSinceEpoch(0),
    );
    final drafts = _ProbeDraftStore();
    final queue = _ProbeSendQueue();
    final app = AppState(
      store: _MemoryProfiles([profile]),
      draftStore: drafts,
    );
    app.sendQueue = queue;
    addTearDown(app.dispose);

    final stack = _ArchiveProbeStack(profile);
    app.debugRegisterStackForTest(stack);
    app.profiles = [profile];
    await app.activate(profile);
    expect(app.activeProfile?.deviceSid, 'device-x');

    final res = await app.archiveTask('task-1');
    expect(res, const {'ok': true});
    expect(
      drafts.sessionsRemoved,
      ['device-x/task-1'],
      reason: '已归档会话的草稿须清理（ADR 0059:30）',
    );
    expect(
      queue.sessionsRemoved,
      ['device-x/task-1'],
      reason: '不清理则断网排队中的消息会在重连后被自动发给已归档会话',
    );
  });
}
