import 'dart:convert';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../state/notify_core.dart';
import '../core/l10n.dart';

/// 安卓通知后端缝（生产 flutter_local_notifications / 测试 Fake）。
abstract class NotificationBackend {
  Future<bool> initialize();

  /// 热点击回调接线（生产后端把插件的回调转发到这里）。
  void setTapHandler(void Function(NotifyTapPayload payload)? handler) {}
  Future<bool> requestPermission();
  Future<void> show(int id, String title, String body, String channel, String payload);
  Future<void> cancel(int id);

  /// 清全部（保留给后端/诊断；启动清理改走 [activeNotifications] +
  /// [cancel] 的选择性路径——审批条目不能在冷启动被误清）。
  Future<void> cancelAll() async {}

  /// 通知栏现存条目（冷启动选择性清理输入）。不支持/查询失败时返回
  /// 空——调用方据此不清扫（宁可让 tasks/goals 条目按 timeoutAfter
  /// 自然过期，也不误杀仍在等待的审批）。
  Future<List<NotifyActiveEntry>> activeNotifications() async => const [];

  /// 冷启动来源（app 由通知点开启动时的 payload；无=null）。
  Future<String?> launchPayload() async => null;
}

/// 通知栏现存条目（id + 通道）。
class NotifyActiveEntry {
  final int id;
  final String? channelId;

  /// 点击路由 payload（F5 接管簿用：冷启动时按它把遗留审批条目还原
  /// 进本进程 _active/_idsByTask）。
  final String? payload;
  const NotifyActiveEntry({required this.id, this.channelId, this.payload});
}

/// 点击路由 payload（不塞完整对象，sid+taskId 反查——设计文档约定）。
class NotifyTapPayload {
  final String deviceSid;
  final String taskId;
  final String kind; // NotifyEventKind.name

  /// 通知产生时刻（事件 atMs）——两步式深链用它定位「产生通知的那条
  /// 消息」（2026-11-04 用户拍板：打开会话后弹短暂浮层，用户确认再定位）。
  final int atMs;
  const NotifyTapPayload(this.deviceSid, this.taskId, this.kind,
      {this.atMs = 0});

  String encode() =>
      jsonEncode({'sid': deviceSid, 'task': taskId, 'kind': kind, 'at': atMs});

  static NotifyTapPayload? decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final map = (jsonDecode(raw) as Map).cast<String, dynamic>();
      final sid = '${map['sid'] ?? ''}';
      final task = '${map['task'] ?? ''}';
      if (sid.isEmpty || task.isEmpty) return null;
      return NotifyTapPayload(
        sid,
        task,
        '${map['kind'] ?? ''}',
        atMs: (map['at'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      return null;
    }
  }
}

/// 通知服务（三通道 + 点击路由 + 回前台清过时）。
///
/// 通道常量与点击 payload 在本文件一处定义（设计文档约定）；
/// 台账与差分在协调器（notify_coordinator.dart），本类只管安卓侧。
class NotificationService {
  NotificationService({required this.backend});

  final NotificationBackend backend;

  static const channelApprovals = 'approvals'; // 审批：高优先级 heads-up
  static const channelTasks = 'tasks'; // 完成/失败
  static const channelGoals = 'goals'; // Goal 里程碑

  String channelOf(NotifyChannel c) => switch (c) {
    NotifyChannel.approvals => channelApprovals,
    NotifyChannel.tasks => channelTasks,
    NotifyChannel.goals => channelGoals,
  };

  bool _ready = false;
  bool get ready => _ready;

  /// 冷启动点击 payload（init 时尚未接线 onTap——由 AppState 挂好
  /// 路由后 consumePendingLaunch 取走，微任务时序吞 payload 的修法，
  /// 发现2b）。
  NotifyTapPayload? _pendingLaunch;

  /// 活跃通知簿（清过时用）：id → (taskId, channel)。
  final Map<int, (String, NotifyChannel)> _active = {};
  Map<int, (String, String)> get activeForTest => {
    for (final e in _active.entries) e.key: (e.value.$1, e.value.$2.name),
  };

  /// 点击路由回调（协调器注入：activate 栈 → 打开会话页）。
  void Function(NotifyTapPayload payload)? onTap;

  /// 初始化 + 冷启动点击 payload 暂存 + 孤儿通知清理。
  Future<void> init({String? launchPayload}) async {
    try {
      _ready = await backend.initialize();
    } catch (_) {
      _ready = false;
    }
    // 热点击接线：后端回调 → handleTap（此前生产后端自己的 onTap 字段
    // 无人赋值，点击只在通知层空转——发现2a）。
    backend.setTapHandler(handleTap);
    // 上一进程遗留的通知栏孤儿（本进程 _active 为空清不到）：只清
    // 本 app 的任务/目标通道——审批条目保留（冷启动差分不会补发仍在
    // 等待的审批，全清=审批提醒永久丢失，状态层批）。查询不到在栏
    // 列表时不清扫（tasks/goals 有 timeoutAfter 自然过期兜底）。
    try {
      final active = await backend.activeNotifications();
      for (final n in active) {
        // F5（复审）②：_nextId 先越过**全部**遗留 id（含将被清除的
        // tasks/goals）——避免新通知按 id 覆盖任何在栏条目。
        if (n.id >= _nextId) _nextId = n.id + 1;
        if (n.channelId == channelTasks || n.channelId == channelGoals) {
          await backend.cancel(n.id);
          continue;
        }
        // F5（复审）①：遗留审批条目接管进本进程簿——clearStale 从此
        // 清得掉（审批不过期）。
        if (n.channelId == channelApprovals) {
          final pl = NotifyTapPayload.decode(n.payload);
          if (pl != null) {
            _active[n.id] = (pl.taskId, NotifyChannel.approvals);
            _idsByTask['${NotifyChannel.approvals.name}:${pl.taskId}'] = n.id;
          }
        }
      }
    } catch (_) {}
    final raw = launchPayload ?? await backend.launchPayload();
    _pendingLaunch = NotifyTapPayload.decode(raw);
  }

  /// 冷启动点击路由（AppState 挂好 onTap 后调用一次；消费后置空）。
  NotifyTapPayload? consumePendingLaunch() {
    final p = _pendingLaunch;
    _pendingLaunch = null;
    return p;
  }

  Future<bool> ensurePermission() async {
    try {
      return await backend.requestPermission();
    } catch (_) {
      return false;
    }
  }

  /// 事件 id 起点避开前台服务常驻通知 id（ForegroundService.kt 用 100）
  /// ——从 1 起编时第 100 条任务通知会覆盖/顶掉常驻状态通知。
  int _nextId = 1000;
  final Map<String, int> _idsByTask = {};

  /// H1-P3-04-4：截断点避开 UTF-16 代理对（emoji）中间——
  /// 孤立代理项经平台通道 UTF-8 编码成 U+FFFD 显示为乱码。
  static String _cutAtCodePoint(String s, int limit) {
    if (limit < s.length && (s.codeUnitAt(limit) & 0xFC00) == 0xDC00) {
      return s.substring(0, limit - 1);
    }
    return s.substring(0, limit);
  }

  /// 事件 id：同任务同通道复用（新事件覆盖旧通知，不堆叠）。
  int _idOf(NotifyEvent e) =>
      _idsByTask.putIfAbsent('${e.channel.name}:${e.taskId}', () => _nextId++);

  Future<bool> post(NotifyEvent e, {String? deviceLabel}) async {
    if (!_ready) return false;
    final id = _idOf(e);
    final label = (deviceLabel == null || deviceLabel.isEmpty) ? '' : '$deviceLabel · ';
    final String title;
    switch (e.kind) {
      case NotifyEventKind.taskCompleted:
        title = '$label${tr('任务完成')}';
      case NotifyEventKind.taskFailed:
        title = '$label${tr('任务失败')}';
      case NotifyEventKind.approvalPending:
        title = '$label${e.detail == 'userInput' ? tr('等你输入') : tr('等你审批')}';
      case NotifyEventKind.goalSettled:
        // F26（2026-10-24 修复批）：三值细分（官方 snapshot.ts:427-428
        // ——notSatisfied=有效结论未达成；failed=验证过程失败）。
        title = '$label${switch (e.detail) {
          'verified' => tr('目标达成'),
          'failed' => tr('目标验证失败'),
          _ => tr('目标未达成'),
        }}';
      case NotifyEventKind.goalVerifying:
        title = '$label${tr('目标验证中')}';
      case NotifyEventKind.awayAggregated:
        // F26：聚合通知也带设备名（多电脑区分谁完成了任务）。
        title = '$label${tr('你不在时完成了 ${e.detail} 个任务')}';
    }
    // F26 正文打磨：完成/失败带最后回复预览（比标题更贴近"完成了
    // 什么"，缺省回退标题）；审批带轻量工具名（si 透传，不带问题等
    // 敏感 payload）；聚合保持引导点击。
    final String body;
    if (e.kind == NotifyEventKind.awayAggregated) {
      // H1-P3-05：聚合点击实际直达 sampleTask 会话页（非任务
      // 列表）——文案与行为对齐。
      body = tr('点按查看任务');
    } else if (e.kind == NotifyEventKind.approvalPending) {
      final tool = (e.tool ?? '').trim();
      body = tool.isEmpty
          ? (e.title.isEmpty ? tr('点按查看任务') : e.title)
          : '$tool · ${e.title}';
    } else {
      final pv = (e.preview ?? '').trim();
      if (pv.isNotEmpty) {
        body = pv.length > 60 ? '${_cutAtCodePoint(pv, 60)}…' : pv;
      } else {
        body = e.title.isEmpty ? tr('点按查看任务列表') : e.title;
      }
    }
    try {
      await backend.show(
        id,
        title,
        body,
        channelOf(e.channel),
        NotifyTapPayload(e.deviceSid, e.taskId, e.kind.name, atMs: e.atMs)
            .encode(),
      );
      _active[id] = (e.taskId, e.channel);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 回前台清过时通知（Tactic 借鉴）：任务/Goal 通道全清（完成类通知
  /// 在回前台后已无提醒价值），审批通道只保留仍在等待的。
  /// [limitToIds]：只清这个 id 集合（=回前台时刻已在栏的快照——回前台
  /// 后新发的通知（如"你不在时完成了 N 个"聚合）不清，否则刚发即被
  /// 3s 清理定时器吃掉）。
  Future<void> clearStale({
    required Set<String> stillPendingTaskIds,
    Set<int>? limitToIds,
  }) async {
    final candidates = limitToIds ?? _active.keys.toList();
    final staleIds = <int>[];
    for (final id in candidates) {
      final info = _active[id];
      if (info == null) continue;
      final (taskId, channel) = info;
      switch (channel) {
        case NotifyChannel.tasks:
        case NotifyChannel.goals:
          staleIds.add(id);
        case NotifyChannel.approvals:
          if (!stillPendingTaskIds.contains(taskId)) staleIds.add(id);
      }
    }
    for (final id in staleIds) {
      try {
        await backend.cancel(id);
      } catch (_) {}
      final info = _active.remove(id);
      // H1-P3-04-1/H2-P3-1：同步回收 id 簿条目——_idsByTask
      // 此前只增不减（FGS 常驻数周场景纯泄漏型增长）。
      if (info != null) {
        _idsByTask.remove('${info.$2.name}:${info.$1}');
      }
    }
  }

  /// 当前活跃通知 id 快照（回前台清过时的候选集来源）。
  Set<int> activeNotificationIds() => Set<int>.of(_active.keys);

  /// 通知点击（前台运行时回调入口，backend 转发）。
  void handleTap(NotifyTapPayload payload) => onTap?.call(payload);
}

/// 生产后端（flutter_local_notifications 封装）。只在有平台通道的环境
/// 构造（main.dart）；纯测试注入 FakeBackend。
class FlutterLocalNotificationsBackend implements NotificationBackend {
  FlutterLocalNotificationsBackend();

  final _plugin = FlutterLocalNotificationsPlugin();
  void Function(NotifyTapPayload payload)? _onTap;

  @override
  void setTapHandler(void Function(NotifyTapPayload payload)? handler) {
    _onTap = handler;
  }

  @override
  Future<bool> initialize() async {
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const settings = InitializationSettings(android: android);
    final ok = await _plugin.initialize(
      settings: settings,
      onDidReceiveNotificationResponse: (response) {
        final payload = NotifyTapPayload.decode(response.payload);
        if (payload != null) _onTap?.call(payload);
      },
    );
    return ok ?? false;
  }

  @override
  Future<bool> requestPermission() async {
    final impl = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    return await impl?.requestNotificationsPermission() ?? false;
  }

  @override
  Future<void> show(
    int id,
    String title,
    String body,
    String channel,
    String payload,
  ) async {
    final details = AndroidNotificationDetails(
      channel,
      _channelName(channel),
      // 单色小图标（fullsweep-1108）：默认 ic_launcher 是全图 alpha=255
      // 的启动图标，状态栏渲染成实心方块——改用 alpha-only 矢量 Z。
      icon: 'ic_notification',
      importance: channel == 'approvals' ? Importance.max : Importance.defaultImportance,
      priority: channel == 'approvals' ? Priority.high : Priority.defaultPriority,
      autoCancel: true,
      // 自动过期（ 决策 1）：tasks/goals 30 分钟后自动出栏，
      // approvals 不过期。策略在 notify_core.notificationTtlMs（纯函数，
      // 单测覆盖），此处只接线；字段=毫秒（flutter_local_notifications
      // 22.3.2 AndroidNotificationDetails.timeoutAfter），仅 Android
      // 生效（本项目唯一平台）。
      timeoutAfter: notificationTtlMs(channel),
    );
    await _plugin.show(
      id: id,
      title: title,
      body: body,
      notificationDetails: NotificationDetails(android: details),
      payload: payload,
    );
  }

  @override
  Future<void> cancel(int id) => _plugin.cancel(id: id);

  @override
  Future<void> cancelAll() => _plugin.cancelAll();

  @override
  Future<List<NotifyActiveEntry>> activeNotifications() async {
    try {
      final list = await _plugin.getActiveNotifications();
      return [
        for (final n in list)
          if (n.id != null)
            NotifyActiveEntry(
              id: n.id!,
              channelId: n.channelId,
              payload: n.payload,
            ),
      ];
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<String?> launchPayload() async {
    try {
      final details = await _plugin.getNotificationAppLaunchDetails();
      if (details?.didNotificationLaunchApp ?? false) {
        return details?.notificationResponse?.payload;
      }
    } catch (_) {}
    return null;
  }

  static String _channelName(String id) => switch (id) {
    'approvals' => tr('审批提醒'),
    'tasks' => tr('任务完成'),
    'goals' => tr('目标进展'),
    _ => id,
  };
}
