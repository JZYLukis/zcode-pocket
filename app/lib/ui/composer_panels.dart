import 'dart:async';

import 'package:flutter/material.dart' hide Text;

import '../core/localized_text.dart';

import '../core/theme.dart';
import '../state/app_state_scope.dart';
import '../transport/conversation.dart';
import 'brand_logo.dart';

/// 输入增强面板（2.6）：斜杠命令（prepareWorkspace 目录）与 @文件
/// （file.searchWorkspaceFiles）候选。贴输入栏上方，点选替换当前 token。
/// ②（2026-10-19 真机反馈）：加关闭出口——「选择能力」打开后面板不选
/// 就没法收起（输入为空时输入变化路径也触不到），头部常驻关闭钮。
class ComposerPanels extends StatelessWidget {
  final List<Map<String, dynamic>> slashCandidates;
  final List<Map<String, dynamic>> fileCandidates;
  final void Function(String insertion) onPick;
  final VoidCallback? onClose;

  const ComposerPanels({
    super.key,
    required this.slashCandidates,
    required this.fileCandidates,
    required this.onPick,
    this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    if (slashCandidates.isEmpty && fileCandidates.isEmpty) {
      return const SizedBox.shrink();
    }
    final isSlash = slashCandidates.isNotEmpty;
    final items = isSlash ? slashCandidates : fileCandidates;
    return Container(
      constraints: const BoxConstraints(maxHeight: 260),
      margin: const EdgeInsets.fromLTRB(8, 4, 8, 0),
      decoration: BoxDecoration(
        color: context.colors.card,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: context.colors.border),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 12, top: 2, right: 2),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    isSlash ? '命令 · 能力' : '文件',
                    style: TextStyle(
                      fontSize: AppType.uiXs,
                      color: context.colors.foregroundSubtlest,
                    ),
                  ),
                ),
                // 批次A（设计审计 6.3）：36→48——tight SizedBox 压掉了
                // IconButton 默认 48 最小盒；去掉后图标仍 16px 居中，
                // 仅面板头加高 12px（透明命中垫，视觉密度不受损）。
                IconButton(
                  key: const ValueKey('composer-panel-close'),
                  padding: EdgeInsets.zero,
                  iconSize: 16,
                  tooltip: tr('收起候选面板'),
                  onPressed: onClose,
                  icon: Icon(
                    Icons.close,
                    color: context.colors.foregroundSubtle,
                  ),
                ),
              ],
            ),
          ),
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: items.length,
              itemBuilder: (context, i) {
                final item = items[i];
                final isSubagent = isSlash && item['kind'] == 'subagent';
                final title = isSlash
                    ? (isSubagent
                          ? '@${item['name'] ?? ''} '
                          : '/${item['name'] ?? ''}')
                    : '${item['path'] ?? item['relativePath'] ?? ''}';
                final subtitle = isSlash
                    ? (isSubagent
                          ? '子智能体 · ${item['description'] ?? ''}'
                          : '${item['description'] ?? ''}')
                    : null;
                return InkWell(
                  key: ValueKey(
                    isSlash
                        ? 'slash-${item['kind']}-${item['name']}'
                        : 'file-$i',
                  ),
                  onTap: () => onPick(title),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: AppType.uiCaption,
                            fontFamily: isSlash ? null : 'monospace',
                            color: context.colors.foreground,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        if (subtitle != null && subtitle.isNotEmpty)
                          Text(
                            subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: AppType.uiXs,
                              color: context.colors.foregroundSubtlest,
                            ),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// 从输入文本解析当前激活的补全 token。
/// 返回 (type, query)：slash=起始 / 未带空格；file=光标前的 @token。
/// [cursor]=光标偏移（null/越界=按文尾）； /：
/// 只认光标前的末 token——中段编辑不弹文尾 token 的面板；分隔符同时
/// 认空格与换行（多行输入里 "@文件" 前是 \n 时也出补全）。
({String type, String token})? activeCompletionToken(String text,
    {int? cursor}) {
  final end = cursor == null || cursor < 0 || cursor > text.length
      ? text.length
      : cursor;
  final head = end == text.length ? text : text.substring(0, end);
  if (head.startsWith('/') && !head.contains(' ')) {
    return (type: 'slash', token: head.substring(1));
  }
  var lastSpace = head.lastIndexOf(' ');
  final lastNl = head.lastIndexOf('\n');
  if (lastNl > lastSpace) lastSpace = lastNl;
  final token = head.substring(lastSpace + 1);
  if (token.startsWith('@')) {
    return (type: 'file', token: token.substring(1));
  }
  return null;
}

/// 斜杠命令过滤（prepareWorkspace.slashCommands）。
List<Map<String, dynamic>> filterSlashCommands(
  List<SlashCommand> commands,
  String query, {
  List<Map<String, dynamic>> subagents = const [],
}) {
  final q = query.toLowerCase();
  return [
    // 官方 SlashCommandPanel 分区：slash commands + subagents + skills
    // （slashCommandPanelSections.tsx:70-89）——子代理插入 `@name`。
    for (final c in commands)
      if (c.name.toLowerCase().contains(q))
        {'kind': 'command', 'name': c.name, 'description': c.description},
    for (final a in subagents)
      if ('${a['name'] ?? ''}'.toLowerCase().contains(q))
        {
          'kind': 'subagent',
          'name': a['name'],
          'description': a['description'],
        },
  ].take(12).toList();
}

/// 模型/模式/思考切换面板（bottom sheet，2.6；2026-10-16 重做）。
/// configOptions 动态消费：id 含 model→switchModelConfig（值带
/// modelProviderName）；含 thought→switchModelConfig 三元组；含
/// mode/collaboration→switchCollaborationMode。当前值取 snapshot.config。
///
/// 根因对齐：官方目录是活性数据（loading/ready/error 状态机 + 空目录
/// 重新水合 + 静态模式兜底），我们旧实现"一次性拉取+失败吞掉+同一句死文案"
/// 在真机上必然卡死。现改为：打开面板即弹（loading 态），现场 refresh 拉取，
/// 失败给重试；configOptions 缺 mode 项时用官方静态四模式兜底
/// （zcode-agent-model-state.ts ZCODE_AGENT_MODE_OPTIONS）。
const List<({String id, String name, String description})> kStaticModeOptions =
    [
      (id: 'build', name: '变更前确认', description: '改文件前先问我'),
      (id: 'guarded', name: '自主模式', description: '在有风险时询问'),
      (id: 'plan', name: '计划模式', description: '先检查代码再给方案'),
      (id: 'yolo', name: '完全访问', description: '更少确认地编辑与运行'),
    ];

Future<void> showModelSheet(
  BuildContext context, {
  required String? sessionId,
  required ConversationState state,
  String? pendingModelProvider,
  String? pendingModelId,
  String? pendingThought,
  void Function(String provider, String model)? onDraftModel,
  void Function(String value)? onDraftThought,
  /// 思考档被联动作废（新模型不含旧档）时的清除回调——页面挂起值同步
  /// 清除（#7：弹层清了、页面照旧提交=白清）。
  VoidCallback? onDraftThoughtCleared,
  VoidCallback? onClearDraft,
}) async {
  final app = AppStateScope.of(context);
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) => SafeArea(
      // 早期反馈①：切换改"挂起语义"（官方 composer 意图）——面板只
      // 记录选择，随下一条 sendText 提交；不再直发切换命令（运行中
      // 会话上 CAS 必 stale 死锁，真机实测 7 连拒）。
      // 2026-10-19 合并药丸：模型列表+思考档 chips 同页（用户拍板，
      // 参考 Claude 系 App「模型 · 档」连排格式）——思考档不再有专属
      // 药丸入口，本面板是唯一选型出口。
      child: _ModelSheetLoader(
        app: app,
        sessionId: sessionId,
        state: state,
        pendingModelProvider: pendingModelProvider,
        pendingModelId: pendingModelId,
        pendingThought: pendingThought,
        onDraftModel: onDraftModel,
        onDraftThought: onDraftThought,
        onDraftThoughtCleared: onDraftThoughtCleared,
        onClearDraft: onClearDraft,
      ),
    ),
  );
}

class _ModelSheetLoader extends StatefulWidget {
  final dynamic app;
  final String? sessionId;
  final ConversationState state;
  final String? pendingModelProvider;
  final String? pendingModelId;
  final String? pendingThought;
  final void Function(String provider, String model)? onDraftModel;
  final void Function(String value)? onDraftThought;
  final VoidCallback? onDraftThoughtCleared;
  final VoidCallback? onClearDraft;

  const _ModelSheetLoader({
    required this.app,
    required this.sessionId,
    required this.state,
    this.pendingModelProvider,
    this.pendingModelId,
    this.pendingThought,
    this.onDraftModel,
    this.onDraftThought,
    this.onDraftThoughtCleared,
    this.onClearDraft,
  });

  @override
  State<_ModelSheetLoader> createState() => _ModelSheetLoaderState();
}

class _ModelSheetLoaderState extends State<_ModelSheetLoader> {
  WorkspacePrep? _prep;
  List<dynamic> _taskOptions = const [];
  List<(String, String)> _thoughtOptions = const [];
  Object? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  /// 会话目录（getTaskConfigOptions / prepareWorkspace）里的思考档分区
  /// → (值, 中文档名)。与模型目录同源派生，零额外 RPC。
  List<(String, String)> _thoughtFrom(List<dynamic> opts) => [
    for (final o in opts)
      if (o is ConfigOption && o.id.toLowerCase().contains('thought'))
        for (final v in o.options)
          (
            v.value,
            _ModelSheetState._valueZh[v.value] ??
                (v.name.isEmpty ? v.value : v.name),
          ),
  ];

  /// 草稿思考档目录（官方 model-selection.getView：挂起/首个模型的
  /// optionSpecs.reasoningLevel.values，语义升序数组）。
  Future<List<(String, String)>> _draftThoughtOptions() async {
    try {
      final view = await widget.app.modelSelectionView();
      final providers = view?['providers'];
      Map? targetModel;
      if (providers is List) {
        for (final p in providers) {
          if (p is! Map) continue;
          final models = p['models'];
          if (models is! List) continue;
          for (final m in models) {
            if (m is! Map) continue;
            final hit =
                widget.pendingModelId != null &&
                widget.pendingModelId == '${m['modelId'] ?? ''}';
            if (hit || targetModel == null) targetModel = m;
            if (hit) break;
          }
        }
      }
      final rawSpecs = targetModel?['config'];
      final specs = rawSpecs is Map ? rawSpecs['optionSpecs'] : null;
      final rl = specs is Map ? specs['reasoningLevel'] : null;
      final levels = rl is Map ? rl['values'] : null;
      if (levels is List && levels.isNotEmpty) {
        return [
          for (final v in levels)
            if (v is String) (v, _ModelSheetState._valueZh[v] ?? v),
        ];
      }
    } catch (_) {
      // 目录不可用：思考档区静默缺省（模型选择不受影响）。
    }
    return const [];
  }

  /// 会话目录（getTaskConfigOptions/prepareWorkspace）不带套餐/图标
  /// 元数据（官方投影只到 providerLabel）——2026-11-05 反馈④：并行拉
  /// getView 建 providerId→元数据映射补齐（失败静默跳过，分组回退
  /// providerId 推断）。
  Map<String, Map<String, String>> _metaFromView(Map? view) {
    final meta = <String, Map<String, String>>{};
    final providers = view is Map ? view['providers'] : null;
    if (providers is List) {
      for (final p in providers) {
        if (p is! Map) continue;
        final pid = '${p['providerId'] ?? ''}';
        if (pid.isEmpty) continue;
        final config = p['config'];
        final access = config is Map ? config['access'] : null;
        meta[pid] = {
          if ('${p['providerName'] ?? ''}'.isNotEmpty)
            'modelProviderName': '${p['providerName']}',
          if (access is Map) ...{
            if ('${access['mode'] ?? ''}'.isNotEmpty)
              'modelAccessMode': '${access['mode']}',
            if ('${access['accountType'] ?? ''}'.isNotEmpty)
              'modelAccessAccountType': '${access['accountType']}',
          },
        };
      }
    }
    return meta;
  }

  /// 模型目录条目按 providerId 注入元数据后重建（仅模型分区）。
  ///
  /// 候选 16 验收反馈（用户实锤「我并没有闲时包跟高速卡」）：getView 的
  /// providers = 官方闸门 A 等价白名单（服务端已滤 visibility:hidden 的
  /// provider——offpeak/highspeed 是母套餐派生执行入口不是独立套餐，
  /// 官方从不展示）。meta 非空时，modelProviderId 不在 meta.keys 的
  /// option 直接丢弃；meta 为空（getView 失败/超时）fail-open 不清空。
  List<ConfigOption> _augmentOptions(
    List<ConfigOption> options,
    Map<String, Map<String, String>> meta,
  ) {
    if (meta.isEmpty) return options;
    return [
      for (final o in options)
        o.id.toLowerCase().contains('model') && o.options.isNotEmpty
            ? ConfigOption.fromMap({
                'id': o.id,
                'name': o.name,
                'category': o.category,
                'type': o.type,
                'options': [
                  for (final v in o.options)
                    // 白名单过滤：getView 里没有的 providerId 丢弃
                    //（hidden 泄漏——offpeak/highspeed 从 registry 直出）。
                    if (meta.containsKey(v.modelProviderId ?? ''))
                      v.toRaw()..addAll(meta[v.modelProviderId ?? ''] ?? const {}),
                ],
              })
            : o,
    ];
  }

  Future<void> _fetch() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    // （WR 对齐）：目录真源 = zcode-task.getTaskConfigOptions（官方
    // web remote 工具栏目录的手机端等价物，含模型/思考/模式三项）。
    // prepareWorkspace 降为兜底（readWorkspacePresentation 只带 mode+斜杠）。
    // 草稿（sessionId null）无 task 可查——走官方 model-selection.getView
    // （宿主级目录真源；prepareWorkspace 只有 mode+斜杠，无模型清单）。
    if (widget.sessionId == null) {
      // 草稿思考档与模型目录并行拉（两个独立 getView 调用）。
      final draftThoughts = _draftThoughtOptions();
      try {
        final view = await widget.app.modelSelectionOptions().catchError(
          (Object _) => const [],
        );
        if (view is List && view.isNotEmpty) {
          _thoughtOptions = await draftThoughts;
          if (mounted) {
            setState(() {
              _taskOptions = view;
              _loading = false;
            });
          }
          return;
        }
      } catch (_) {}
    } else {
      // 会话路径元数据（2026-11-05 反馈④）与目录并行拉。
      final metaFuture = widget.app
          .modelSelectionView()
          .catchError((Object _) => null);
      try {
        final taskOptions = await widget.app
            .getTaskConfigOptions(widget.sessionId!)
            .catchError((Object _) => const []);
        if (taskOptions is List && taskOptions.isNotEmpty) {
          final meta = _metaFromView(await metaFuture);
          final augmented = [
            for (final o in taskOptions)
              if (o is ConfigOption) o,
          ];
          _thoughtOptions = _thoughtFrom(taskOptions);
          if (mounted) {
            setState(() {
              _taskOptions = _augmentOptions(augmented, meta);
              _loading = false;
            });
          }
          return;
        }
      } catch (_) {}
    }
    try {
      final prep = await widget.app.prepareWorkspace(refresh: true);
      _thoughtOptions = _thoughtFrom(prep?.configOptions ?? const []);
      if (mounted) {
        setState(() {
          _prep = prep;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e;
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return SizedBox(
        height: 220,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                height: 28,
                width: 28,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(height: 12),
              Text(
                '正在获取可切换目录…',
                style: TextStyle(
                  fontSize: AppType.uiCaption,
                  color: context.colors.foregroundSubtle,
                ),
              ),
            ],
          ),
        ),
      );
    }
    if (_error != null) {
      return SizedBox(
        height: 200,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '目录获取失败：$_error',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: AppType.uiCaption,
                  color: context.colors.destructive,
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton(onPressed: _fetch, child: const Text('重试')),
            ],
          ),
        ),
      );
    }
    // task 目录优先：包成 WorkspacePrep 形状供 _ModelSheet 消费。
    if (_taskOptions.isNotEmpty) {
      return _ModelSheet(
        prep: WorkspacePrep.fromOptions([
          for (final o in _taskOptions)
            if (o is ConfigOption) o,
        ]),
        state: widget.state,
        pendingModelProvider: widget.pendingModelProvider,
        pendingModelId: widget.pendingModelId,
        pendingThought: widget.pendingThought,
        thoughtOptions: _thoughtOptions,
        onDraftModel: widget.onDraftModel,
        onDraftThought: widget.onDraftThought,
        onDraftThoughtCleared: widget.onDraftThoughtCleared,
        onClearDraft: widget.onClearDraft,
        onRetry: _fetch,
      );
    }
    return _ModelSheet(
      prep: _prep,
      state: widget.state,
      pendingModelProvider: widget.pendingModelProvider,
      pendingModelId: widget.pendingModelId,
      pendingThought: widget.pendingThought,
      thoughtOptions: _thoughtOptions,
      onDraftModel: widget.onDraftModel,
      onDraftThought: widget.onDraftThought,
      onDraftThoughtCleared: widget.onDraftThoughtCleared,
      onClearDraft: widget.onClearDraft,
      onRetry: _fetch,
    );
  }
}

/// 精确剥 providerId 前缀取 modelId（2026-11-05 反馈④）——OpenRouter
/// 命名空间值形如 `openrouter/z-ai/glm-5.3`，首个 `/` 盲切虽此处同果，
/// 但 providerId 缺失的兜底语义必须显式：优先按已知 providerId 剥前缀，
/// 否则退回首 `/` 之后。
String modelIdOf(ConfigOptionValue v) {
  final pid = v.modelProviderId ?? '';
  final value = v.value;
  if (pid.isNotEmpty && value.startsWith('$pid/')) {
    return value.substring(pid.length + 1);
  }
  return value.contains('/')
      ? value.substring(value.indexOf('/') + 1)
      : value;
}

/// 1.0.1 验收终修（用户拍板「分组按照桌面端的方式来」）：桌面按
/// **provider** 分组（Z.AI/BigModel/OCG 各一组），套餐类型是组头徽标
/// 不是组名——对齐 buildComposerPlanGroups.ts 语义。
/// 分组键=providerId；组头=provider 短名+套餐徽标；不跨 provider
/// 合并同名模型（桌面行为）。
String providerGroupKey(ConfigOptionValue v) {
  final pid = v.modelProviderId ?? '';
  if (pid.isNotEmpty) return pid;
  // 空 providerId 条目全
  // 并入同一组且不可选。改显式 isNotEmpty 判断。
  return v.value.contains('/')
      ? v.value.substring(0, v.value.indexOf('/'))
      : '';
}

/// 套餐徽标（桌面 labelBadge 对位）：个人/团队/免费/API；非套餐无。
String planBadgeOf(ConfigOptionValue v) {
  var kind = v.modelAccessMode ?? '';
  if (kind.isEmpty) {
    final pid = v.modelProviderId ?? '';
    if (pid.contains('start-plan')) kind = 'start-plan';
    else if (pid.contains('team-coding-plan')) kind = 'team-coding-plan';
    else if (pid.contains('individual-coding-plan') ||
        pid.contains('coding-plan')) kind = 'individual-coding-plan';
  }
  // 1.0.1 验收修复：非套餐 provider 兜底 'API'——真机实锤四个
  // BigModel 组头两组完全同名不可辨；桌面语义=每个 provider 组都
  // 有类型标识（个人/团队/免费/API），消歧义。
  return switch (kind) {
    'individual-coding-plan' => tr('个人'),
    'team-coding-plan' => tr('团队'),
    'start-plan' => tr('免费'),
    _ => 'API',
  };
}

/// 碰撞组消歧后缀（候选 15 验收 终修）：内部 ID 不可直出——
/// account:bigmodel-offpeak-idle-plan 整串进组头既不可读又挤爆行宽
/// （真机实锤徽标被裁成「A」）。规则：providerId 里的套餐 token 映射
/// 人话词（闲时/高速/加油/包月…），多 token 取可辨组合；无已知 token
/// 取末段短词截断 6 字；仍取不到退序号。恒短（≤8 字）防溢出。
@visibleForTesting
String groupDisambigSuffix(String providerId, int nth) =>
    _groupDisambigSuffix(providerId.toLowerCase(), nth);

String _groupDisambigSuffix(String pid, int nth) {
  const tokenWords = {
    'offpeak': '闲时',
    'idle': '闲时',
    'highspeed': '高速',
    'speed': '速',
    'card': '卡',
    'plan': '包',
    'monthly': '包月',
    'trial': '试用',
    'free': '免费',
    'pro': '专业',
    'max': '超大',
    'lite': '轻量',
  };
  // 去掉 account:/家族前缀后按分隔符切 token，映射已知词。
  final body = pid.replaceAll(RegExp(r'^account:'), '');
  final segs = body.split(RegExp(r'[-_]'));
  final words = <String>[];
  for (final seg in segs) {
    final w = tokenWords[seg];
    if (w != null && !words.contains(w)) words.add(w);
  }
  if (words.isNotEmpty) {
    final combined = words.join();
    return combined.length > 6 ? combined.substring(0, 6) : combined;
  }
  // 未知 token：取最后一段非家族词，截断 6 字。
  final familyFree = segs.where((s) => s.isNotEmpty).toList();
  String? last;
  for (final seg in familyFree.reversed) {
    if (!['bigmodel', 'zai', 'api', 'opencode', 'account'].contains(seg)) {
      last = seg;
      break;
    }
  }
  if (last != null && last.isNotEmpty) {
    return last.length > 6 ? last.substring(0, 6) : last;
  }
  return '$nth';
}

/// 去重键：providerId+modelId——只在同一 provider 内去重（同 provider
/// 多变体归并），跨 provider 各自成行（桌面行为，同名不同来源平铺）。
String modelDedupKey(ConfigOptionValue v) =>
    '${providerGroupKey(v)}|${modelIdOf(v).toLowerCase()}';

/// 判断是否套餐 provider（个人/团队/Start Plan）——排序用（桌面
/// composerPlanGroups.ts：套餐组在前按 label 排，其余在后原序）。
/// API（非套餐）不排前。
bool isPlanProvider(ConfigOptionValue v) {
  var kind = v.modelAccessMode ?? '';
  if (kind.isEmpty) {
    final pid = v.modelProviderId ?? '';
    if (pid.contains('start-plan')) kind = 'start-plan';
    else if (pid.contains('team-coding-plan')) kind = 'team-coding-plan';
    else if (pid.contains('individual-coding-plan') ||
        pid.contains('coding-plan')) kind = 'individual-coding-plan';
  }
  return kind == 'individual-coding-plan' ||
      kind == 'team-coding-plan' ||
      kind == 'start-plan';
}

/// 行尾徽标短标签（2026-11-05 反馈④）：弃全长 modelProviderName
///（「BigModel Individ…」截断不可读）；账号族优先官方 access.
/// accountType（zai/bigmodel），回退 providerId 已知映射，未知取
/// providerName 首词。
String providerShortLabel(ConfigOptionValue v) {
  final pid = (v.modelProviderId ?? '').toLowerCase();
  final account = (v.modelAccessAccountType ?? '').toLowerCase();
  final String? family = account == 'zai'
      ? 'Z.AI'
      : account == 'bigmodel'
      ? 'BigModel'
      : pid.contains('bigmodel')
      ? 'BigModel'
      : pid.contains('zai')
      ? 'Z.AI'
      : null;
  if (pid.contains('start-plan')) return family ?? 'Start Plan';
  if (family != null) return pid.contains('-api') ? '$family API' : family;
  const known = <String, String>{
    'opencode-go': 'OCG',
    'opencode-zen': 'OCG',
    'openrouter': 'OpenRouter',
    'volcengine': 'Volcengine',
    'moonshot': 'Moonshot',
    'deepseek': 'DeepSeek',
    'minimax': 'MiniMax',
    'anthropic': 'Anthropic',
    'openai': 'OpenAI',
    'xiaomi': 'Xiaomi',
    'stepfun': 'StepFun',
    'tencent': 'Tencent',
    'siliconflow': 'SiliconFlow',
    'alibaba': 'Qwen',
  };
  for (final e in known.entries) {
    if (pid.contains(e.key)) return e.value;
  }
  final name = v.modelProviderName ?? '';
  if (name.isNotEmpty) {
    final first = name.split(RegExp(r'\s+')).first;
    if (first.isNotEmpty) return first;
  }
  // 无名未知 provider：不显脏 providerId，行尾留空。
  return '';
}

/// R 轮 UX：面板打开期间监听会话状态——切换成功后顶部"模型/思考"
/// 当前值行实时刷新（选中不关页的配套反馈）。
/// 早期反馈①：挂起语义——本地 draft 态即时高亮，随下次发送提交。
/// 2026-10-19 合并药丸配套：底部新增思考档横向 chips（单行不换行），
/// 选模型联动其 modelThoughtLevels（官方字段，子代理编辑器 同源）。
class _ModelSheet extends StatefulWidget {
  final WorkspacePrep? prep;
  final ConversationState state;
  // draft 真源=页面 pending（sheet 关闭不失忆）——sheet 只做
  // 即时编辑视图，初值由页面播种。
  final String? pendingModelProvider;
  final String? pendingModelId;
  final String? pendingThought;
  final List<(String, String)> thoughtOptions;
  final void Function(String provider, String model)? onDraftModel;
  final void Function(String value)? onDraftThought;
  final VoidCallback? onDraftThoughtCleared;
  final VoidCallback? onClearDraft;
  final VoidCallback onRetry;

  const _ModelSheet({
    required this.prep,
    required this.state,
    this.pendingModelProvider,
    this.pendingModelId,
    this.pendingThought,
    this.thoughtOptions = const [],
    this.onDraftModel,
    this.onDraftThought,
    this.onDraftThoughtCleared,
    this.onClearDraft,
    required this.onRetry,
  });

  @override
  State<_ModelSheet> createState() => _ModelSheetState();
}

class _ModelSheetState extends State<_ModelSheet> {
  late String? _draftProvider = widget.pendingModelProvider;
  late String? _draftModel = widget.pendingModelId;
  late String? _draftThought = widget.pendingThought;

  bool get _hasDraft => _draftModel != null || _draftThought != null;

  /// 视觉代理复验（2026-10-17 夜）：目录分区标题与选项 chips 均为服务端
  /// 英文——中文界面基准下做已知词映射，未知原样透传。
  static const _valueZh = <String, String>{
    // 思考档位（官方 chat.toolbar.thoughtLevel.value.* 全集八档——
    // 2026-10-26 对齐轮实证：minimal=极低（原误「极少」），补
    // on/xhigh/ultra 三档防兜底透传英文）。
    'low': '低', 'medium': '中', 'high': '高', 'max': '最高',
    'off': '关闭', 'none': '无', 'minimal': '极低',
    'on': '开启', 'xhigh': '极高', 'ultra': '极致',
    // 协作模式（原始枚举 + 官方 label 两种形态；mode.label.glm.* 全集
    // ——2026-10-26 对齐轮实证：build=变更前确认（原误「构建」）；ask/
    // 'Ask before changes' 是 build 的英文 label 非独立枚举，译同值；
    // 补 default/edit/guarded 三态）。
    'build': '变更前确认', 'plan': '计划模式', 'autonomous': '自主模式',
    'guarded': '自主模式', 'default': '默认', 'edit': '自动编辑',
    'yolo': '完全访问', 'ask': '变更前确认', 'full': '完全访问',
    'Ask before changes': '变更前确认',
    'Autonomous mode': '自主模式',
    'Plan mode': '计划模式',
    'Full access': '完全访问',
  };

  String _valueLabelZh(String raw) => _valueZh[raw] ?? raw;

  String _sectionTitleOf(String id, String fallback) {
    final i = id.toLowerCase();
    if (i.contains('model')) return '模型';
    if (i.contains('thought')) return '思考档位';
    if (i.contains('mode') || i.contains('collaboration')) return '模式';
    return fallback;
  }

  /// 1.0.1 验收终修：分组改按 provider（桌面对齐）——去重键=
  /// providerId+modelId，同 provider 多变体归并，跨 provider 各自成行
  /// （同名模型在 Z.AI/BigModel/OCG 各组独立出现=桌面行为）。
  ({
    List<ConfigOptionValue> choices,
    Map<String, List<ConfigOptionValue>> alternates,
  })
  _dedupModels(List<ConfigOptionValue> opts, String currentProvider) {
    final byModel = <String, ConfigOptionValue>{};
    final alternates = <String, List<ConfigOptionValue>>{};
    for (final v in opts) {
      final key = modelDedupKey(v);
      alternates.putIfAbsent(key, () => []).add(v);
      byModel.putIfAbsent(key, () => v);
    }
    if (currentProvider.isNotEmpty) {
      for (final e in byModel.entries) {
        final list = alternates[e.key]!;
        // 代表行与 ⇄ 序首选当前 provider（无命中保持原序）。
        final hitIdx = list.indexWhere(
          (v) =>
              (v.modelProviderId ?? '') == currentProvider ||
              (v.value.contains('/') &&
                  v.value.substring(0, v.value.indexOf('/')) ==
                      currentProvider),
        );
        if (hitIdx > 0) {
          final hit = list.removeAt(hitIdx);
          list.insert(0, hit);
          byModel[e.key] = hit;
        }
      }
    }
    return (choices: byModel.values.toList(), alternates: alternates);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.state,
      builder: (context, _) => _build(context),
    );
  }

  /// 选中的模型目录项（挂起草稿优先）——modelThoughtLevels 联动用。
  ConfigOptionValue? _selectedModelEntry(String currentModel) {
    final target = _draftModel ?? currentModel;
    for (final option in (widget.prep?.configOptions ?? const [])) {
      if (!option.id.toLowerCase().contains('model')) continue;
      for (final v in option.options) {
        if (modelIdOf(v).toLowerCase() == target.toLowerCase()) return v;
      }
    }
    return null;
  }

  /// 思考档 chips 取值：选中模型自带的 modelThoughtLevels 优先（官方
  /// 联动字段），否则用会话级思考目录（子代理编辑器同源语义）。
  List<(String, String)> _thoughtChoices(String currentModel) {
    final entry = _selectedModelEntry(currentModel);
    if (entry != null && entry.modelThoughtLevels.isNotEmpty) {
      return [for (final l in entry.modelThoughtLevels) (l, _valueLabelZh(l))];
    }
    return widget.thoughtOptions;
  }

  Widget _build(BuildContext context) {
    final config = widget.state.config ?? const {};
    final currentModel = '${config['model'] ?? ''}';
    final currentProvider = '${config['provider'] ?? ''}';
    final currentThought = '${config['thought'] ?? ''}';

    final options = widget.prep?.configOptions ?? const [];
    // V2 审美优化（评审 2.2#5）：删顶部「模型/思考」当前值两行——与
    // 分区标题重复；选中态改由分区 chip 黑底白字表达，挂起提示行保留。
    final List<Widget> sections = [];
    for (final option in options) {
      final id = option.id.toLowerCase();
      final isModel = id.contains('model');
      final isThought = id.contains('thought');
      // 'model'.contains('mode')==true——不排除 model 会让
      // 静态模式兜底被误杀（模式切换能力整段蒸发）。
      final isMode =
          !isModel && (id.contains('mode') || id.contains('collaboration'));
      if (option.options.isEmpty) continue;
      // 去重轮（用户 2026-10-17）：思考/模式已有工具栏专属药丸入口，
      // 面板收敛为纯模型选择（原三合一=功能出口重复）。
      if (isThought || isMode) continue;
      if (!isModel) {
        // 未知类别：只读展示，不接线
        sections.add(_SectionTitle(option.name));
        sections.add(
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final v in option.options)
                Chip(
                  label: Text(
                    v.name,
                    style: const TextStyle(fontSize: AppType.uiCaption),
                  ),
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
        );
        continue;
      }
      // 选中态=挂起草稿优先，其次当前值（：统一 modelId 比较）。
      var current = _draftModel ?? currentModel;
      if (current.contains('/')) {
        current = current.substring(current.indexOf('/') + 1);
      }
      sections.add(_SectionTitle(_sectionTitleOf(option.id, option.name)));
      final dedup = _dedupModels(
        option.options,
        _draftProvider ?? currentProvider,
      );
      sections.add(
        _ModelList(
          choices: dedup.choices,
          alternates: dedup.alternates,
          current: current,
          provider: _draftProvider ?? currentProvider,
          onPick: (v) {
            var clearedThought = false;
            setState(() {
              // providerId 只认 id 形态（目录 id 或值前缀）——
              // 显示名/空值会被服务端解析失配。
              final prov =
                  v.modelProviderId ??
                  (v.value.contains('/')
                      ? v.value.substring(0, v.value.indexOf('/'))
                      : null) ??
                  (currentProvider.contains('/') ? '' : null);
              if (prov == null || prov.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('该目录项缺少供应商信息，无法挂起'),
                    duration: Duration(seconds: 2),
                  ),
                );
                return;
              }
              _draftProvider = prov;
              _draftModel = modelIdOf(v);
              // 联动（官方 modelThoughtLevels）：新模型若声明档位清单且
              // 挂起档不在其中 → 清空挂起档（随模型默认），避免提交
              // 不支持的档位。页面侧挂起值同步清除（#7：弹层清了、页面
              // 照旧提交，等于白清）。
              if (v.modelThoughtLevels.isNotEmpty &&
                  _draftThought != null &&
                  !v.modelThoughtLevels.contains(_draftThought)) {
                _draftThought = null;
                clearedThought = true;
              }
              widget.onDraftModel?.call(_draftProvider!, _draftModel!);
            });
            if (clearedThought) widget.onDraftThoughtCleared?.call();
          },
        ),
      );
    }
    // 思考档区（2026-10-26 复刻桌面材质，用户拍板：渐变胶囊轨道+白色圆
    // 把手+上方「思考强度 当前档」文字行——取代验收二轮的分段文字条；
    // 交互沿用：点选跳档+拖动跟手+吸附动画，挂起语义不变随消息提交）。
    // 目录缺失时静默缺省（模型选择不受影响）。
    final thoughtChoices = _thoughtChoices(currentModel);
    if (thoughtChoices.isNotEmpty) {
      sections.add(const SizedBox(height: 20));
      sections.add(
        _ThoughtSlider(
          choices: thoughtChoices,
          value: _draftThought ?? currentThought,
          onChanged: (v) {
            setState(() => _draftThought = v);
            widget.onDraftThought?.call(v);
          },
        ),
      );
    }
    if (_hasDraft) {
      sections.addAll([
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              child: Text(
                '选择将随下一条消息发送时生效（桌面同款语义）',
                style: TextStyle(
                  fontSize: AppType.uiCaption,
                  color: context.colors.linkBlue,
                ),
              ),
            ),
            // 唯一取消挂起的入口（模型+思考档一并清除）。
            TextButton(
              onPressed: () => setState(() {
                _draftProvider = null;
                _draftModel = null;
                _draftThought = null;
                widget.onClearDraft?.call();
              }),
              child: const Text('清除挂起'),
            ),
          ],
        ),
      ]);
    }
    if (options.isEmpty) {
      sections.addAll([
        const SizedBox(height: 8),
        Text(
          '模型目录暂不可用（会话激活后自动恢复）。',
          style: TextStyle(
            fontSize: AppType.uiCaption,
            color: context.colors.foregroundSubtle,
          ),
        ),
        TextButton(onPressed: widget.onRetry, child: const Text('重新获取目录')),
      ]);
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 460),
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: sections,
      ),
    );
  }
}

/// 模型竖向点选列表（2026-10-25 用户拍板，参考同类 AI 应用：摊开 chips
/// 改上下滑动点选）。整页滚动由外层 ListView 承担（弹层 ConstrainedBox
/// 460 上限内上下滑）；每行=品牌 logo + 模型名 + 选中勾（分支弹层当前
/// 标记同款语言）；首帧把选中行滚入可视区（长目录不必翻找）。
class _ModelList extends StatefulWidget {
  final List<ConfigOptionValue> choices;
  final Map<String, List<ConfigOptionValue>> alternates;
  final String current;

  /// 验收#1：当前 provider（挂起优先）——分块后同名模型在两个
  /// 块各一行，选中判定必须含 provider（否则点亮错误套餐的行）。
  final String? provider;
  final void Function(ConfigOptionValue v) onPick;

  const _ModelList({
    required this.choices,
    required this.current,
    required this.onPick,
    this.alternates = const {},
    this.provider,
  });

  @override
  State<_ModelList> createState() => _ModelListState();
}

class _ModelListState extends State<_ModelList> {
  /// 选中行的 GlobalKey（首帧滚入可视区用）。
  final GlobalKey _selectedKey = GlobalKey();

  /// 验收#1：分组折叠态。默认=选中组展开、其余收起（活跃套餐
  /// 直达模型，非活跃点组头展开——用户拍板的两级结构）。
  final Map<String, bool> _collapsedByGroup = {};

  @override
  void initState() {
    super.initState();
    // 首帧后把选中行滚入可视区（选中项常在目录中部，免翻找）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ctx = _selectedKey.currentContext;
      if (ctx != null) Scrollable.ensureVisible(ctx, alignment: 0.4);
    });
  }

  @override
  Widget build(BuildContext context) {
    Widget rowOf(ConfigOptionValue v, bool selected) => _ModelListRow(
      // 行身份恒定（ValueKey 不随选中态漂移——key 换成选中专用的
      // GlobalKey 会让元素复用断裂）；选中行外层再包 GlobalKey 壳
      // 供首帧滚入。
      key: ValueKey('model-row-${v.value}'),
      value: v,
      selected: selected,
      onPick: widget.onPick,
      // 2026-11-05 反馈④：alternates 键=套餐组+modelId（与 _dedupModels
      // 同款 modelDedupKey—— 教训：必须 ${...} 取值防 miss）。
      alternates: widget.alternates[modelDedupKey(v)] ?? const [],
    );
    // 选中判定=短名+provider 双匹配（2026-11-05 反馈④：合并行代表
    // provider 可能≠当前——代表行或任一 alternate 命中都算选中）。
    var selectedIndex = -1;
    for (var i = 0; i < widget.choices.length; i++) {
      final v = widget.choices[i];
      if (modelIdOf(v).toLowerCase() != widget.current.toLowerCase()) {
        continue;
      }
      final prov = widget.provider;
      if (prov == null || prov.isEmpty) {
        selectedIndex = i;
        break;
      }
      bool pidMatches(ConfigOptionValue x) {
        final pid = x.modelProviderId ?? '';
        final prefix = x.value.contains('/')
            ? x.value.substring(0, x.value.indexOf('/'))
            : '';
        return pid == prov || (prefix.isNotEmpty && prefix == prov);
      }

      final alts = widget.alternates[modelDedupKey(v)] ?? const [];
      if (pidMatches(v) || alts.any(pidMatches)) {
        selectedIndex = i;
        break;
      }
    }

    // 1.0.1 验收终修（用户拍板「分组按照桌面端的方式来」）：
    // 分组=provider（Z.AI/BigModel/OCG 各一组），套餐是组头徽标；
    // 排序=套餐组按 provider 名排在前→其余 provider 原序在后。
    final groups = <String, List<ConfigOptionValue>>{};
    for (final v in widget.choices) {
      groups.putIfAbsent(providerGroupKey(v), () => []).add(v);
    }
    // 组头数据：provider 短名+套餐徽标。
    // 候选 13 验收反馈（2026-11-09）：两个 BigModel API 渠道（不同
    // providerId）经短名+徽标映射后组头完全同名——「兜底 API 徽标」
    // 在双 API 渠道下失效，用户无法分辨该点哪组。修：label+badge
    // 碰撞的组追加消歧后缀（providerId 已知映射尾段，未知则序号）。
    final groupMeta = <String, ({String label, String badge})>{};
    for (final e in groups.entries) {
      final first = e.value.first;
      groupMeta[e.key] = (
        label: providerShortLabel(first),
        badge: planBadgeOf(first),
      );
    }
    final collisions = <String, int>{};
    for (final m in groupMeta.values) {
      final k = '${m.label}|${m.badge}';
      collisions[k] = (collisions[k] ?? 0) + 1;
    }
    if (collisions.values.any((c) => c > 1)) {
      final seen = <String, int>{};
      final orderedKeys = groups.keys.toList();
      for (final k in orderedKeys) {
        final meta = groupMeta[k]!;
        final ck = '${meta.label}|${meta.badge}';
        if ((collisions[ck] ?? 0) > 1) {
          final nth = (seen[ck] ?? 0)  + 1;
          seen[ck] = nth;
          groupMeta[k] = (
            label: '${meta.label}·${_groupDisambigSuffix(k, nth)}',
            badge: meta.badge,
          );
        }
      }
    }
    // 排序：套餐组（isPlanProvider）按 label 字母序在前，其余原序在后。
    final planKeys = groups.keys
        .where((k) => isPlanProvider(groups[k]!.first))
        .toList()
      ..sort((a, b) => groupMeta[a]!.label.compareTo(groupMeta[b]!.label));
    final otherKeys = groups.keys
        .where((k) => !isPlanProvider(groups[k]!.first))
        .toList();
    final ordered = <MapEntry<String, List<ConfigOptionValue>>>[
      for (final k in [...planKeys, ...otherKeys]) MapEntry(k, groups[k]!),
    ];

    // 选中行所在组（默认展开；其余组默认收起——显式操作优先）。
    final globalIndexOf = <ConfigOptionValue, int>{};
    for (var i = 0; i < widget.choices.length; i++) {
      globalIndexOf.putIfAbsent(widget.choices[i], () => i);
    }
    // 1.0.1 验收修复：选中组匹配——精确（provider+modelId）优先，
    // 失败降级到 modelId 模糊（真机 provider 形态可能与会话目录不同，
    // 精确匹配恒 miss → 全收起+选中不可见）。
    // 高④：原模糊回退被 selectedIndex>=0 挡死（精确必中时
    // 不需要、selectedIndex==-1 时被门挡），真机 provider 不匹配的
    // 场景仍全收起。修：selectedIndex<0 且有 current 时走模糊匹配。
    final selectedGroup = ordered
        .where(
          (g) => g.value.any((v) => globalIndexOf[v] == selectedIndex),
        )
        .map((g) => g.key)
        .firstOrNull ??
        (selectedIndex < 0 && widget.current.isNotEmpty
            ? ordered
                  .where((g) => g.value.any(
                        (v) => modelIdOf(v).toLowerCase() ==
                            widget.current.toLowerCase(),
                      ))
                  .map((g) => g.key)
                  .firstOrNull
            : null);
    // 无选中（新会话/目录无当前值）时首组默认展开。
    final defaultOpen = selectedGroup ?? ordered.first.key;
    bool groupCollapsed(String key) =>
        _collapsedByGroup[key] ?? (key != defaultOpen);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final g in ordered) ...[
          // 组头=provider 短名+套餐徽标+计数（桌面 labelBadge 对位）。
          InkWell(
            key: ValueKey('model-group-${g.key}'),
            borderRadius: BorderRadius.circular(AppRadius.sm),
            onTap: () => setState(
              () => _collapsedByGroup[g.key] = !groupCollapsed(g.key),
            ),
            child: Padding(
              padding: const EdgeInsets.only(left: 4, top: 10, bottom: 4),
              child: Row(
                children: [
                  Icon(
                    groupCollapsed(g.key)
                        ? Icons.expand_more
                        : Icons.expand_less,
                    size: 18,
                    color: context.colors.foregroundSubtle,
                  ),
                  const SizedBox(width: 2),
                  Flexible(
                    child: Text(
                      groupMeta[g.key]!.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: AppType.uiCaption,
                        fontWeight: FontWeight.w600,
                        color: context.colors.foregroundSubtle,
                      ),
                    ),
                  ),
                  if (groupMeta[g.key]!.badge.isNotEmpty) ...[
                    const SizedBox(width: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: context.colors.brandAccent.withValues(
                          alpha: 0.12,
                        ),
                        borderRadius: BorderRadius.circular(AppRadius.pill),
                      ),
                      child: Text(
                        groupMeta[g.key]!.badge,
                        style: TextStyle(
                          fontSize: AppType.uiXs,
                          color: context.colors.brandAccent,
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(width: 6),
                  Text(
                    '${g.value.length}',
                    style: TextStyle(
                      fontSize: AppType.uiXs,
                      color: context.colors.foregroundSubtlest,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (!groupCollapsed(g.key))
            for (final v in g.value)
              globalIndexOf[v] == selectedIndex
                  ? KeyedSubtree(key: _selectedKey, child: rowOf(v, true))
                  : rowOf(v, false),
        ],
      ],
    );
  }
}

class _ModelListRow extends StatelessWidget {
  final ConfigOptionValue value;
  final bool selected;
  final void Function(ConfigOptionValue v) onPick;
  final List<ConfigOptionValue> alternates;

  const _ModelListRow({
    super.key,
    required this.value,
    required this.selected,
    required this.onPick,
    this.alternates = const [],
  });

  @override
  Widget build(BuildContext context) {
    final name = modelIdOf(value);
    final asset = brandLogoAsset(name);
    // 2026-10-26 真机验收二轮：再收紧+logo 恒占位——无 logo 的模型此前
    // 不占位导致名字左缘不齐（真机实锤"乱"）：18 位恒留（无标时中性小
    // 圆点占位），名字全部对齐同一 x。行高 44→40/内距 v6→4 h12→10/
    // logo 20→18/字 uiBase→uiCaption/图标距 8→6。40 低于 44 触控下限
    // ——design_guard 豁免留痕（更新）。
    // 2026-10-26 选中行对齐桌面风格（用户拍板：风格/排版对齐，尺寸按
    // 手机优化）——桌面源码 ModelConfigSelect.tsx:394-415 + Radix
    // RadioItem：选中=右侧细勾（foreground-subtle 灰，非彩色），无
    // 常驻强调底；截图里的浅灰带=打开菜单时的焦点高亮。手机化：选中
    // 行给浅选中底（无 hover 的触屏替代）+文字加粗（可扫读性），去掉
    // 反白与彩色勾。
    // 2026-11-05 反馈④：行尾徽标=provider 短标签（弃全长 providerName
    // 截断；所有分组都显示——「其他」组行尾不再空白不可区分）；短标签
    // 内在宽不参与分宽（模型名 Expanded 独享剩余空间）。

    return Material(
      color: selected ? context.colors.selected : Colors.transparent,
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: InkWell(
        onTap: () => onPick(value),
        borderRadius: BorderRadius.circular(AppRadius.sm),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 40),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            child: Row(
              children: [
                // logo 槽恒在（名字对齐）；无标模型用中性小圆点占位。
                SizedBox(
                  width: 18,
                  height: 18,
                  child: Center(
                    child: asset != null
                        // 品牌色自动策略（2026-10-26 拍板①）：浅色原色/
                        // 深色提亮——选中态保留品牌色（勾号即选中信号）。
                        ? BrandLogo(asset: asset, size: 18)
                        : Container(
                            width: 6,
                            height: 6,
                            decoration: BoxDecoration(
                              color: context.colors.foregroundSubtlest,
                              shape: BoxShape.circle,
                            ),
                          ),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppType.uiCaption,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                      color: context.colors.foreground,
                    ),
                  ),
                ),
                // 1.0.1 验收终修：分组按 provider（桌面对齐）——组头
                // 已携带 provider 身份+套餐徽标，行内不再重复来源标签。
                // 行尾固定 ✓ 槽位（选中/非选中尾列齐平）。
                SizedBox(
                  width: 26,
                  child: selected
                      ? Icon(
                          Icons.check,
                          size: 18,
                          color: context.colors.foregroundSubtle,
                        )
                      : null,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    // 验收二轮：区块标题上下距 10/6→8/4（整页更紧凑）。
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Text(
        text,
        style: TextStyle(
          fontSize: AppType.uiSm,
          fontWeight: FontWeight.w600,
          color: context.colors.foregroundSubtle,
        ),
      ),
    );
  }
}

/// 思考档渐变滑动条（2026-10-26 复刻桌面材质，用户拍板）：
/// 一根连续渐变胶囊轨道（青绿→深蓝，方向感=弱→强，桌面实测色
/// #1FA67D→#2F6BFF 观感）+白色圆形把手吸附档位（略大于轨道、上下
/// 凸出、轻阴影浮起——浅色底上自行补浮起感）+轨道上各档槽点仅微小
/// 刻度点；**档名不上轨道**，上方文字行「思考强度 {当前档}」随把手
/// 联动（当前档提亮加重）。交互沿用验收二轮拍板：点选跳档+按住拖动
/// 跟手（80ms）、松手/点选吸附（240ms easeOutCubic），挂起语义随下
/// 一条消息不变。
class _ThoughtSlider extends StatefulWidget {
  final List<(String, String)> choices;
  final String? value;
  final void Function(String value) onChanged;
  const _ThoughtSlider({
    required this.choices,
    required this.value,
    required this.onChanged,
  });

  @override
  State<_ThoughtSlider> createState() => _ThoughtSliderState();
}

class _ThoughtSliderState extends State<_ThoughtSlider> {
  int _dragIndex = -1;

  int get _count => widget.choices.length;
  int get _selected {
    for (var i = 0; i < _count; i++) {
      if (widget.choices[i].$1 == widget.value) return i;
    }
    return 0;
  }

  int get _display => _dragIndex >= 0 ? _dragIndex : _selected;

  /// 档位 → 轨道行程位置（0..1，行程=轨道宽-把手宽，两端对齐把手心）。
  double _progressOf(int index) => _count <= 1 ? 0 : index / (_count - 1);

  int _indexAtProgress(double t) =>
      (t * (_count - 1)).round().clamp(0, _count - 1);

  @override
  Widget build(BuildContext context) {
    final n = _count;
    final currentLabel = widget.choices[_selected].$2;
    // #7：当前值不在该模型可选档位里时滑条回退默认档——必须给可见
    // 提示（否则用户以为显示的就是已生效档位）。
    final unavailable =
        widget.value != null &&
        widget.value!.isNotEmpty &&
        !widget.choices.any((c) => c.$1 == widget.value);
    final isMax = _selected == n - 1 && n > 1;
    final bright = Theme.of(context).brightness;
    // 桌面源码 token（composer-thought-slider.css + styles.css）：浅色
    // fill=green-600/深色=green-500；最高档渐变端=blue-500（270deg oklch
    // 青色路径→Flutter 无 oklch 插值，teal-500 三停近似中段防发灰）。
    final fillGreen = bright == Brightness.light
        ? const Color(0xFF16A34A)
        : const Color(0xFF22C55E);
    const fillBlue = Color(0xFF3B82F6);
    const fillTeal = Color(0xFF14B8A6);
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        const thumb = 28.0;
        final travel = w - thumb;
        final p = _progressOf(_display);
        final thumbLeft = travel * p;
        // 填充到把手心（桌面 calc(14px + (100%-28px)*p)）。
        final fillWidth = thumb / 2 + travel * p;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: (d) => setState(
            () => _dragIndex = _indexAtProgress(
              (d.localPosition.dx - thumb / 2) / travel,
            ),
          ),
          onHorizontalDragUpdate: (d) {
            final t = ((d.localPosition.dx - thumb / 2) / travel).clamp(
              0.0,
              1.0,
            );
            final idx = _indexAtProgress(t);
            if (idx != _dragIndex) setState(() => _dragIndex = idx);
          },
          onHorizontalDragEnd: (_) {
            final v = widget.choices[_display].$1;
            setState(() => _dragIndex = -1);
            widget.onChanged(v);
          },
          onHorizontalDragCancel: () => setState(() => _dragIndex = -1),
          onTapUp: (d) {
            final t = ((d.localPosition.dx - thumb / 2) / travel).clamp(
              0.0,
              1.0,
            );
            widget.onChanged(widget.choices[_indexAtProgress(t)].$1);
          },
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 文字行（桌面 ComposerEffortHeading 同构）：「思考强度」
              // 常规灰 + 当前档提亮加重。
              Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: '思考强度 ',
                      style: TextStyle(
                        fontSize: AppType.uiCaption,
                        color: context.colors.foregroundSubtle,
                      ),
                    ),
                    TextSpan(
                      text: currentLabel,
                      style: TextStyle(
                        fontSize: AppType.uiCaption,
                        fontWeight: FontWeight.w600,
                        color: context.colors.foreground,
                      ),
                    ),
                  ],
                ),
              ),
              if (unavailable)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    tr('当前档不可用，已按默认档显示'),
                    style: TextStyle(
                      fontSize: AppType.uiXs,
                      color: context.colors.warning,
                    ),
                  ),
                ),
              const SizedBox(height: 6),
              SizedBox(
                height: 32,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    // ① 槽：浅灰胶囊+内描边（桌面 bg-foreground/10 + 底层
                    // border foreground/10——描边放底层让填充完全盖住）。
                    Positioned(
                      top: 4,
                      bottom: 4,
                      left: 0,
                      right: 0,
                      child: Container(
                        key: const ValueKey('thought-slider-track'),
                        decoration: BoxDecoration(
                          color: context.colors.foreground.withValues(
                            alpha: 0.10,
                          ),
                          border: Border.all(
                            color: context.colors.foreground.withValues(
                              alpha: 0.10,
                            ),
                          ),
                          borderRadius: BorderRadius.circular(AppRadius.pill),
                        ),
                      ),
                    ),
                    // ② 进度填充（到把手心）：平时纯绿；最高档渐变层 200ms
                    // 淡入（绿→teal→蓝）+气泡层（仅最高档）。
                    Positioned(
                      top: 4,
                      bottom: 4,
                      left: 0,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 120),
                        curve: Curves.easeOut,
                        width: fillWidth,
                        clipBehavior: Clip.hardEdge,
                        decoration: BoxDecoration(
                          color: fillGreen,
                          borderRadius: BorderRadius.circular(AppRadius.pill),
                        ),
                        child: Stack(
                          children: [
                            Positioned.fill(
                              child: AnimatedOpacity(
                                duration: const Duration(milliseconds: 200),
                                curve: Curves.easeOut,
                                opacity: isMax ? 1 : 0,
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                      colors: [fillGreen, fillTeal, fillBlue],
                                    ),
                                    borderRadius: BorderRadius.circular(
                                      AppRadius.pill,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            if (isMax &&
                                !MediaQuery.of(context).disableAnimations)
                              const Positioned.fill(child: _ThoughtBubbles()),
                          ],
                        ),
                      ),
                    ),
                    // ③ 档位刻度点（桌面：未填=foreground-subtlest 灰、
                    // 已填=白 30%；横向分布=把手行程范围，两端 14px）。
                    for (var i = 0; i < n; i++)
                      Positioned(
                        left: travel * _progressOf(i) + thumb / 2 - 2,
                        top: 0,
                        bottom: 0,
                        child: Center(
                          child: Container(
                            width: 4,
                            height: 4,
                            decoration: BoxDecoration(
                              color: i <= _display
                                  ? Colors.white.withValues(alpha: 0.30)
                                  : context.colors.foregroundSubtlest,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                      ),
                    // ④ 白色圆把手（28px shadow-sm；120ms easeOut 与桌面
                    // 一致——拖拽跟手与吸附同短过渡，桌面注释明言）。
                    AnimatedPositioned(
                      duration: const Duration(milliseconds: 120),
                      curve: Curves.easeOut,
                      left: thumbLeft,
                      top: 2,
                      width: thumb,
                      height: thumb,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.white,
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.15),
                              blurRadius: 3,
                              offset: const Offset(0, 1),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 最高档气泡层（桌面 ComposerModelMenu EFFORT_BUBBLES 12 枚固定配置
/// 逐项复刻：top%/size/duration/delay 错峰；白点峰值 40% 透明度，从右
/// 往左漂（keyframes 104%→-4%，15%~80% 平台段）。reduce-motion 外层
/// 门控（MediaQuery.disableAnimations）。
class _ThoughtBubbles extends StatefulWidget {
  const _ThoughtBubbles();

  @override
  State<_ThoughtBubbles> createState() => _ThoughtBubblesState();
}

class _ThoughtBubblesState extends State<_ThoughtBubbles>
    with TickerProviderStateMixin {
  static const _bubbles = [
    (top: 4.0, size: 2.0, duration: 2.6, delay: 0.4),
    (top: 14.0, size: 3.0, duration: 3.2, delay: 2.1),
    (top: 8.0, size: 4.0, duration: 2.8, delay: 1.1),
    (top: 18.0, size: 2.0, duration: 3.6, delay: 0.8),
    (top: 3.0, size: 3.0, duration: 3.0, delay: 2.5),
    (top: 12.0, size: 2.0, duration: 3.4, delay: 1.7),
    (top: 6.0, size: 3.0, duration: 3.1, delay: 0.9),
    (top: 17.0, size: 4.0, duration: 2.9, delay: 2.3),
    (top: 10.0, size: 2.0, duration: 3.5, delay: 0.2),
    (top: 2.0, size: 2.0, duration: 2.7, delay: 1.8),
    (top: 15.0, size: 3.0, duration: 3.3, delay: 1.2),
    (top: 7.0, size: 4.0, duration: 3.6, delay: 3.1),
  ];

  final _controllers = <AnimationController>[];

  @override
  void initState() {
    super.initState();
    for (final b in _bubbles) {
      final c = AnimationController(
        vsync: this,
        duration: Duration(milliseconds: (b.duration * 1000).round()),
      );
      // 负 delay=相位前移（CSS animation-delay 负值语义）。
      c.value = (1 - b.delay / b.duration) % 1.0;
      c.repeat();
      _controllers.add(c);
    }
  }

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        return ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.pill),
          child: Stack(
            children: [
              for (var i = 0; i < _bubbles.length; i++)
                AnimatedBuilder(
                  animation: _controllers[i],
                  builder: (context, _) {
                    final t = _controllers[i].value;
                    final b = _bubbles[i];
                    // keyframes：0% x=104% o=0；15%~80% o=0.4；100%
                    // x=-4% o=0（x 按填充宽百分比换算）。
                    final x = (104 - t * 108) / 100 * w;
                    final o = t < 0.15
                        ? t / 0.15 * 0.4
                        : t > 0.80
                        ? (1 - (t - 0.80) / 0.20) * 0.4
                        : 0.4;
                    return Positioned(
                      left: x,
                      top: b.top,
                      child: Opacity(
                        opacity: o,
                        child: Container(
                          width: b.size,
                          height: b.size,
                          decoration: const BoxDecoration(
                            color: Colors.white,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                    );
                  },
                ),
            ],
          ),
        );
      },
    );
  }
}
