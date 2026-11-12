// 应用锁状态层。
//
// 设计拍板（用户 2026-11-12）：全部用户可选——方式三态（关/系统锁屏
// 凭证/自建 PIN）、自动锁定时机（冷启动必锁恒成立，后台超过可配时长
// 再锁）、锁定期 FLAG_SECURE 防缩略图泄露（默认开，仅锁定遮罩期间
// 生效——与「使用中可自由截屏」拍板不冲突）。
//
// 关键结构决策：Controller 独立挂 WidgetsBindingObserver，不走
// AppState.onAppPaused/onAppResumed——那两条路径各有提前 return 分支
// （审批提醒 keepAlive / 未悬挂 resume），锁逻辑挂尾部会被跳过；且
// resume 快路径不 notifyListeners，锁状态若依赖 AppState 通知会漏刷。
// 独立 notifier 让锁遮罩只听锁状态，AppState 频繁 notify 不牵连重建。
//
// 威胁模型=防旁人翻看（非对抗取证）：PIN 用盐+SHA-256 单次哈希
//（crypto 已有依赖）即可；「已解锁」不持久化——进程被杀/冷启动天然
// 回到锁定态。
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// 应用锁方式（持久化串见 [appLockModeToString]/[appLockModeFromString]）。
enum AppLockMode { none, system, pin }

String appLockModeToString(AppLockMode m) => switch (m) {
      AppLockMode.none => 'none',
      AppLockMode.system => 'system',
      AppLockMode.pin => 'pin',
    };

AppLockMode appLockModeFromString(String? raw) => switch (raw) {
      'system' => AppLockMode.system,
      'pin' => AppLockMode.pin,
      _ => AppLockMode.none, // 未知/缺失=关（fail-open 与「可选开关默认关」拍板一致）
    };

/// 回前台是否应重新锁定（纯函数，可测）。pausedAt 为 null 表示进程
/// 冷启动（无后台时刻）——mode!=none 时恒锁。
bool shouldLockOnResume(DateTime? pausedAt, DateTime now, int autoLockSeconds) {
  if (pausedAt == null) return true;
  if (autoLockSeconds <= 0) return true; // 0=立即锁
  return now.difference(pausedAt).inSeconds >= autoLockSeconds;
}

/// PIN 盐+哈希（16 进制串）。随机盐用 Random.secure。
String randomPinSalt() {
  final r = Random.secure();
  final bytes = List<int>.generate(16, (_) => r.nextInt(256));
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

String hashPin(String pin, String saltHex) {
  final salt = List<int>.generate(
    saltHex.length ~/ 2,
    (i) => int.parse(saltHex.substring(i * 2, i * 2 + 2), radix: 16),
  );
  return sha256.convert([...salt, ...pin.codeUnits]).toString();
}

/// PIN 解锁失败冷却：连续错 5 次锁 30s（防旁人爆破；墙钟注入可测）。
class PinAttemptLimiter {
  static const maxAttempts = 5;
  static const cooldownSeconds = 30;
  int _failures = 0;
  DateTime? _cooldownUntil;

  /// 冷却中剩余秒数（0=可尝试）。
  int cooldownRemaining(DateTime now) {
    final until = _cooldownUntil;
    if (until == null) return 0;
    final s = until.difference(now).inSeconds;
    return s > 0 ? s : 0;
  }

  /// 记一次失败。返回当前冷却剩余（触发冷却时>0）。
  int recordFailure(DateTime now) {
    _failures++;
    if (_failures >= maxAttempts) {
      _cooldownUntil = now.add(const Duration(seconds: cooldownSeconds));
      _failures = 0;
    }
    return cooldownRemaining(now);
  }

  void recordSuccess() {
    _failures = 0;
    _cooldownUntil = null;
  }
}

/// 应用锁控制器：锁状态 + 生命周期判定 + 解锁动作。
/// UI（AppLockGate）只监听本对象；设置页改 UiPrefs 后调 [reloadFromPrefs]。
class AppLockController extends ChangeNotifier with WidgetsBindingObserver {
  AppLockController({@visibleForTesting MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('companion/app_lock');

  final MethodChannel _channel;
  AppLockMode _mode = AppLockMode.none;
  bool _secureOn = false;
  int _autoLockSeconds = 60;
  bool _secureFlagPref = true;
  bool _locked = false;
  DateTime? _backgroundedAt;
  // 系统凭证验证 Activity 返回时 resumed 不得把刚完成的
  // 解锁再锁回去（验证页停留超阈值/立即档必现死循环）——一次性抑制。
  bool _suppressNextResumeLock = false;
  final PinAttemptLimiter _pinLimiter = PinAttemptLimiter();
  // 测试缝：默认墙钟（真机不可注入）。
  @visibleForTesting
  DateTime Function() now = DateTime.now;

  AppLockMode get mode => _mode;
  bool get locked => _locked;
  int get autoLockSeconds => _autoLockSeconds;

  /// 从 UiPrefs 语义值装载（settings 页改动后调用；初始装载由
  /// AppLockGate 首帧完成——冷启动 locked=(mode!=none)）。
  /// pin 材料缺失时的降级信号（gate 据此提示"应用锁数据缺失已停用"）。
  final ValueNotifier<bool> pinMaterialMissing = ValueNotifier(false);

  /// 系统凭证验证不可用（设备锁被移除等）——锁屏给"去系统设置配锁"
  /// 出口。
  final ValueNotifier<bool> systemUnlockUnavailable = ValueNotifier(false);

  void loadFromPrefs({
    required AppLockMode mode,
    required int autoLockSeconds,
    required bool secureFlagPref,
    bool initialLock = false,
    String? pinSalt,
    String? pinHash,
  }) {
    //  软锁死：mode=pin 而盐/哈希缺失（部分写失败/迁移丢键
    // 可达）→ 永远"PIN 不正确"且无恢复入口。降级为关（没有 secret 可
    // 保护，不构成安全降级），由 gate/设置页提示重设。
    if (mode == AppLockMode.pin &&
        (pinSalt == null || pinHash == null || pinSalt.isEmpty || pinHash.isEmpty)) {
      mode = AppLockMode.none;
      pinMaterialMissing.value = true;
    } else {
      pinMaterialMissing.value = false;
    }
    // 模式切换（→锁定模式）必锁（安全优先——含从 none 开启的首次
    // 装载）；initialLock 只决定「模式未变」时首载的初始态。
    final modeChanged = _mode != mode;
    _mode = mode;
    _autoLockSeconds = autoLockSeconds;
    _secureFlagPref = secureFlagPref;
    if (modeChanged || initialLock) {
      _setLocked(mode != AppLockMode.none);
    }
    if (_mode == AppLockMode.none) {
      _backgroundedAt = null;
      _setSecureFlag(false);
    }
  }

  void attach() {
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_mode == AppLockMode.none) return;
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        // 回前台序列也含合成 hidden（paused→hidden→…
        // →hidden→inactive→resumed）——仅在"尚无后台时刻"时写入，
        // 不得把回前台的 hidden 当作刚退后台重置计时（否则定时档全失效）。
        _backgroundedAt ??= now();
        // 立即档：切后台当下就锁+开 FLAG_SECURE（遮罩先于系统任务栏
        // 缩略图刷新渲染的窗口尽量提前）。
        if (_autoLockSeconds <= 0) _setLocked(true);
        break;
      case AppLifecycleState.resumed:
        if (_suppressNextResumeLock) {
          _suppressNextResumeLock = false;
          _backgroundedAt = null;
          break;
        }
        final pausedAt = _backgroundedAt;
        _backgroundedAt = null;
        if (shouldLockOnResume(pausedAt, now(), _autoLockSeconds)) {
          _setLocked(true);
        }
        break;
      default:
        break;
    }
  }

  /// system 模式解锁：调系统锁屏凭证验证（成功/取消/失败回传）。
  /// 返回 true=解锁成功。通道异常按失败处理（停留锁屏）。
  Future<bool> unlockWithSystem() async {
    if (_mode != AppLockMode.system) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('requestSystemUnlock');
      if (ok != true) {
        // 设备锁被移除后 intent 为 null——不给提示会像
        // 按钮坏了一样，且设置页不可达=死锁。返回可区分错误给 UI。
        systemUnlockUnavailable.value = true;
        return false;
      }
      systemUnlockUnavailable.value = false;
      if (ok == true) {
        _setLocked(false);
        // /④：系统验证页是 opaque Activity——本应用必然
        // 走过 paused；onActivityResult 先于 onResume 送达，若不清后台
        // 时刻/不抑制，紧随的 resumed 会按已过阈值立刻再锁（死循环）。
        _backgroundedAt = null;
        _suppressNextResumeLock = true;
        return true;
      }
    } catch (_) {}
    return false;
  }

  /// pin 模式解锁：本地校验（带爆破冷却）。返回：
  /// true=成功；false=PIN 错；正数=冷却剩余秒（本次未校验）。
  Future<Object> unlockWithPin(String pin, {String? saltHex, String? hashHex}) {
    final cooldown = _pinLimiter.cooldownRemaining(now());
    if (cooldown > 0) return Future.value(cooldown);
    final storedHash = hashHex;
    if (storedHash == null || saltHex == null) return Future.value(false);
    if (hashPin(pin, saltHex) == storedHash) {
      _pinLimiter.recordSuccess();
      _setLocked(false);
      return Future.value(true);
    }
    return Future.value(_pinLimiter.recordFailure(now()) > 0 ? 5 : false);
  }

  void _setLocked(bool v) {
    if (_locked == v) return;
    _locked = v;
    _setSecureFlag(v && _secureFlagPref);
    notifyListeners();
  }

  void _setSecureFlag(bool on) {
    if (_secureOn == on) return; // 去重：重复目标态不发通道调用
    _secureOn = on;
    _channel.invokeMethod<void>('setSecureFlag', on).catchError((_) {});
  }
}
