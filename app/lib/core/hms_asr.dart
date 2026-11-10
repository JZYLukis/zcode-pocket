import 'package:flutter/services.dart';

/// HMS ML ASR 客户端（companion/hms_asr 通道）——私包专属语音引擎
/// （HMS 结构性剥离 2026-10-29 批次）：原生实现=src/voiceHms 条件源集的
/// HmsAsrPlugin（仅 -PvoiceHms=true 构建在包；默认/公开构建无此类与任何
/// HMS 依赖，语音走 [SystemAsr] 系统通道）。选择逻辑见
/// voice_input_sheet.hmsVoiceConfigured。
///
/// 协议与 SystemAsr 同构：start→（partial…）→final / error；原生事件经
/// invokeMethod('event') 推送。prepare 一步做 AGConnect 编程式初始化 +
/// 构建期 API Key 注入（ 坑4 双保险）。
class HmsAsr {
  static const MethodChannel _ch = MethodChannel('companion/hms_asr');

  /// 私包原生插件是否在包（默认构建=缺席）。启动预热一次；测试环境
  /// （无原生 handler）安全回落 false。
  static bool? _availableCache;

  static bool get available => _availableCache ?? false;

  static Future<bool> probe() async {
    if (_availableCache != null) return _availableCache!;
    try {
      _availableCache = await _ch.invokeMethod<bool>('ping') ?? false;
    } on MissingPluginException {
      _availableCache = false;
    } on PlatformException {
      // 瞬时异常不落缓存（与 SystemAsr.probe 同款）：
      // 一次性错误只影响本次结果，下次再探。
      return false;
    }
    return _availableCache!;
  }

  /// 测试缝：清空探测缓存（用例间隔离）。
  static void resetForTest() => _availableCache = null;

  /// 测试缝：直接注入可用性（通道选择矩阵用例）。
  static void debugSetAvailable(bool? value) => _availableCache = value;

  static HmsAsrSession start({
    String? apiKey,
    String language = 'zh-CN',
    required void Function(String partial) onPartial,
    required void Function(String finalText) onFinal,
    required void Function(int code, String message) onError,
  }) {
    final session = HmsAsrSession._(
      onPartial: onPartial,
      onFinal: onFinal,
      onError: onError,
    );
    session._bind();
    session._invoke('prepare', {'apiKey': apiKey});
    session._invoke('start', {'language': language});
    return session;
  }

  /// 单槽 handler 会话守卫（与 SystemAsr._active 同款）：
  /// cancel 只在槽位仍属于自己时才摘除，迟到 cancel 不误杀后继会话。
  static HmsAsrSession? _active;
}

/// 一次识别会话：prepare→start→（partial…）→final / error。
/// HMS 无 stop API（停顿自动吐终稿），stop 为协议占位。
class HmsAsrSession {
  HmsAsrSession._({
    required void Function(String partial) onPartial,
    required void Function(String finalText) onFinal,
    required void Function(int code, String message) onError,
  }) : _onPartial = onPartial,
       _onFinal = onFinal,
       _onError = onError;

  static const MethodChannel _ch = MethodChannel('companion/hms_asr');
  final void Function(String partial) _onPartial;
  final void Function(String finalText) _onFinal;
  final void Function(int code, String message) _onError;
  bool _closed = false;

  void _bind() {
    HmsAsr._active = this;
    _ch.setMethodCallHandler((call) async {
      if (call.method != 'event' || _closed) return null;
      final map = Map<String, dynamic>.from(call.arguments as Map);
      switch (map['type'] as String? ?? '') {
        case 'partial':
          final text = map['text'] as String? ?? '';
          if (text.isNotEmpty) _onPartial(text);
        case 'final':
          _closed = true;
          _onFinal(map['text'] as String? ?? '');
        case 'error':
          _closed = true;
          _onError(
            (map['code'] as num?)?.toInt() ?? -1,
            map['message'] as String? ?? '',
          );
      }
      return null;
    });
  }

  Future<void> _invoke(String method, [Map<String, dynamic>? args]) async {
    try {
      await _ch.invokeMethod(method, args);
    } on PlatformException catch (e) {
      // 原生侧 result.error（start_failed 等，如非华为 arm
      // 机 HMS 引擎缺席）此前穿透成无人接的异步异常——统一并入失败分支。
      if (!_closed) {
        _closed = true;
        _onError(-1, '${e.code}: ${e.message ?? ''}');
      }
      return;
    } on MissingPluginException {
      // 默认构建误开 VOICE_HMS（原生插件缺席）或测试环境——直接报错走
      // 统一失败分支，不悬挂。
      if (!_closed) {
        _closed = true;
        _onError(-1, 'hms asr unavailable (default build?)');
      }
    }
  }

  /// 提前收尾占位（HMS 无 stop API；8s 兜底由调用方状态机处理）。
  Future<void> stop() => _invoke('stop');

  /// 放弃（面板关闭）。槽位守卫见 HmsAsr._active 注释。
  Future<void> cancel() {
    _closed = true;
    if (identical(HmsAsr._active, this)) {
      HmsAsr._active = null;
      _ch.setMethodCallHandler(null);
    }
    return _invoke('cancel');
  }
}
