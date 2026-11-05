import 'dart:async';
import 'dart:typed_data';

import 'ipc_codec.dart';

/// Channel RPC client mirroring the web client's channel RPC client.
///
/// Request header array: [reqType, reqId, channelName, name] followed by the
/// argument value (an args list for calls, free-form for event listens).
/// Response: [respType, reqId] + data value.
class ChannelClient {
  static const reqPromise = 100;
  static const reqPromiseCancel = 101;
  static const reqEventListen = 102;
  static const reqEventDispose = 103;

  static const resInitialize = 200;
  static const resPromiseSuccess = 201;
  static const resPromiseError = 202;
  static const resPromiseErrorObj = 203;
  static const resEventFire = 204;

  final void Function(Uint8List ipcBody) sendBody;
  final void Function(String line)? onLog;

  int _lastRequestId = 0;
  final _initialized = Completer<void>();
  final _handlers = <int, void Function(int type, Object? data)>{};
  final _persistentEventIds = <int>{};

  ChannelClient({required this.sendBody, this.onLog});

  Future<void> get ready => _initialized.future;

  void handleMessage(Uint8List body) {
    try {
      final reader = ValueReader(body);
      final header = decodeValue(reader);
      if (header is! List || header.isEmpty || header[0] is! num) return;
      final type = (header[0] as num).toInt();
      if (type == resInitialize) {
        onLog?.call('[ipc] initialized');
        if (!_initialized.isCompleted) _initialized.complete();
        return;
      }
      if (header.length < 2 || header[1] is! num) return;
      final id = (header[1] as num).toInt();
 // 无 handler 的帧（超时后迟到响应/未知
 // id）不再整帧解码——最坏 64MiB JSON 解码纯白耗 CPU；帧间自包含，
 // 跳过读取不影响后续帧。
      final h = _handlers[id];
      if (h == null) return;
      dynamic data;
      try {
        data = decodeValue(reader);
      } on Object catch (e) {
 // （D-8 ）：try 只包解码——handler 自身抛错不得被归因为
 // "载荷损坏"（会以 frameLost 失败在途 call，误报结果未知）。
        onLog?.call('[ipc] invalid payload (id=$id): $e');
        final h2 = _handlers[id];
        if (h2 != null && !_persistentEventIds.contains(id)) {
          _handlers.remove(id);
          h2(-1, null);
        }
        return;
      }
      h(type, data);
    } on Object catch (e) {
      onLog?.call('[ipc] invalid frame: $e');
    }
  }

  void _sendRequest(
    int reqType,
    int id,
    String channel,
    String name,
    Object? arg,
  ) {
    final writer = ValueWriter();
    encodeValue(writer, [reqType, id, channel, name]);
    encodeValue(writer, arg);
    sendBody(writer.toBytes());
  }

 /// 物理丢帧（SEQ GAP）时失败所有在途调用：响应帧可能就在丢失集里，
 /// 等待只会白耗 timeout——立即失败让调用方重试（重试响应走新帧）。
  void failPendingOnGap() {
    final ids = _handlers.keys
        .where((id) => !_persistentEventIds.contains(id))
        .toList();
    if (ids.isEmpty) return;
    onLog?.call('[ipc] gap: failing ${ids.length} in-flight call(s)');
    for (final id in ids) {
      final h = _handlers.remove(id);
      h?.call(
        -1,
        null,
      ); // 特殊 type 触发下方 fail 路径
    }
  }

  Future<dynamic> call(
    String channel,
    String method,
    List<Object?> args, {
    Duration timeout = const Duration(seconds: 30),
  }) {
    return Future.wait([
      ready.timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          throw TimeoutException(
            'channel init timeout (no Initialize frame from desktop)',
          );
        },
      ),
    ]).then((_) {
      final id = _lastRequestId++;
      final completer = Completer<dynamic>();
      _handlers[id] = (type, data) {
        switch (type) {
          case resPromiseSuccess:
            _handlers.remove(id);
            completer.complete(data);
            break;
          case resPromiseError:
            _handlers.remove(id);
            final message = data is Map
                ? (data['message'] ?? data).toString()
                : '$data';
            completer.completeError(ChannelRpcError(message, data));
            break;
          case resPromiseErrorObj:
            _handlers.remove(id);
            completer.completeError(ChannelRpcError('$data', data));
            break;
          default:
 // 物理丢帧（failPendingOnGap 以未知 type 触发）：立即失败，
 // 调用方按 ChannelRpcError 重试——不等 timeout。
            _handlers.remove(id);
            completer.completeError(
              ChannelRpcError(
                'response frame lost (relay seq gap)',
                null,
                frameLost: true,
              ),
            );
        }
      };
      onLog?.call('[ipc] call $channel.$method id=$id');
      _sendRequest(reqPromise, id, channel, method, args);
      return completer.future.timeout(
        timeout,
        onTimeout: () {
          _handlers.remove(id);
          throw TimeoutException('$channel.$method timed out', timeout);
        },
      );
    });
  }

 /// Subscribe to a channel event. Returns a cancel function which sends
 /// EventDispose. Mirrors `requestEvent` / `sendCancelOrDispose`.
  void Function() addEventListener(
    String channel,
    String event,
    void Function(dynamic event) onEvent, {
    Object? arg,
  }) {
    final id = _lastRequestId++;
    var sent = false;
    var cancelled = false;
    _persistentEventIds.add(id);
    _handlers[id] = (type, data) {
      if (type == resEventFire) onEvent(data);
    };
    ready.then((_) {
      if (cancelled) return;
      sent = true;
      onLog?.call('[ipc] listen $channel.$event id=$id');
      _sendRequest(reqEventListen, id, channel, event, arg);
    });
    return () {
      cancelled = true;
      _persistentEventIds.remove(id);
      _handlers.remove(id);
      if (sent) _sendRequest(reqEventDispose, id, channel, event, null);
    };
  }

  void dispose() {
 // 换桥/销桥时在途 call 立即失败（gap 同款
 // 语义——响应可能已随旧通道丢失，调用方按「结果未知/可重试」收敛），
 // 不再各自干等 30-120s timeout；持久事件监听无 completer，清表即可。
    failPendingOnGap();
    _handlers.clear();
    _persistentEventIds.clear();
  }
}

class ChannelRpcError implements Exception {
  final String message;
  final Object? data;

 /// 「响应帧丢失（结果未知）」的结构化标记：此前
 /// 消费方（conversation_page）靠裸字符串 contains('response frame lost')
 /// 跨层匹配，任一侧改文案即静默把「结果未知」降级成普通失败（用户
 /// 重发=双投递）。生产方在此立单一真源，消费方按字段判定（UI 侧接线
 /// 归界面批次）。
  final bool frameLost;
  ChannelRpcError(this.message, this.data, {this.frameLost = false});

  @override
  String toString() => 'ChannelRpcError: $message';
}

/// Well-known channel names (`Wb` enum in the web client).
class Channels {
  static const file = 'file';
  static const system = 'system';
  static const terminal = 'terminal';
  static const git = 'git';
  static const gitCheckpoint = 'git-checkpoint';
  static const setting = 'setting';
  static const credential = 'credential';
  static const broadcast = 'broadcast';
  static const zcodeTask = 'zcode-task';
  static const zcodeAgent = 'zcode-agent';
  static const zcodeSession = 'zcode-session';
  static const fileWatcher = 'file-watcher';
  static const oauth = 'oauth';
  static const modelProvider = 'model-provider';
  static const modelSelection = 'model-selection';
  static const usageStats = 'usage-stats';
  static const codingPlanSubscription = 'coding-plan-subscription';
  static const skills = 'skills';
  static const skillSync = 'skill-sync';
  static const mcpSync = 'mcp-sync';
  static const pluginSync = 'plugin-sync';
  static const plugins = 'plugins';
  static const pluginManagement = 'plugin-management';
  static const subagents = 'subagents';
  static const commands = 'commands';
  static const hooks = 'hooks';
  static const memory = 'memory';
  static const outputStyle = 'output-style';
  static const settingsSync = 'settings-sync';
  static const bots = 'bots';
  static const feedback = 'feedback';
  static const repoWiki = 'repo-wiki';
  static const promptAttachmentTransfer = 'prompt-attachment-transfer';
  static const offPeakTask = 'off-peak-task';

 /// 窗口宿主 Controller 服务（controller/tasks-index 主题所在，
 /// ）——官方 ServiceChannels.WindowController（channels.ts:112）。
  static const windowController = 'window-controller';

 /// Host 项目服务（readTree 项目全集， 工作区列表修复）——
 /// 官方 ServiceChannels.Project（channels.ts:117）。
  static const project = 'project';
}
