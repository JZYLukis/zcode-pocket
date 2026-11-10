import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// 官方 `packages/shared/test/fixtures/fake-relay-v2.ts` 的 Dart 移植
/// （RelayV2Client 离线测试专用）。语义对齐点：
/// - HTTP：Bearer JWT → `users` 精确映射 userId（无签名校验）；token 60s
///   一次性、WS Upgrade 前原子消费；设备按 userId 隔离；删他人设备
///   code=1006。
/// - WS：auth_init 校验设备归属（不属 → error AUTH_FAILED+close）；同 SID
///   同角色新连接 → 旧连接收 KICKED 后关闭；data 只转发给对端角色；
///   device 断开 → terminal 收 waiting+DEVICE_OFFLINE 并被关闭；terminal
///   断开 → device 收 waiting。
class FakeRelayV2 {
  FakeRelayV2({Map<String, String>? users})
    : users = users ?? {'jwt-alice': 'user-alice', 'jwt-bob': 'user-bob'};

  /// 测试 JWT → userId 精确映射（官方同款：不验真）。
  final Map<String, String> users;

  /// 终端 pair_status_query 是否应答（false=模拟 relay 停止喂狗 → 客户端
  /// 看门狗重连）。
  bool terminalAcksEnabled = true;

  /// WS Upgrade 黑洞开关（传输层批，/）：接受
  /// TCP/HTTP 但永不回 101、也不关连接——复现 VPN 断隧道/防火墙 DROP
  /// 的"连接悬挂"（Upgrade 永不落定，socket.ready 永不完成）。
  bool wsUpgradeBlackHole = false;

  /// 终端 pair_status_query 累计（心跳节奏断言用）。
  int terminalQueries = 0;

  HttpServer? _server;
  final _devices = <String, _FakeDeviceRecord>{};
  final _tokens = <String, _FakeToken>{};
  final _roleConns = <String, Map<String, _FakeWsConn>>{};

  final log = <String>[];

  Uri get origin => Uri.parse('http://127.0.0.1:${_server!.port}');
  int wsConnections = 0;

  final _random = Random();

  void _log(String line) {
    log.add(line);
  }

  /// [loopbackOnly]=false 时绑 0.0.0.0——runner 跨设备（模拟器经
  /// 10.0.2.2 访问宿主）必须全接口监听；单测（host 内）保持 loopback。
  Future<void> start({int port = 0, bool loopbackOnly = true}) async {
    _server = await HttpServer.bind(
      loopbackOnly ? InternetAddress.loopbackIPv4 : InternetAddress.anyIPv4,
      port,
    );
    _server!.listen((request) => unawaited(_onRequest(request)));
  }

  Future<void> close() async {
    for (final conns in _roleConns.values) {
      for (final c in conns.values) {
        c.close();
      }
    }
    _roleConns.clear();
    await _server?.close(force: true);
  }

  // ------------------------------------------------------------ 测试驾驶 API

  /// 内存注册设备（不走 HTTP），返回 device_sid。
  String registerDevice(String jwt, {String? mid}) {
    final userId = users[jwt];
    if (userId == null) throw StateError('unknown jwt');
    final sid = 'd_${_randomBase64Url(15)}';
    _devices[sid] = _FakeDeviceRecord(
      sid: sid,
      mid: mid ?? 'mid-${_randomBase64Url(6)}',
      userId: userId,
      createdAtSec: _nowSec(),
    );
    return sid;
  }

  /// 以 device 角色接入（扮演桌面端）。等待 auth_ack 后返回驾驶句柄。
  Future<FakeDeviceSide> connectDevice(String sid) async {
    final record = _devices[sid]!;
    final token = _issueToken(record.userId, 'device');
    final ws = await WebSocket.connect(_wsUrl(token));
    final side = FakeDeviceSide._(ws);
    side.send({
      'type': 'auth_init',
      'device_sid': sid,
      'meta': {'platform': 'fake-desktop', 'name': '桌面'},
      'client_ts': _nowSec(),
    });
    final ack = await side.waitFor('auth_ack', const Duration(seconds: 3));
    if (ack == null) {
      throw StateError('fake device 连接未获 auth_ack：frames=${side.frames}');
    }
    return side;
  }

  /// 另一台"手机"接入同 SID：旧 terminal 应收 KICKED 并被关闭。
  Future<void> stealTerminal(String sid) async {
    final record = _devices[sid]!;
    final token = _issueToken(record.userId, 'terminal');
    final ws = await WebSocket.connect(_wsUrl(token));
    ws.add(jsonEncode({'type': 'auth_init', 'device_sid': sid}));
    await Future<void>.delayed(const Duration(milliseconds: 250));
    await ws.close();
  }

  /// 直接销毁 device 角色连接（模拟桌面掉线 → DEVICE_OFFLINE 路径）。
  void dropDevice(String sid) {
    _roleConns[sid]?['device']?.destroy();
  }

  /// 从路由表摘除 device 角色但**不发任何通知**（模拟 relay 侧对端消失、
  /// 手机端 WS 仍活——官方夹具 data 找不到对端回 INTERNAL 的路径）。
  void vanishDevice(String sid) {
    _roleConns[sid]?.remove('device');
  }

  /// 向当前 terminal 连接注入 error 帧（官方夹具 sendError 对位；只带
  /// code——生产 relay 的 error 帧不含 message）。
  void sendErrorToTerminal(String sid, String code) {
    _roleConns[sid]?['terminal']?.sendError(code);
  }

  // ------------------------------------------------------------ HTTP/WS 内部

  int _nowSec() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  String _randomBase64Url(int byteCount) => base64Url
      .encode(List.generate(byteCount, (_) => _random.nextInt(256)))
      .replaceAll('=', '');

  String _issueToken(String userId, String role) {
    final token = _randomBase64Url(16);
    _tokens[token] = _FakeToken(
      userId: userId,
      role: role,
      expiresAt: DateTime.now().add(const Duration(seconds: 60)),
    );
    return token;
  }

  String _wsUrl(String token) =>
      'ws://127.0.0.1:${_server!.port}/api/v1/remote/ws2?token=$token';

  Future<void> _onRequest(HttpRequest request) async {
    final path = request.uri.path;
    final method = request.method;
    try {
      if (path == '/api/v1/remote/ws2' && method == 'GET') {
        await _handleUpgrade(request);
        return;
      }
      final userId = _authUser(request);
      if (userId == null) {
        _respond(request, 401, {'code': 401, 'msg': 'unauthorized'});
        return;
      }
      dynamic body;
      if (method == 'POST') {
        body = jsonDecode(await utf8.decoder.bind(request).join());
      }
      if (path == '/api/v1/remote/token' && method == 'POST') {
        final role = body is Map ? body['role'] : null;
        if (role != 'device' && role != 'terminal') {
          _respond(request, 400, {'code': 3001, 'msg': 'parameter error'});
          return;
        }
        final token = _issueToken(userId, role as String);
        _log('token($role) for $userId');
        _respond(request, 200, {
          'code': 0,
          'msg': 'ok',
          'data': {'token': token, 'expires_in': 60},
        });
        return;
      }
      if (path == '/api/v1/remote/device' && method == 'GET') {
        final list = [
          for (final d in _devices.values.where((d) => d.userId == userId))
            _deviceJson(d),
        ];
        _respond(request, 200, {'code': 0, 'msg': 'ok', 'data': list});
        return;
      }
      if (path == '/api/v1/remote/device' && method == 'POST') {
        final mid = body is Map ? '${body['device_mid'] ?? ''}' : '';
        if (mid.trim().isEmpty) {
          _respond(request, 400, {'code': 3001, 'msg': 'parameter error'});
          return;
        }
        final sid = 'd_${_randomBase64Url(15)}';
        _devices[sid] = _FakeDeviceRecord(
          sid: sid,
          mid: mid,
          userId: userId,
          createdAtSec: _nowSec(),
        );
        _log('register $sid ($mid) for $userId');
        _respond(request, 200, {
          'code': 0,
          'msg': 'ok',
          'data': _deviceJson(_devices[sid]!),
        });
        return;
      }
      if (path == '/api/v1/remote/device/delete' && method == 'POST') {
        final sid = body is Map ? '${body['device_sid'] ?? ''}' : '';
        final record = _devices[sid];
        if (record == null) {
          _respond(request, 200, {'code': 0, 'msg': 'ok'});
          return;
        }
        if (record.userId != userId) {
          _respond(request, 200, {'code': 1006, 'msg': 'no permission'});
          return;
        }
        // 官方夹具：在线设备删除回 400/3005 wrong status（先让桌面下线）。
        if (_roleConns[sid]?['device'] != null) {
          _respond(request, 400, {'code': 3005, 'msg': 'wrong status'});
          return;
        }
        _devices.remove(sid);
        final conns = _roleConns.remove(sid);
        conns?.values.forEach((c) => c.close());
        _log('delete $sid');
        _respond(request, 200, {'code': 0, 'msg': 'ok', 'data': null});
        return;
      }
      _respond(request, 404, {'code': 404, 'msg': 'not found'});
    } catch (e) {
      _log('request error: $e');
      try {
        _respond(request, 500, {'code': 500, 'msg': '$e'});
      } catch (_) {}
    }
  }

  Map<String, dynamic> _deviceJson(_FakeDeviceRecord d) => {
    'device_sid': d.sid,
    'device_mid': d.mid,
    'online': _roleConns[d.sid]?['device'] != null,
    'created_at': d.createdAtSec,
    'meta': _roleConns[d.sid]?['device']?.meta ?? const <String, dynamic>{},
  };

  String? _authUser(HttpRequest request) {
    final auth = request.headers.value(HttpHeaders.authorizationHeader);
    if (auth == null || !auth.startsWith('Bearer ')) return null;
    return users[auth.substring(7)];
  }

  void _respond(HttpRequest request, int status, Map<String, dynamic> body) {
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(body));
    request.response.close();
  }

  Future<void> _handleUpgrade(HttpRequest request) async {
    if (wsUpgradeBlackHole) {
      _log('ws upgrade black-holed (test)');
      return; // 不升级、不响应、不关连接——客户端 Upgrade 悬挂
    }
    final token = request.uri.queryParameters['token'];
    final rec = token == null ? null : _tokens.remove(token);
    final expired = rec != null && DateTime.now().isAfter(rec.expiresAt);
    if (rec == null || expired) {
      request.response.statusCode = 401;
      request.response.close();
      return;
    }
    final ws = await WebSocketTransformer.upgrade(request);
    wsConnections++;
    final conn = _FakeWsConn(ws, rec.role, rec.userId);
    unawaited(
      _runSession(ws, conn).catchError((Object e) {
        _log('session error: $e');
      }),
    );
  }

  /// 会话：首条必须是 auth_init（设备归属校验），之后路由 query/data。
  Future<void> _runSession(WebSocket ws, _FakeWsConn conn) async {
    final completer = Completer<void>();
    final sid = <String?>[null]; // 认证后赋值；未认证断开时 teardown 跳过
    void teardown() {
      final s = sid[0];
      if (!completer.isCompleted) completer.complete();
      if (s == null) return;
      final connsNow = _roleConns[s];
      if (connsNow?[conn.role] == conn) connsNow?.remove(conn.role);
      _log('ws ${conn.role} closed on $s');
      final otherRole = conn.role == 'terminal' ? 'device' : 'terminal';
      final otherNow = _roleConns[s]?[otherRole];
      if (otherNow != null) {
        otherNow.pushPairStatus('waiting');
        if (conn.role == 'device') {
          otherNow.sendError('DEVICE_OFFLINE');
          otherNow.close();
        }
      }
    }

    ws.listen(
      (raw) async {
        if (raw is! String) return;
        dynamic frame;
        try {
          frame = jsonDecode(raw);
        } catch (_) {
          return;
        }
        if (frame is! Map) return;
        final type = frame['type'];
        if (!conn.authed) {
          if (type != 'auth_init') {
            conn.sendError('WRONG_PARAM');
            conn.close();
            return;
          }
          final s = '${frame['device_sid'] ?? ''}';
          final record = s.trim().isEmpty ? null : _devices[s];
          if (record == null || record.userId != conn.userId) {
            conn.sendError('AUTH_FAILED');
            conn.close();
            return;
          }
          if (frame['meta'] is Map) {
            conn.meta = (frame['meta'] as Map).cast<String, dynamic>();
          }
          conn.authed = true;
          sid[0] = s;
          final conns = _roleConns.putIfAbsent(s, () => {});
          // 同角色替换：旧连接 KICKED + 关闭（官方 :252-258）。
          final old = conns[conn.role];
          if (old != null && !identical(old, conn)) {
            old.sendError('KICKED');
            old.close();
          }
          conns[conn.role] = conn;
          final otherRole = conn.role == 'terminal' ? 'device' : 'terminal';
          final otherConn = conns[otherRole];
          final pairStatus = otherConn != null ? 'matched' : 'waiting';
          // 官方夹具：auth_ack 恒带 terminal_sid（device 角色为空串）。
          conn.sendJson({
            'type': 'auth_ack',
            'device_sid': s,
            'terminal_sid': conn.terminalSid,
            'pair_status': pairStatus,
            'server_ts': _nowSec(),
          });
          otherConn?.pushPairStatus('matched');
          _log('ws ${conn.role} connected to $s ($pairStatus)');
          return;
        }
        switch (type) {
          case 'pair_status_query':
            if (conn.role == 'terminal') terminalQueries++;
            if (conn.role == 'terminal' && !terminalAcksEnabled) return;
            final otherRole = conn.role == 'terminal' ? 'device' : 'terminal';
            final other = _roleConns[sid[0] ?? '']?[otherRole];
            conn.sendJson({
              'type': 'pair_status_ack',
              'pair_status': other != null ? 'matched' : 'waiting',
              'terminal_sid': other?.terminalSid ?? '',
              'server_ts': _nowSec(),
            });
            break;
          case 'data':
            final otherRole = conn.role == 'terminal' ? 'device' : 'terminal';
            final other = _roleConns[sid[0] ?? '']?[otherRole];
            if (other == null) {
              // 官方夹具：对端不存在 → 回 INTERNAL（不关连接）——手机端
              // 据此降级 waiting 继续查询，而不是把它放大成重连风暴。
              conn.sendError('INTERNAL');
              break;
            }
            other.sendData(frame['payload']);
            break;
          case 'auth_init':
            conn.sendError('WRONG_PARAM');
            conn.close();
            break;
        }
      },
      onDone: teardown,
      onError: (_) => teardown(),
      cancelOnError: true,
    );
    return completer.future;
  }
}

class _FakeDeviceRecord {
  final String sid;
  final String mid;
  final String userId;
  final int createdAtSec;
  _FakeDeviceRecord({
    required this.sid,
    required this.mid,
    required this.userId,
    required this.createdAtSec,
  });
}

class _FakeToken {
  final String userId;
  final String role;
  final DateTime expiresAt;
  _FakeToken({
    required this.userId,
    required this.role,
    required this.expiresAt,
  });
}

class _FakeWsConn {
  final WebSocket ws;
  final String role;
  final String userId;

  /// 终端连接 sid（官方 auth_ack 恒带 terminal_sid；device 角色空串）。
  final String terminalSid;
  bool authed = false;
  Map<String, dynamic> meta = const {};
  _FakeWsConn(this.ws, this.role, this.userId)
    : terminalSid =
          role == 'terminal'
              ? 't_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
              : '';

  /// 写入已关闭的连接一律静默丢弃：测试 teardown 关闭服务器后，在途的
  /// 心跳/转发写入会命中已关 sink 并抛 "StreamSink is closed"。该异常
  /// 属收尾噪声（既非被测行为也非断言目标），此前会漂移到下一个用例的
  /// setUp 头部，制造"已知偶发家族"的假失败（AGENTS 活事项 6 记录）。
  /// 结构性消除：假服务器只负责在活连接上投递帧。
  void sendJson(Map<String, dynamic> frame) {
    try {
      ws.add(jsonEncode(frame));
    } on StateError {
      // 连接已关（teardown 竞态）——丢弃该帧。
    }
  }

  /// 官方夹具 error 帧只带 code（无 message——生产 relay 同款；客户端
  /// 依赖 message 的路径必须自带兜底文案）。
  void sendError(String code) => sendJson({
    'type': 'error',
    'code': code,
    'server_ts': DateTime.now().millisecondsSinceEpoch ~/ 1000,
  });

  void pushPairStatus(String status, {String terminalSid = ''}) => sendJson({
    'type': 'pair_status_ack',
    'pair_status': status,
    'terminal_sid': terminalSid,
    'server_ts': DateTime.now().millisecondsSinceEpoch ~/ 1000,
  });

  void sendData(dynamic payload) => sendJson({
    'type': 'data',
    'payload': payload,
    'server_ts': DateTime.now().millisecondsSinceEpoch ~/ 1000,
  });

  void close() {
    try {
      unawaited(ws.close());
    } catch (_) {}
  }

  /// 断开连接（dart:io WebSocket 无 destroy；teardown 的 onDone 照常触发
  /// DEVICE_OFFLINE 推送路径）。
  void destroy() {
    close();
  }
}

/// 测试侧"桌面端"驾驶句柄：等待帧/发送 data/关闭。
class FakeDeviceSide {
  final WebSocket _ws;
  final List<Map<String, dynamic>> frames = [];
  final _waiters = <String, List<Completer<Map<String, dynamic>>>>{};
  final _payloadController = StreamController<Map<String, dynamic>>.broadcast();

  /// 新到 data 帧的事件流（runner 消费用——绝不能用 waitFor 轮询历史，
  /// 会自旋打满 isolate 把 HttpServer 饿死）。
  Stream<Map<String, dynamic>> get onData => _payloadController.stream;

  final _done = Completer<void>();
  bool closed = false;

  FakeDeviceSide._(this._ws) {
    _ws.listen(
      (raw) {
        if (raw is! String) return;
        dynamic f;
        try {
          f = jsonDecode(raw);
        } catch (_) {
          return;
        }
        if (f is! Map) return;
        final frame = f.cast<String, dynamic>();
        frames.add(frame);
        if (frame['type'] == 'data' && frame['payload'] is Map) {
          _payloadController.add((frame['payload'] as Map).cast<String, dynamic>());
        }
        final pending = _waiters.remove(frame['type']);
        if (pending != null) {
          for (final c in pending) {
            if (!c.isCompleted) c.complete(frame);
          }
        }
      },
      onDone: () {
        closed = true;
        if (!_done.isCompleted) _done.complete();
      },
      onError: (_) {
        closed = true;
        if (!_done.isCompleted) _done.complete();
      },
      cancelOnError: true,
    );
  }

  void send(Map<String, dynamic> frame) =>
      _ws.add(jsonEncode(frame));

  /// 发业务载荷（relay 侧包装为 data 帧）。
  void sendPayload(Map<String, dynamic> payload) =>
      send({'type': 'data', 'payload': payload});

  Future<Map<String, dynamic>?> waitFor(String type, Duration timeout) async {
    for (final f in frames) {
      if (f['type'] == type) return f;
    }
    final completer = Completer<Map<String, dynamic>>();
    (_waiters[type] ??= []).add(completer);
    try {
      return await completer.future.timeout(timeout);
    } on TimeoutException {
      _waiters[type]?.remove(completer);
      return null;
    }
  }

  Future<void> get done => _done.future;

  Future<void> close() async {
    closed = true;
    try {
      await _ws.close();
    } catch (_) {}
  }
}
