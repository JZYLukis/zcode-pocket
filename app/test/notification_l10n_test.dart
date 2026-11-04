import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/l10n.dart';
import 'package:zcode_pocket/notify/notification_service.dart';
import 'package:zcode_pocket/state/notify_core.dart';

class _Backend implements NotificationBackend {
  final shown = <(int, String, String)>[];

  @override
  Future<bool> initialize() async => true;
  @override
  void setTapHandler(void Function(NotifyTapPayload)? handler) {}
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
    shown.add((id, title, body));
  }
  @override
  Future<void> cancel(int id) async {}
  @override
  Future<void> cancelAll() async {}
  @override
  Future<String?> launchPayload() async => null;
}

void main() {
  tearDown(L10n.resetForTest);

  test('英文通知只翻译界面文案，用户标题与设备名保持原文', () async {
    L10n.setTestLocale('en-US');
    final backend = _Backend();
    final service = NotificationService(backend: backend);
    await service.init();
    await service.post(
      NotifyEvent(
        channel: NotifyChannel.tasks,
        kind: NotifyEventKind.taskCompleted,
        deviceSid: 'd1',
        taskId: 't1',
        title: '用户任务标题',
        atMs: 1,
      ),
      deviceLabel: '折叠屏真机',
    );
    await service.post(
      NotifyEvent(
        channel: NotifyChannel.approvals,
        kind: NotifyEventKind.approvalPending,
        deviceSid: 'd1',
        taskId: 't2',
        title: '审批任务标题',
        tool: 'Bash',
        detail: 'permission',
        atMs: 2,
      ),
      deviceLabel: '折叠屏真机',
    );
    await service.post(
      NotifyEvent(
        channel: NotifyChannel.tasks,
        kind: NotifyEventKind.awayAggregated,
        deviceSid: 'd1',
        taskId: 'aggregate',
        title: '',
        detail: '2',
        atMs: 3,
      ),
      deviceLabel: '折叠屏真机',
    );

    expect(backend.shown[0].$2, '折叠屏真机 · Task completed');
    expect(backend.shown[0].$3, '用户任务标题');
    expect(backend.shown[1].$2, '折叠屏真机 · Approval required');
    expect(backend.shown[1].$3, 'Bash · 审批任务标题');
    expect(
      backend.shown[2].$2,
      '折叠屏真机 · 2 tasks completed while you were away',
    );
    expect(backend.shown[2].$3, 'Tap to view task');
  });
}
