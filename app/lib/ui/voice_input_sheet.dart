import 'dart:async';
import 'dart:io' show Process;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide Text;

import '../core/l10n.dart' show L10n;
import '../core/localized_text.dart';

import 'package:permission_handler/permission_handler.dart';

import '../core/hms_asr.dart';
import '../core/system_asr.dart';
import '../core/theme.dart';
import '../core/voice_refine.dart';
import '../state/app_state_scope.dart';

/// HMS 识别是否启用（2026-10-28 脱敏翻转）：默认关闭——系统
/// SpeechRecognizer 是所有构建的唯一默认通道，不携带任何私有引擎
/// 倾向。私有包构建时经 --dart-define=VOICE_HMS=1 打开并注入
/// AGC_API_KEY（构建脚本成对注入），公开仓库的默认形态与
/// 文档只出现通用通道。测试缝：[debugVoiceHmsOverride]。
bool? debugVoiceHmsOverride;
const String _kVoiceHmsDefineValue = String.fromEnvironment('VOICE_HMS');

/// 1.0.1 验收⑧根因：`bool.fromEnvironment('VOICE_HMS')` 只认字面
/// 'true'——构建传 `=1` 时探针串（String 语义）'zp-voice-hms:1' 断言
/// 通过而运行时 bool 恒 false（HMS 静默走系统通道=零回调；
/// 「正则改 (true|1)」恰好盖住此错配）。统一走 String 语义+宽容解析。
bool voiceHmsDefineEnabled(String value) {
    final v = value.trim().toLowerCase();
    return v == '1' || v == 'true';
}

bool get hmsVoiceConfigured =>
    debugVoiceHmsOverride ?? voiceHmsDefineEnabled(_kVoiceHmsDefineValue);

/// 语音识别可用性（两级）：系统识别服务可用（SystemAsr.available，
/// 启动预热——设备生态提供的通用识别能力）即可用；私有包打开
/// VOICE_HMS 时恒可用。皆无则隐藏入口。测试缝：
/// [debugVoiceRecognitionAvailable] 覆写。
bool? debugVoiceRecognitionAvailable;
bool get voiceRecognitionAvailable {
  final debug = debugVoiceRecognitionAvailable;
  if (debug != null) return debug;
  if (hmsVoiceConfigured) return true;
  if (SystemAsr.available) return true;
  // 缓存为空=启动探测尚未完成或开机瞬时失败（probe 失败不落缓存）。
  // 消费点按节流兜底重探，服务恢复后入口不会整会话隐藏（2026-11-08
  // 对抗审查；成功结果在下一次页面重建时可见）。
  SystemAsr.probeIfUnknown();
  return false;
}

/// 语音输入面板（阶段 3 第三段， 决策 5 / 四坑照单）。
///
/// 交互定稿（2026-10-20 用户真机反馈三轮打磨）：
/// 说话 →（可选）口语整理 → **预览可编辑** → 用户点「发送」直接发出。
/// - 整理在进入预览时完成（发送零等待）；成功=编辑框预填整理稿+一行
///   状态说明+「用原文」一键切换；失败=预填原文+失败原因行（①整理
///   结果必须可见）；未配置=预填原文不显示整理相关 UI。
/// - 预览框可任意编辑（识别错字随手改）；发送调 [onSend]（页面侧复用
///   手动发送同一条链路，不再进输入框绕一圈）。
/// - 识别：HMS ML ASR 无界面流式（zh-CN + FEATURE_WORDFLUX，真机
///   4.35s 全程实测可用）；x86 模拟器无 HMS 走不可用分支（ABI 护栏，
///   2026-10-19 装机窗口实锤）。
class VoiceInputSheet extends StatefulWidget {
  final void Function(String text) onSend;

  /// 测试缝：直接进可编辑预览态，跳过麦克风权限/HMS 平台通道。
  @visibleForTesting
  static String? debugPreviewText;

  const VoiceInputSheet({super.key, required this.onSend});

  @override
  State<VoiceInputSheet> createState() => _VoiceInputSheetState();
}

enum _VoicePhase { starting, listening, recognizing, refining, preview, failed }

class _VoiceInputSheetState extends State<VoiceInputSheet> {
  _VoicePhase _phase = _VoicePhase.starting;
  String _partial = '';
  String _error = '';
  String? _original; // 听写原文（整理成功时的回切目标）
  bool _refineOk = false;
  bool _refineAttempted = false;
  HmsAsrSession? _hmsSession;
  SystemAsrSession? _systemSession;
  final Completer<String> _finalCompleter = Completer<String>();
  final _draft = TextEditingController();
  bool _closed = false;

  /// listening 零回调看门狗（验收 G）：识别服务启动后 10s 内
  /// 无任何 partial/final/error 事件（华为系统识别服务=FakeRecognition
  /// Service 零回调实锤）→ 明确失败，不再无限停在拾音态。任何引擎
  /// 事件到达即解除（partial/final/error 都算"服务活着"）。
  Timer? _engineWatchdog;

  void _log(String line) => debugPrint('[voice] $line');

  /// x86/x86_64 ABI 检测（getprop，Android 必有；失败按 arm 处理不影响
  /// 真机路径）。
  Future<bool> _nonArmAbi() async {
    if (defaultTargetPlatform != TargetPlatform.android) return false;
    try {
      final r = Process.runSync('getprop', ['ro.product.cpu.abi']);
      final abi = '${r.stdout}'.trim();
      final nonArm = abi.startsWith('x86');
      if (nonArm) _log('abi=$abi → 不可用分支（HMS 原生库无 x86 版）');
      return nonArm;
    } catch (_) {
      return false;
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void dispose() {
    _closed = true;
    _engineWatchdog?.cancel();
    _draft.dispose();
    unawaited(_hmsSession?.cancel() ?? Future<void>.value());
    _systemSession?.cancel();
    super.dispose();
  }

  /// 识别语言跟随 app 界面语言：英文界面用户不再
  /// 被塞进中文识别引擎（英文口音进 zh-CN 引擎=识别质量差/ERROR_NO_MATCH）。
  String get _asrLanguage =>
      L10n.resolvedLocale == 'en-US' ? 'en-US' : 'zh-CN';

  Future<void> _start() async {
    _log('hmsVoiceConfigured=$hmsVoiceConfigured（VOICE_HMS=$_kVoiceHmsDefineValue）');
    final debugPreview = VoiceInputSheet.debugPreviewText;
    if (debugPreview != null) {
      setState(() {
        _original = debugPreview;
        _draft.text = debugPreview;
        _phase = _VoicePhase.preview;
      });
      return;
    }
    // 通道分派：默认系统 SpeechRecognizer（通用适配）；私有包打开
    // VOICE_HMS 时走 HMS（仅维护者自用构建）。
    // 错配自愈——Dart 开关开了但原生插件缺席
    // （构建参数错配，如 形态）时 probe=false，回退系统通道。
    final hmsReady = hmsVoiceConfigured && await HmsAsr.probe();
    // await 恢复点守卫：面板在探测/权限悬挂期间被
    // 关闭时不得继续拉起识别（release 下 assert 被剥掉，原生侧会开拾音
    // 且无人 cancel=麦克风常驻）。
    if (!mounted || _closed) return;
    if (hmsReady) {
      await _startHms();
    } else {
      if (hmsVoiceConfigured) {
        _log('HMS 插件缺席（VOICE_HMS 开关与原生源集错配）→ 回退系统通道');
      }
      await _startSystem();
    }
  }

  Future<void> _startHms() async {
    // 硬件护栏（2026-10-19 装机窗口实锤）：HMS ML ASR 原生库只有 arm 版
    // （x86_64 上 startRecognizing 的 NativeVadDetector JNI 无实现 →
    // UnsatisfiedLinkError 主线程 FATAL，Dart 不可捕获）。
    if (await _nonArmAbi()) {
      if (!mounted || _closed) return;
      setState(() {
        _phase = _VoicePhase.failed;
        _error = tr('此设备 CPU 不支持当前语音服务');
      });
      return;
    }
    final mic = await Permission.microphone.request();
    if (!mounted || _closed) return; // await 恢复点守卫（见 _start 注释）
    if (mic != PermissionStatus.granted) {
      setState(() {
        _phase = _VoicePhase.failed;
        _error = tr('未授予麦克风权限（设置→应用→权限）');
      });
      return;
    }
    // HMS 结构性剥离（2026-10-29 批次）：huawei_ml_language 插件退役，
    // 识别经自写 companion/hms_asr 通道（原生=条件源集 HmsAsrPlugin，
    // 与系统通道同构）。API Key 构建期注入（ 补记§五）在通道
    // prepare 一步完成（原生 AGConnect 编程式初始化为真机主路径，
    // setApiKey 是双保险另一半）。默认构建误开 VOICE_HMS 时（原生插件
    // 缺席）走统一失败分支，不悬挂。
    try {
      const agcApiKey = String.fromEnvironment('AGC_API_KEY');
      setState(() => _phase = _VoicePhase.listening);
      _armEngineWatchdog(const Duration(seconds: 15));
      _listenFinal();
      _hmsSession = HmsAsr.start(
        apiKey: agcApiKey.isEmpty ? null : agcApiKey,
        language: _asrLanguage,
        onPartial: (partial) {
          if (!mounted || _closed) return;
          _engineAlive();
          // 迟到 partial 不得把 failed/recognizing 拉回
          // 拾音态（看门狗判死后引擎复活的 UI 漂移）。
          if (_phase != _VoicePhase.listening && _phase != _VoicePhase.starting) {
            return;
          }
          setState(() {
            _partial = partial;
            _phase = _VoicePhase.listening;
          });
        },
        onFinal: (result) {
          _engineAlive();
          _log('final: $result');
          if (!_finalCompleter.isCompleted) {
            _finalCompleter.complete(result);
          }
        },
        onError: (code, message) {
          _engineAlive();
          _log('error code=$code msg=$message');
          if (_finalCompleter.isCompleted) return;
          _finalCompleter.completeError('[$code] $message');
        },
      );
    } catch (e) {
      setState(() {
        _phase = _VoicePhase.failed;
        _error = '${tr('语音服务不可用：')}$e';
      });
    }
  }

  /// 系统识别通道（2026-10-28 泛用批）：与 HMS 共用同一状态机
  /// （_partial/_finalCompleter/预览整理链路），仅识别来源不同。
  Future<void> _startSystem() async {
    final mic = await Permission.microphone.request();
    if (!mounted || _closed) return; // await 恢复点守卫（见 _start 注释）
    if (mic != PermissionStatus.granted) {
      setState(() {
        _phase = _VoicePhase.failed;
        _error = tr('未授予麦克风权限（设置→应用/权限）');
      });
      return;
    }
    setState(() => _phase = _VoicePhase.starting);
    _armEngineWatchdog();
    _listenFinal();
    _systemSession = SystemAsr.start(
      language: _asrLanguage,
      onPartial: (text) {
        if (!mounted || _closed) return;
        _engineAlive();
        // 同 HMS——迟到 partial 不复活 failed/recognizing。
        if (_phase != _VoicePhase.listening && _phase != _VoicePhase.starting) {
          return;
        }
        setState(() {
          _partial = text;
          _phase = _VoicePhase.listening;
        });
      },
      onFinal: (text) {
        _engineAlive();
        _log('sys final: $text');
        if (!_finalCompleter.isCompleted) _finalCompleter.complete(text);
      },
      onError: (code, message) {
        _engineAlive();
        _log('sys error code=$code msg=$message');
        if (_finalCompleter.isCompleted) return;
        // 已有部分结果时"没听清/超时"（code 6/7）不判失败，按部分结果
        // 收尾；其余码复用既有失败文案（零新增翻译串）。
        if ((code == 6 || code == 7) && _partial.trim().isNotEmpty) {
          _finalCompleter.complete(_partial);
          return;
        }
        _finalCompleter.completeError(
          code == 6 || code == 7 ? '没听到内容，再试一次' : '语音服务不可用：[$code]',
        );
      },
    );
    setState(() => _phase = _VoicePhase.listening);
  }

  /// 引擎事件到达（服务活着）——解除零回调看门狗。
  void _engineAlive() => _engineWatchdog?.cancel();

  /// 看门狗档位：系统通道 10s；HMS 15s（AGConnect 冷启+引擎唤醒+弱网
  /// 取配置可超 10s，防慢启动误杀——审查 D4a）。
  void _armEngineWatchdog([Duration duration = const Duration(seconds: 10)]) {
    _engineWatchdog?.cancel();
    _engineWatchdog = Timer(duration, () {
      if (_closed || _finalCompleter.isCompleted) return;
      _log('engine watchdog: ${duration.inSeconds}s 零回调（识别服务无响应）');
      // 判死即回收引擎——失败态不得继续拾音（隐私），
      // 且防迟到 partial 把 failed 拉回 listening。
      unawaited(_hmsSession?.cancel() ?? Future<void>.value());
      _systemSession?.cancel();
      if (!mounted) return;
      setState(() {
        _phase = _VoicePhase.failed;
        _error = tr('语音服务未响应，请重试或改用键盘输入');
      });
    });
  }

  /// 用户点"说完了"：等终稿（HMS 无 stopRecognizing，停顿后自动吐），
  /// 8s 兜底用当前部分结果 → 进预览（含整理）。系统通道有显式 stop
  /// （停拾音促原生吐 final，仍受同一 8s 兜底保护）。空部分结果也
  /// 必然收尾——_enterPreview 空文本走「没听到内容」失败态（
  /// 验收 G：此前空 partial 时 completer 永不完成=面板卡在识别中）。
  Future<void> _finish() async {
    _engineAlive();
    setState(() => _phase = _VoicePhase.recognizing);
    _systemSession?.stop();
    unawaited(_hmsSession?.stop() ?? Future<void>.value());
    _listenFinal();
    Timer(const Duration(seconds: 8), () {
      if (_closed || _finalCompleter.isCompleted) return;
      _finalCompleter.complete(_partial);
    });
  }

  /// 不等终稿直接以当前部分结果进预览。
  /// ：修复前非空分支只 complete 无人监听的 completer
  /// ——UI 纹丝不动、引擎继续拾音（审查 D4b 实锤"按钮无操作"）。修=与
  /// _finish 同构：先挂监听、停引擎、立即以部分结果收尾进预览。
  void _finishWithPartial() {
    if (_finalCompleter.isCompleted) return;
    if (_partial.trim().isNotEmpty) {
      _engineAlive();
      setState(() => _phase = _VoicePhase.recognizing);
      _systemSession?.stop();
      unawaited(_hmsSession?.stop() ?? Future<void>.value());
      _listenFinal();
      _finalCompleter.complete(_partial);
    } else {
      // 零部分结果：不能只挂监听——completer 永不完成，按钮点了毫无
      // 反馈且面板卡在拾音态（2026-11-08 对抗审查）。先取消引擎（隐私：
      // 不再等 native final），再以空稿收尾——_enterPreview 的空文本分支
      // 给出「没听到内容」失败态。
      _engineAlive();
      _systemSession?.cancel();
      unawaited(_hmsSession?.cancel() ?? Future<void>.value());
      _listenFinal();
      _finalCompleter.complete('');
    }
  }

  /// final/error 一到达即驱动 UI（：修复前监听只在
  /// 「说完了」才挂——listening 期引擎报错/自动终稿时 UI 悬挂在拾音态
  /// 且 completer 错误无人接=unhandled async error）。幂等防双挂接
  /// （双挂=同一结果两次进预览、整理请求双发）。
  bool _finalListened = false;
  void _listenFinal() {
    if (_finalListened) return;
    _finalListened = true;
    _finalCompleter.future.then(
      _enterPreview,
      onError: (Object e) {
        if (mounted && !_closed) {
          setState(() {
            _phase = _VoicePhase.failed;
            _error = '${tr('识别失败：')}$e';
          });
        }
      },
    );
  }

  /// 终稿 → （可选整理）→ 预览可编辑态。
  Future<void> _enterPreview(String original) async {
    if (_closed) return;
    final text = original.trim();
    if (text.isEmpty) {
      setState(() {
        _phase = _VoicePhase.failed;
        _error = '没听到内容，再试一次';
      });
      return;
    }
    _original = text;
    var result = text;
    var attempted = false;
    var ok = false;
    final app = AppStateScope.of(context);
    final prefs = app.uiPrefs;
    final configured =
        prefs.voiceRefineEnabled && (prefs.voiceApiKey ?? '').trim().isNotEmpty;
    if (configured) {
      setState(() => _phase = _VoicePhase.refining);
      attempted = true;
      final refined = await refineDictation(
        apiKey: prefs.voiceApiKey,
        raw: text,
        providerId: prefs.voiceApiProvider,
      );
      if (refined.trim().isNotEmpty && refined.trim() != text) {
        result = refined.trim();
        ok = true;
      }
    }
    if (_closed) return;
    _draft.text = result;
    setState(() {
      _refineAttempted = attempted;
      _refineOk = ok;
      _phase = _VoicePhase.preview;
    });
  }

  /// 预览「用原文/用整理稿」一键切换。
  void _toggleOriginal() {
    final orig = _original;
    if (orig == null || orig == _draft.text) return;
    final cur = _draft.text;
    _draft.text = orig;
    _original = cur;
    setState(() {});
  }

  void _send() {
    // 防抖——pop 动画窗口内二次点击=onSend 双发两条消息。
    if (_closed) return;
    final text = _draft.text.trim();
    if (text.isEmpty) return;
    _closed = true;
    widget.onSend(text);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final phase = _phase;
    return PopScope(
      canPop: phase != _VoicePhase.refining,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  switch (phase) {
                    _VoicePhase.starting ||
                    _VoicePhase.listening => Icons.graphic_eq,
                    _VoicePhase.recognizing ||
                    _VoicePhase.refining => Icons.hourglass_top,
                    _VoicePhase.preview => Icons.edit_note_outlined,
                    _VoicePhase.failed => Icons.mic_off_outlined,
                  },
                  size: 20,
                  color: phase == _VoicePhase.failed
                      ? context.colors.destructive
                      : context.colors.brand,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    switch (phase) {
                      _VoicePhase.starting => '正在启动语音…',
                      _VoicePhase.listening => '正在听你说（普通话，说完点下方按钮）',
                      _VoicePhase.recognizing => '正在生成终稿…',
                      _VoicePhase.refining => '正在整理成规范指令…',
                      _VoicePhase.preview => '检查一下再发送',
                      _VoicePhase.failed => '语音输入不可用',
                    },
                    style: const TextStyle(
                      fontSize: AppType.uiBase,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              constraints: const BoxConstraints(minHeight: 72),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: context.colors.card,
                borderRadius: BorderRadius.circular(AppRadius.sm),
                border: Border.all(color: context.colors.border),
              ),
              child: phase == _VoicePhase.preview
                  ? TextField(
                      key: const ValueKey('voice-preview-input'),
                      controller: _draft,
                      minLines: 2,
                      maxLines: 6,
                      autofocus: true,
                      style: const TextStyle(fontSize: AppType.mobileInputSafe),
                      decoration: InputDecoration(
                        isCollapsed: true,
                        border: InputBorder.none,
                        hintText: tr('（可编辑后发送）'),
                      ),
                    )
                  : SingleChildScrollView(
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      child: Text(
                        phase == _VoicePhase.failed
                            ? _error
                            : (_partial.isEmpty
                                  ? tr('（开口说话，文字会实时出现在这里）')
                                  : _partial),
                        style: TextStyle(
                          fontSize: AppType.uiLg,
                          height: 1.5,
                          color: _partial.isEmpty || phase == _VoicePhase.failed
                              ? context.colors.foregroundSubtle
                              : context.colors.foreground,
                        ),
                        translate: false,
                      ),
                    ),
            ),
            const SizedBox(height: 12),
            if (phase == _VoicePhase.listening) ...[
              FilledButton(
                key: const ValueKey('voice-finish'),
                onPressed: _finish,
                child: const Text('说完了'),
              ),
              TextButton(
                key: const ValueKey('voice-finish-partial'),
                onPressed: _finishWithPartial,
                child: const Text('直接用当前文字'),
              ),
            ],
            if (phase == _VoicePhase.preview) ...[
              // 整理结果状态行（①：成功/失败都必须可见；未配置不显示）。
              if (_refineAttempted)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    children: [
                      Icon(
                        _refineOk ? Icons.auto_awesome : Icons.info_outline,
                        size: 13,
                        color: _refineOk
                            ? context.colors.success
                            : context.colors.warning,
                      ),
                      const SizedBox(width: 5),
                      Expanded(
                        child: Text(
                          _refineOk
                              ? '已按口语整理（${voiceRefineProviderOf(AppStateScope.of(context).uiPrefs.voiceApiProvider).label}）'
                              : '口语整理未生效，已用原文（检查 API key/网络）',
                          style: TextStyle(
                            fontSize: AppType.uiXs,
                            color: _refineOk
                                ? context.colors.success
                                : context.colors.warning,
                          ),
                        ),
                      ),
                      if (_refineOk)
                        TextButton(
                          key: const ValueKey('voice-use-original'),
                          onPressed: _toggleOriginal,
                          style: TextButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            textStyle: const TextStyle(fontSize: AppType.uiXs),
                          ),
                          child: const Text('用原文'),
                        ),
                    ],
                  ),
                ),
              FilledButton(
                key: const ValueKey('voice-send'),
                onPressed: _draft.text.trim().isEmpty ? null : _send,
                child: const Text('发送'),
              ),
            ],
            if (phase == _VoicePhase.starting ||
                phase == _VoicePhase.recognizing ||
                phase == _VoicePhase.refining)
              const Padding(
                padding: EdgeInsets.all(8),
                child: Center(
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              ),
            if (phase == _VoicePhase.failed) ...[
              const SizedBox(height: 4),
              Text(
                '当前设备无可用语音服务属预期；真机首次使用请确认麦克风权限。'
                '整理功能需在设置里选提供商并填对应 API key（没有则直接用原文）。',
                style: TextStyle(
                  fontSize: AppType.uiXs,
                  color: context.colors.foregroundSubtlest,
                ),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('关闭'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 打开语音面板；[onSend]=用户在预览确认后直发（页面复用手动发送链路）。
Future<void> showVoiceInputSheet(
  BuildContext context, {
  required void Function(String text) onSend,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    // 2026-10-23 真机反馈：预览编辑框聚焦弹键盘时面板被输入法盖住——
    // isScrollControlled 已开，补 viewInsets 垫高让面板抬到键盘上方。
    builder: (sheetContext) => Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(sheetContext).viewInsets.bottom,
      ),
      child: SafeArea(child: VoiceInputSheet(onSend: onSend)),
    ),
  );
}
