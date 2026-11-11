import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// UI 偏好（阶段 2 波次 1）：工具调用显示开关（需求池 #1，设置页第一项）。
/// 默认显示（与桌面端工具组默认可见一致）；关闭后消息流隐藏 edit/bash/
/// read/write 等工具活动，仅保留思考条与正文。
class UiPrefs extends ChangeNotifier {
  UiPrefs({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static const _keyShowToolCalls = 'ui.showToolCalls';
  static const _keyLastModel = 'ui.lastModel'; // "providerId/modelId"
  static const _keyLastThought = 'ui.lastThought';
  static const _keyAlertsEnabled = 'ui.alertsEnabled';
  static const _keyMuteApprovals = 'ui.muteApprovals';
  static const _keyMuteTasks = 'ui.muteTasks';
  static const _keyMuteGoals = 'ui.muteGoals';
  static const _keyFollowupMode = 'ui.followupMode'; // queue|guide
  static const _keyVoiceApiKey = 'ui.voiceApiKey';
  static const _keyVoiceRefine = 'ui.voiceRefine';
  static const _keyVoiceApiProvider = 'ui.voiceApiProvider';

  /// 深色模式批 2（ 拍板③）：主题档位 system|light|dark，
  /// 默认跟随系统；设置页三档开关为唯一出口，重启保持、切换即时生效。
  static const _keyThemeMode = 'ui.themeMode';
  static const _keyLocalePreference = 'ui.localePreference';
  static const _keyCodeHighlight = 'ui.codeHighlight';

  /// multi-account-ux-1 批4（2026-11-04 拍板）：首页显示其他电脑任务
  /// （缓存快照）——默认关。实现纯读 LocalCacheStore，不建连接不订阅。
  static const _keyShowOtherComputers = 'ui.showOtherComputers';

  /// （2026-10-24 修复批）：Start Plan 低额提醒"展示即记录"持久化
  /// （官方 startPlanQuotaReminderStore 语义）——值=JSON {reminderKey:
  /// expiresAt}，到期判据用快照时间（毫秒），不信任设备时钟。
  static const _keyQuotaReminders = 'ui.quotaReminders';

  /// 项目排序（2026-10-26 拍板③，官方 preferences.reorder 同语义=本地
  /// 界面偏好不同步）：值=JSON {deviceSid: [projectId…]}——按电脑分开记。
  static const _keyProjectOrders = 'ui.projectOrders';

  /// 提问自动采纳（官方
  /// askUserQuestionAutoResolutionEnabled 同款默认开）——经
  /// zcode-agent.syncAppRuntimePreferences 下发 CLI。
  static const _keyAskAutoResolution = 'ui.askAutoResolution';

  /// 任务主页折叠组（官方 localStorage 每项目
  /// expanded 对位；JSON 数组，全局集合）。
  static const _keyHomeCollapsedGroups = 'ui.homeCollapsedGroups';

  /// 2026-11-05 反馈③：悬浮球长按菜单一次性引导已展示（展示即记，
  /// 不再打扰）。
  static const _keyFabMenuHintShown = 'ui.fabMenuHintShown';

  /// 宽屏双栏左栏收起态（折叠屏用户反馈需要整栏收起/展开）。
  /// 收起后右栏全宽，顶栏同位钮切换。
  static const _keyDualPaneCollapsed = 'ui.dualPaneCollapsed';

  final FlutterSecureStorage _storage;
  bool _showToolCalls = true;
  bool _fabMenuHintShown = false;
  bool _dualPaneCollapsed = false;
  String? _lastModel;
  String? _lastThought;
  String _themeMode = 'system';
  String _localePreference = 'system';
  bool _codeHighlightEnabled = true;
  bool _showOtherComputers = false;
  Map<String, int> _quotaReminders = {};
  Map<String, List<String>> _projectOrders = {};

  /// "审批提醒"（阶段 3 第二段）：开=安卓前台服务保连接常驻（后台也
  /// 实时通知）；关（默认）=退后台约 90 秒断开连接，回前台秒连。
  bool _alertsEnabled = false;
  bool _muteApprovals = false;
  bool _muteTasks = false;
  bool _muteGoals = false;

  /// 运行中收到新消息的处置（官方 followupMode，queue|guide——设置页为
  /// 用户事实源，SessionPane.tsx:4173-4190 同款：改设置即推送到活跃会话）。
  String _followupMode = 'queue';

  /// 语音输入（ 决策 5；2026-10-19 扩展多提供商）：整理开关
  /// （默认开）+ 用户自己的 API key + 提供商（zhipu/deepseek/kimi，
  /// 默认 zhipu 兼容老配置；无 key/失败退回原文）。
  bool _voiceRefineEnabled = true;
  String? _voiceApiKey;
  String _voiceApiProvider = 'zhipu';

  /// 提问自动采纳（默认开，官方同款）。
  bool _askAutoResolutionEnabled = true;

  /// 任务主页折叠组键集合。
  Set<String> _homeCollapsedGroups = {};
  bool loaded = false;

  bool get showToolCalls => _showToolCalls;

  /// 主题档位（system|light|dark）。原始字符串存储，解析为 ThemeMode
  /// 由 app 层负责（保持 state 层不依赖 material）。
  String get themeMode => _themeMode;

  /// 语言档位（system|zh-CN|en-US），与官方 IntlProvider 三态一致。
  String get localePreference => _localePreference;

  /// 代码语法高亮总开关（批 2-5，默认开；用户 2026-10-23 要求可关）。
  bool get codeHighlightEnabled => _codeHighlightEnabled;
  bool get showOtherComputers => _showOtherComputers;
  bool get alertsEnabled => _alertsEnabled;
  bool get muteApprovals => _muteApprovals;
  bool get muteTasks => _muteTasks;
  bool get muteGoals => _muteGoals;
  String get followupMode => _followupMode;
  bool get voiceRefineEnabled => _voiceRefineEnabled;
  String? get voiceApiKey => _voiceApiKey;
  String get voiceApiProvider => _voiceApiProvider;

  /// 上次显式选择的模型（providerId/modelId）与思考档——新建窗口
  /// 默认预选（用户 2026-10-18 需求：不用每次手选）。
  String? get lastModel => _lastModel;
  String? get lastThought => _lastThought;


  /// （2026-10-24 修复批）：偏好写失败哨兵——统一 write/delete+catch+
  /// 留痕（此前 12 处 catch(_){} 静默回跳，偏好写失败零信号；内存值仍
  /// 生效，仅本次会话丢失持久化）。
  Future<void> _persist(String key, String? value) async {
    try {
      if (value == null) {
        await _storage.delete(key: key);
      } else {
        await _storage.write(key: key, value: value);
      }
    } catch (e) {
      debugPrint('[prefs] write-fail key=$key: $e');
    }
  }

  Future<void> load() async {
    try {
      // 16 个键此前串行 await（每键一次平台
      // 通道+Keystore 解密往返）阻塞启动链——Future.wait 并行读（键间
      // 无顺序依赖），解码与默认值语义不变。
      final reads = await Future.wait<String?>([
        _storage.read(key: _keyShowToolCalls), // 0
        _storage.read(key: _keyLastModel), // 1
        _storage.read(key: _keyLastThought), // 2
        _storage.read(key: _keyAlertsEnabled), // 3
        _storage.read(key: _keyMuteApprovals), // 4
        _storage.read(key: _keyMuteTasks), // 5
        _storage.read(key: _keyMuteGoals), // 6
        _storage.read(key: _keyFollowupMode), // 7
        _storage.read(key: _keyVoiceApiKey), // 8
        _storage.read(key: _keyVoiceRefine), // 9
        _storage.read(key: _keyVoiceApiProvider), // 10
        _storage.read(key: _keyThemeMode), // 11
        _storage.read(key: _keyLocalePreference), // 12
        _storage.read(key: _keyCodeHighlight), // 13
        _storage.read(key: _keyQuotaReminders), // 14
        _storage.read(key: _keyAskAutoResolution), // 15
        _storage.read(key: _keyHomeCollapsedGroups), // 16
        _storage.read(key: _keyProjectOrders), // 17
        _storage.read(key: _keyShowOtherComputers), // 18
        _storage.read(key: _keyFabMenuHintShown), // 19
        _storage.read(key: _keyDualPaneCollapsed), // 20
      ]);
      final raw = reads[0];
      if (raw != null) _showToolCalls = raw == 'true';
      _lastModel = reads[1];
      _lastThought = reads[2];
      final alerts = reads[3];
      if (alerts != null) _alertsEnabled = alerts == 'true';
      _muteApprovals = reads[4] == 'true';
      _muteTasks = reads[5] == 'true';
      _muteGoals = reads[6] == 'true';
      final fm = reads[7];
      if (fm == 'guide') _followupMode = 'guide';
      _voiceApiKey = reads[8];
      _voiceRefineEnabled = reads[9] != 'false';
      final vp = reads[10];
      if (vp != null && vp.isNotEmpty) _voiceApiProvider = vp;
      final tm = reads[11];
      if (tm == 'light' || tm == 'dark') _themeMode = tm!;
      final locale = reads[12];
      if (locale == 'zh-CN' || locale == 'en-US') {
        _localePreference = locale!;
      }
      _codeHighlightEnabled = reads[13] != 'false';
      _showOtherComputers = reads[18] == 'true';
      _fabMenuHintShown = reads[19] == 'true';
      _dualPaneCollapsed = reads[20] == 'true';
      try {
        final qr = reads[14];
        if (qr != null && qr.isNotEmpty) {
          final decoded = jsonDecode(qr);
          if (decoded is Map) {
            _quotaReminders = {
              for (final e in decoded.entries)
                if (e.value is num) '${e.key}': (e.value as num).toInt(),
            };
          }
        }
      } catch (e) {
        // 损坏按空记录走（官方同款：存储禁用不阻塞提醒逻辑）。
        debugPrint('[prefs] quota-reminders decode-fail: $e');
      }
      _askAutoResolutionEnabled = reads[15] != 'false';
      try {
        final cg = reads[16];
        if (cg != null && cg.isNotEmpty) {
          final decoded = jsonDecode(cg);
          if (decoded is List) {
            _homeCollapsedGroups = {
              for (final g in decoded)
                if (g is String) g,
            };
          }
        }
      } catch (e) {
        debugPrint('[prefs] home-collapsed decode-fail: $e');
      }
      try {
        final po = reads[17];
        if (po != null && po.isNotEmpty) {
          final decoded = jsonDecode(po);
          if (decoded is Map) {
            _projectOrders = {
              for (final e in decoded.entries)
                if (e.value is List)
                  '${e.key}': [
                    for (final id in e.value)
                      if (id is String) id,
                  ],
            };
          }
        }
      } catch (e) {
        debugPrint('[prefs] project-orders decode-fail: $e');
      }
    } catch (e) {
      // 读取失败按默认值走，不阻塞启动（留痕不再静默）。
      debugPrint('[prefs] load-fail: $e');
    }
    loaded = true;
    notifyListeners();
  }

  /// 主题档位切换（system|light|dark）。即时生效由 app 根的
  /// ListenableBuilder(uiPrefs) 驱动 MaterialApp.themeMode 重建。
  Future<void> setThemeMode(String mode) async {
    final v = (mode == 'light' || mode == 'dark') ? mode : 'system';
    if (_themeMode == v) return;
    _themeMode = v;
    notifyListeners();
    await _persist(_keyThemeMode, v);
  }

  Future<void> setLocalePreference(String preference) async {
    final value = (preference == 'zh-CN' || preference == 'en-US')
        ? preference
        : 'system';
    if (_localePreference == value) return;
    _localePreference = value;
    notifyListeners();
    await _persist(_keyLocalePreference, value);
  }

  Future<void> setShowOtherComputers(bool value) async {
    if (_showOtherComputers == value) return;
    _showOtherComputers = value;
    notifyListeners();
    await _persist(_keyShowOtherComputers, value ? 'true' : 'false');
  }

  Future<void> setCodeHighlightEnabled(bool value) async {
    if (_codeHighlightEnabled == value) return;
    _codeHighlightEnabled = value;
    notifyListeners();
    await _persist(
        _keyCodeHighlight,
        value ? 'true' : 'false',
      );
  }

  /// 审批提醒总开关（前台服务）。切换副作用（启停服务）由调用方
  /// （AppState.setAlertsEnabled）处理，这里只管偏好落盘。
  Future<void> setAlertsEnabled(bool value) async {
    if (_alertsEnabled == value) return;
    _alertsEnabled = value;
    notifyListeners();
    await _persist(
        _keyAlertsEnabled,
        value ? 'true' : 'false',
      );
  }

  Future<void> setChannelMute(String channel, bool muted) async {
    // 双 switch 冗余（第一个只算 key，第二
    // 个 default: return 后 `if (key == null) return` 不可达）——合并
    // 单 switch：case 内同时落内存字段与持久化键。
    final String key;
    switch (channel) {
      case 'approvals':
        _muteApprovals = muted;
        key = _keyMuteApprovals;
      case 'tasks':
        _muteTasks = muted;
        key = _keyMuteTasks;
      case 'goals':
        _muteGoals = muted;
        key = _keyMuteGoals;
      default:
        return;
    }
    notifyListeners();
    await _persist(key, muted ? 'true' : 'false');
  }

  /// followupMode 变更（queue|guide）。推送副作用由调用方（AppState/
  /// 设置页）处理——对活跃订阅补发 setFollowupMode（官方同款收敛）。
  Future<void> setFollowupMode(String mode) async {
    final v = mode == 'guide' ? 'guide' : 'queue';
    if (_followupMode == v) return;
    _followupMode = v;
    notifyListeners();
    await _persist(_keyFollowupMode, v);
  }

  bool get askAutoResolutionEnabled => _askAutoResolutionEnabled;

  /// 悬浮球长按菜单引导是否已展示过（反馈③）。
  bool get fabMenuHintShown => _fabMenuHintShown;
  Future<void> setFabMenuHintShown() async {
    if (_fabMenuHintShown) return;
    _fabMenuHintShown = true;
    try {
      await _storage.write(key: _keyFabMenuHintShown, value: 'true');
    } on Object {
      // 存储不可用（存储禁用/异常）容忍：仅本会话内不重复提示。
    }
  }
  Set<String> get homeCollapsedGroups =>
      Set.unmodifiable(_homeCollapsedGroups);

  /// 双栏左栏收起态（本机界面偏好，跨会话记忆）。
  bool get dualPaneCollapsed => _dualPaneCollapsed;

  Future<void> setDualPaneCollapsed(bool value) async {
    if (_dualPaneCollapsed == value) return;
    _dualPaneCollapsed = value;
    notifyListeners();
    await _persist(_keyDualPaneCollapsed, value ? 'true' : 'false');
  }

  /// 自动采纳开关（下发副作用由调用方处理——设置页直发 CLI）。
  Future<void> setAskAutoResolutionEnabled(bool value) async {
    if (_askAutoResolutionEnabled == value) return;
    _askAutoResolutionEnabled = value;
    notifyListeners();
    await _persist(_keyAskAutoResolution, value ? 'true' : 'false');
  }

  /// 主页折叠组增删（整集合落盘 JSON）。
  Future<void> setHomeGroupCollapsed(String key, bool collapsed) async {
    final changed = collapsed
        ? _homeCollapsedGroups.add(key)
        : _homeCollapsedGroups.remove(key);
    if (!changed) return;
    notifyListeners();
    await _persist(_keyHomeCollapsedGroups, jsonEncode(
      _homeCollapsedGroups.toList(),
    ));
  }

  Future<void> setVoiceRefineEnabled(bool value) async {
    if (_voiceRefineEnabled == value) return;
    _voiceRefineEnabled = value;
    notifyListeners();
    await _persist(
        _keyVoiceRefine,
        value ? 'true' : 'false',
      );
  }

  Future<void> setVoiceApiKey(String? value) async {
    final v = (value ?? '').trim();
    if (v.isEmpty) {
      _voiceApiKey = null;
    } else {
      _voiceApiKey = v;
    }
    notifyListeners();
    await _persist(_keyVoiceApiKey, v.isEmpty ? null : v);
  }

  /// 语音整理提供商（zhipu/deepseek/kimi）。
  Future<void> setVoiceApiProvider(String id) async {
    if (_voiceApiProvider == id) return;
    _voiceApiProvider = id;
    notifyListeners();
    await _persist(_keyVoiceApiProvider, id);
  }

  Future<void> setLastModel(String providerId, String modelId) async {
    _lastModel = '$providerId/$modelId';
    await _persist(_keyLastModel, _lastModel!);
  }

  Future<void> setLastThought(String value) async {
    _lastThought = value;
    await _persist(_keyLastThought, value);
  }

  Future<void> setShowToolCalls(bool value) async {
    if (_showToolCalls == value) return;
    _showToolCalls = value;
    notifyListeners();
    await _persist(
        _keyShowToolCalls,
        value ? 'true' : 'false',
      );
  }

  /// 低额提醒是否已展示过（本周期内不再出现）。到期判据=快照时间
  /// （与桶有效性同源，设备时钟漂移不影响裁决——官方 read() 同款）。
  bool isQuotaReminderHidden(String key, int referenceTime) =>
      _quotaReminders[key] != null && _quotaReminders[key]! > referenceTime;

  /// 展示即记录（官方 markShown 语义）：横幅出现的瞬间就落"已展示"
  /// 事实，关闭与否都不改变周期内不再出现；写入时顺手清理过期项。
  Future<void> markQuotaReminderShown(
    String key,
    int expiresAt,
    int referenceTime,
  ) async {
    if (key.isEmpty || expiresAt <= referenceTime) return;
    // 只有**仍有效**的记录才挡新落账——陈旧条目（周期已滚动）
    // 视同不存在，走正常清理+记新（否则同 key 新周期的 expiresAt 永远
    // 落不进去，跨实例/重启横幅每周期反复弹）。
    final existing = _quotaReminders[key];
    if (existing != null && existing > referenceTime) return;
    final next = Map<String, int>.from(_quotaReminders)
      ..removeWhere((_, exp) => exp <= referenceTime)
      ..[key] = expiresAt;
    _quotaReminders = next;
    await _persist(
      _keyQuotaReminders,
      jsonEncode(next),
    );
  }

  /// 项目排序（按电脑 sid 分桶；null=未自定义）。 ：
  /// 返回不可变视图（对齐同文件 homeCollapsedGroups 惯例，防内部列表
  /// 被调用方原地变更绕过持久化）。
  List<String>? projectOrder(String deviceSid) {
    final order = _projectOrders[deviceSid];
    return order == null ? null : List.unmodifiable(order);
  }

  /// 写入某电脑的项目顺序（ids 只含真实项目；「任务」伪项目恒排末尾，
  /// 由展示层保证，不进偏好）。
  Future<void> setProjectOrder(String deviceSid, List<String> ids) async {
    _projectOrders = {..._projectOrders, deviceSid: List.of(ids)};
    notifyListeners();
    await _persist(_keyProjectOrders, jsonEncode(_projectOrders));
  }
}
