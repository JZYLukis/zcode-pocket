import 'dart:async';

import 'package:flutter/material.dart' hide Text;

import '../core/localized_text.dart';

import '../core/theme.dart';
import '../state/app_state_scope.dart';
import '../transport/channel_client.dart';
import 'app_widgets.dart';

// 优化批 #3：异常→人话映射（原始异常仍在调用方 debugPrint 留痕）。
String friendlyError(Object e) {
  final msg = '$e';
  if (msg.contains('TimeoutException') || msg.contains('timeout')) {
    return '网络不佳，请稍后再试';
  }
  if (msg.contains('401') || msg.contains('auth')) {
    return '账号凭据失效，请重新登录';
  }
  return '加载失败，请重试';
}

/// 子智能体管理（2.5 / D5 裁决：含定义 CRUD 编辑，复刻桌面设置-子智能体）。
/// Channels.subagents：list（agents+userAgents+pluginAgents）/ setEnabled /
/// createAgent / updateAgent / deleteAgent。
///
/// 编辑范围：name / description / systemPrompt / tools / disallowedTools /
/// maxTurns（SubAgentConfig 核心字段；color/modelSelection 等进阶项 P1）。
class SubagentsPage extends StatefulWidget {
  const SubagentsPage({super.key});

  @override
  State<SubagentsPage> createState() => _SubagentsPageState();
}

class _SubagentsPageState extends State<SubagentsPage> {
  Map<String, dynamic>? _data;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
 // AppStateScope.of 不能在 initState 同步调用（阶段 1 根因陷阱）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _load();
        _loadCatalog();
      }
    });
  }

  Future<Map<String, dynamic>?> _channel(
    String method,
    Map<String, dynamic> args,
  ) async {
    final app = AppStateScope.of(context);
    final bridge = app.bridge;
    if (bridge == null) throw StateError('未连接电脑');
    final res = await bridge.channels.call(Channels.subagents, method, [
      args,
    ], timeout: const Duration(seconds: 15));
    return res is Map ? res.cast<String, dynamic>() : null;
  }

  Future<void> _load() async {
    final app = AppStateScope.of(context);
    final ws = app.activeWorkspace;
    if (ws == null) {
      setState(() {
        _error = '未打开工作区';
        _loading = false;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await _channel('list', {
        'workspacePath': ws['workspacePath'],
        if (ws['workspaceIdentity'] != null)
          'workspaceIdentity': ws['workspaceIdentity'],
      });
      if (mounted) {
        setState(() {
          _data = res;
          _loading = false;
        });
      }
    } catch (e) {
 // 优化批 #3：原始异常只进日志，用户可见文案走人话映射。
      debugPrint('[subagents] 列表加载失败: $e');
      if (mounted) {
        setState(() {
          _error = friendlyError(e);
          _loading = false;
        });
      }
    }
  }

  List<Map<String, dynamic>> _section(String key) =>
      _filterSection(
        (_data?[key] as List?)
                ?.whereType<Map>()
                .map((e) => e.cast<String, dynamic>())
                .toList() ??
            const [],
      );

  void _snack(String text) => ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(text), duration: const Duration(seconds: 3)),
  );

  final Map<String, bool> _optimisticEnabled = {};

 /// B29：列表搜索（官方 SubagentsSection 搜索框对位，
 /// 按名称/描述过滤三段全量）。
  String _searchQuery = '';
  bool _searchOpen = false;

  List<Map<String, dynamic>> _filterSection(List<Map<String, dynamic>> list) {
    final q = _searchQuery.trim().toLowerCase();
    if (q.isEmpty) return list;
    return list
        .where(
          (a) =>
              '${a['name'] ?? ''}'.toLowerCase().contains(q) ||
              '${a['description'] ?? ''}'.toLowerCase().contains(q),
        )
        .toList();
  }

  Future<void> _toggle(Map<String, dynamic> agent, bool enabled) async {
 // 乐观更新（#6：15s 往返期间受控开关回弹像"点击失败"）
    setState(() => _optimisticEnabled['${agent['id']}'] = enabled);
    try {
      await _channel('setEnabled', {
        'agentId': agent['id'],
        'enabled': enabled,
      });
      await _load();
    } catch (e) {
      if (mounted) {
        setState(() => _optimisticEnabled['${agent['id']}'] = !enabled);
      }
      _snack('操作失败：$e');
    }
  }

  Future<void> _delete(Map<String, dynamic> agent) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删除「${agent['name']}」？'),
        content: const Text('子智能体定义文件将被删除，不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: context.colors.destructive,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _channel('deleteAgent', {
 // H4（审计）：官方 AgentDeleteParams {agentId, filePath} 必填——
 // 实现第一行就 rm(filePath)，缺失必 TypeError。
        'agentId': agent['id'],
        'filePath': agent['path'] ?? '',
      });
      await _load();
    } catch (e) {
      _snack('删除失败：$e');
    }
  }

 /// 内置/插件行的行内「模型/思考档覆盖」（验收④：官方桌面
 /// SubagentModelOverrideControl 对位——两只 32dp 行内下拉即改即存，
 /// 不再走底部弹层）。官方语义：这些档案只读，覆盖写用户级
 /// agents-state；modelSelection 传 null=清除覆盖恢复默认。
  List<Map<String, dynamic>> _modelCatalog = const [];
  List<String> _thoughtLevels = const [];

  Future<void> _loadCatalog() async {
    try {
      final app = AppStateScope.of(context);
      final options = await app.modelSelectionOptions();
      if (!mounted) return;
      final models = <Map<String, dynamic>>[];
      final thought = <String>{};
      for (final o in options) {
        final dyn = o as dynamic;
        if (!'${dyn.id}'.toLowerCase().contains('model')) continue;
        for (final v in dyn.options) {
          models.add({
            'value': v.value,
            'name': v.name,
            'thoughtLevels': v.modelThoughtLevels,
          });
          for (final level in v.modelThoughtLevels) {
            thought.add('$level');
          }
        }
      }
      setState(() {
        _modelCatalog = models;
        _thoughtLevels = thought.toList();
      });
    } catch (_) {
 // 目录不可用：清除已有覆盖仍可用；新选模型暂不可用。
    }
  }

  String? _selectionToValue(Map? ms) {
    if (ms == null) return null;
    final provider = '${ms['providerId'] ?? ''}';
    final model = '${ms['modelId'] ?? ''}';
    if (model.isEmpty) return null;
    return provider.isEmpty ? model : '$provider/$model';
  }

 /// 行内覆盖控制器（_AgentTile 消费）：null=非覆盖目标（不显示 chips）。
  _InlineOverride? _inlineOverrideFor(Map<String, dynamic> agent) {
    if (!_isOverrideTarget(agent)) return null;
    final override = agent['modelSelectionOverride'];
    final effective = agent['modelSelection'];
    final modelValue = _selectionToValue(
      override is Map ? override : null,
    );
    final baseModel =
        modelValue ??
        _selectionToValue(effective is Map ? effective : null);
    final opts = override is Map ? override['options'] : null;
    final thought = opts is Map && opts['reasoningLevel'] != null
        ? '${opts['reasoningLevel']}'
        : null;
    return _InlineOverride(
      modelValue: modelValue,
      thought: thought,
      baseModelValue: baseModel,
      models: [
        for (final m in _modelCatalog)
          ('${m['value']}', '${m['name']}'),
      ],
      thoughtLevels: _thoughtFor(modelValue ?? baseModel),
      onPickModel: (v) => _applyOverride(agent, modelValue: v, pickModel: true),
      onPickThought: (v) =>
          _applyOverride(agent, thought: v, pickThought: true),
    );
  }

  List<String> _thoughtFor(String? modelValue) {
    if (modelValue == null) return _thoughtLevels;
    final entry = _modelCatalog
        .where((m) => '${m['value']}' == modelValue)
        .toList();
    if (entry.isEmpty) return _thoughtLevels;
    return [for (final l in entry.first['thoughtLevels'] as List) '$l'];
  }

 /// 即改即存（官方同款）：选模型（null=继承默认=清除全部）；选思考档
 /// 时模型基=当前覆盖??继承档；换模型重置思考档（与原弹层语义一致）。
  Future<void> _applyOverride(
    Map<String, dynamic> agent, {
    String? modelValue,
    bool pickModel = false,
    String? thought,
    bool pickThought = false,
  }) async {
    final isPlugin = '${agent['source'] ?? ''}' == 'plugin';
    final override = agent['modelSelectionOverride'];
    final curModel = _selectionToValue(override is Map ? override : null);

    String? nextModel;
    String? nextThought;
    if (pickModel) {
      nextModel = modelValue;
      nextThought = null; // 换模型重置思考档（原弹层同款）
    } else if (pickThought) {
      nextModel =
          curModel ??
          _selectionToValue(
            agent['modelSelection'] is Map
                ? agent['modelSelection'] as Map
                : null,
          );
      nextThought = thought;
    }
    Map<String, dynamic>? selection;
    if (nextModel != null && nextModel.isNotEmpty) {
      final slash = nextModel.indexOf('/');
      selection = {
        if (slash > 0) 'providerId': nextModel.substring(0, slash),
        'modelId': slash > 0 ? nextModel.substring(slash + 1) : nextModel,
        if (nextThought != null)
          'options': {'reasoningLevel': nextThought},
      };
    }
    try {
      await _channel(
        isPlugin ? 'setPluginAgentModelOverride' : 'setBuiltInModelOverride',
        isPlugin
            ? {'agentId': agent['id'], 'modelSelection': selection}
            : {'agentName': agent['name'], 'modelSelection': selection},
      );
      await _load();
    } catch (e) {
      _snack('保存失败：$e');
      await _load();
    }
  }

 /// A4：编辑时透传编辑器不管的既有字段（官方全字段覆写语义）。
 /// name 由 saved 决定（改名合法），skills/disallowedTools/
 /// permissionMode/background/mcpServers/injectAgentsMd 原样保留。
  Map<String, dynamic> _preserveEditorForeignFields(
    Map<String, dynamic> agent,
  ) => {
    for (final k in const [
      'disallowedTools',
      'skills',
      'permissionMode',
      'background',
      'mcpServers',
      'injectAgentsMd',
    ])
      if (agent[k] != null) k: agent[k],
  };

  Future<void> _edit({Map<String, dynamic>? agent}) async {
    final saved = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (dialogContext) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(dialogContext).viewInsets.bottom,
        ),
        child: _AgentEditorSheet(agent: agent),
      ),
    );
    if (!mounted || saved == null) return;
    try {
      final app = AppStateScope.of(context);
      final ws = app.activeWorkspace;
      final base = {
        'provider': 'glm',
        'scope': 'user',
        'workspacePath': ws?['workspacePath'],
        if (ws?['workspaceIdentity'] != null)
          'workspaceIdentity': ws!['workspaceIdentity'],
      };
      if (agent == null) {
        await _channel('createAgent', {...base, 'config': saved});
      } else {
        await _channel('updateAgent', {
          ...base,
          'agentId': agent['id'],
 // M3（审计）：官方 AgentUpdateParams 带 oldFilePath——改名/移动
 // 时缺失会写新文件不删旧文件，留下重复 agent。
          'oldFilePath': agent['path'] ?? '',
 // A4（2026-10-29 审查实证）：官方 updateAgent=
 // serialize(config)+整体覆写文件（subagentsService.ts:778-781）。
 // 编辑器只产出 7 字段——不透传既有字段的话，disallowedTools/
 // skills/permissionMode/background/mcpServers 会被抹掉。
 // 桌面同款（SubagentsSection.tsx:1011-1032 全字段透传）。
          'config': {
            ..._preserveEditorForeignFields(agent),
            ...saved,
          },
        });
      }
      await _load();
    } catch (e) {
      _snack('保存失败：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: _searchOpen
            ? TextField(
                key: const ValueKey('subagent-search'),
                autofocus: true,
                decoration: InputDecoration(
                  hintText: tr('搜索名称或描述'),
                  border: InputBorder.none,
                  isDense: true,
                ),
                onChanged: (v) => setState(() => _searchQuery = v),
              )
            : const Text('子智能体', style: TextStyle(fontSize: AppType.uiLg)),
        actions: [
 // B29：列表搜索（官方 SubagentsSection 搜索框
 // 对位，名称/描述过滤三段）。
          IconButton(
            key: const ValueKey('subagent-search-toggle'),
            icon: Icon(_searchOpen ? Icons.close : Icons.search),
            onPressed: () => setState(() {
              _searchOpen = !_searchOpen;
              if (!_searchOpen) _searchQuery = '';
            }),
          ),
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: context.colors.border),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const ValueKey('subagent-new'),
        onPressed: _edit,
        icon: const Icon(Icons.add),
        label: const Text('新建'),
      ),
      body: _loading
 // 优化批 #2：裸转圈换带说明的 AppLoading。
          ? const Center(child: AppLoading('正在加载子代理…'))
          : _error != null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
 // 优化批 #3：错误文案为人话映射结果（原始异常进日志）。
                  Text(
                    _error!,
                    style: TextStyle(
                      fontSize: AppType.uiCaption,
                      color: context.colors.destructive,
                    ),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton(onPressed: _load, child: const Text('重试')),
                ],
              ),
            )
          : _buildBody(),
    );
  }

 /// 按 id 去重兜底：宿主 runtimeAgents 可能带裸名别名（canonical 与
 /// 裸名同名互撞时只报 diagnostic），同 id 保留首条。
  List<Map<String, dynamic>> _dedupeById(
    Iterable<Map<String, dynamic>> list,
  ) {
    final seen = <String>{};
    final out = <Map<String, dynamic>>[];
    for (final a in list) {
      final id = '${a['id'] ?? ''}';
      if (id.isNotEmpty && !seen.add(id)) continue;
      out.add(a);
    }
    return out;
  }

  Widget _buildBody() {
 // 官方 projectSettingsSubagents 投影（SubagentsSection.tsx）：agents
 // 是运行时投影、canonical 插件条目也在其中，直接渲染会与
 // pluginAgents（一文件一条）整组重复——内置组须先滤掉 source=plugin。
    final sections = {
      '自定义': _dedupeById(_section('userAgents')),
      '内置': _dedupeById(
        _section('agents').where((a) => '${a['source'] ?? ''}' != 'plugin'),
      ),
      '插件': _dedupeById(_section('pluginAgents')),
    };
    final total = sections.values.map((l) => l.length).fold(0, (a, b) => a + b);
    if (total == 0) {
      return Center(
        child: Text(
          '没有子智能体\n点右下角「新建」创建',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: AppType.uiCaption,
            color: context.colors.foregroundSubtle,
          ),
        ),
      );
    }
    return ListView(
      key: const ValueKey('subagent-list'),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 88),
      children: [
        for (final entry in sections.entries)
          if (entry.value.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 10, 4, 6),
              child: Text(
                '${entry.key} (${entry.value.length})',
                style: TextStyle(
                  fontSize: AppType.uiSm,
                  fontWeight: FontWeight.w600,
                  color: context.colors.foregroundSubtle,
                ),
              ),
            ),
            for (final agent in entry.value)
              _AgentTile(
                agent: agent,
                editable: entry.key == '自定义',
                enabled:
                    _optimisticEnabled['${agent['id']}'] ??
                    agent['enabled'] != false,
                onToggle: (v) => _toggle(agent, v),
                onEdit: () => _edit(agent: agent),
                onDelete: () => _delete(agent),
                inlineOverride: _inlineOverrideFor(agent),
              ),
          ],
      ],
    );
  }
}

/// 官方 supportsModelOverride（SubagentsSection.ts:159）对位：内置仅
/// general-purpose / Explore、插件全量开放行内「模型/思考档覆盖」——
/// 它们是只读档案（插件 md 升级会被覆写），官方不开放全字段编辑，
/// 覆盖写用户级 agents-state 不动档案本体。
bool _isOverrideTarget(Map<String, dynamic> agent) {
  final source = '${agent['source'] ?? ''}';
  if (source == 'plugin') return true;
  final scope = '${agent['scope'] ?? ''}';
  final name = '${agent['name'] ?? ''}';
  return (scope == 'built-in' || source == 'built-in') &&
      (name == 'general-purpose' || name == 'Explore');
}

/// 行内覆盖控制器（验收④重排）：官方桌面 SubagentModelOverrideControl
/// 对位——两只 32dp 行内下拉即改即存，按钮文字即覆盖状态（「继承默认」/
/// 模型名），无额外角标。
class _InlineOverride {
  const _InlineOverride({
    required this.modelValue,
    required this.thought,
    required this.baseModelValue,
    required this.models,
    required this.thoughtLevels,
    required this.onPickModel,
    required this.onPickThought,
  });

 /// 当前覆盖模型值（'provider/model'；null=继承默认）。
  final String? modelValue;
  final String? thought;

 /// 覆盖??继承 的模型（思考档可用性判据；null=思考档禁用）。
  final String? baseModelValue;
  final List<(String, String)> models;

 /// (value, name) 位置记录。
  final List<String> thoughtLevels;
  final void Function(String? value) onPickModel;
  final void Function(String? level) onPickThought;
}

/// 验收#17（优化意见 P，视觉子代理七项分析）重排：主行=图标+
/// 「名称单行省略+副行模型摘要」双列+开关；模型/思考档下拉移入点按
/// 展开区（原行内图标+名称+插件 chip+两只下拉+开关四件套把名称挤到
/// 2 字符宽逐字断行+元素叠压的根除）；删与小节标题语义重复的插件
/// chip；8dp 栅格；展开区规范 48dp 触控行。
class _AgentTile extends StatefulWidget {
  final Map<String, dynamic> agent;
  final ValueChanged<bool> onToggle;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final bool editable;
  final bool enabled;

 /// 非空=内置/插件覆盖目标（点行展开配置区）；null=不显示。
  final _InlineOverride? inlineOverride;

  const _AgentTile({
    required this.agent,
    required this.onToggle,
    required this.onEdit,
    required this.onDelete,
    this.editable = true,
    required this.enabled,
    this.inlineOverride,
  });

  @override
  State<_AgentTile> createState() => _AgentTileState();
}

class _AgentTileState extends State<_AgentTile> {
  bool _expanded = false;

 /// agent.color（服务端调色板名）→ 色点；未知名/缺失返回 null（不画）。
  static Color? _agentDotColor(Object? raw) {
    switch ('${raw ?? ''}') {
      case 'blue':
        return const Color(0xFF3B82F6);
      case 'cyan':
        return const Color(0xFF06B6D4);
      case 'green':
        return const Color(0xFF22C55E);
      case 'red':
        return const Color(0xFFEF4444);
      case 'orange':
        return const Color(0xFFF97316);
      case 'purple':
        return const Color(0xFFA855F7);
      case 'pink':
        return const Color(0xFFEC4899);
      case 'yellow':
        return const Color(0xFFEAB308);
      default:
        return null;
    }
  }

  String _modelLabel(String value) {
    final hit = widget.inlineOverride?.models
        .where((m) => m.$1 == value)
        .firstOrNull;
    if (hit != null) return hit.$2;
    final slash = value.indexOf('/');
    return slash > 0 ? value.substring(slash + 1) : value;
  }

  String? get _summaryLine {
 // 2026-11-05 反馈①：副标题恒显 description（官方 SubagentsSection
 // L554-556 同款恒显+两行截断）——覆盖目标的「模型 · 继承默认」此前
 // 把它顶掉，恰好 general-purpose/Explore 与全部插件行全中（用户
 // 「看不出是什么类型的子代理」）；模型/思考覆盖状态由展开区行内
 // chips 承载（验收#17 形态），信息不丢。
    final d = '${widget.agent['description'] ?? ''}';
    return d.isEmpty ? null : d;
  }

  @override
  Widget build(BuildContext context) {
    final agent = widget.agent;
    final enabled = widget.enabled;
    final o = widget.inlineOverride;
    final summary = _summaryLine;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: context.colors.card,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: context.colors.border),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: ValueKey('subagent-${agent['id']}'),
 // 自定义行整行点进编辑器；内置/插件行点按=展开/收起配置区
 //（的行内 chips 形态被 验收#17 重排推翻）。
          onTap: widget.editable
              ? widget.onEdit
              : (o == null
                    ? null
                    : () => setState(() => _expanded = !_expanded)),
          borderRadius: BorderRadius.circular(AppRadius.sm),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
 // 官方行首 36dp 圆角图标砖（底色比卡片暗一档反转对比）。
 // 2026-11-05 反馈①：agent.color 存在时右下角画颜色点
 //（官方 SubagentsSection L540-545 对位；内置
 // general-purpose=blue / Explore=cyan 服务端定义）——
 // 同一机器人轮廓下给出类型身份的可扫读差异。
                    Builder(
                      builder: (dotCtx) {
                        final agentColor = _agentDotColor(agent['color']);
                        final icon = Icon(
                          Icons.smart_toy_outlined,
                          size: 18,
                          color: context.colors.foregroundSubtle,
                        );
                        if (agentColor == null) {
                          return Container(
                            width: 36,
                            height: 36,
                            decoration: BoxDecoration(
                              color: context.colors.background,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: icon,
                          );
                        }
                        return Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: context.colors.background,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Stack(
                            clipBehavior: Clip.none,
                            children: [
                              Center(child: icon),
                              Positioned(
                                right: -2,
                                bottom: -2,
                                child: Container(
                                  width: 10,
                                  height: 10,
                                  decoration: BoxDecoration(
                                    color: agentColor,
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: context.colors.card,
                                      width: 2,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${agent['name']}',
                            translate: false,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: AppType.uiBase,
                              fontWeight: FontWeight.w500,
                              color: enabled
                                  ? context.colors.foreground
                                  : context.colors.foregroundSubtlest,
                            ),
                          ),
                          if (summary != null && summary.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Text(
                                summary,
                                translate: false,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: AppType.uiXs,
                                  color: context.colors.foregroundSubtle,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
 // 官方 supportsEnabledToggle：仅 user scope 可切换——
 // 内置/插件行恒启用（验收④：官方 Switch 32×18，
 // FittedBox scaleDown 收到同档）；不可切行为展开箭头。
                    if ('${agent['scope'] ?? 'user'}' == 'user')
                      SizedBox(
                        width: 40,
                        height: 22,
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Switch(
                            value: enabled,
                            onChanged: widget.onToggle,
                          ),
                        ),
                      )
                    else if (o != null)
                      Icon(
                        _expanded ? Icons.expand_less : Icons.expand_more,
                        size: 20,
                        color: context.colors.foregroundSubtle,
                      ),
                    if (widget.editable)
                      SizedBox(
                        width: 30,
                        height: 40,
                        child: PopupMenuButton<String>(
                          padding: EdgeInsets.zero,
                          onSelected: (v) =>
                              v == 'edit' ? widget.onEdit() : widget.onDelete(),
                          itemBuilder: (_) => const [
                            PopupMenuItem(value: 'edit', child: Text('编辑')),
                            PopupMenuItem(value: 'delete', child: Text('删除')),
                          ],
                        ),
                      ),
                  ],
                ),
 // 展开配置区（内置/插件行）：「模型/思考档」两只规范行，
 // 48dp 触控目标。
                if (o != null && _expanded) ...[
                  Divider(height: 20, color: context.colors.border),
                  _overrideRow(
                    context: context,
                    chipKey: 'override-model',
                    rowLabel: '模型',
                    label: o.modelValue == null
                        ? '继承默认'
                        : _modelLabel(o.modelValue!),
                    items: [('', '继承默认'), ...o.models],
                    initialValue: o.modelValue,
                    onSelected: o.onPickModel,
                  ),
                  _overrideRow(
                    context: context,
                    chipKey: 'override-thought',
                    rowLabel: '思考档',
                    label: o.thought ?? '思考·继承',
                    enabled: o.baseModelValue != null,
                    items: [
                      ('', '思考·继承'),
                      for (final l in o.thoughtLevels) (l, l),
                    ],
                    initialValue: o.thought,
                    onSelected: o.onPickThought,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

 /// 展开区规范下拉行（48dp 触控）：行首灰 label+当前值+箭头。
  Widget _overrideRow({
    required BuildContext context,
    required String chipKey,
    required String rowLabel,
    required String label,
    required List<(String, String)> items,
    required String? initialValue,
    required void Function(String? value) onSelected,
    bool enabled = true,
  }) {
    final dim = enabled ? 1.0 : 0.45;
    return Opacity(
      opacity: dim,
      child: PopupMenuButton<String>(
        key: ValueKey('$chipKey-${widget.agent['id']}'),
        initialValue: initialValue,
        enabled: enabled,
        constraints: const BoxConstraints(maxWidth: 280),
        onSelected: (v) => onSelected(v.isEmpty ? null : v),
        itemBuilder: (_) => [
          for (final (value, name) in items)
            PopupMenuItem(
              value: value,
              height: 40,
              child: Text(
                name,
                translate: false,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: AppType.uiCaption),
              ),
            ),
        ],
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
          child: Row(
            children: [
              SizedBox(
                width: 56,
                child: Text(
                  rowLabel,
                  style: TextStyle(
                    fontSize: AppType.uiCaption,
                    color: context.colors.foregroundSubtle,
                  ),
                ),
              ),
              Expanded(
                child: Text(
                  label,
                  translate: false,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: AppType.uiCaption,
                    fontWeight: FontWeight.w500,
                    color: context.colors.foreground,
                  ),
                ),
              ),
              Icon(
                Icons.arrow_drop_down,
                size: 18,
                color: context.colors.foregroundSubtle,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 子智能体编辑器（新建/更新共用）。SubAgentConfig 核心字段。
class _AgentEditorSheet extends StatefulWidget {
  final Map<String, dynamic>? agent;

  const _AgentEditorSheet({this.agent});

  @override
  State<_AgentEditorSheet> createState() => _AgentEditorSheetState();
}

class _AgentEditorSheetState extends State<_AgentEditorSheet> {
  late final _name = TextEditingController(
    text: '${widget.agent?['name'] ?? ''}',
  );
  late final _description = TextEditingController(
    text: '${widget.agent?['description'] ?? ''}',
  );
  late final _systemPrompt = TextEditingController(
    text: '${widget.agent?['systemPrompt'] ?? ''}',
  );
  late final _tools = TextEditingController(
    text: ((widget.agent?['tools'] as List?) ?? []).join(', '),
  );
  late final _maxTurns = TextEditingController(
    text: '${widget.agent?['maxTurns'] ?? ''}',
  );
  String? _nameError;
  String? _descriptionError;
  String? _promptError;

 /// F13（WR 对齐）：模型/思考档（官方 SubAgentConfig.modelSelection；
 /// 目录源=当前活跃会话的 getTaskConfigOptions，与模型面板同源）。
  String? _selectedModel; // "providerId/modelId" 或 null=继承默认
  String? _selectedThought;
  List<Map<String, dynamic>> _modelCatalog = const [];
  List<String> _thoughtLevels = const [];

 /// 官方 AGENT_COLORS（SubagentsSection.tsx:1063-1094）。
  static const _agentColors = [
    '#6366f1',
    '#8b5cf6',
    '#ec4899',
    '#f43f5e',
    '#f97316',
    '#eab308',
    '#22c55e',
    '#06b6d4',
  ];
  String? _color;

  @override
  void initState() {
    super.initState();
    final ms = widget.agent?['modelSelection'];
    if (ms is Map) {
      final p = '${ms['providerId'] ?? ms['provider'] ?? ''}';
      final m = '${ms['modelId'] ?? ms['model'] ?? ''}';
      if (m.isNotEmpty) {
        _selectedModel = p.isEmpty ? m : '$p/$m';
      }
      final msOptions = ms['options'];
      _selectedThought = msOptions is Map && msOptions['reasoningLevel'] != null
          ? '${msOptions['reasoningLevel']}'
          : null;
    }
    _color = widget.agent?['color'] == null
        ? null
        : '${widget.agent!['color']}';
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _loadCatalog();
    });
  }

  Future<void> _loadCatalog() async {
    try {
      final app = AppStateScope.of(context);
 // 宿主级 model-selection 目录（2026-10-27 真机验收⑧）：不要求活跃
 // 会话——设置页直接新建/编辑子代理时也能设置默认模型与思考档；
 // 旧 getTaskConfigOptions 在无会话时目录为空，只剩"继承默认"。
      final options = await app.modelSelectionOptions();
      if (!mounted) return;
      final models = <Map<String, dynamic>>[];
      final thought = <String>{};
      for (final o in options) {
        final dyn = o as dynamic;
        final id = '${dyn.id}'.toLowerCase();
        if (!id.contains('model')) continue;
        for (final v in dyn.options) {
          models.add({
            'value': v.value,
            'name': v.name,
            'providerId': v.modelProviderId,
            'thoughtLevels': v.modelThoughtLevels,
          });
          for (final level in v.modelThoughtLevels) {
            thought.add('$level');
          }
        }
      }
      setState(() {
        _modelCatalog = models;
        _thoughtLevels = thought.toList();
      });
    } catch (_) {
 // 目录不可用：模型/思考档保持"继承默认"可用。
    }
  }

  List<String> _thoughtForModel(String? modelValue) {
    if (modelValue == null) return _thoughtLevels;
    final entry = _modelCatalog.where((m) => m['value'] == modelValue).toList();
    if (entry.isEmpty) return _thoughtLevels;
    final levels = entry.first['thoughtLevels'] as List;
    return [for (final l in levels) '$l'];
  }

  Map<String, dynamic> _buildModelSelection() {
 // 官方 modelSelectionSchema（strict）：{providerId, modelId,
 // options?: {reasoningLevel}}——思考档在 options.reasoningLevel，
 // 顶层多余字段（如 thoughtLevel）会被 strict 拒（F13 复查抓出）。
    final v = _selectedModel!;
    final slash = v.indexOf('/');
    return {
      if (slash > 0) 'providerId': v.substring(0, slash),
      'modelId': slash > 0 ? v.substring(slash + 1) : v,
      if (_selectedThought != null)
        'options': {'reasoningLevel': _selectedThought},
    };
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    _systemPrompt.dispose();
    _tools.dispose();
    _maxTurns.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.agent == null ? '新建子智能体' : '编辑子智能体',
            style: const TextStyle(fontSize: AppType.uiLg),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _name,
            decoration: InputDecoration(
              labelText: tr('名称'),
              errorText: _nameError,
              border: const OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _description,
            decoration: InputDecoration(
              labelText: tr('描述（一句话）'),
              errorText: _descriptionError,
              border: const OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _systemPrompt,
            maxLines: 5,
            decoration: InputDecoration(
              labelText: tr('系统提示词'),
              errorText: _promptError,
              border: const OutlineInputBorder(),
              isDense: true,
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _tools,
            decoration: InputDecoration(
              labelText: tr('工具白名单（逗号分隔，留空=全部）'),
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _maxTurns,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: tr('最大轮数（可选）'),
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 10),
 // F13：颜色（官方 8 色对位）。
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final c in _agentColors)
                GestureDetector(
 // 点击已选颜色=取消选择。
                  onTap: () => setState(() => _color = _color == c ? null : c),
                  child: Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: Color(int.parse('FF${c.substring(1)}', radix: 16)),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: _color == c
                            ? context.colors.foreground
                            : Colors.transparent,
                        width: 2.5,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
 // F13：模型选择（目录=getTaskConfigOptions；空目录=继承默认）。
          DropdownButtonFormField<String?>(
 // 目录异步到达前 items 只有"继承默认"——value 必须在
 // items 中否则 debug 断言崩溃；不在目录时退回 null（继承）。
            initialValue: _modelCatalog.any((m) => m['value'] == _selectedModel)
                ? _selectedModel
                : null,
            decoration: InputDecoration(
              labelText: tr('模型（默认继承）'),
              border: OutlineInputBorder(),
              isDense: true,
            ),
            items: [
              const DropdownMenuItem(value: null, child: Text('继承默认')),
              for (final m in _modelCatalog)
                DropdownMenuItem(
                  value: '${m['value']}',
                  child: Text('${m['name']}', overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (v) => setState(() {
              _selectedModel = v;
              _selectedThought = null;
            }),
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<String?>(
            initialValue:
                _thoughtForModel(_selectedModel).contains(_selectedThought)
                ? _selectedThought
                : null,
            decoration: InputDecoration(
              labelText: tr('思考强度（默认继承）'),
              border: OutlineInputBorder(),
              isDense: true,
            ),
            items: [
              const DropdownMenuItem(value: null, child: Text('继承默认')),
              for (final lv in _thoughtForModel(_selectedModel))
                DropdownMenuItem(value: lv, child: Text(lv)),
            ],
            onChanged: (v) => setState(() => _selectedThought = v),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: context.colors.brand,
                  foregroundColor: context.colors.onBrand,
                ),
                onPressed: () {
 // 官方校验（SubagentsSection.tsx:929-959）。
                  final name = _name.text.trim();
                  final desc = _description.text.trim();
                  final prompt = _systemPrompt.text.trim();
                  if (name.length < 3 ||
                      name.length > 50 ||
                      !RegExp(r'^[a-zA-Z0-9-]+$').hasMatch(name)) {
                    setState(() => _nameError = '3-50 字符，仅字母/数字/连字符');
                    return;
                  }
                  if (desc.isEmpty) {
                    setState(() => _descriptionError = '描述不能为空');
                    return;
                  }
                  if (prompt.isEmpty) {
                    setState(() => _promptError = '系统提示词不能为空');
                    return;
                  }
                  setState(() {
                    _nameError = null;
                    _descriptionError = null;
                    _promptError = null;
                  });
                  final maxTurns = int.tryParse(_maxTurns.text.trim());
                  Navigator.pop(context, {
                    'name': name,
                    'description': desc,
                    'systemPrompt': prompt,
 // 全角/半角逗号都认（中文输入法默认全角， #7）
                    'tools': _tools.text
                        .split(RegExp(r'[,，]'))
                        .map((t) => t.trim())
                        .where((t) => t.isNotEmpty)
                        .toList(),
                    if (maxTurns != null) 'maxTurns': maxTurns,
                    if (_color != null) 'color': _color,
                    if (_selectedModel != null && _selectedModel!.contains('/'))
                      'modelSelection': _buildModelSelection(),
                  });
                },
                child: const Text('保存'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}


/// 内置/插件子智能体的「模型/思考档覆盖」弹层（官方行内覆盖控件对位；
/// 官方不开放这些只读档案的全字段编辑——插件 md 升级会被覆写）。
