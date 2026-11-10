// 通知服务层修复批（2026-11-09）红绿：
// - 冷启动孤儿清理只清本 app 任务/目标通道，审批条目保留（此前无条件
//   cancelAll 把仍在等待的审批通知一并清掉，差分不会补发）；
// - 事件 id 起点避开前台服务常驻通知 id（ForegroundService.kt 用 100）。
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/notify/notification_service.dart';
import 'package:zcode_pocket/state/notify_core.dart';

class _Backend implements NotificationBackend {
  _Backend({this.active = const []});

  final List<NotifyActiveEntry> active;
  final cancelled = <int>[];
  int cancelAllCalls = 0;
  int shownId = -1;

  @override
  Future<bool> initialize() async => true;

  @override
  void setTapHandler(void Function(NotifyTapPayload payload)? handler) {}

  @override
  Future<bool> requestPermission() async => true;

  @override
  Future<void> show(
    int id,
    String title,
    String body,
    String channel,
    String payload,
  ) async {
    shownId = id;
  }

  @override
  Future<void> cancel(int id) async {
    cancelled.add(id);
  }

  @override
  Future<void> cancelAll() async {
    cancelAllCalls++;
  }

  @override
  Future<List<NotifyActiveEntry>> activeNotifications() async => active;

  @override
  Future<String?> launchPayload() async => null;
}

void main() {
  test('冷启动孤儿清理选择性：tasks/goals 清，审批与未知通道保留', () async {
    final backend = _Backend(active: const [
      NotifyActiveEntry(id: 1, channelId: 'tasks'),
      NotifyActiveEntry(id: 2, channelId: 'approvals'),
      NotifyActiveEntry(id: 3, channelId: 'goals'),
      NotifyActiveEntry(id: 4, channelId: null),
    ]);
    final service = NotificationService(backend: backend);
    await service.init();

    // 红：修复前无条件 cancelAll——仍在等待的审批通知被清且差分不补发。
    expect(backend.cancelAllCalls, 0, reason: '不再全清');
    expect(backend.cancelled, unorderedEquals([1, 3]),
        reason: '只清任务/目标通道遗留条目');
  });

  test('后端不提供在栏列表（返回空）时不清扫（宁留待过期不误杀审批）', () async {
    final backend = _Backend();
    final service = NotificationService(backend: backend);
    await service.init();
    expect(backend.cancelled, isEmpty);
    expect(backend.cancelAllCalls, 0);
  });

  test('事件 id 从 1000 起编，避开前台服务常驻通知 id=100', () async {
    final backend = _Backend();
    final service = NotificationService(backend: backend);
    await service.init();
    await service.post(NotifyEvent(
      channel: NotifyChannel.tasks,
      kind: NotifyEventKind.taskCompleted,
      deviceSid: 'd1',
      taskId: 't1',
      title: '任务',
      atMs: 1,
    ));
    expect(backend.shownId, greaterThanOrEqualTo(1000),
        reason: '红：修复前从 1 起编，第 100 条任务通知会顶掉常驻状态通知');
  });

    test('F5：冷启动遗留审批接管进簿，新通知不覆盖、clearStale 清得掉', () async {
      final backend = _Backend(active: [
        const NotifyActiveEntry(
          id: 1002,
          channelId: 'approvals',
          payload: '{"sid":"d1","task":"t-x","kind":"approvalPending","at":1700000000000}',
        ),
        const NotifyActiveEntry(id: 1003, channelId: 'tasks'),
      ]);
      final service = NotificationService(backend: backend);
      await service.init();
      expect(backend.cancelled, contains(1003));
      expect(backend.cancelled, isNot(contains(1002)));
      expect(service.activeForTest[1002], ('t-x', 'approvals'),
          reason: '遗留审批必须进本进程簿（否则永清不掉）');
      await service.post(NotifyEvent(
        channel: NotifyChannel.tasks,
        kind: NotifyEventKind.taskCompleted,
        deviceSid: 'd1',
        taskId: 't-new',
        title: '任务',
        atMs: 1,
      ));
      expect(backend.shownId, greaterThan(1003),
          reason: '修复前 _nextId 从 1000 重起 → 第 3 条新通知顶掉在栏审批');
    });
}
