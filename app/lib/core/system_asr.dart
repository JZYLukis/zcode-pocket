import 'package:flutter/services.dart';

/// 系统 SpeechRecognizer 客户端（companion/sys_asr 通道）：
/// 语音识别的主体通道——设备生态提供的通用识别能力（海外机=Google
/// 服务、多数国产机=ROM 内置语音服务，语音键盘同源），所有构建默认
/// 走此通道；私有维护者构建可经 VOICE_HMS 覆盖为另一引擎（仅本地，
/// 见 voice_input_sheet.hmsVoiceConfigured）。系统服务与私有引擎皆无
/// 时隐藏语音入口。
///
/// 原生实现=MainActivity 挂载的 SystemAsrPlugin（零第三方依赖，纯
/// android.speech.SpeechRecognizer）。事件由原生 invokeMethod('event')
/// 推送，[onEvent] 统一分发：type ∈ partial / final / error。
class SystemAsr {
  static const MethodChannel _ch = MethodChannel('companion/sys_asr');

  /// 探测结果缓存（启动预热一次；探测本身是本地 Intent 查询，零网络）。
  static bool? _availableCache;

  /// 系统识别服务是否可用（设备有语音识别 provider 即 true——海外机
  /// =Google 服务、多数国产机=ROM 内置语音服务，语音键盘同源）。
  /// 测试环境（无原生 handler）安全回落 false。
  static bool get available => _availableCache ?? false;

  static Future<bool> probe() async {
    if (_availableCache != null) return _availableCache!;
    try {
      _availableCache = await _ch.invokeMethod<bool>('isAvailable') ?? false;
    } on MissingPluginException {
      _availableCache = false;
    } on PlatformException {
      // 瞬时异常不落缓存（开源审查 P1 P3-4）：开机识别服务暂不可用等
      // 一次性错误若缓存 false，本会话语音入口永久隐藏（重启才恢复）。
      // 本次返回 false，下次再探；插件缺席（MissingPlugin）才是终态 false。
      return false;
    }
    return _availableCache!;
  }

  /// 测试缝：清空探测缓存（用例间隔离）。
  static void resetForTest() => _availableCache = null;

  /// 测试缝：直接注入可用性（通道选择矩阵用例）。
  static void debugSetAvailable(bool? value) => _availableCache = value;

  static SystemAsrSession start({
    String language = 'zh-CN',
    required void Function(String partial) onPartial,
    required void Function(String finalText) onFinal,
    required void Function(int code, String message) onError,
  }) {
    final session = SystemAsrSession._(
      onPartial: onPartial,
      onFinal: onFinal,
      onError: onError,
    );
    session._bind();
    session._invoke('start', {'language': language});
    return session;
  }

  /// 单槽 handler 会话守卫（开源审查 P1 P3-3/P2 P2-4/Q1 P3-10）：
  /// companion 通道是全进程单 handler 槽——后 start 覆盖、先 cancel
  /// 无差别置 null 会让并存会话互踩（前者失聪/后者被摘）。约定同通道
  /// 同一时刻至多一个活动会话：bind 时登记，cancel 只在槽位仍属于
  /// 自己时才摘除，迟到 cancel 不误杀后继会话（协议本身不动）。
  static SystemAsrSession? _active;
}

/// 一次识别会话：start→（partial…）→final / error。
class SystemAsrSession {
  SystemAsrSession._({
    required void Function(String partial) onPartial,
    required void Function(String finalText) onFinal,
    required void Function(int code, String message) onError,
  })  : _onPartial = onPartial,
        _onFinal = onFinal,
        _onError = onError;

  static const MethodChannel _ch = MethodChannel('companion/sys_asr');
  final void Function(String partial) _onPartial;
  final void Function(String finalText) _onFinal;
  final void Function(int code, String message) _onError;
  bool _closed = false;

  void _bind() {
    SystemAsr._active = this;
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
      // review-fix-1：原生侧 result.error（unavailable/start_failed）统一
      // 并入失败分支（此前穿透成无人接的异步异常）。
      if (!_closed) {
        _closed = true;
        _onError(-1, '${e.code}: ${e.message ?? ''}');
      }
      return;
    } on MissingPluginException {
      // 测试环境无原生侧——直接报错走统一失败分支。
      if (!_closed) {
        _closed = true;
        _onError(-1, 'system asr unavailable');
      }
    }
  }

  /// 提前收尾（用户点"说完了"——部分结果兜底由调用方状态机处理，
  /// 这里只让原生侧停止拾音并尽快吐 final）。
  Future<void> stop() => _invoke('stop');

  /// 放弃（面板关闭）。槽位守卫见 SystemAsr._active 注释。
  Future<void> cancel() {
    _closed = true;
    if (identical(SystemAsr._active, this)) {
      SystemAsr._active = null;
      _ch.setMethodCallHandler(null);
    }
    return _invoke('cancel');
  }
}
