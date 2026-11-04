import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import '../transport/relay_client.dart' show BatteryNetCounters;

/// 电量日志（2026-10-19 用户需求：包内常驻、无 UI、只落日志——日常使用
/// 时自动做"什么状态下耗了多少电"的统计与归因，给后续优化提依据）。
///
/// **临时探针（用户拍板）**：电量优化完成后本文件可整体删除（连同
/// AppState 启动接线 / relay_client 的 BatteryNetCounters /
/// MainActivity 的 companion/battery 通道 / 对应测试）——拆除清单见
/// docs/battery-measure.md 生命周期节。
///
/// 记录轴（一行一个样本，battery-journal.jsonl 追加）：
/// - lvl/chg：电量百分比与充电态（充电段在分析时剔除）
/// - st：前台/后台 × 连接态（fg-conn / bg-disc / …）——归因主轴
/// - fgs：审批提醒（前台服务长连）是否开
/// - run：运行中回合数（流式帧活跃度）
/// - cpu：本进程累计 CPU 秒（/proc/self/stat，CLK_TCK=100）
/// - rx/tx：WebSocket 字节数累计（relay 层喂的计数器）
///
/// 写入规则（batteryShouldWrite）：电量变 1% / 充电沿 / 状态切换立即写；
/// 否则每 10 个 tick（约 10 分钟）心跳一行。文件 >512KB 从头截半（整行）。
/// 配套分析：tools/battery-journal-analyze.py（按状态桶出 耗电%/时、
/// CPU 秒/时、流量 KB/时）。进程被杀后日志自然停写——那段窗口归
/// batterystats（adb 层）管，见 docs/battery-measure.md。
class BatteryJournal with WidgetsBindingObserver {
  static const _channel = MethodChannel('companion/battery');
  static const _fgTickInterval = Duration(seconds: 60);
  static const _bgTickInterval = Duration(minutes: 5);
  static const _maxFileBytes = 512 * 1024;
  static const _trimToBytes = 256 * 1024;
  /// Android bionic CLK_TCK（用户态时钟节拍/秒）。
  static const _clkTck = 100;

  final void Function(String line)? onLog;
  Timer? _timer;
  int _tick = 0;
  int seq = 0;

  AppLifecycleState _lifecycle = AppLifecycleState.resumed;
  _BatterySample? _prev;
  bool _channelBroken = false;

  /// 通道破坏后的采样计数（开源审查 E2-P3-7：重试判据此前用 _tick，
  /// 而 lifecycle 强制采样路径不递增 _tick——重试窗口漂移）。
  int _brokenSamples = 0;

  /// 开源审查 E3-P3-6：start 幂等门（重复调用=双定时器+双观察者+双 sink）。
  bool _started = false;
  File? _file;
  IOSink? _sink;
  int _writtenBytes = 0;
  bool _rotating = false;

  /// 由调用方提供的连接态（"conn"/"disc"）——journal 自身只管前后台。
  String Function()? connProvider;
  bool Function()? fgServiceProvider;
  int Function()? runningTurnsProvider;

  BatteryJournal({this.onLog});

  Future<void> start({
    required String Function() connProvider,
    required bool Function() fgServiceProvider,
    required int Function() runningTurnsProvider,
  }) async {
    if (_started) return;
    _started = true;
    this.connProvider = connProvider;
    this.fgServiceProvider = fgServiceProvider;
    this.runningTurnsProvider = runningTurnsProvider;
    final dir = await getApplicationSupportDirectory();
    final file = File('${dir.path}/battery-journal.jsonl');
    await _rotateIfNeeded(file);
    _file = file;
    _writtenBytes = await file.length();
    _sink = file.openWrite(mode: FileMode.append);
    WidgetsBinding.instance.addObserver(this);
    _scheduleNextTick();
    // 启动即写一行（拿到基线，别等满一分钟）。
    unawaited(_sampleAndMaybeWrite(force: true));
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    WidgetsBinding.instance.removeObserver(this);
    // 开源审查 E2-P3-7：flush 完成后再 close、错误面收口（两个裸
    // unawaited 的任一失败都会成未处理异步错误）。
    final sink = _sink;
    _sink = null;
    _started = false;
    if (sink != null) {
      unawaited(sink.flush().then((_) => sink.close()).catchError((_) {}));
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycle = state;
    unawaited(_sampleAndMaybeWrite(force: true));
  }

  /// 自调度（观察者效应控制）：前台 60s 一拍；退后台降到 5 分钟一拍——
  /// 后台掉电本就以分钟计，降采样不损数据分辨率，却把自身唤醒频率砍到
  /// 1/5。前后台切换沿仍由 lifecycle 回调立即落行，不依赖拍子。
  void _scheduleNextTick() {
    _timer?.cancel();
    final inFg = _lifecycle == AppLifecycleState.resumed ||
        _lifecycle == AppLifecycleState.inactive;
    _timer = Timer(inFg ? _fgTickInterval : _bgTickInterval, () async {
      _tick += 1;
      await _sampleAndMaybeWrite(force: false);
      if (_sink != null) _scheduleNextTick();
    });
  }

  Future<void> _sampleAndMaybeWrite({required bool force}) async {
    final sink = _sink;
    if (sink == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final batt = await _readBattery();
    if (batt == null) return;
    final conn = connProvider?.call() ?? 'disc';
    final life = _lifecycle == AppLifecycleState.resumed ||
            _lifecycle == AppLifecycleState.inactive
        ? 'fg'
        : 'bg';
    final nowSample = _BatterySample(
      t: now,
      level: batt.level,
      charging: batt.charging,
      stateCode: '$life-$conn',
      fgService: fgServiceProvider?.call() ?? false,
      runningTurns: runningTurnsProvider?.call() ?? 0,
      cpuSeconds: _processCpuSeconds(),
      rxKb: BatteryNetCounters.rxBytes ~/ 1024,
      txKb: BatteryNetCounters.txBytes ~/ 1024,
    );
    final prev = _prev;
    if (!force &&
        !batteryShouldWrite(
          prevLevel: prev?.level,
          prevCharging: prev?.charging,
          prevStateCode: prev?.stateCode,
          prevFgService: prev?.fgService,
          level: nowSample.level,
          charging: nowSample.charging,
          stateCode: nowSample.stateCode,
          fgService: nowSample.fgService,
          tick: _tick,
        )) {
      return;
    }
    _prev = nowSample;
    seq += 1;
    try {
      final line = batteryJournalLine(
        t: nowSample.t,
        level: nowSample.level,
        charging: nowSample.charging,
        stateCode: nowSample.stateCode,
        fgService: nowSample.fgService,
        runningTurns: nowSample.runningTurns,
        cpuSeconds: nowSample.cpuSeconds,
        rxKb: nowSample.rxKb,
        txKb: nowSample.txKb,
        seq: seq,
      );
      sink.writeln(line);
      _writtenBytes += line.length + 1;
      // 低频落地（flush 策略：每次写即 flush——量极小，换数据安全）。
      unawaited(sink.flush());
      // 开源审查 E2-P3-6：轮转不再只在 start() 执行（长驻进程无界增长）
      // ——写入路径按累计字节触发截半轮转（tmp+rename 原子替换）。
      if (_writtenBytes > _maxFileBytes) {
        unawaited(_rotateNow());
      }
    } catch (_) {}
    if (seq == 1 || seq % 500 == 0) {
      onLog?.call('[battery] journal lines=$seq');
    }
  }

  Future<({int level, bool charging})?> _readBattery() async {
    if (_channelBroken) {
      // 每 10 次采样重试一次（activity 重建等场景可恢复）。
      if (_brokenSamples < 10) {
        _brokenSamples += 1;
        return null;
      }
      _brokenSamples = 0;
    }
    try {
      // 开源审查 E1-P3-8：平台通道无超时——native 挂死会让
      // _sampleAndMaybeWrite 永不返回、tick 链永久停摆、journal 静默
      // 停写。10s 超时兜底（超时按无样本跳过本轮）。
      final res = await _channel
          .invokeMethod<Map>('get')
          .timeout(const Duration(seconds: 10), onTimeout: () => null);
      if (res is Map) {
        final level = (res['level'] as num?)?.toInt() ?? -1;
        if (level < 0) return null;
        _channelBroken = false;
        _brokenSamples = 0;
        return (level: level, charging: res['charging'] == true);
      }
      return null;
    } on PlatformException {
      _channelBroken = true;
      return null;
    } on MissingPluginException {
      _channelBroken = true;
      return null;
    } catch (_) {
      return null;
    }
  }

  /// 写入路径触发的截半轮转（开源审查 E2-P3-6）：flush+close 当前 sink →
  /// tmp+rename 原子替换（轮转重写中途被杀不截断日志）→ 重开 append。
  /// 轮转期间新写入用旧 sink 抛错被上层 catch 吞（探针丢 1-2 行可接受）。
  Future<void> _rotateNow() async {
    if (_rotating) return;
    _rotating = true;
    try {
      final file = _file;
      final sink = _sink;
      if (file == null || sink == null) return;
      await sink.flush();
      await sink.close();
      _sink = null;
      final content = await file.readAsString();
      final trimmed = trimJournalHead(content, _trimToBytes);
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(trimmed, flush: true);
      await tmp.rename(file.path);
      _sink = file.openWrite(mode: FileMode.append);
      _writtenBytes = _trimToBytes;
    } catch (_) {
      // 轮转失败：尽力重开 append（文件保持原状，下轮字节阈值再试）。
      final file = _file;
      if (file != null && _sink == null) {
        try {
          _sink = file.openWrite(mode: FileMode.append);
        } catch (_) {}
      }
    } finally {
      _rotating = false;
    }
  }

  /// /proc/self/stat 的 utime+stime（字段 14/15，comm 可含空格——从最后
  /// 一个 ')' 之后切）。读取失败返回 -1（分析端跳过该轴）。
  static double _processCpuSeconds() {
    try {
      final stat = File('/proc/self/stat').readAsStringSync();
      final tail = stat.substring(stat.lastIndexOf(')') + 2).split(' ');
      // tail[0] 对应字段 3（state）→ utime=tail[11]、stime=tail[12]。
      if (tail.length < 13) return -1;
      final ticks = (int.tryParse(tail[11]) ?? 0) + (int.tryParse(tail[12]) ?? 0);
      return ticks / _clkTck;
    } catch (_) {
      return -1;
    }
  }

  static Future<void> _rotateIfNeeded(File file) async {
    try {
      if (!await file.exists()) return;
      final len = await file.length();
      if (len <= _maxFileBytes) return;
      final content = await file.readAsString();
      final trimmed = trimJournalHead(content, _trimToBytes);
      await file.writeAsString(trimmed, flush: true);
    } catch (_) {}
  }
}

/// 紧凑一行（字段名缩到 2-3 字符省体积；顺序固定便于肉眼扫）。
String batteryJournalLine({
  required int t,
  required int level,
  required bool charging,
  required String stateCode,
  required bool fgService,
  required int runningTurns,
  required double cpuSeconds,
  required int rxKb,
  required int txKb,
  required int seq,
}) {
  final m = {
    't': t,
    'lvl': level,
    'chg': charging ? 1 : 0,
    'st': stateCode,
    if (fgService) 'fgs': 1,
    if (runningTurns > 0) 'run': runningTurns,
    if (cpuSeconds >= 0) 'cpu': double.parse(cpuSeconds.toStringAsFixed(1)),
    'rx': rxKb,
    'tx': txKb,
    'n': seq,
  };
  return jsonEncode(m);
}

/// 写入判定（纯函数）：强制沿（充电切换/状态码变化/电量变化/开关变）
/// 立即写；否则按心跳间隔。prev 传 null = 首样本恒写。
bool batteryShouldWrite({
  required int? prevLevel,
  required bool? prevCharging,
  required String? prevStateCode,
  required bool? prevFgService,
  required int level,
  required bool charging,
  required String stateCode,
  required bool fgService,
  required int tick,
  int heartbeatEvery = 10,
}) {
  if (prevLevel == null ||
      prevCharging == null ||
      prevStateCode == null ||
      prevFgService == null) {
    return true;
  }
  if (prevCharging != charging) return true;
  if (prevStateCode != stateCode) return true;
  if (prevLevel != level) return true;
  if (prevFgService != fgService) return true;
  return tick % heartbeatEvery == 0;
}

/// 体积截断：从头丢整行，保留尾部约 [keepBytes]。
String trimJournalHead(String content, int keepBytes) {
  final bytes = utf8.encode(content);
  if (bytes.length <= keepBytes) return content;
  // 从尾部回找 keepBytes 附近的行首。
  var cut = bytes.length - keepBytes;
  while (cut < bytes.length && bytes[cut] != 0x0a) {
    cut += 1;
  }
  if (cut >= bytes.length) return content;
  return utf8.decode(bytes.sublist(cut + 1), allowMalformed: true);
}

class _BatterySample {
  final int t;
  final int level;
  final bool charging;
  final String stateCode;
  final bool fgService;
  final int runningTurns;
  final double cpuSeconds;
  final int rxKb;
  final int txKb;

  _BatterySample({
    required this.t,
    required this.level,
    required this.charging,
    required this.stateCode,
    required this.fgService,
    required this.runningTurns,
    required this.cpuSeconds,
    required this.rxKb,
    required this.txKb,
  });
}
