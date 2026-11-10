// E 批（2026-11-08 拍板③）+ F1 对抗审查返工（同日五路审查）：
// ①选择=纯本地（toggleWorkspaceHookReviewItem 是写配置+作废审核代的
// 命令，不是选择态同步——误用会导致信任所选必被 superseded 拒绝，已撤）；
// ②respond 须查 ACK status（业务拒绝 status:'failed'+reasonCode 不是
// 通道异常，官方 accepted∈{accepted,duplicate,noop}）；
// ③deadlineAt 在 payload 顶层（官方禁该类交互带 autoResolution）；
// ④trustState 官方闭集词表（workspace-hook-review.ts:9-17）+默认勾选
// ={pending_trust,revoked,stale_digest}（=官方 pendingCount 口径）；
// ⑤选择门控只按官方 trust_selected 语义（只要求 items 子集）——editable
// 只约束「写配置」（toggle 命令），不约束信任勾选；不可写盘项加小字标注。
import 'package:flutter/material.dart' hide Text;

import '../core/localized_text.dart';
import '../core/theme.dart';
import '../state/app_state_scope.dart';

/// 交互载荷 → 命令 target（官方 workspaceHookReviewCommandTargetSchema
/// 的字段全部随载荷携带）。
Map<String, dynamic> hookReviewTargetOf(Map<String, dynamic> interaction) => {
      'sessionId': '${interaction['sessionId'] ?? ''}',
      'taskId': '${interaction['taskId'] ?? ''}',
      'runId': '${interaction['runId'] ?? ''}',
      if ('${interaction['remoteSessionId'] ?? ''}'.isNotEmpty)
        'remoteSessionId': '${interaction['remoteSessionId']}',
      'workspaceIdentity': '${interaction['workspaceIdentity'] ?? ''}',
      'bundleDigest': '${interaction['bundleDigest'] ?? ''}',
      'reviewFlowId': '${interaction['reviewFlowId'] ?? ''}',
      'generation': interaction['generation'],
      'interactionId': '${interaction['interactionId'] ?? ''}',
    };

String _trustWord(String state) => switch (state) {
      'trusted_persistent' => '已信任',
      'pending_trust' => '待信任',
      'blocked_untrusted' => '已阻止',
      'blocked_policy' => '策略阻止',
      'revoked' => '已撤销',
      'stale_digest' => '摘要过期',
      'not_applicable' => '不适用',
      _ => state,
    };

class WorkspaceHookReviewPage extends StatefulWidget {
  final Map<String, dynamic> interaction;
  const WorkspaceHookReviewPage({super.key, required this.interaction});

  @override
  State<WorkspaceHookReviewPage> createState() =>
      _WorkspaceHookReviewPageState();
}

class _WorkspaceHookReviewPageState extends State<WorkspaceHookReviewPage> {
  /// 本地选择集（F1：默认勾选=官方 pendingCount 口径三态
  /// {pending_trust, revoked, stale_digest}）；「信任所选」以它为准。
  late final Set<String> _selected = {
    for (final it in _items)
      if (const {'pending_trust', 'revoked', 'stale_digest'}
          .contains('${it['trustState'] ?? ''}'))
        '${it['reviewItemId'] ?? ''}',
  };
  bool _busy = false;

  List<Map<String, dynamic>> get _items => [
        for (final it in (widget.interaction['items'] as List? ?? const []))
          if (it is Map) it.cast<String, dynamic>(),
      ];

  List<Map<String, dynamic>> get _sourceFiles => [
        for (final f in (widget.interaction['sourceFiles'] as List? ?? const []))
          if (f is Map) f.cast<String, dynamic>(),
      ];

  void _toggle(String itemId, bool value) {
    // F1：纯本地选择——toggleWorkspaceHookReviewItem 是写配置+作废
    // 审核代的命令（对抗审查高①），服务端无选择态字段，绝不在此发。
    setState(() {
      value ? _selected.add(itemId) : _selected.remove(itemId);
    });
  }

  Future<void> _trustSelected() async {
    if (_busy || _selected.isEmpty) return;
    setState(() => _busy = true);
    try {
      final res = await AppStateScope.of(context).respondWorkspaceHookReview(
        '${widget.interaction['sessionId'] ?? ''}',
        hookReviewTargetOf(widget.interaction),
        _selected.toList(),
      );
      if (!mounted) return;
      // F1（对抗审查中②）：业务拒绝=ACK status:'failed'+reasonCode，
      // 不是通道异常——官方判 accepted∈{accepted,duplicate,noop}。
      final status = '${res?['status'] ?? 'accepted'}';
      if (status != 'accepted' &&
          status != 'duplicate' &&
          status != 'noop') {
        setState(() => _busy = false);
        final reason = '${res?['reasonCode'] ?? status}';
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text('信任未生效（$reason）——审核已更新，请返回重进')),
        );
        return; // 不 pop：审核代已变，页面数据已陈旧
      }
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text('信任失败：$e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final summary = (widget.interaction['summary'] as Map?)?.cast<String, dynamic>() ?? const {};
    // F1（对抗审查）：官方禁该类交互带 autoResolution（snapshot.ts
    // :339-345），deadlineAt 在 payload 顶层（workspace-hook-review.ts:93）。
    final deadline = (widget.interaction['deadlineAt'] as num?)?.toInt();
    return Scaffold(
      backgroundColor: context.colors.background,
      appBar: AppBar(
        backgroundColor: context.colors.background,
        surfaceTintColor: Colors.transparent,
        title: const Text('工作区 Hook 审核'),
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              key: const ValueKey('hook-review-body'),
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              children: [
                // 摘要行：工作区 + 计数 + 截止。
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: context.colors.card,
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                    border: Border.all(color: context.colors.borderFaint),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.shield_outlined,
                              size: 14, color: context.colors.warning),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              '${widget.interaction['workspaceLabel'] ?? ''}',
                              translate: false,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: AppType.uiCaption,
                                  fontWeight: FontWeight.w600),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '这些钩子将在本工作区自动执行命令——确认来源后才应信任',
                        style: TextStyle(
                            fontSize: AppType.uiXs,
                            color: context.colors.foregroundSubtle),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${summary['eventCount'] ?? 0} 类事件 · '
                        '${summary['hookCount'] ?? 0} 个钩子 · '
                        '${summary['pendingCount'] ?? 0} 待审'
                        '${deadline != null ? ' · 截止 ${_fmtDeadline(deadline)}' : ''}',
                        style: TextStyle(
                            fontSize: AppType.uiXs,
                            color: context.colors.foregroundSubtlest),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                if (_sourceFiles.isNotEmpty) ...[
                  Text('源文件',
                      style: TextStyle(
                          fontSize: AppType.uiSm,
                          fontWeight: FontWeight.w600,
                          color: context.colors.foregroundSubtle)),
                  const SizedBox(height: 4),
                  for (final f in _sourceFiles)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Row(
                        children: [
                          Icon(
                            f['editable'] == true
                                ? Icons.edit_document
                                : Icons.lock_outline,
                            size: 13,
                            color: context.colors.foregroundSubtlest,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              '${f['displayPath'] ?? f['path'] ?? ''}',
                              translate: false,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: AppType.uiXs,
                                  fontFamily: 'monospace',
                                  color: context.colors.foregroundSubtle),
                            ),
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 10),
                ],
                Text('钩子清单（勾选后统一信任）',
                    style: TextStyle(
                        fontSize: AppType.uiSm,
                        fontWeight: FontWeight.w600,
                        color: context.colors.foregroundSubtle)),
                const SizedBox(height: 4),
                for (final it in _items)
                  _HookItemCard(
                    item: it,
                    selected:
                        _selected.contains('${it['reviewItemId'] ?? ''}'),
                    onToggle: (v) =>
                        _toggle('${it['reviewItemId'] ?? ''}', v),
                  ),
              ],
            ),
          ),
          // 底部动作区：信任所选（主）+暂不。
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      key: const ValueKey('hook-review-later'),
                      onPressed: _busy ? null : () => Navigator.of(context).pop(),
                      child: const Text('暂不'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 2,
                    child: FilledButton(
                      key: const ValueKey('hook-review-trust'),
                      onPressed:
                          _busy || _selected.isEmpty ? null : _trustSelected,
                      child: Text(_busy
                          ? '提交中…'
                          : '信任所选（${_selected.length}）'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _fmtDeadline(int ms) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    final left = ms - now.millisecondsSinceEpoch;
    if (left <= 0) return '已到';
    if (left < 3600000) return '${left ~/ 60000 + 1} 分钟内';
    return '${dt.month}/${dt.day} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }
}

class _HookItemCard extends StatelessWidget {
  final Map<String, dynamic> item;
  final bool selected;
  final ValueChanged<bool> onToggle;
  const _HookItemCard({
    required this.item,
    required this.selected,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final trustState = '${item['trustState'] ?? ''}';
    // 官方闭集里「已信任」= trusted_persistent（旧判 'trusted' 永不命中，
    // 已信任项被渲染成红色危险色）。
    final trusted = trustState == 'trusted_persistent';
    final color = trusted
        ? context.colors.foregroundSubtle
        : trustState == 'pending_trust'
            ? context.colors.warning
            : context.colors.destructive;
    return Container(
      key: ValueKey('hook-item-${item['reviewItemId'] ?? ''}'),
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: context.colors.card,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: context.colors.borderFaint),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // 官方 trust_selected 只要求 reviewItemIds 是 items 子集——
              // editable 只约束写配置（toggle 命令），不约束信任勾选：
              // 所有条目均可勾选（此前非 editable 待信任项被强制勾选且
              // 无法取消）。不可写盘仅作视觉标注（卡片下方小字）。
              // VR-4a（视觉审查 1109）：原命中区=SizedBox(32,24)+FittedBox
              // 缩放后的开关本体，实际可点区仅 32×24（低于 44 触控下限）。
              // 修=40×40 热区外壳 + opaque GestureDetector 承接槽内空白处
              // 点按（开关本体手势优先，不会双触发）；开关视觉尺寸不变。
              SizedBox(
                key: ValueKey('hook-item-switch-${item['reviewItemId'] ?? ''}'),
                width: 40,
                height: 40,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onToggle(!selected),
                  child: Center(
                    child: SizedBox(
                      width: 32,
                      height: 24,
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Switch(value: selected, onChanged: onToggle),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '${item['displayName'] ?? item['event'] ?? ''}',
                  translate: false,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: AppType.uiCaption, fontWeight: FontWeight.w500),
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                ),
                child: Text(
                  _trustWord(trustState),
                  style: TextStyle(fontSize: AppType.uiXs, color: color),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '${item['displayCommand'] ?? ''}',
            translate: false,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: AppType.uiXs,
                fontFamily: 'monospace',
                color: context.colors.foregroundSubtle),
          ),
          const SizedBox(height: 4),
          Text(
            // F7（复审）：不得先 tr('后台') 再拼——英文下拼出的整串
            // 是 'event · Background · 超时 30s'，整串再走词表时模式
            // 匹配中文「后台」永不命中（pattern 成死代码）。整串直出，
            // 由 localized Text 的组合模式整体翻译。
            '${item['event'] ?? ''} · '
            "${item['executionMode'] == 'background' ? '后台' : '前台'} · "
            '超时 ${((item['resolvedTimeoutMs'] as num?) ?? 0) ~/ 1000}s',
            style: TextStyle(
                fontSize: AppType.uiXs,
                color: context.colors.foregroundSubtlest),
          ),
          // editable 只约束写配置：非 editable 项仍可勾选信任，但配置
          // 由来源文件管理——给用户一句明确说明（避免误以为可改）。
          if (item['editable'] != true) ...[
            const SizedBox(height: 2),
            Row(
              children: [
                Icon(
                  Icons.lock_outline,
                  size: 11,
                  color: context.colors.foregroundSubtlest,
                ),
                const SizedBox(width: 4),
                Text(
                  tr('不可写盘（配置由来源文件维护）'),
                  style: TextStyle(
                    fontSize: AppType.uiXs,
                    color: context.colors.foregroundSubtlest,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
