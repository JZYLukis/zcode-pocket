import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'device_info.dart';
import 'protocol_drift.dart';
import 'relay_client.dart'
    show BatteryNetCounters, RelayConnection, RelayFailure, RelayState;

/// Relay V2 连接层（3.16 适配 P0-1）。
///
/// 契约出处（refs/new-snapshot，全部已核实到行）：
/// - wire schema：packages/shared/src/web-remote-relay/contract.ts:19-94
///   （上行 auth_init/pair_status_query/data；下行 auth_ack/pair_status_ack/
///   data/error；strictObject——上行多一个字段即被服务端整条拒绝）。
/// - 心跳/退避参数：web-remote-relay/domain/heartbeatTiming.ts:1-5、
///   retry.ts:6-31 + 官方 terminal transport
///   packages/web/src/web-remote-control/adapters/webRemoteControlTransport.ts:45-49。
/// - HTTP API：POST token `{role}` → `{token, expires_in}`（60s 一次性，
///   WS Upgrade 前原子消费、失败不恢复、重连必须重新申请）；GET/POST
///   device 列表/注册/删除；鉴权一律 `Authorization: Bearer <账号JWT>`。
/// - 入口：`/api/v1/remote/ws2?token=&mid=`（contract.ts:102）。
/// - 二维码 V2：只带 sid/mid/name/app_version；带 hash/t 的 V1 链接直接
///   拒绝（web-remote-control.ts:191-206）。
///
/// 生产实证（2026-10-21，tools/relay-v2-probe.mjs）：zcode.z.ai 的 V2
/// 端点已上线（device 列表 200、token 签发 22 字符/60s 与契约一致）；
/// 实测账号 JWT 被 V2 HTTP 接受，**payload 无 exp 字段**
/// （签发月余仍有效）——过期判定只能靠 401 兜底，无本地 exp 解析路径
/// （官方 resolveJwtExpiration 移植件已随删除）。
///
/// V2 的 passHash/HMAC proof 在本栈全部退役。

/// V2 端点路径（contract.ts:96-103）。
const String relayV2TokenPath = '/api/v1/remote/token';
const String relayV2DevicePath = '/api/v1/remote/device';
const String relayV2DeviceDeletePath = '/api/v1/remote/device/delete';
const String relayV2WsPath = '/api/v1/remote/ws2';

/// HTTP 响应体字节上限（P3-3）：token/设备列表的正常响应
/// 远小于此；恶意/异常中间盒灌巨 body 时无界 join 会整页进内存。与
/// rpc-frame 消息级 64MiB 单一真源（ipc_codec ValueReader.maxValueBytes）
/// 不同——HTTP 信封是轻量控制通道，取独立更紧值 4MiB；超限按不可重试
/// 失败（重试只会再拖一遍巨 body）。
const int relayV2MaxHttpResponseBytes = 4 * 1024 * 1024;

/// 生产 origin（zcodeEndpoint.ts:3）。测试可覆盖（launch extra
/// relay_v2_origin → E2E 连本机 Dart fake relay）。
String? relayV2EndpointOverride;

Uri relayV2DefaultOrigin() =>
    Uri.parse(relayV2EndpointOverride ?? 'https://zcode.z.ai');

class RelayV2Timing {
  /// 心跳基准 5s（contract heartbeatTiming.ts:1）。
  final Duration heartbeatBase;

  /// 后台心跳档（电量专项，2026-10-28）：审批提醒保活退后台时放宽到此
  /// 值。安全依据=--heartbeat 探针对生产中继实测（tools/logs/）：
  /// 30s/60s 间隔照常 ACK、120s 完全静默连接不断、补发 0ms 应答——
  /// 服务端对安静客户端无超时，5s 心跳与 15s 看门狗均为客户端自愿行为。
  /// 看门狗随档放宽为 heartbeatBackground+ackTimeout（30+15=45s）。
  final Duration heartbeatBackground;

  /// 心跳抖动 ±1s——每轮均匀采样 [base-jitter, base+jitter]。
  final Duration heartbeatJitter;

  /// 任意 ACK（auth_ack/pair_status_ack）后的静默看门狗：15s 无 ACK 重连。
  final Duration ackTimeout;

  /// auth_ack(waiting) 后等待配对超时 → desktop-disconnected 失败事件。
  final Duration waitingTimeout;

  /// DEVICE_OFFLINE 后的恢复宽限：期内未重新 paired → desktop-disconnected。
  final Duration deviceOfflineGrace;

  /// 网络类重连退避：500ms×2ⁿ（官方 terminal 参数，无 jitter）。
  final Duration backoffInitial;
  final Duration backoffMax;

  /// KICKED 首次恢复延迟 2~5s；60s 窗口内第二次 → session-conflict 终态。
  final Duration kickFirstMin;
  final Duration kickFirstMax;
  final Duration kickWindow;

  /// poke() 探针后的快速看门狗（官方 recoverConnection 语义的快速档，
  /// 3s 内无应答即重建）。P3-5：原为 _armAckWatchdog 内的
  /// 硬编码，不入 timing——数值不变，仅随 timing 注入可测。
  final Duration probeTimeout;

  const RelayV2Timing({
    this.heartbeatBase = const Duration(seconds: 5),
    this.heartbeatBackground = const Duration(seconds: 30),
    this.heartbeatJitter = const Duration(seconds: 1),
    this.ackTimeout = const Duration(seconds: 15),
    this.waitingTimeout = const Duration(seconds: 30),
    this.deviceOfflineGrace = const Duration(seconds: 15),
    this.backoffInitial = const Duration(milliseconds: 500),
    this.backoffMax = const Duration(seconds: 10),
    this.kickFirstMin = const Duration(seconds: 2),
    this.kickFirstMax = const Duration(seconds: 5),
    this.kickWindow = const Duration(seconds: 60),
    this.probeTimeout = const Duration(seconds: 3),
  });
}

// ------------------------------------------------------------- HTTP 层

/// 账号 JWT 失效/缺失（HTTP 401 或重连前 JWT 缺失）——上层应清除凭据并
/// 引导重新登录（官方语义：401=清会话回登录页，不做网络错误重试）。
class RelayV2AuthRequired implements Exception {
  const RelayV2AuthRequired();
  @override
  String toString() => 'RelayV2AuthRequired（账号凭据缺失或已失效，需重新登录）';
}

/// 中继 HTTP 不可用（5xx/网络/非 JSON/code!=0 的非 401 失败）。
class RelayV2Unavailable implements Exception {
  final bool retryable;
  final String detail;
  const RelayV2Unavailable(this.detail, {this.retryable = false});
  @override
  String toString() => 'RelayV2Unavailable: $detail';
}

/// 网络类连接失败分类（2026-10-23 用户拍板第一档：把"连不上"翻译成
/// 人话+可操作提示——VPN 间歇性 DNS 故障等场景用户此前完全无信息）。
/// reason 机器可判（UI 按 reason 出文案），message 人话短句。
RelayFailure classifyRelayNetworkFailure(Object e) {
  final t = e is RelayV2Unavailable ? e.detail : '$e';
  final low = t.toLowerCase();
  if (low.contains('failed host lookup') ||
      low.contains('unknown host') ||
      low.contains('lookup failed') ||
      low.contains('name or service not known')) {
    return const RelayFailure(
      'network-dns',
      '域名解析失败（zcode.z.ai 无法解析出服务器地址）',
    );
  }
  // 「超时」中文匹配：生产端 res.close().timeout 的响应超时抛的是
  // 'HTTP /api/... 超时'（本文件内中文串），审查 A1 实锤——漏判会使
  // 超时专属文案在最典型的 VPN 黑洞路径上不可达，落 network-unknown。
  if (low.contains('timed out') ||
      low.contains('timeout') ||
      t.contains('超时')) {
    return const RelayFailure('network-timeout', '连接中继服务器超时');
  }
  if (low.contains('connection refused')) {
    return const RelayFailure('network-refused', '连接被中继服务器拒绝');
  }
  if (low.contains('http 401') || low.contains('unauthorized')) {
    return const RelayFailure('network-auth', '账号鉴权失败（401）');
  }
  return RelayFailure('network-unknown', '网络错误：$t');
}

class RelayV2Device {
  final String deviceSid;
  final String deviceMid;
  final bool online;
  final Map<String, dynamic> meta;
  const RelayV2Device({
    required this.deviceSid,
    required this.deviceMid,
    required this.online,
    this.meta = const {},
  });
}

/// V2 HTTP 客户端（token 签发/设备列表）。只做终端角色需要的两个只读
/// 调用；register/delete 是桌面角色/调试用途，不在生产路径。
class RelayV2Api {
  final Uri origin;
  final Future<String?> Function() jwtProvider;
  final Duration timeout;
  final void Function(String line)? onLog;

  /// 复用连接池（P3-4/F2-P3-2）：token 端点每次重连必调
  /// （契约禁止缓存 token，但 HTTP client 可复用）——此前每请求新建并
  /// 强杀 HttpClient，退避风暴（500ms 起步）下每拍一遍完整 TCP+TLS 握手。
  io.HttpClient? _httpClient;

  io.HttpClient get _client =>
      _httpClient ??= (io.HttpClient()..connectionTimeout = timeout);

  /// 释放连接池。RelayV2Client.dispose 会调用；独立短生命周期用法
  /// （设备列表页）可省略——空闲连接由 HttpClient 自身 idleTimeout 回收。
  void close() {
    _httpClient?.close(force: true);
    _httpClient = null;
  }

  RelayV2Api({
    required this.origin,
    required this.jwtProvider,
    this.timeout = const Duration(seconds: 15),
    this.onLog,
  });

  /// 一次性 token（60s，Upgrade 前原子消费）——**每次连接重新申请，禁止
  /// 缓存**（契约 :24；官方 webRemoteControlV2Token.ts:7 同款）。
  Future<String> fetchToken({required String role}) async {
    final data = await _request('POST', relayV2TokenPath, body: {'role': role});
    final token = data is Map ? data['token'] : null;
    if (token is! String || token.isEmpty) {
      // P3-8：传输层是协议漂移第一现场——token 信封骨架字段
      // 缺席先打哨兵（：只观察不拦截，失败路径照旧）。
      noteProtocolDrift(
        'relayV2.fetchToken',
        data is Map ? data : null,
        ['token'],
        onLog: onLog == null ? null : (line) => onLog?.call(line),
      );
      throw RelayV2Unavailable('token 响应缺 data.token');
    }
    return token;
  }

  /// 当前账号的设备列表（"最近在线设备可直连"的数据源）。
  Future<List<RelayV2Device>> listDevices() async {
    final data = await _request('GET', relayV2DevicePath);
    if (data is! List) throw RelayV2Unavailable('device 响应非数组');
    return [
      for (final e in data)
        if (e is Map && e['device_sid'] is String)
          RelayV2Device(
            deviceSid: e['device_sid'] as String,
            deviceMid: '${e['device_mid'] ?? ''}',
            online: e['online'] == true,
            meta: e['meta'] is Map
                ? (e['meta'] as Map).cast<String, dynamic>()
                : const {},
          ),
    ];
  }

  Future<dynamic> _request(String method, String path, {Map? body}) async {
    final jwt = await jwtProvider();
    if (jwt == null || jwt.isEmpty) throw const RelayV2AuthRequired();
    final client = _client;
    try {
      final req = await client.openUrl(method, origin.replace(path: path));
      req.headers.set(io.HttpHeaders.authorizationHeader, 'Bearer $jwt');
      req.headers.set(io.HttpHeaders.contentTypeHeader, 'application/json');
      req.followRedirects = false;
      if (body != null) req.write(jsonEncode(body));
      final res = await req.close().timeout(timeout);
      // 响应体限字节读取（F2-P3-3）：超限即断——不整页 join 进内存。
      final bodyBytes = BytesBuilder(copy: false);
      await for (final chunk in res) {
        bodyBytes.add(chunk);
        if (bodyBytes.length > relayV2MaxHttpResponseBytes) {
          throw RelayV2Unavailable(
            'HTTP $path 响应体超 '
            '${relayV2MaxHttpResponseBytes ~/ (1024 * 1024)}MiB 上限',
            retryable: false,
          );
        }
      }
      final text = utf8.decode(bodyBytes.takeBytes());
      if (res.statusCode == 401) throw const RelayV2AuthRequired();
      // P2-2/F2-P2-3/F3-P2-3（三路同报）：仅 401/403/404 保持
      // 终态（401 已前置抛 RelayV2AuthRequired；403/404 是不会自愈的拒绝/
      // 路径错误）；429 限流/408 超时/3xx portal 重定向（followRedirects=
      // false 不跟随，凭据不跨域重放）等其余档位一律按瞬态退避重试——
      // 重连风暴本身恰是最易触发 429 的路径，终态化会把可自愈场景钉死
      // 在 error。
      bool terminalStatus(int s) => s == 403 || s == 404;
      dynamic decoded;
      try {
        decoded = jsonDecode(text);
      } catch (_) {
        // 非 JSON 多为中间盒/限流页——随状态码同一套分级。
        throw RelayV2Unavailable(
          'HTTP ${res.statusCode} 非法 JSON 响应',
          retryable: !terminalStatus(res.statusCode),
        );
      }
      // 响应信封 {code:0,msg,data}（宽松解析：服务端可新增字段，契约 :11-13）
      final code = decoded is Map ? decoded['code'] : null;
      if (terminalStatus(res.statusCode)) {
        throw RelayV2Unavailable('HTTP ${res.statusCode} code=$code');
      }
      if (res.statusCode != 200 || code is! num || code.toInt() != 0) {
        throw RelayV2Unavailable(
          'HTTP ${res.statusCode} code=$code',
          retryable: true,
        );
      }
      return decoded is Map ? decoded['data'] : null;
    } on RelayV2AuthRequired {
      rethrow;
    } on TimeoutException {
      throw RelayV2Unavailable('HTTP $path 超时', retryable: true);
    } on io.SocketException catch (e) {
      throw RelayV2Unavailable('HTTP $path 网络错误：$e', retryable: true);
    }
    // 注：不在此处 close client——连接池跨请求复用（见 _client 注释），
    // 生命周期归 close()/RelayV2Client.dispose。
  }
}

// ------------------------------------------------------------ WS 客户端

/// V2 连接目标：endpointOrigin（生产 https://zcode.z.ai）+ 目标桌面
/// deviceSid（V2 二维码或设备列表选定）。
class RelayV2Config {
  final Uri endpointOrigin;
  final String deviceSid;
  final String? deviceMid;
  final String? deviceName;
  final String? appVersion;

  const RelayV2Config({
    required this.endpointOrigin,
    required this.deviceSid,
    this.deviceMid,
    this.deviceName,
    this.appVersion,
  });

  Uri wsUri(String oneTimeToken) {
    final wsScheme = endpointOrigin.scheme == 'https' ? 'wss' : 'ws';
    final q = 'token=${Uri.encodeQueryComponent(oneTimeToken)}'
        '${(deviceMid ?? '').trim().isEmpty ? '' : '&mid=${Uri.encodeQueryComponent(deviceMid!.trim())}'}';
    return Uri(
      scheme: wsScheme,
      host: endpointOrigin.host,
      // 无端口时用 null 而非 0（P3-3）：0 依赖 dart:io 两层
      // 归一（wss→https、port0→443）才不产出 `wss://host:0` 的坏 URL——
      // V1 connection_params 同位置即 null，对齐消除脆弱巧合链。
      port: endpointOrigin.hasPort ? endpointOrigin.port : null,
      path: relayV2WsPath,
      query: q,
    );
  }
}

/// Relay V2 终端角色客户端：JWT→token→ws2→auth_init→paired。
///
/// 状态机与 V1 RelayClient 同构（idle/connecting/authenticating/waiting/
/// paired/reconnecting/error/kicked/closed），LinkPhase 派生无需改动。
/// 官方 terminal 语义（webRemoteControlTransport.ts + docs :262-281）：
/// - 心跳 pair_status_query 每轮 4~6s 均匀采样；任意 ACK 重置 15s 看门狗；
/// - 退避 500ms×2ⁿ cap 10s，auth_ack 清零；
/// - KICKED 首次 2~5s 重连，60s 内第二次=session-conflict 终态；
/// - DEVICE_OFFLINE 立即重连+15s 宽限，期内未 paired=desktop-disconnected；
/// - AUTH_FAILED=device-not-owned（账号与桌面不同归属）；
/// - WRONG_PARAM=invalid-mobile-connection；
/// - HTTP 401/JWT 缺失=auth-required（清凭据回登录，不重试）。
/// ：异常 message 常含完整 ws2 URL（token 在
/// query）——日志脱敏后再落（内存环+debugPrint 都会进 logcat/取证归档）。
String _maskRelayToken(Object e) =>
    ('$e').replaceAll(RegExp(r'token=[^&\s]+'), 'token=***');

class RelayV2Client implements RelayConnection {
  final RelayV2Config config;
  final RelayV2Timing timing;
  final Future<String?> Function() jwtProvider;
  final void Function(String line)? onLog;
  final Random _random;

  final RelayV2Api _api;

  RelayV2Client({
    required this.config,
    required this.jwtProvider,
    this.timing = const RelayV2Timing(),
    this.onLog,
    Random? random,
  }) : _api = RelayV2Api(
         origin: config.endpointOrigin,
         jwtProvider: jwtProvider,
         onLog: onLog,
       ),
       _random = random ?? Random();

  WebSocketChannel? _socket;
  StreamSubscription? _socketSub;
  int _generation = 0;
  bool _connectInFlight = false;
  bool _disposed = false;
  bool _intentionallyClosed = false;

  final _state = ValueNotifier<RelayState>(RelayState.idle);
  @override
  ValueListenable<RelayState> get stateListenable => _state;
  @override
  RelayState get state => _state.value;

  final _payloadController = StreamController<Map<String, dynamic>>.broadcast();
  @override
  Stream<Map<String, dynamic>> get payloads => _payloadController.stream;

  final _failureController = StreamController<RelayFailure>.broadcast();
  @override
  Stream<RelayFailure> get failures => _failureController.stream;

  bool _authenticated = false;
  bool _wasPaired = false;
  int _backoffFailures = 0;
  DateTime? _lastKickAt;

  Timer? _handshakeDeadline;
  Timer? _heartbeatTimer;
  Timer? _ackWatchdog;

  /// 后台心跳档是否生效（ setBackgroundHeartbeat；前台恢复由
  /// onAppResumed 的 poke() 统一做快速活性探测，这里只切档重排）。
  bool _backgroundHeartbeatMode = false;

  /// 完全静默档（电量优化批 #17，2026-10-31）：优先级高于后台档——
  /// 90s 断连倒计时窗口内不发心跳、不挂看门狗。安全依据：服务器对
  /// 安静客户端无超时（--heartbeat 探针 120s 完全静默连接不断，见
  /// RelayV2Timing.heartbeatBackground 注），窗口结束连接本就拆除；
  /// 回前台 setRelaySilent(false)+poke() 探活兜底（坏链路 3s 内重建）。
  bool _silentMode = false;
  Timer? _waitingTimer;
  Timer? _offlineGraceTimer;
  Timer? _reconnectTimer;
  DateTime _lastAckAt = DateTime.now();

  /// 出站队列（非 paired 态的 sendPayload 缓冲，paired 后冲刷；V1 同款）。
  final List<Map<String, dynamic>> _outboundQueue = [];
  static const int _outboundQueueLimit = 100;

  // ------------------------------------------------------------ lifecycle

  @override
  void start() {
    if (_disposed || _state.value != RelayState.idle) return;
    unawaited(_connect());
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _intentionallyClosed = true;
    _cancelTimers();
    _offlineGraceTimer?.cancel();
    _offlineGraceTimer = null;
    // 复用连接池随连接生命周期释放（P3-4/F2-P3-2）。
    _api.close();
    await _socketSub?.cancel();
    // 同 _reconnect：悬挂连接的 close 永不完成，dispose 不得随之挂死
    // （上层 disposeStack/切账号拆除序列会连带卡死——P1-1）。
    unawaited(_socket?.sink.close().catchError((_) {}));
    _socket = null;
    await _payloadController.close();
    await _failureController.close();
    _state.value = RelayState.closed;
    _state.dispose();
  }

  /// 被踢终态后的用户主动恢复入口（与 V1 同名同义）。
  @override
  void retryAfterKicked() {
    if (_disposed || _state.value != RelayState.kicked) return;
    _intentionallyClosed = false;
    _backoffFailures = 0;
    _lastKickAt = null;
    unawaited(_reconnect(delay: Duration.zero));
  }

  /// 回前台探测：paired 且 ACK 静默超阈值 → 立即探一拍，3s 内无应答重建。
  /// （官方 recoverConnection 语义的手机端等价物。）
  @override
  void poke() {
    if (_disposed) return;
    if (_state.value != RelayState.paired) return;
    // P2-1/F1-P3-10：_reconnect 的关闭窗口内 state 尚未迁移
    // （仍 paired）但 _authenticated 已同步置 false——旧实现 poke 会在该
    // 窗口把探针打进垂死 socket（适配层已 close 的 sink 上 add 抛
    // StateError）并误挂 3s 探针看门狗（引发多余重连）。与
    // sendPayload 同判据。
    if (!_authenticated) return;
    if (DateTime.now().difference(_lastAckAt) <
        timing.ackTimeout - const Duration(seconds: 2)) {
      return;
    }
    _log('[v2] poke: probe pair_status_query');
    _send({'type': 'pair_status_query', 'client_ts': _nowSec()});
    _armAckWatchdog(probe: true);
  }

  // ------------------------------------------------------------ connect

  Future<void> _connect() async {
    if (_connectInFlight || _disposed) return;
    _connectInFlight = true;
    final gen = ++_generation;
    _setState(RelayState.connecting);
    try {
      final token = await _api.fetchToken(role: 'terminal');
      if (_disposed || gen != _generation) return;
      // connectTimeout=ackTimeout（P1-3/F2-P1-1/F3-P1 三路同
      // 报）：黑洞网络（VPN 断隧道/DROP 型防火墙）下 Upgrade 永不落定，
      // 包内默认永不超时——悬挂会在 fetchToken 之后卡死整条连接机；到点
      // 转失败走既有退避。ready 的错误若无人消费会成为 zone 未捕获异步
      // 错误（适配层 _readyCompleter.completeError 无监听者，F1-P2-1）
      // ——连接失败已由下方 stream.listen(onError) 统一走重连，这里只
      // 接住 future 本身。
      final socket = IOWebSocketChannel.connect(
        config.wsUri(token),
        connectTimeout: timing.ackTimeout,
      );
      unawaited(socket.ready.catchError((_) {}));
      _socket = socket;
      _setState(RelayState.authenticating);
      _handshakeDeadline = Timer(timing.ackTimeout, () {
        if (gen != _generation) return;
        _log('[v2] handshake deadline（${timing.ackTimeout.inSeconds}s 无 auth_ack）');
        unawaited(_reconnect());
      });
      _socketSub = socket.stream.listen(
        (data) {
          if (gen != _generation) return;
          _handleRaw(data, gen);
        },
        onError: (Object e) {
          if (gen != _generation) return;
          _log('[v2] socket error: ${_maskRelayToken(e)}');
          unawaited(_reconnect());
        },
        onDone: () {
          if (gen != _generation) return;
          _log('[v2] socket closed (onDone)');
          if (!_intentionallyClosed && !_disposed) unawaited(_reconnect());
        },
        cancelOnError: true,
      );
      // 官方在 open 后发 auth_init；web_socket_channel 的 sink 在连接建立
      // 前会排队（V1 RelayClient 同款时序）。strict 契约：**不带 role**、
      // 不带任何凭据字段——角色由一次性 token 决定。
      final name = (config.deviceName ?? '').trim();
      _send({
        'type': 'auth_init',
        'device_sid': config.deviceSid,
        'meta': {
          'platform': companionPlatformName(),
          // QR 无 app_version 时兜底 'unknown'（P3-2/F3-P3-11）
          // ——旧兜底是应用名/字面量，桌面端"已连接客户端"会把名字当
          // 版本号显示，排障误导。
          'version': config.appVersion ?? 'unknown',
          if (name.isNotEmpty) 'name': name,
        },
        'client_ts': _nowSec(),
      });
    } on RelayV2AuthRequired {
      // dispose 与在飞 fetchToken 的 401 交错时不得触碰已释放资源
      //（_failTerminal 会写已 dispose 的 ValueNotifier、向已 close 的
      // _failureController add 抛 StateError——P1-1，与相邻
      // 两个 catch 同款守卫）。
      if (_disposed) return;
      _failTerminal(RelayState.error, 'auth-required', '账号凭据缺失或已失效');
    } on RelayV2Unavailable catch (e) {
      if (_disposed) return;
      _log('[v2] token 失败: ${_maskRelayToken(e)}');
      // 网络类失败走退避重试（终态型 relay-unavailable 停止）。
      if (!e.retryable) {
        _failTerminal(RelayState.error, 'relay-unavailable', '$e');
      } else {
        // 第一档诊断：重试型网络失败按类别上报（UI 出人话提示）。
        _failureController.add(classifyRelayNetworkFailure(e));
        unawaited(_reconnect());
      }
    } catch (e) {
      if (_disposed) return;
      _log('[v2] connect 失败: ${_maskRelayToken(e)}');
      _failureController.add(classifyRelayNetworkFailure(e));
      unawaited(_reconnect());
    } finally {
      _connectInFlight = false;
    }
  }

  Future<void> _reconnect({Duration? delay}) async {
    if (_disposed) return;
    final gen = ++_generation;
    _cancelTimers();
    _authenticated = false;
    await _socketSub?.cancel();
    // 悬挂/半开升级的 socket：close 的 done future 可能永不完成（适配层
    // 失败路径不给 outbound controller 挂监听者，P1-1/F3-P1）
    // ——close 的完成性不得承担状态机推进，fire-and-forget（_failTerminal
    // 同款范式），先置空再继续退避排程。
    unawaited(_socket?.sink.close().catchError((_) {}));
    _socket = null;
    if (_intentionallyClosed) return;
    _setState(RelayState.reconnecting);
    final d = delay ?? _backoffDelay();
    _log('[v2] reconnect in ${d.inMilliseconds}ms');
    _reconnectTimer = Timer(d, () {
      if (!_disposed && gen == _generation) unawaited(_connect());
    });
  }

  Duration _backoffDelay() {
    final exp = 1 << _backoffFailures.clamp(0, 16);
    _backoffFailures++;
    final ms = (timing.backoffInitial.inMilliseconds * exp)
        .clamp(0, timing.backoffMax.inMilliseconds);
    return Duration(milliseconds: ms);
  }

  // ------------------------------------------------------------ frames

  int _nowSec() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  bool _send(Map<String, dynamic> frame) {
    final s = _socket;
    if (s == null || _state.value == RelayState.closed) return false;
    final encoded = jsonEncode(frame);
    // 电量日志网络轴（P3-5/F2-P3-1/F3-P3-4）：与 V1 同口径
    // 用 UTF-16 码元数近似——旧实现对完整字符串二次 utf8 编码纯为计长，
    // 流式大帧每帧多一次全量编码+分配。
    BatteryNetCounters.txBytes += encoded.length;
    try {
      s.sink.add(encoded);
    } catch (_) {
      // P3-10：适配层在连接失败路径同步 close 本地 sink，
      // 迟到的 add 会抛 StateError——看门狗会兜住重建，异常不得从定时器
      // 回调/业务调用方同步逃逸。
      return false;
    }
    return true;
  }

  /// 发业务载荷（bridge 层入口）：非 paired 态入队（V1 同款缓冲语义）。
  @override
  void sendPayload(Map<String, dynamic> payload) {
    if (_disposed) return;
    if (_state.value != RelayState.paired || !_authenticated) {
      if (_outboundQueue.length < _outboundQueueLimit) {
        _outboundQueue.add(payload);
      } else {
        // A6①（2026-10-24 修复批）：溢出静默丢弃→留痕（断连期发送丢失
        // 此前无任何信号，排障只能靠猜）。
        _log(
          '[v2] outbound queue overflow ($_outboundQueueLimit), drop: '
          '${payload['zcode_type'] ?? payload['type'] ?? 'payload'}',
        );
      }
      return;
    }
    _send({'type': 'data', 'payload': payload, 'client_ts': _nowSec()});
  }

  void _flushOutboundQueue() {
    if (_outboundQueue.isEmpty) return;
    final queued = List.of(_outboundQueue);
    _outboundQueue.clear();
    for (final p in queued) {
      sendPayload(p);
    }
  }

  void _handleRaw(dynamic data, int gen) {
    // 电量日志网络轴（P3-8）：与 V1 同口径——全部入站帧计长
    // （含坏帧/二进制帧），不再仅计合法 JSON 帧（V2 期实测流量不再偏小）。
    if (data is String) {
      BatteryNetCounters.rxBytes += data.length;
    } else {
      if (data is List<int>) BatteryNetCounters.rxBytes += data.length;
      // P3-8：二进制帧=协议漂移信号（契约只有 JSON 文本帧），
      // 打一行日志暴露而非静默吞掉。
      _log('[v2] 非 JSON 文本帧被忽略（${data.runtimeType}）');
      return;
    }
    Map<String, dynamic>? frame;
    try {
      final decoded = jsonDecode(data);
      if (decoded is Map) frame = decoded.cast<String, dynamic>();
    } catch (_) {}
    if (frame == null) return;
    switch (frame['type']) {
      case 'auth_ack':
        // 官方严格语义：仅在 authenticating 态且 device_sid 与目标一致时接受。
        if (_state.value == RelayState.authenticating &&
            frame['device_sid'] == config.deviceSid) {
          _authenticated = true;
          _backoffFailures = 0;
          _handshakeDeadline?.cancel();
          _applyPairStatus('${frame['pair_status'] ?? 'waiting'}');
        }
        break;
      case 'pair_status_ack':
        if (!_authenticated || _state.value == RelayState.closed) return;
        _applyPairStatus('${frame['pair_status'] ?? 'waiting'}');
        break;
      case 'data':
        if (!_authenticated || _state.value != RelayState.paired) return;
        final payload = frame['payload'];
        if (payload is Map) {
          _payloadController.add(payload.cast<String, dynamic>());
        }
        break;
      case 'error':
        _handleRelayError('${frame['code'] ?? ''}',
            message: frame['message'] is String ? frame['message'] as String? : null);
        break;
    }
  }

  void _applyPairStatus(String status) {
    // P3-8：未知 pair_status 枚举=协议漂移信号（
    // 哨兵：只观察不拦截——按 waiting 容错路径继续）。
    if (status != 'matched' && status != 'waiting') {
      _log('[v2] 未知 pair_status 枚举: $status（按 waiting 容错）');
    }
    _lastAckAt = DateTime.now();
    _acknowledged();
    if (status == 'matched') {
      _waitingTimer?.cancel();
      _offlineGraceTimer?.cancel();
      final hadPaired = _wasPaired;
      _wasPaired = true;
      _setState(RelayState.paired);
      _flushOutboundQueue();
      if (!hadPaired) {
        _log('[v2] paired（device=${config.deviceSid}）');
      }
    } else {
      // waiting：曾 paired 保持同 WS 继续等（官方 :344-354 语义）；仅在
      // "进入 waiting 的迁移"时武装 30s 超时（等待期内心跳 ack 不重置它）。
      final enteringWaiting = _state.value != RelayState.waiting;
      _setState(RelayState.waiting);
      if (enteringWaiting) {
        _waitingFailureEmitted = false;
        _armWaitingTimeout();
      }
    }
  }

  void _handleRelayError(String code, {String? message}) {
    _log('[v2] relay error: $code${message == null ? '' : ' ($message)'}');
    switch (code) {
      case 'KICKED':
        final now = DateTime.now();
        final last = _lastKickAt;
        _lastKickAt = now;
        if (last != null && now.difference(last) < timing.kickWindow) {
          // 60s 内第二次：session-conflict 终态（官方 kickedDelay→null）。
          _failTerminal(
            RelayState.kicked,
            'session-conflict',
            '60 秒内两次被踢（其他手机接管）',
          );
        } else {
          final d = _kickFirstDelay();
          unawaited(_reconnect(delay: d));
        }
        return;
      case 'AUTH_FAILED':
        _failTerminal(
          RelayState.error,
          'device-not-owned',
          '该电脑不属于当前账号（需与电脑同账号登录）',
        );
        return;
      case 'WRONG_PARAM':
        _failTerminal(
          RelayState.error,
          'invalid-mobile-connection',
          message ?? '中继拒绝连接参数',
        );
        return;
      case 'DEVICE_OFFLINE':
        // 立即重连 + 宽限：期内未重新 paired → desktop-disconnected（一次性）。
        _armOfflineGrace();
        unawaited(_reconnect(delay: Duration.zero));
        return;
      case 'INTERNAL':
        if (_wasPaired) {
          // 已有过配对会话：保持现连接降级 waiting 继续查询（官方 :590-602）。
          // P3-1/F2-P2-2/F3-P3-2（三路同报）：从 paired 降级进
          // waiting 是新 episode——_waitingFailureEmitted 必须随迁移重置，
          // 否则第二次 INTERNAL 降级起「桌面端不在线」永不再发
          // （_applyPairStatus 的 enteringWaiting 同款语义；waiting 内重复
          // INTERNAL 不重置，不刷屏）。
          if (_state.value != RelayState.waiting) _waitingFailureEmitted = false;
          _setState(RelayState.waiting);
          _armWaitingTimeout();
        } else {
          unawaited(_reconnect());
        }
        return;
      default:
        unawaited(_reconnect());
    }
  }

  Duration _kickFirstDelay() {
    final min = timing.kickFirstMin.inMilliseconds;
    final max = timing.kickFirstMax.inMilliseconds;
    // P3-6：自定义 timing 传反（max<min）时 nextInt 负区间抛
    // RangeError——按 min 兜底（与 _scheduleHeartbeat 的 clamp 同款防御；
    // const 默认值安全，此为测试/未来配置的防御）。
    final span = max - min;
    return Duration(
      milliseconds: min + (span <= 0 ? 0 : _random.nextInt(span + 1)),
    );
  }

  // ------------------------------------------------------------ timers

  /// 当前档的看门狗时长：后台档=heartbeatBackground+ackTimeout（30+15=45s，
  /// 给下一拍留足余量）；前台=ackTimeout（官方 15s）。
  Duration get _effectiveAckTimeout => _backgroundHeartbeatMode
      ? timing.heartbeatBackground + timing.ackTimeout
      : timing.ackTimeout;

  /// 后台自适应心跳开关（电量专项）。切档立即重排心跳与在途看门狗
  /// （两个方向同权）。服务器容忍度见 RelayV2Timing.heartbeatBackground 注。
  @override
  void setBackgroundHeartbeat(bool enabled) {
    if (_disposed || _backgroundHeartbeatMode == enabled) return;
    _backgroundHeartbeatMode = enabled;
    _log('[v2] heartbeat: ${enabled ? "background ${timing.heartbeatBackground.inSeconds}s" : "foreground ${timing.heartbeatBase.inSeconds}s"}');
    // 切档必须立即重排在途看门狗（P3-9：旧实现只重排"开"
    // 方向）：
    // - 开→后台档：旧 15s 档会在第一拍慢心跳应答前先到期，把放宽误杀
    //   成重连风暴（红绿用例实锤的时序坑）；
    // - 后台→前台档（回前台）：poke 的新鲜度阈（ackTimeout-2s）会把
    //   "刚 ACK 过"判为新鲜而跳过探针，残留 45s 后台档看门狗决定重建
    //   时机——短暂退后台后回前台要 ~45s 才重连，与"回前台 ≤5s 恢复"
    //   验收线冲突；立即按前台档重排后 ≤15s。
    if (_authenticated) _armAckWatchdog();
    _scheduleHeartbeat();
  }

  /// 完全静默档（电量优化批 #17）：静默=停心跳+停看门狗（重连定时器
  /// 不动——网络层故障仍走既有自愈退避）。退出静默时若已认证，立即
  /// 补一拍心跳+重挂看门狗（档位沿用 _backgroundHeartbeatMode 当前值，
  /// 前台恢复路径随后会切回 5s 档）。静默期 ACK 到达不重排（守卫在
  /// [_scheduleHeartbeat]/[_armAckWatchdog]——覆盖服务端主动推送与
  /// 静默期自愈重连两条再武装路径）。
  @override
  void setRelaySilent(bool silent) {
    if (_disposed || _silentMode == silent) return;
    _silentMode = silent;
    _log('[v2][battery] relay silent mode ${silent ? 'on（90s 倒计时窗口：不发心跳、不看门狗）' : 'off'}');
    if (silent) {
      _heartbeatTimer?.cancel();
      _heartbeatTimer = null;
      _ackWatchdog?.cancel();
      _ackWatchdog = null;
      return;
    }
    if (_authenticated) {
      _armAckWatchdog();
      _scheduleHeartbeat();
    }
  }

  void _acknowledged() {
    // 优化批 #17：静默档 ACK 到达不重挂看门狗/不排心跳（守卫统一在
    // _armAckWatchdog/_scheduleHeartbeat 内，覆盖服务端主动推送与静默期
    // 自愈重连两条再武装路径）。
    // 看门狗装配与 _armAckWatchdog 合一（P3-5：此前两份近乎
    // 相同的 Timer 装配靠人工同步维护）。
    _armAckWatchdog();
    _scheduleHeartbeat();
  }

  void _scheduleHeartbeat() {
    if (_silentMode) return; // 优化批 #17：静默档不排心跳
    _heartbeatTimer?.cancel();
    final base = (_backgroundHeartbeatMode
            ? timing.heartbeatBackground
            : timing.heartbeatBase)
        .inMilliseconds;
    final jitter = timing.heartbeatJitter.inMilliseconds;
    final lo = (base - jitter).clamp(1, base + jitter);
    final hi = base + jitter;
    final d = Duration(milliseconds: lo + _random.nextInt(hi - lo + 1));
    _heartbeatTimer = Timer(d, () {
      if (_disposed || !_authenticated) return;
      // 官方语义：认证后每轮都发查询（waiting 态同样发——relay 的 waiting
      // ack 就是看门狗的喂狗帧；桌面缺席由 waitingTimeout 表达）。
      _send({'type': 'pair_status_query', 'client_ts': _nowSec()});
    });
  }

  void _armAckWatchdog({bool probe = false}) {
    if (_silentMode) return; // 优化批 #17：静默档不挂看门狗
    _ackWatchdog?.cancel();
    final d = probe ? timing.probeTimeout : _effectiveAckTimeout;
    _ackWatchdog = Timer(d, () {
      if (_disposed || _state.value == RelayState.closed) return;
      _log('[v2] ack watchdog（${d.inMilliseconds}ms 无 ACK）-> reconnect');
      unawaited(_reconnect());
    });
  }

  void _armWaitingTimeout() {
    _waitingTimer?.cancel();
    _waitingTimer = Timer(timing.waitingTimeout, () {
      if (_disposed || _state.value == RelayState.paired) return;
      _log('[v2] waiting 超时（${timing.waitingTimeout.inSeconds}s 未配上桌面）');
      // 每个等待 episode 只发一次失败事件；保持 waiting + 心跳——桌面上线
      // 即自动配上（官方为失败页终态，此处保留可自动恢复， 决策）。
      if (!_waitingFailureEmitted) {
        _waitingFailureEmitted = true;
        _failureController.add(
          const RelayFailure('desktop-disconnected', '桌面端不在线'),
        );
      }
      _armWaitingTimeout();
    });
  }

  bool _waitingFailureEmitted = false;

  void _armOfflineGrace() {
    _offlineGraceTimer?.cancel();
    _offlineGraceTimer = Timer(timing.deviceOfflineGrace, () {
      if (_disposed || _state.value == RelayState.paired) return;
      _log('[v2] device offline 宽限到仍未 paired');
      _failureController.add(
        const RelayFailure('desktop-disconnected', '桌面端已离线'),
      );
    });
  }

  void _failTerminal(RelayState state, String reason, String message) {
    _intentionallyClosed = true;
    _cancelTimers();
    // 宽限定时器不随 _cancelTimers 走（见其注释）——终态必须显式撤。
    _offlineGraceTimer?.cancel();
    _offlineGraceTimer = null;
    _setState(state);
    _failureController.add(RelayFailure(reason, message));
    unawaited(_socketSub?.cancel());
    unawaited(_socket?.sink.close().catchError((_) {}));
    _socket = null;
  }

  void _cancelTimers() {
    // offlineGrace 不在此列（P1-2/F3-P2-1）：DEVICE_OFFLINE
    // 分支先武装宽限再立即 _reconnect，若随重连取消则 15s 宽限永不可能
    // 触发（原实现即此死代码，信号退化到 30s waiting 超时）。它的生命
    // 周期=重新 paired（_applyPairStatus 取消）/终态与 dispose（显式
    // 取消），必须跨重连存活。
    _handshakeDeadline?.cancel();
    _heartbeatTimer?.cancel();
    _ackWatchdog?.cancel();
    _waitingTimer?.cancel();
    _reconnectTimer?.cancel();
    _handshakeDeadline = null;
    _heartbeatTimer = null;
    _ackWatchdog = null;
    _waitingTimer = null;
    _reconnectTimer = null;
  }

  void _setState(RelayState s) {
    if (_state.value == s) return;
    _state.value = s;
    _log('[v2] state -> $s');
  }

  void _log(String line) => onLog?.call(line);
}
