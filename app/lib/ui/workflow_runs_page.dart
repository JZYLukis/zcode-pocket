import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart' hide Text;
import '../core/artifact_share.dart' show kArtifactShareBlockBytes;
import '../core/localized_text.dart';
import '../core/theme.dart';
import 'turn_model.dart' show toolInputArgs;
import 'workflow_dashboards.dart';
import '../state/app_state.dart';
import '../state/app_state_scope.dart';
import 'app_widgets.dart' show AppLoading;
import 'file_preview.dart' show HtmlPreviewPage;
import 'share_flow.dart'
    show formatArtifactBytes, shareArtifactRemotely, shareBytesAsFile;

/// 工作流 run 目录与详情（workflow-runs-1，2026-10-30 用户拍板「更新
/// 工作流及闲时执行部分」）：官方 v4 只读查询族——workflowRuns（run 摘
/// 要，五态）/workflowRunEvents（journal 事件分页）/workflowRunArtifacts
/// （产物清单）/workflowRunArtifactRead（内容产物字节 ≤512KiB 分块，形
/// 状照 attachmentRead）。全部只读、无状态、超时重发安全（transport.ts
/// 注释），手机端为纯消费页。

/// 图片产物预览：artifactRead
/// 是纯数据读取（零 token、不进模型上下文）——与 base64 塞上下文的方案
/// 本质不同。纯函数判定 + 首块字节嗅探双保险；上限 16MiB；解码降采样
/// 2048px。SVG 不在 Flutter 原生支持集，走"不支持的格式"提示。
const artifactImagePreviewMaxBytes = 16 * 1024 * 1024;

/// 「收集产物」预设提示词（早前批次 定稿，2026-11-13 用户逐句
/// 拍板）：工作流搬运配方——把会话生成的文件（含二进制）发布为产物，
/// 手机端经产物分享链路带走（协议边界内唯一二进制可达路径）。
/// 铁律来源：①cd 对齐工作流工作区+相对路径发布（真机实证：工作区
/// 漂移=artifact.file 全部被拒）②无子代理/无校验/脚本免注释（token
/// 大头：子代理=整轮模型调用×N、校验=多余的 world.run、注释=自然
/// 语言全价计费）③只发布文件本身（防 agent 默认产报告——实证其脚本
/// 自带 Finding 汇报结构）。中文撰写：GLM 分词器中文优先于英文，
/// agent 侧指令不随界面语言切换。
const kCollectArtifactsPrompt =
    '把本回合生成的文件发布为工作流产物：cd 到文件所在目录（分散先 cp 集中）'
    '→ 建极简工作流：无子代理、无校验、脚本免注释，用相对路径逐个 '
    'artifact.file 发布这些文件本身；id 与 title 都用带后缀的完整文件名'
    '（如 report.pdf），并显式传 contentType——手机下载的文件名取自 '
    'title，无后缀的 xlsx/pptx/pdf 会打不开。不要附加报告或摘要类产物。'
    '文件内容不动。';

/// 分块读取一个内容产物（512KiB/块）。返回拼接字节与截断/超限标志。
///
/// 图片类（扩展名或首块魔数命中）放宽到 32 块/16MiB；上限随魔数嗅探
/// 放宽（公开同步终审抓出：上限预定死，无扩展名图片 >4MiB 被静默
/// 截断）；超限判定结合「还有下一块」——恰好 16MiB 的完整图片不误报。
/// 纯逻辑抽离供单测直灌 read 回调（终审覆盖缺口）。
typedef ArtifactBlockRead = Future<dynamic> Function({
  required int offset,
  required int blockLimit,
});

class ArtifactBlocks {
  ArtifactBlocks({
    required this.bytes,
    required this.truncated,
    required this.oversized,
    required this.isImage,
  });
  final List<int> bytes;
  final bool truncated;
  final bool oversized;
  final bool isImage;
}

Future<ArtifactBlocks> readArtifactBlocks({
  required String name,
  required ArtifactBlockRead read,
}) async {
  var isImage = artifactLooksImageByExtension(name);
  var blockLimit = isImage ? 32 : 8;
  final bytes = <int>[];
  var offset = 0;
  var truncated = false;
  for (var i = 0; i < blockLimit; i++) {
    final res = await read(offset: offset, blockLimit: blockLimit);
    final b64 = '${(res is Map ? res['dataBase64'] : '') ?? ''}';
    if (b64.isEmpty) break;
    bytes.addAll(base64.decode(b64));
    if (i == 0 && !isImage && sniffImageMagic(bytes)) {
      isImage = true;
      blockLimit = 32;
    }
    final next =
        (res is Map ? (res['nextOffset'] as num?)?.toInt() : null) ?? -1;
    if (next <= offset || next <= 0) break;
    if (isImage &&
        bytes.length >= artifactImagePreviewMaxBytes &&
        next > offset) {
      return ArtifactBlocks(
        bytes: bytes, truncated: false, oversized: true, isImage: isImage);
    }
    offset = next;
    if (i == blockLimit - 1) truncated = !isImage;
  }
  return ArtifactBlocks(
    bytes: bytes, truncated: truncated, oversized: false, isImage: isImage);
}
const _imageArtifactExts = {'.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp'};

/// 按标题/id 的扩展名判定（大小写不敏感；无扩展名=非图片，等嗅探兜底）。
bool artifactLooksImageByExtension(String titleOrId) {
  final dot = titleOrId.lastIndexOf('.');
  if (dot < 0 || dot + 1 >= titleOrId.length) return false;
  return _imageArtifactExts.contains(
    titleOrId.substring(dot).toLowerCase(),
  );
}

/// 首块字节嗅探（PNG/JPEG/GIF/WEBP/BMP 魔数；扩展名缺失或被骗时兜底）。
bool sniffImageMagic(List<int> b) {
  if (b.length < 4) return false;
  bool eq(int start, List<int> magic) {
    if (b.length < start + magic.length) return false;
    for (var i = 0; i < magic.length; i++) {
      if (b[start + i] != magic[i]) return false;
    }
    return true;
  }

  return eq(0, [0x89, 0x50, 0x4E, 0x47]) || // PNG
      eq(0, [0xFF, 0xD8, 0xFF]) || // JPEG
      eq(0, [0x47, 0x49, 0x46, 0x38]) || // GIF8
      (eq(0, [0x52, 0x49, 0x46, 0x46]) && // RIFF….WEBP
          b.length >= 12 &&
          eq(8, [0x57, 0x45, 0x42, 0x50])) ||
      eq(0, [0x42, 0x4D]); // BM
}

/// run 状态五态的人话与配色（官方词表 runs 投影同一套）。
({String label, Color color}) workflowRunStatusOf(
  BuildContext context,
  String status,
) => switch (status) {
  'running' => (label: '运行中', color: context.colors.warning),
  'pending' => (label: '排队中', color: context.colors.foregroundSubtle),
  'completed' => (label: '已完成', color: context.colors.success),
  'errored' => (label: '出错', color: context.colors.destructive),
  'stopped' => (label: '已停止', color: context.colors.foregroundSubtle),
  _ => (label: status, color: context.colors.foregroundSubtle),
};

String _shortRunId(String runId) =>
    runId.length <= 10 ? runId : runId.substring(0, 10);

String _relTime(int? epochMs) {
  if (epochMs == null || epochMs <= 0) return '';
  final diff = DateTime.now().millisecondsSinceEpoch - epochMs;
  if (diff < 60_000) return '刚刚';
  if (diff < 3_600_000) return '${diff ~/ 60_000} 分钟前';
  if (diff < 86_400_000) return '${diff ~/ 3_600_000} 小时前';
  return '${diff ~/ 86_400_000} 天前';
}

/// run 摘要联接（目录/详情两入口唯一实现）：优先 runId、回退 toolCallId
///（老 run 没有 toolCallId）。官方 run 目录 schema（transport.ts
/// v4ConversationWorkflowRunSummarySchema，.strict()）**没有**
/// lastEventSequence——最后事件序号只在快照 workflowRuns 投影里
///（workflow-runs.ts:581），run 详情「最新一页」反推必须走投影。
Map<String, dynamic>? joinWorkflowRunProjection(
  List<Map<String, dynamic>> runs, {
  String? runId,
  String? toolCallId,
}) {
  for (final r in runs) {
    if (runId != null &&
        runId.isNotEmpty &&
        '${r['runId'] ?? ''}' == runId) {
      return r;
    }
    if (toolCallId != null &&
        toolCallId.isNotEmpty &&
        '${r['toolCallId'] ?? ''}' == toolCallId) {
      return r;
    }
  }
  return null;
}

/// 会话的 run 目录页。
class WorkflowRunsPage extends StatefulWidget {
  final String sessionId;

  /// 产物下载枢纽（早前批次，用户拍板：顶栏工作流入口换成下载
  /// 图标直达本页——指引+收集产物入口+运行列表同页，想下载的人自然
  /// 到达并得到提示）。false=原「工作流运行」目录形态。
  final bool downloadsHub;

  /// 收集指令回发（把弹层文本作为消息发进会话；conversation 侧接线
  /// _sendText 管线，离线自动入队）。仅 hub 模式使用。
  final Future<bool> Function(String prompt)? onCollectPrompt;

  const WorkflowRunsPage({
    super.key,
    required this.sessionId,
    this.downloadsHub = false,
    this.onCollectPrompt,
  });

  @override
  State<WorkflowRunsPage> createState() => _WorkflowRunsPageState();
}

class _WorkflowRunsPageState extends State<WorkflowRunsPage> {
  List<Map<String, dynamic>> _runs = const [];
  bool _loading = true;
  /// 收集指令发出后的延时重拉（B-/C-M3）——dispose 取消防泄漏。
  final _collectReloadTimers = <Timer>[];

  @override
  void dispose() {
    for (final t in _collectReloadTimers) {
      t.cancel();
    }
    super.dispose();
  }
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final app = AppStateScope.of(context);
      final res = await app.workflowRuns(widget.sessionId);
      final runs = (res is Map ? res['runs'] as List? : null) ?? const [];
      if (!mounted) return;
      // lastEventSequence 只在快照投影里（官方目录 schema 无此字段）——
      // 按 runId（回退 toolCallId）联接补进目录行，详情页才有「最新页」
      // 反推依据。
      final projection =
          app.conversationStates[widget.sessionId]?.workflowRunsList ??
          const <Map<String, dynamic>>[];
      setState(() {
        _runs = [
          for (final r in runs.whereType<Map>())
            _withProjectedLastEvent(r.cast<String, dynamic>(), projection),
        ];
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _loading = false;
        });
      }
    }
  }

  /// 目录行联接投影（投影优先；投影缺席时保留原值）。对抗审查
  /// B-/C-（2026-11-14）：演示模式批 原实现读 RPC 行的
  /// artifacts——RPC schema（transport.ts v4ConversationWorkflowRun
  /// SummarySchema.strict）根本没有该字段，artifacts 只在快照投影里，
  /// 生产环境计数恒 0、测试夹具自造字段掩盖（fullsweep 同型事故）。
  /// 修=与 lastEventSequence 同源联接投影 artifacts。
  Map<String, dynamic> _withProjectedLastEvent(
    Map<String, dynamic> run,
    List<Map<String, dynamic>> projection,
  ) {
    final joined = joinWorkflowRunProjection(
      projection,
      runId: '${run['runId'] ?? ''}',
      toolCallId: '${run['toolCallId'] ?? ''}',
    );
    if (joined == null) return run;
    final seq = (joined['lastEventSequence'] as num?)?.toInt();
    final arts = joined['artifacts'];
    return {
      ...run,
      if (seq != null) 'lastEventSequence': seq,
      // 投影 artifacts（List<Map>）；payload_guard：build 期禁裸强转。
      if (arts is List)
        'artifacts': [
          for (final a in arts)
            if (a is Map) a.cast<String, dynamic>(),
        ],
    };
  }

  @override
  Widget build(BuildContext context) {
    final hub = widget.downloadsHub;
    return Scaffold(
      backgroundColor: context.colors.background,
      appBar: AppBar(
        backgroundColor: context.colors.background,
        surfaceTintColor: Colors.transparent,
        title: Text(hub ? tr('产物下载') : '工作流运行'),
      ),
      body: Column(
        children: [
          if (hub) _hubHeader(context),
          Expanded(
            child: _loading
          ? const Center(child: AppLoading('正在加载…'))
          : _error != null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    tr('加载失败：') + _error!,
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
          : _runs.isEmpty
          // 对抗审查 B-/C-M3：空态也要能下拉刷新（收集产物的首次
          // 使用主路径就是空列表）。
          ? RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                children: [
                  const SizedBox(height: 120),
                  Center(
                    child: Text(
                      '本会话没有工作流运行',
                      style: TextStyle(
                        fontSize: AppType.uiCaption,
                        color: context.colors.foregroundSubtle,
                      ),
                    ),
                  ),
                ],
              ),
            )
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView.separated(
                key: const ValueKey('workflow-runs-list'),
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                itemCount: _runs.length,
                separatorBuilder: (_, _) => const SizedBox(height: 6),
                itemBuilder: (context, i) {
                  final run = _runs[i];
                  final status = workflowRunStatusOf(
                    context,
                    '${run['status'] ?? ''}',
                  );
                  // 产物计数（演示模式批，2026-11-14 用户拍板：
                  // 清单应显示是否有产物及数量）：官方 workflowRuns 投影
                  // 自带 artifacts 元数据（热态准；CLI 冷恢复后为空——
                  // artifact-projection.ts:28 官方注释），故 N>0 才显示、
                  // 0/缺席不显示（缺席=无产物或重启后未知，宁缺勿谎，
                  // 详情页 workflowRunArtifacts 为权威）。
                  // payload_guard：build 期禁裸强转（形态漂移不崩）。
                  final artsList = run['artifacts'];
                  final artifactCount = artsList is List ? artsList.length : 0;
                  final label =
                      '${run['label'] ?? ''}'.trim().isNotEmpty
                      ? '${run['label']}'
                      : _shortRunId('${run['runId'] ?? ''}');
                  return Material(
                    color: context.colors.card,
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                    child: InkWell(
                      key: ValueKey('workflow-run-${run['runId']}'),
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => WorkflowRunDetailPage(
                            sessionId: widget.sessionId,
                            runId: '${run['runId']}',
                            title: label,
                            // 官方 afterSequence 缺省=从头取（最旧一页）
                            // ——目录行已按投影联接补上 lastEventSequence，
                            // 详情页据此反推最新页。
                            lastEventSequence:
                                (run['lastEventSequence'] as num?)?.toInt(),
                          ),
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        child: LayoutBuilder(
                          builder: (context, constraints) => Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      label,
                                    translate: false,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: AppType.uiBase,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                  if ('${run['failureMessage'] ?? ''}'
                                      .isNotEmpty)
                                    Text(
                                      '${run['failureMessage']}',
                                      translate: false,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: AppType.uiXs,
                                        color: context.colors.destructive,
                                      ),
                                    )
                                  else
                                    Text.rich(
                                      TextSpan(
                                        children: [
                                          if (artifactCount > 0) ...[
                                            WidgetSpan(
                                              alignment: PlaceholderAlignment
                                                  .middle,
                                              child: Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  Icon(
                                                    Icons.folder_zip_outlined,
                                                    size: 10,
                                                    color: context
                                                        .colors.foregroundSubtle,
                                                  ),
                                                  const SizedBox(width: 2),
                                                  Text(
                                                    // 复用既有 ^产物（N）$
                                                    // 模式（EN 界面正确翻译）。
                                                    tr('产物（$artifactCount）'),
                                                    style: TextStyle(
                                                      fontSize: AppType.uiXs,
                                                      color: context.colors
                                                          .foregroundSubtle,
                                                    ),
                                                  ),
                                                  const SizedBox(width: 6),
                                                ],
                                              ),
                                            ),
                                          ],
                                          TextSpan(
                                            text: _shortRunId(
                                              '${run['runId'] ?? ''}',
                                            ),
                                          ),
                                        ],
                                      ),
                                      style: TextStyle(
                                        fontSize: AppType.uiXs,
                                        fontFamily: 'monospace',
                                        color:
                                            context.colors.foregroundSubtlest,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                              const SizedBox(width: 8),
                              // 视觉补跑必修（Visual B
                              // 像素实测）：原先 Flexible(状态) 与 Expanded(标题)
                              // 双分把行宽对半分——状态只画约 55dp、剩余约
                              // 87dp 全落行尾=右缘死区（时间不靠右、不同状态
                              // 起始 x 参差、长标题提前约 10 字省略）。改=标题
                              // 独占弹性，状态/时间为非弹性尾簇（窄屏长状态
                              // 72dp 封顶省略，行尾贴卡片右缘）。
                              ConstrainedBox(
                                constraints:
                                    const BoxConstraints(maxWidth: 72),
                                child: Text(
                                  status.label,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: AppType.uiCaption,
                                    color: status.color,
                                  ),
                                ),
                              ),
                              // 320+1.3 英文档实测右侧
                              // 溢出 100px——窄屏隐藏相对时间（次要信息，
                              // 官方桌面窄侧栏也只留状态）。
                              if (constraints.maxWidth >= 300) ...[
                                const SizedBox(width: 6),
                                Text(
                                  _relTime(
                                    (run['updatedAt'] as num?)?.toInt(),
                                  ),
                                  style: TextStyle(
                                    fontSize: AppType.uiXs,
                                    color: context.colors.foregroundSubtlest,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 产物下载页头（早前批次）：指引 + 收集产物入口。
  Widget _hubHeader(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: context.colors.card,
          borderRadius: BorderRadius.circular(AppRadius.sm),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.file_download_outlined,
                  size: 16,
                  color: context.colors.foregroundSubtle,
                ),
                const SizedBox(width: 6),
                // 对抗审查 B-/：EN 长标题 320dp 溢出——Expanded
                // 弹性+单行省略。
                Expanded(
                  child: Text(
                    tr('如何下载会话中的文件'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: AppType.uiSm,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              tr('会话生成的文件（含图片 / PDF / 表格）需先发布为工作流产物才能下载：点「收集产物」让智能体整理本回合文件；已发布的产物在下方运行里点开，行尾即可分享保存。'),
              style: TextStyle(
                fontSize: AppType.uiCaption,
                height: 1.5,
                color: context.colors.foregroundSubtle,
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                key: const ValueKey('hub-collect-button'),
                icon: const Icon(Icons.download, size: 18),
                label: Text(tr('收集产物')),
                // 对抗审查 B-/C-：readOnly 子代理下钻会话不可发送
                //（onCollectPrompt=null→禁用；此前 null 只是 no-op 可点）。
                onPressed: widget.onCollectPrompt == null
                    ? null
                    : () async {
                        final onSend = widget.onCollectPrompt!;
                        final ok = await showCollectArtifactsPrompt(
                          context,
                          onSend: onSend,
                        );
                        if (!mounted) return;
                        if (!ok) {
                          // 对抗审查 B-/C-M2：_sending 在飞/发送失败
                          // 此前静默丢——给出明确反馈。
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                tr('未能发送（会话正忙或发送失败），请稍后再试'),
                              ),
                            ),
                          );
                          return;
                        }
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              tr('已发送收集指令，产物就绪后会出现在下方'),
                            ),
                          ),
                        );
                        // 对抗审查 B-/C-M3：发送后页面从不刷新——延时
                        // 两次自动重拉覆盖 agent 编排-提交窗口。可取消
                        // Timer（页面退出即弃——widget 测试 pending timer
                        // 断言同样要求）。
                        for (final t in _collectReloadTimers) {
                          t.cancel();
                        }
                        _collectReloadTimers
                          ..clear()
                          ..addAll([
                            Timer(const Duration(seconds: 3), () {
                              if (mounted) _load();
                            }),
                            Timer(const Duration(seconds: 10), () {
                              if (mounted) _load();
                            }),
                          ]);
                      },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// run 详情页：摘要 + 事件时间线 + 产物清单（内容产物点开分块读取文本
/// 预览；html 走 HtmlPreviewPage 本地渲染）。
class WorkflowRunDetailPage extends StatefulWidget {
  final String sessionId;
  final String runId;
  final String title;

  /// 投影的最后事件序号（用于反推事件「最新一页」；目录/run 卡入口
  /// 从快照 workflowRuns 投影联接传入）。
  final int? lastEventSequence;
  const WorkflowRunDetailPage({
    super.key,
    required this.sessionId,
    required this.runId,
    required this.title,
    this.lastEventSequence,
  });

  @override
  State<WorkflowRunDetailPage> createState() => _WorkflowRunDetailPageState();
}

class _WorkflowRunDetailPageState extends State<WorkflowRunDetailPage> {
  /// 官方事件页上界（条数）：CLI 侧钳 ≤500，字节上界更小。
  static const _eventsPageSize = 500;

  /// 首载自动追平的最大页数（防异常 hasMore 无限翻页）。
  static const _eventsMaxPages = 10;

  List<Map<String, dynamic>> _events = const [];
  List<Map<String, dynamic>> _artifacts = const [];
  bool _loading = true;
  bool _eventsBusy = false;
  bool _eventsHasMore = false;
  String? _eventsMoreError;
  String? _error;

  /// 投影的最后事件序号（快照 workflowRuns 投影；目录/run 卡入口会传，
  /// 没传时首载再从投影按 runId 回捞——官方目录 schema 无此字段）。
  int? _lastEventSequence;

  @override
  void initState() {
    super.initState();
    _lastEventSequence = widget.lastEventSequence;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  /// 反推「最新一页」的依据（显式传入优先，其次投影联接）。
  int? _resolveLastEventSequence(AppState app) {
    if (widget.lastEventSequence != null) return widget.lastEventSequence;
    final runs =
        app.conversationStates[widget.sessionId]?.workflowRunsList ??
        const <Map<String, dynamic>>[];
    final joined = joinWorkflowRunProjection(runs, runId: widget.runId);
    return (joined?['lastEventSequence'] as num?)?.toInt();
  }

  Future<({List<Map<String, dynamic>> events, bool hasMore})>
  _fetchEventsPage(AppState app, int? afterSequence) async {
    final res = await app.workflowRunEvents(
      widget.sessionId,
      widget.runId,
      afterSequence: afterSequence,
    );
    final map = res is Map ? res : const {};
    return (
      events: [
        for (final e in (map['events'] as List? ?? const []))
          if (e is Map) e.cast<String, dynamic>(),
      ],
      hasMore: map['hasMore'] == true,
    );
  }

  /// 事件升序归一（官方 journal 升序；展示层 reversed=最新在前）。
  List<Map<String, dynamic>> _sorted(List<Map<String, dynamic>> events) {
    final out = [...events];
    out.sort(
      (a, b) => ((a['sequence'] as num?)?.toInt() ?? 0).compareTo(
        (b['sequence'] as num?)?.toInt() ?? 0,
      ),
    );
    return out;
  }

  /// 首载追平：有投影序号时从「最后序号-页大小」反推窗口，逐页翻到
  /// events.last.sequence >= lastEventSequence 或 hasMore=false 为止
  ///（容纳字节上界导致的短页）；无投影序号=官方语义从头取最早一页。
  /// 页数上限只影响本次自动翻页，余量交「加载更多」。
  Future<({List<Map<String, dynamic>> events, bool hasMore})>
  _fetchEventsCatchingUp(AppState app, int? lastSequence) async {
    final events = <Map<String, dynamic>>[];
    var afterSequence = lastSequence == null
        ? null
        : lastSequence > _eventsPageSize
        ? lastSequence - _eventsPageSize
        : 0;
    var hasMore = false;
    for (var page = 0; page < _eventsMaxPages; page++) {
      final fetched = await _fetchEventsPage(app, afterSequence);
      events.addAll(fetched.events);
      hasMore = fetched.hasMore;
      if (!hasMore) break;
      // 无投影序号：只取最早一页，更晚事件交按钮（不静默扫全量）。
      if (lastSequence == null) break;
      // 游标=本页最大序号（官方 journal 升序；取 max 防乱序页回退死循环）。
      var tailSequence = 0;
      for (final e in fetched.events) {
        final s = (e['sequence'] as num?)?.toInt() ?? 0;
        if (s > tailSequence) tailSequence = s;
      }
      if (tailSequence == 0 || tailSequence >= lastSequence) break;
      afterSequence = tailSequence;
    }
    return (events: _sorted(events), hasMore: hasMore);
  }

  Future<void> _load() async {
    final app = AppStateScope.of(context);
    setState(() {
      _loading = true;
      _error = null;
      _eventsMoreError = null;
    });
    final lastSequence = _resolveLastEventSequence(app);
    _lastEventSequence = lastSequence;
    try {
      // 两路只读查询并行（事件追平与产物清单无依赖）。
      final results = await Future.wait<dynamic>([
        _fetchEventsCatchingUp(app, lastSequence),
        app.workflowRunArtifacts(widget.sessionId, widget.runId),
      ]);
      if (!mounted) return;
      final page =
          results[0]
              as ({List<Map<String, dynamic>> events, bool hasMore});
      setState(() {
        _events = page.events;
        _eventsHasMore = page.hasMore;
        _artifacts =
            ((results[1] is Map
                        ? results[1]['artifacts'] as List?
                        : null) ??
                    const [])
                .whereType<Map>()
                .map((e) => e.cast<String, dynamic>())
                .toList();
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _loading = false;
        });
      }
    }
  }

  /// 「加载更多」：从已加载末条继续向后翻（每次一页）；失败保留现有
  /// 时间线，错误内联在页脚。
  Future<void> _loadMoreEvents() async {
    if (_eventsBusy) return;
    final app = AppStateScope.of(context);
    final after = _events.isEmpty
        ? 0
        : ((_events.last['sequence'] as num?)?.toInt() ?? 0);
    setState(() {
      _eventsBusy = true;
      _eventsMoreError = null;
    });
    try {
      final fetched = await _fetchEventsPage(app, after);
      if (!mounted) return;
      setState(() {
        _events = _sorted([..._events, ...fetched.events]);
        _eventsHasMore = fetched.hasMore;
        _eventsBusy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _eventsBusy = false;
        _eventsMoreError = '$e';
      });
    }
  }

  /// 事件标题的诚实口径：追平（到顶）才敢说「最新」；有投影序号但没有
  /// 更晚事件=最新；无投影序号=官方从头取，只能称「最早」。
  /// 追平档复用既有可翻译标题形态（custom_l10n 的
  /// `^事件（最新 (\d+) 条）$` 模式），英文界面不裸露中文。
  String get _eventsTitle {
    final count = _events.length;
    if (_lastEventSequence == null) {
      return _eventsHasMore ? '最早 $count 条 · 仍有更晚事件未加载' : '最早 $count 条';
    }
    if (!_eventsHasMore) return '事件（最新 $count 条）';
    final newest = _events.isEmpty
        ? null
        : (_events.last['sequence'] as num?)?.toInt();
    return '已加载至 #${newest ?? 0} · 更晚事件未加载';
  }

  /// 看板四类无内容字节（官方注释明示），不可 ArtifactRead。
  bool _artifactReadable(Map<String, dynamic> a) {
    const dashboards = {'chart', 'table', 'metrics', 'board'};
    final kind = '${a['kind'] ?? ''}';
    return kind.isEmpty || !dashboards.contains(kind);
  }

  /// 内容产物分块读取（≤512KiB/块；文本类拼到 8 块止，防超长拖垮 UI）。
  /// ：①行内 busy 防重入（此前可双击叠推两个
  /// 预览页）；②块间字节缓冲——512KiB 边界可能切在多字节字符中间，逐
  /// 块独立 decode 会各出一个替换符；③8 块截断不再静默（预览页顶部
  /// 明示"内容过长已截断"）。
  bool _artifactBusy = false;
  Future<void> _openArtifact(Map<String, dynamic> artifact) async {
    if (_artifactBusy) return;
    final app = AppStateScope.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _artifactBusy = true);
    try {
      final r = await readArtifactBlocks(
        name: '${artifact['title'] ?? artifact['id']}',
        read: ({
          required int offset,
          required int blockLimit,
        }) =>
            app.workflowRunArtifactRead(
              widget.sessionId,
              widget.runId,
              '${artifact['id']}',
              version: (artifact['version'] as num?)?.toInt() ?? 1,
              offset: offset,
              limit: 512 * 1024,
            ),
      );
      if (r.oversized) {
        if (!mounted) return;
        messenger.showSnackBar(
          SnackBar(content: Text(tr('图片过大（超过 16MB），暂不支持预览'))),
        );
        return;
      }
      final bytes = r.bytes;
      final truncated = r.truncated;
      final isImage = r.isImage;
      if (!mounted) return;
      final name = '${artifact['title'] ?? artifact['id']}';
      if (isImage) {
        if (bytes.isEmpty) {
          messenger.showSnackBar(
            const SnackBar(content: Text('该产物没有可读的内容')),
          );
          return;
        }
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ArtifactImagePage(
              title: name,
              bytes: Uint8List.fromList(bytes),
            ),
          ),
        );
        return;
      }
      // 二进制产物（xlsx/pptx/pdf/zip 等，2026-11-14 验收：此前被当
      // 文本渲染成满屏乱码、用户以为报错）→ 体面的不支持预览页（带
      // 分享出口，bytes 完整在手）。
      if (looksBinaryContent(bytes)) {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => BinaryArtifactPage(
              title: name,
              bytes: Uint8List.fromList(bytes),
              truncated: truncated,
            ),
          ),
        );
        return;
      }
      final text = utf8.decode(bytes, allowMalformed: true);
      if (text.isEmpty) {
        messenger.showSnackBar(
          const SnackBar(content: Text('该产物没有可读的文本内容')),
        );
        return;
      }
      final displayName = truncated
          ? '$name（${tr('内容过长已截断')}）'
          : name;
      // 截断标记透传 html 预览页（A-M3/B-：半份 html 不给分享）；
      // 落盘文件名与显示标题解耦（截断标记不进文件名）。
      // 早前批次：截断的预览不是完整文件——文本页分享入口仅在
      // 未截断时给出（完整内容走产物行分享入口回源拉全量）。
      // html 嗅探正则锚定文首（此前 `|` 优先
      // 级让正文任意位置的 <html 字样也会误进 WebView）。
      if (RegExp(r'^\s*(<!doctype html|<html)', caseSensitive: false)
          .hasMatch(text)) {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => HtmlPreviewPage(
              title: displayName,
              htmlContent: text,
              truncated: truncated,
              fileName: name,
            ),
          ),
        );
      } else {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => _ArtifactTextPage(
              title: displayName,
              fileName: name,
              content: text,
              truncated: truncated,
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text('读取产物失败：$e')));
      }
    } finally {
      if (mounted) setState(() => _artifactBusy = false);
    }
  }

  /// 产物行「分享」（早前批次）：回源全量拉取（进度弹窗可取消）
  /// → 系统分享面板（方案 A：私有目录+分享，零存储权限）。独立 busy
  /// 防弹窗弹出前双击叠弹。
  bool _shareBusy = false;
  Future<void> _shareArtifact(Map<String, dynamic> artifact) async {
    if (_shareBusy) return;
    _shareBusy = true;
    try {
      final app = AppStateScope.of(context);
      await shareArtifactRemotely(
        context,
        displayName: '${artifact['title'] ?? artifact['id']}',
        read: (offset) => app.workflowRunArtifactRead(
          widget.sessionId,
          widget.runId,
          '${artifact['id']}',
          version: (artifact['version'] as num?)?.toInt() ?? 1,
          offset: offset,
          limit: kArtifactShareBlockBytes,
        ),
      );
    } finally {
      _shareBusy = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.colors.background,
      appBar: AppBar(
        backgroundColor: context.colors.background,
        surfaceTintColor: Colors.transparent,
        title: Text(widget.title, translate: false, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: _loading
          ? const Center(child: AppLoading('正在加载…'))
          : _error != null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    tr('加载失败：') + _error!,
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
          : ListView(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
              children: [
                if (_events.isNotEmpty) ...[
                  Text(
                    _eventsTitle,
                    style: TextStyle(
                      fontSize: AppType.uiSm,
                      fontWeight: FontWeight.w600,
                      color: context.colors.foregroundSubtle,
                    ),
                  ),
                  const SizedBox(height: 6),
                  for (final e in _events.reversed)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '#${e['sequence']}',
                            style: TextStyle(
                              fontSize: AppType.uiXs,
                              fontFamily: 'monospace',
                              color: context.colors.foregroundSubtlest,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '${e['type']}'
                              '${e['truncated'] == true ? tr('（已截断）') : ''}',
                              style: const TextStyle(
                                fontSize: AppType.uiCaption,
                                fontFamily: 'monospace',
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  // 未追平：手动续页（失败内联，不顶掉已在屏时间线）。
                  if (_eventsMoreError != null)
                    Padding(
                      key: const ValueKey('workflow-events-more-error'),
                      padding: const EdgeInsets.only(top: 2),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              '加载更多失败：$_eventsMoreError',
                              style: TextStyle(
                                fontSize: AppType.uiXs,
                                color: context.colors.destructive,
                              ),
                            ),
                          ),
                          TextButton(
                            onPressed: _eventsBusy ? null : _loadMoreEvents,
                            child: Text(tr('重试')),
                          ),
                        ],
                      ),
                    ),
                  if (_eventsHasMore)
                    Center(
                      child: TextButton(
                        key: const ValueKey('workflow-events-load-more'),
                        onPressed: _eventsBusy ? null : _loadMoreEvents,
                        child: Text(_eventsBusy ? '加载中…' : '加载更多'),
                      ),
                    ),
                ],
                if (_artifacts.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(
                    '产物（${_artifacts.length}）',
                    style: TextStyle(
                      fontSize: AppType.uiSm,
                      fontWeight: FontWeight.w600,
                      color: context.colors.foregroundSubtle,
                    ),
                  ),
                  const SizedBox(height: 6),
                  // （视觉走查）：产物卡此前零间距叠放+行高
                  // 39.7（低于 44 触控/可读下限），两张卡像一整块。
                  // 修=相邻卡 6dp 间距 + 卡内容 minHeight 44（行高抬到
                  // ≥44，图标/字号不变）。
                  for (var ai = 0; ai < _artifacts.length; ai++)
                    Padding(
                      padding: EdgeInsets.only(top: ai == 0 ? 0 : 6),
                      child: Builder(builder: (_) {
                        final a = _artifacts[ai];
                        return Material(
                          color: context.colors.card,
                          borderRadius: BorderRadius.circular(AppRadius.sm),
                          child: InkWell(
                            key: ValueKey('workflow-artifact-${a['id']}'),
                            borderRadius: BorderRadius.circular(AppRadius.sm),
                            // A 批（2026-11-08 拍板⑥）：内容产物=分块字节读取；
                            // 看板四类（chart/table/metrics/board）=数据页渲染
                            //（workflowRunArtifactData + spec 宽松解析）。
                            onTap: _artifactReadable(a)
                                ? () => _openArtifact(a)
                                : () => Navigator.of(context).push(
                                      MaterialPageRoute(
                                        builder: (_) => WorkflowDashboardPage(
                                          sessionId: widget.sessionId,
                                          runId: widget.runId,
                                          artifact: a,
                                        ),
                                      ),
                                    ),
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(minHeight: 44),
                              child: Padding(
                                // 行垂直 padding 归零（视觉走查 artifact-
                                // share-1：分享按钮 44dp 盒若叠加 10dp
                                // padding 会把卡撑到 60dp、同列表行高不一；
                                // 文本行由 minHeight 44 兜底居中，观感不变）。
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                ),
                                child: Row(
                                  children: [
                                    Icon(
                                      Icons.description_outlined,
                                      size: 16,
                                      color: context.colors.foregroundSubtle,
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        '${a['title'] ?? a['id']}',
                                        translate: false,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontSize: AppType.uiCaption,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                    ),
                                    // 分享入口（早前批次）：仅内容
                                    // 产物——看板四类无内容字节可下。M3 默认
                                    // 盒 40×40 须显式收缩到 44dp 且 shrinkWrap
                                    // （constraints 参数在 M3 下不生效——
                                    // 视觉走查像素实证）。
                                    if (_artifactReadable(a))
                                      IconButton(
                                        key: ValueKey(
                                          'workflow-artifact-share-${a['id']}',
                                        ),
                                        icon: const Icon(Icons.ios_share,
                                            size: 18),
                                        tooltip: tr('分享'),
                                        style: IconButton.styleFrom(
                                          minimumSize: const Size(44, 44),
                                          padding: EdgeInsets.zero,
                                          tapTargetSize:
                                              MaterialTapTargetSize.shrinkWrap,
                                        ),
                                        onPressed: () => _shareArtifact(a),
                                      ),
                                    Text(
                                      '${a['kind']} · v${a['version'] ?? 1}',
                                      style: TextStyle(
                                        fontSize: AppType.uiXs,
                                        color:
                                            context.colors.foregroundSubtlest,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                      }),
                    ),
                ],
                if (_events.isEmpty && _artifacts.isEmpty)
                  Center(
                    child: Text(
                      '该运行没有事件与产物记录',
                      style: TextStyle(
                        fontSize: AppType.uiCaption,
                        color: context.colors.foregroundSubtle,
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}

/// 简单文本产物页（等宽只读）。[truncated]=内容超出 8 块预览上限被
/// 截断——此时不给分享入口（半份内容不是完整文件，要分享走产物行
/// 回源全量；早前批次）。
class _ArtifactTextPage extends StatelessWidget {
  final String title;
  final String fileName;
  final String content;
  final bool truncated;
  const _ArtifactTextPage({
    required this.title,
    required this.fileName,
    required this.content,
    this.truncated = false,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.colors.background,
      appBar: AppBar(
        backgroundColor: context.colors.background,
        surfaceTintColor: Colors.transparent,
        title: Text(title, translate: false, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          if (!truncated)
            IconButton(
              key: const ValueKey('artifact-text-share'),
              icon: const Icon(Icons.ios_share, size: 20),
              tooltip: tr('分享'),
              onPressed: () =>
                  shareBytesAsFile(context, fileName, utf8.encode(content)),
            ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: SelectableText(
          content,
          style: const TextStyle(
            fontSize: AppType.uiCaption,
            fontFamily: 'monospace',
            height: 1.5,
          ),
        ),
      ),
    );
  }
}

/// 图片产物预览页：入口已限 16MiB；解码降采样 2048px
/// 防大图位图尖峰；双指缩放平移；解码期 spinner 占位（大图分块读+解码
/// 有可感窗口，不留空白画布）；图片套 1px borderFaint 防白底产物与画布
/// 零边界；解码失败人话降级（SVG 被扩展名拦在入口，此处兜底罕见格式与
/// 损坏数据）。AppBar 走全库标准（实体面+1px hairline）。
class ArtifactImagePage extends StatelessWidget {
  final String title;
  final Uint8List bytes;

  const ArtifactImagePage({super.key, required this.title, required this.bytes});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.colors.background,
      appBar: AppBar(
        title: Text(
          title,
          translate: false,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        // 入口已限 16MiB 且超限被拦——bytes 即完整文件，直分享。
        actions: [
          IconButton(
            key: const ValueKey('artifact-image-share'),
            icon: const Icon(Icons.ios_share, size: 20),
            tooltip: tr('分享'),
            onPressed: () => shareBytesAsFile(context, title, bytes),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: context.colors.border),
        ),
      ),
      body: InteractiveViewer(
        maxScale: 8,
        child: Center(
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadius.sm),
              border: Border.all(color: context.colors.borderFaint),
            ),
            padding: const EdgeInsets.all(2),
            child: Image.memory(
              bytes,
              cacheWidth: 2048,
              fit: BoxFit.contain,
              frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
                if (wasSynchronouslyLoaded || frame != null) return child;
                return const SizedBox(
                  width: 56,
                  height: 56,
                  child: Center(
                    child: SizedBox(
                      width: 28,
                      height: 28,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                );
              },
              errorBuilder: (context, error, stackTrace) => Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  tr('图片解码失败：该格式不受支持'),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: AppType.uiCaption,
                    color: context.colors.foregroundSubtle,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}


// ------------------------------------------------------------ 闲时任务卡

/// OffPeakCreate 工具行输出摘要（官方 readOffPeakCreateTaskOutputSummary
/// 语义：output 可为 JSON 字符串；{task:{…}} 或平铺；缺 offPeakTaskId=
/// 无效回退普通工具行）。
class OffPeakCreateSummary {
  const OffPeakCreateSummary({
    required this.offPeakTaskId,
    this.title,
    this.status,
    this.queuePosition,
  });
  final String offPeakTaskId;
  final String? title;
  final String? status;
  final int? queuePosition;
}

OffPeakCreateSummary? offPeakCreateSummary(Map<String, dynamic> row) {
  dynamic candidate = row['output'];
  if (candidate is String) {
    try {
      candidate = jsonDecode(candidate);
    } catch (_) {
      return null;
    }
  }
  if (candidate is! Map) return null;
  final task = candidate['task'] is Map ? candidate['task']! as Map : candidate;
  final id = '${task['offPeakTaskId'] ?? ''}'.trim();
  if (id.isEmpty) return null;
  final title = '${task['title'] ?? ''}'.trim();
  final status = '${task['status'] ?? ''}'.trim();
  final pos = (task['queuePosition'] as num?)?.toInt();
  return OffPeakCreateSummary(
    offPeakTaskId: id,
    title: title.isEmpty ? null : title,
    status: status.isEmpty ? null : status,
    queuePosition: pos != null && pos > 0 ? pos : null,
  );
}

/// 闲时任务卡（官方 offpeak-create.tsx 对位：标题+「已加入闲时队列
/// （第 N 位）/已加入闲时队列 · 运行在当前会话」状态行）。
class OffPeakTaskCard extends StatelessWidget {
  final Map<String, dynamic> row;
  const OffPeakTaskCard({super.key, required this.row});

  @override
  Widget build(BuildContext context) {
    final s = offPeakCreateSummary(row);
    if (s == null) return const SizedBox.shrink();
    final queueLine = s.queuePosition != null
        ? '已加入闲时队列（第 ${s.queuePosition} 位）'
        : '已加入闲时队列';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: context.colors.card,
          borderRadius: BorderRadius.circular(AppRadius.sm),
          border: Border.all(color: context.colors.border),
        ),
        child: Row(
          children: [
            Icon(
              Icons.schedule_outlined,
              size: 18,
              color: context.colors.brandAccent,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    s.title ?? tr('闲时任务'),
                    translate: s.title == null,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: AppType.uiBase,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    // 分段本地化；协议 status token 走
                    // 五态映射（原样透传=中英界面都露协议词）。
                    '$queueLine · ${tr('运行在当前会话')}'
                    '${s.status != null ? ' · ${workflowRunStatusOf(context, s.status!).label}' : ''}',
                    style: TextStyle(
                      fontSize: AppType.uiXs,
                      color: context.colors.foregroundSubtle,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A 批（拍板⑧）+ 对抗审查返工（高③）：会话内工作流 run 卡。
/// runId/status 权威源=快照 workflowRuns 投影按 toolCallId 联接（官方
/// workflowRunCardJoin.ts:33-51——v4 工具行 output 只有散文，结构化
/// 字段不在行上）；联接不上=只显示名称不可点（官方同款：编不过的
/// CreateWorkflow 走反馈行，不出假卡）。
class WorkflowRunCard extends StatelessWidget {
  final Map<String, dynamic> row;

  /// 快照 workflowRuns 投影（页面传入；null=无投影不联接）。
  final List<Map<String, dynamic>>? runs;
  final String? sessionId;
  const WorkflowRunCard({
    super.key,
    required this.row,
    this.runs,
    this.sessionId,
  });

  static Map<String, dynamic>? _tryJson(String raw) {
    try {
      final v = jsonDecode(raw);
      return v is Map ? v.cast<String, dynamic>() : null;
    } catch (_) {
      return null;
    }
  }

  /// toolCallId 联接（官方 buildWorkflowRunByToolCallId 对位）。
  Map<String, dynamic>? _joinedRun() {
    final tcId = '${row['toolCallId'] ?? ''}';
    if (tcId.isEmpty || runs == null) return null;
    for (final r in runs!) {
      if ('${r['toolCallId'] ?? ''}' == tcId) return r;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    // 名称取值链与官方 toolCallRowAdapter 同序：结构化 input 优先（进入
    // running 即携带），inputText JSON 兜底——run 早期 inputText 未定稿
    // 时不再让名字退化成「工作流」。
    final input = toolInputArgs(row) ?? _tryJson('${row['inputText'] ?? ''}') ?? const {};
    var name = '${input['name'] ?? ''}'.trim();
    if (name.isEmpty) name = '${input['description'] ?? ''}'.trim();
    final run = _joinedRun();
    // status 只认投影（工具行 status 是 success/error 工具态，
    // 不是 run 态——混用会显示英文原词）。
    final status = '${run?['status'] ?? ''}';
    final runId = '${run?['runId'] ?? ''}';
    final live = status == 'running' || status == 'pending';
    final done = status == 'completed';
    final color = done
        ? context.colors.foregroundSubtle
        : status == 'errored'
        ? context.colors.destructive
        : live
        ? context.colors.running
        : context.colors.foregroundSubtlest;
    final statusLabel =
        status.isEmpty ? tr('工作流') : workflowRunStatusWord(status);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Container(
        key: ValueKey('workflow-run-card-${row['rowId'] ?? row['toolCallId'] ?? ''}'),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: context.colors.card,
          borderRadius: BorderRadius.circular(AppRadius.sm),
          border: Border.all(color: context.colors.border),
        ),
        child: InkWell(
          onTap: runId.isEmpty || sessionId == null
              ? null
              : () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => WorkflowRunDetailPage(
                        sessionId: sessionId!,
                        runId: runId,
                        title: name.isEmpty ? tr('工作流') : name,
                        // 入口必须传投影序号：官方 run 目录 schema 没有该
                        // 字段，详情页靠它反推「最新一页」。
                        lastEventSequence:
                            (run?['lastEventSequence'] as num?)?.toInt(),
                      ),
                    ),
                  ),
          child: Row(
            children: [
              Icon(
                Icons.account_tree_outlined,
                size: 18,
                color: live ? context.colors.running : color,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name.isEmpty ? tr('工作流') : name,
                      translate: false,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: AppType.uiBase,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      statusLabel,
                      style: TextStyle(fontSize: AppType.uiXs, color: color),
                    ),
                  ],
                ),
              ),
              if (runId.isNotEmpty && sessionId != null)
                Icon(
                  Icons.chevron_right,
                  size: 16,
                  color: context.colors.foregroundSubtlest,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 「收集产物」弹层（早前批次 定稿；早前批次 迁至产物
/// 下载页）：预设 [kCollectArtifactsPrompt] 预填、可编辑（补文件名/
/// 删减指令）后交 [onSend] 发送（返回是否受理）。
Future<bool> showCollectArtifactsPrompt(
  BuildContext context, {
  required Future<bool> Function(String text) onSend,
}) async {
  final result = await showDialog<String>(
    context: context,
    builder: (dctx) => const _CollectArtifactsDialog(),
  );
  if (result == null || result.trim().isEmpty) return false;
  return onSend(result.trim());
}

/// controller 由 State 持有——外层 await 后 dispose 会撞弹窗退场动画
///（widget 测试实证 used-after-disposed）。
class _CollectArtifactsDialog extends StatefulWidget {
  const _CollectArtifactsDialog();

  @override
  State<_CollectArtifactsDialog> createState() =>
      _CollectArtifactsDialogState();
}

class _CollectArtifactsDialogState extends State<_CollectArtifactsDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: kCollectArtifactsPrompt);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(tr('收集产物')),
      content: SizedBox(
        width: double.maxFinite,
        child: TextField(
          controller: _controller,
          key: const ValueKey('collect-artifacts-input'),
          maxLines: null,
          minLines: 5,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr('取消')),
        ),
        FilledButton(
          key: const ValueKey('collect-artifacts-send'),
          onPressed: () => Navigator.pop(context, _controller.text),
          child: Text(tr('发送')),
        ),
      ],
    );
  }
}

/// 二进制内容判定（2026-11-14 验收：xlsx/pptx/pdf 等此前被 utf8
/// allowMalformed 解码成满屏乱码、用户以为报错）。判据从严：任一 NUL
/// 字节或严格 UTF-8 解码失败即二进制——文本误判为二进制的代价=提示
/// 页（还有分享出口），二进制误判为文本的代价=乱码页，后者更伤。
bool looksBinaryContent(List<int> bytes) {
  if (bytes.isEmpty) return false;
  if (bytes.contains(0)) return true;
  try {
    utf8.decode(bytes, allowMalformed: false);
    return false;
  } catch (_) {
    return true;
  }
}

/// 二进制产物页（不支持预览的体面形态）：文件图标+文件名+大小+人话
/// 提示+AppBar 分享（bytes 完整=可直分享；截断时不给——同文本页规则）。
class BinaryArtifactPage extends StatelessWidget {
  final String title;
  final Uint8List bytes;
  final bool truncated;

  const BinaryArtifactPage({
    super.key,
    required this.title,
    required this.bytes,
    this.truncated = false,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.colors.background,
      appBar: AppBar(
        backgroundColor: context.colors.background,
        surfaceTintColor: Colors.transparent,
        title: Text(
          truncated ? '$title（${tr('内容过长已截断')}）' : title,
          translate: false,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          if (!truncated)
            IconButton(
              key: const ValueKey('artifact-binary-share'),
              icon: const Icon(Icons.ios_share, size: 20),
              tooltip: tr('分享'),
              onPressed: () => shareBytesAsFile(context, title, bytes),
            ),
        ],
      ),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.insert_drive_file_outlined,
              size: 48,
              color: context.colors.foregroundSubtle,
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                title,
                translate: false,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: AppType.uiBase,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              formatArtifactBytes(bytes.length),
              style: TextStyle(
                fontSize: AppType.uiCaption,
                color: context.colors.foregroundSubtle,
              ),
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                // 对抗审查 B-M3：截断态没有分享钮，提示不得指向它。
                truncated
                    ? tr('内容过大，仅加载了部分')
                    : tr('该格式暂不支持预览，可点右上角分享保存到手机'),
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: AppType.uiCaption,
                  color: context.colors.foregroundSubtle,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
