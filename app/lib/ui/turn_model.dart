/// Turn 分组模型（2.1 消息渲染器核心，纯数据层）：把 v4 行序列投影为
/// 渲染条目序列。
///
/// 桌面对齐基准（2026-10-16 末波重做，依据 refs/ZCode 源码规格）：
/// - wire 顺序 [turnHeader][userInput][reasoning/toolCall…][assistantText]
/// （product-projection.ts 先 append turnHeader 再 append userInput；
/// 2026-10-22 真机验收③实锤：此前误记 [userInput][turnHeader]，导致
/// userInput 处 closeTurn 清掉本轮 header，全部回合拿空 header——
/// 文案永远兜底「已处理」、运行中被判完成默认收起），turnHeader
/// 是轮次元数据（权威工时/文件摘要），**不是**显示条目；
/// - 工作条（「工作中 X」/「已工作 X」）渲染在用户消息之后、首个工作行
/// 之前——它是 agent 历史折叠区的头部（ConversationTurnGroup.tsx:775），
/// 不再位于用户消息上方（F5 真机反馈根因：旧实现 turnHeader 直接开组
/// 产生「条/消息/条」三明治）；
/// - **正文不打断工作段**（官方 splitVisualWorkSegments 实证
/// conversationTurnWorkSegments.ts:83-95：切段唯一断点是 guided 用户
/// 输入；"工具→正文→工具"同属一段一个状态条。2026-10-22 用户实锤
/// 回合分组模型修复——此前正文切段导致运行中被多条"已处理"分割、
/// 完成后不收归一条）；
/// - 每轮末尾（正文后）投一张 FileSummaryItem（turnHeader.fileChanges
/// 非空时），承载文件变更折叠卡（ConversationFileSummaryPanel 对位）。
library;

import 'dart:convert';

import '../core/l10n.dart' show tr;
import '../core/payload_guard.dart';

sealed class ChatItem {
  const ChatItem();
}

class UserItem extends ChatItem {
  final String text;

 /// 源行引用（行级操作 target 的唯一可靠来源——文本反查会在重复
 /// 文本时命中错误行， 2026-10-15 抓出的真实 bug）。
  final Map<String, dynamic> row;
  const UserItem(this.text, this.row);
}

/// 一个 turn 的工作组：header（turnHeader 行，旧会话可缺省）+ 工作行。
/// work 列表与渲染条目共享引用——占位条目先入列，后续行继续追加。
class TurnWork {
  final Map<String, dynamic>? header;
  final List<Map<String, dynamic>> work;
  final String prefixText;

 /// B9（2026-10-24 修复批）：guided 段事实定位——本段的切档触发行
 /// （guided 输入，首段为 null）与段序（官方 splitVisualWorkSegments
 /// 下标），用于按段解析工时（官方 resolveSegmentDurationMs）。
  final Map<String, dynamic>? triggerRow;
  final int segmentIndex;

  TurnWork(
    this.header, {
    this.prefixText = '',
    this.triggerRow,
    this.segmentIndex = 0,
  }) : work = [] {
    isMultiSegment = triggerRow != null;
  }

 /// 本轮是否多段（guided 切段）。首段在切段时置 true；后续段构造即
 /// true（triggerRow 非空）。多段时工时按段解析，不再读整轮 activeMs。
  bool isMultiSegment = false;

 /// 旧快照兜底（官方同款）：本段结束边界=下一段 guided 触发行的
 /// createdAt；末段为 null（退 header.endedAt）。切段时写入。
  int? nextTriggerAt;

 /// 段内「可见正文」（官方 visibleAssistantTextRow 同义：段内最后一行
 /// 非空正文）——收起态外置渲染在状态条外，收起后正文仍可见。
  Map<String, dynamic>? get visibleTextRow {
    for (final r in work.reversed) {
      if (r['kind'] != 'assistantText') continue;
      if ('${r['text'] ?? ''}'.trim().isNotEmpty) return r;
    }
    return null;
  }

 /// 生产渲染的运行态判定统一走 [stateLabel]（含 phaseRunning 承接、
 /// guided 前段语义）；本 getter 仅测试消费（钉语义，
 /// 防误用——两者对 guided 前段/空 header 行为不同）。
  bool get running {
    final state = header?['state'];
    if (state is String && state.isNotEmpty) {
 // B9：非末段（guided 前段）在运行轮中已完成——官方
 // segmentCompleted 语义（segmentIndex < len-1），不显"工作中"。
      return state == 'running' && isLastSegment;
    }
    return work.any(
      (r) =>
          r['state'] == 'streaming' ||
          r['status'] == 'running' ||
          r['status'] == 'inputStreaming' ||
          r['status'] == 'pendingApproval',
    );
  }

 /// 轮正常完成（B3：官方轮尾操作行只认 row.state==='complete'
 /// ——中断/失败轮的反馈/分支大概率被服务端 guard 拒）。
  bool get completedOk => header?['state'] == 'completedSuccess';

 /// 是否轮内最后一个工作段（B2：guided 追问一轮切多个段，
 /// 若每段都挂轮尾操作行=一轮 N 条四钮行；官方一轮只一条 action bar）。
 /// buildChatItems 在 guided 切段时把前段置 false。
  bool isLastSegment = true;

 /// 本轮发了轮尾文件卡（操作行改挂卡后——见 closeTurn 的顺序对齐）。
  bool hasSummaryCard = false;

 /// 轮级子代理配对（H12 2026-10-25，官方 conversationAssistantWork
 /// Items.ts:203-269 同构）：Agent 工具行 rowId → 配对 subagent 行；
 /// claimed=已并入合并卡的 subagent 行 rowId（渲染时撤销）。guided 切段
 /// 后各段共享同一份（配对按轮，不按段）。由 buildChatItems 尾段统一
 /// 回填，null=未配对（渲染路径各自 fail-open 双渲染）。
  Map<int, Map<String, dynamic>>? pairedSubagentByToolRowId;
  Set<int>? claimedSubagentRowIds;

 /// 整轮全部非空正文段合并（B1：官方轮尾复制=全部 text 段
 /// join("\n\n")，ConversationTurnGroup.tsx:1336——此前只复制最后一段，
 /// 多段轮丢前段；prefixText=切段继承的前序段正文）。
  String get allTextJoined {
 // B10（2026-10-29 审查）：官方轮尾复制追加
 // ExitPlanMode 的计划 markdown（ConversationTurnRow.tsx:86-110
 // + planToolCall.ts readStringField[plan,text,content]）——计划
 // 正文来自结构化 tool 行，不混入普通工具输出；已在正文段中的
 // 不重复追加。此前手机复制丢计划正文。
    final segments = [
      if (prefixText.trim().isNotEmpty) prefixText,
      for (final r in work)
        if (r['kind'] == 'assistantText' &&
            '${r['text'] ?? ''}'.trim().isNotEmpty)
          '${r['text']}',
    ];
    final included = segments.toSet();
    for (final r in work) {
      if (r['kind'] != 'toolCall' ||
          '${r['toolName'] ?? r['name'] ?? ''}' != 'ExitPlanMode') {
        continue;
      }
 // 优化批 #11：提取收敛到 extractPlanToolCallContent 单源（计划卡
 // 与轮尾复制共用；取值链扩到 output 兜底对齐官方）。
      final plan = extractPlanToolCallContent(r);
      if (plan != null && !included.contains(plan.markdown)) {
        segments.add(plan.markdown);
        included.add(plan.markdown);
      }
    }
    return segments.join('\n\n');
  }

 /// 本段对应的 workSegments 事实（官方 fact 匹配：triggerEntityId 精确
 /// 匹配优先，退段下标）。
  Map<String, dynamic>? get _segmentFact {
    final segs = header?['workSegments'];
    if (segs is! List) return null;
    final tid = '${triggerRow?['entityId'] ?? ''}';
    if (tid.isNotEmpty) {
      for (final s in segs) {
        if (s is Map && '${s['triggerEntityId'] ?? ''}' == tid) {
          return s.cast<String, dynamic>();
        }
      }
    }
    final byIndex = segmentIndex < segs.length ? segs[segmentIndex] : null;
    return byIndex is Map ? byIndex.cast<String, dynamic>() : null;
  }

 /// 段计时起点（"工作中 N 秒"实时计时的锚）：段事实 startedAt →
 /// trigger 行 createdAt → 整轮 startedAt（单段/旧数据）。
  int? get startedAtMs {
    final fact = _segmentFact;
    final fs = intOf(fact?['startedAt']);
    if (fs != null) return fs;
    final tc = intOf(triggerRow?['createdAt']);
    if (tc != null) return tc;
    return intOf(header?['startedAt']);
  }

 /// 段工时（B9：官方 resolveSegmentDurationMs 对齐）：
 /// ①段事实 activeMs → ②段事实 endedAt-startedAt → ③多段无事实退
 /// trigger 行时间边界（旧 guide 快照兜底：trigger.createdAt →
 /// nextTriggerAt/header.endedAt）→ ④单段保持整轮语义
 /// （header.activeMs → endedAt-startedAt）。运行中为 null（实时计时
 /// 由 workBarLabel 用 startedAtMs 驱动）。
  int? get activeMs {
    final fact = _segmentFact;
    if (fact != null) {
      final a = intOf(fact['activeMs']);
      if (a != null) return a;
      final fs = intOf(fact['startedAt']);
      final fe = intOf(fact['endedAt']);
      if (fs != null && fe != null && fe > fs) return fe - fs;
    }
    if (!isMultiSegment) {
      final active = intOf(header?['activeMs']);
      if (active != null) return active;
      final started = intOf(header?['startedAt']);
      final ended = intOf(header?['endedAt']);
      if (started != null && ended != null && ended > started) {
        return ended - started;
      }
      return null;
    }
    final startedAt =
        intOf(triggerRow?['createdAt']) ?? intOf(header?['startedAt']);
    final endedAt = nextTriggerAt ?? intOf(header?['endedAt']);
    if (startedAt != null && endedAt != null && endedAt > startedAt) {
      return endedAt - startedAt;
    }
    return null;
  }

  Map<String, dynamic>? get fileChanges => mapOf(header?['fileChanges']);

 /// controlOnly 轮（executionKind，设置轮/中枢直启）：官方不出工作条
 /// （conversationTurnWorkSegments.ts:44 无 workStatus），内容直出。
  bool get isControlOnly => header?['executionKind'] == 'controlOnly';

 /// 折叠覆盖键（回合快捷菜单/段头开关共用）：有头按 header rowId；
 /// 无头半截回合按尾行 rowId——与 chatItemKey 的 turn-tail 同源
 /// （多个 -1 哨兵键会让折叠状态跨回合串扰）。
 ///
 /// guided 多段（2026-11-04 用户拍板「按段独立折叠」）：同一轮的多个
 /// 工作段共享 header rowId，直接当键会让展开/收起一段连带所有段——
 /// 段号并入低位（rowId 为服务端自增，量级远小于 1e15，×1000 不溢出；
 /// -1 哨兵保持原样不参与段号，防退化键跨回合串扰）。
  int get collapseKeyId {
    final base = _collapseBaseId;
    if (base < 0) return base;
    return segmentIndex <= 0 ? base : base * 1000 + segmentIndex;
  }

  int get _collapseBaseId {
    final h = intOf(header?['rowId']);
    if (h != null) return h;
    return work.isEmpty ? -1 : (intOf(work.last['rowId']) ?? -1);
  }

 /// 轮次终态（turnHeader.state）：interrupted 的文案按官方区分
 /// editRerun（被新消息中断）/其余（已停止）。
 /// B9：运行轮中的 guided 前段按官方 segmentCompleted 语义视作已完成
 /// （不显"工作中"，工时按段）。
  String get stateLabel {
    final state = '${header?['state'] ?? ''}';
    return switch (state) {
      'running' => isLastSegment ? 'running' : 'completed',
      'completedInterrupted' =>
        '${header?['origin'] ?? ''}' == 'editRerun' ? 'interrupted' : 'stopped',
      'failed' => 'failed',
      _ => 'completed',
    };
  }

  Iterable<Map<String, dynamic>> get reasoningRows =>
      work.where((r) => r['kind'] == 'reasoning');

  Iterable<Map<String, dynamic>> get toolRows =>
      work.where((r) => r['kind'] == 'toolCall');
}

class TurnBarItem extends ChatItem {
  final TurnWork work;
  const TurnBarItem(this.work);
}

/// 轮尾文件变更卡条目（桌面 ConversationFileSummaryPanel 对位）。
class FileSummaryItem extends ChatItem {
  final Map<String, dynamic>? header;

 /// 本回合子代理行数（Paseo 参考 2026-10-23：轮尾汇总含「N 个子代理」
 /// 胶囊——官方轮尾卡无此字段，裁量项；子代理行本体仍逐行渲染）。
  final int subagentCount;

 /// 轮尾操作行数据（2026-10-24 用户验收：操作行与文件卡间距过远且
 /// sandwich 顺序怪——对齐官方 deferAssistantActions 顺序：文件卡在
 /// 前、动作行在卡后。发卡轮的操作行由卡尾渲染；非空=轮正常完成且
 /// 为末段（收起态正文后不再重复挂载）。
  final Map<String, dynamic>? tailRow;
  final String? tailCopyText;

  FileSummaryItem(
    this.header, {
    this.subagentCount = 0,
    this.tailRow,
    this.tailCopyText,
  });

  Map<String, dynamic>? get fileChanges => mapOf(header?['fileChanges']);

 /// controlOnly 轮（executionKind，设置轮/中枢直启）：官方不出工作条
 /// （conversationTurnWorkSegments.ts:44 无 workStatus），内容直出。
  bool get isControlOnly => header?['executionKind'] == 'controlOnly';
}

/// parity（2026-10-17 refs 实证）：服务端 timelineMarker 行——官方
/// MarkerDividerRow 渲染为"─ 图标 文案 ─"分隔线。modelChange 变体：
/// "模型已切换 X(套餐) → Y(套餐)" / 首轮 "正在使用 X(套餐)"。
class TimelineMarkerItem extends ChatItem {
  final String label;
  final Map<String, dynamic> row;

 /// B11：运行中标记（压缩进行中/目标校验中）——呈现层可用细动效，
 /// 终态标记 false。
  final bool running;
  TimelineMarkerItem(this.label, this.row, {this.running = false});
}

/// timelineMarker 行 → (label, running)；null=不渲染（畸形 marker）。
/// 顶层（轮边界 lane，经 TimelineMarkerItem）与段内
/// （mid-turn assistantWork lane，经 TurnWork.work）两处渲染共用单源
/// 解析——文案/running 语义不得两份漂移。
(String, bool)? timelineMarkerLabelOf(Map<String, dynamic> row) {
  final marker = row['marker'];
  if (marker is! Map) return null;
  final type = '${marker['type'] ?? ''}';
 // B11（2026-10-29 审查）：官方渲染 compact /
 // forkNotice / goalVerify / modelChange 四类分隔线
 // （ConversationRowView.tsx:1926-2035）——此前只解析 modelChange，
 // 压缩/分支来源/目标校验标记静默丢弃。
  String? label;
  var running = false;
 // 官方 planLabel：codingPlan=个人套餐/startPlan=体验套餐/teamPlan=团队
 // 套餐。我们拿不到 plan 维度时退化为纯模型名（provider 与套餐不混写）。
  String modelLabelOf(Map m) {
    return '${m['toModel'] ?? ''}';
  }

  if (type == 'modelChange') {
    final to = modelLabelOf(marker);
    final fromName = '${marker['fromModel'] ?? ''}';
    label = to.isEmpty
        ? null
        : (fromName.isEmpty ? '正在使用 $to' : '模型已切换 $fromName → $to');
  } else if (type == 'compact') {
    final status = '${marker['status'] ?? ''}';
    final auto = '${marker['origin'] ?? ''}' == 'auto';
 // compact-command-1：文案对齐官方 zh-CN（contextCompaction.*
 // started=正在压缩上下文/skipped=已是最新/completedAuto=已自动
 // 压缩/completed=已压缩）。
    label = switch (status) {
      'running' => '正在压缩上下文',
      'noop' => '上下文已是最新，无需压缩',
      'cancelled' => '上下文压缩已中断',
      'failed' => '上下文压缩失败',
      _ => auto ? '上下文已自动压缩' : '上下文已压缩',
    };
    running = status == 'running';
  } else if (type == 'forkNotice') {
    label = '本会话由分支创建';
  } else if (type == 'goalVerify') {
    final n = intOrZero(marker['iteration']);
    final outcome = '${marker['outcome'] ?? ''}';
 // 官方 zh-CN 原文两句；n 缺省
 //（<=0）不再拼「第 0 次迭代」。
    final status = outcome == 'running'
        ? '目标校验中'
        : outcome == 'pass'
        ? '目标已完成，任务结束'
        : '目标未完成，任务继续';
    label = n > 0 ? '第 $n 次迭代 · $status' : status;
    running = outcome == 'running';
  }
  if (label == null) return null;
  return (label, running);
}

/// 列表定位与搜索共用的稳定条目键，禁止两处各拼一套导致锚点漂移。
/// 锚键前插迁移（2026-10-29 跳转根因修复的收口半步）：无头半截回合
/// 按尾行建键（'turn-tail-{rowId}'），其头部行随更早历史到达后键切换
/// 为 'turn-h{headerRowId}'（一次性、窗口状态固有）。此函数在锚键未
/// 命中时按尾行号在新条目集里找回该回合（尾行必仍在该回合 work 内），
/// 返回迁移后的索引；找不到返回 -1。
int migrateAnchorIndexAfterPrepend(String key, List<ChatItem> items) {
  if (!key.startsWith('turn-tail-')) return -1;
  final tailId = int.tryParse(key.substring('turn-tail-'.length));
  if (tailId == null) return -1;
  for (var i = 0; i < items.length; i++) {
    final item = items[i];
    if (item is TurnBarItem &&
        item.work.work.any((r) => intOf(r['rowId']) == tailId)) {
      return i;
    }
  }
  return -1;
}

/// 条目 key（列表锚定+搜索定位共用——/0059）。
///
/// 稳定性铁律（2026-10-29 真机"上滑跳转/入页闪动"根因修复）：
/// - TurnBarItem 此前用 `header ?? index`+`work.first`——窗口起点的
/// 半截回合（头部行未载入，header=null）在加载更早补齐头部/更早
/// 工作行后 key 变化：条目重挂=闪动；若恰为锚定 center 条目则
/// 锚丢失→整列跳到新最老条目=大跳转。
/// - 现方案：有头回合按头行 rowId（回合唯一，前后插均不变）；无头
/// 半截回合按**尾行** rowId（只存在于窗口老边、只向上生长——prepend
/// 不改尾行；新回合必带头行故不与流式 append 相互作用）。index 兜底
/// 全部移除（index 参与 key=前插必变）。
/// - A1-/：协议保证 rowId 在场，但防御路径一旦
/// 走到（畸形帧缺 rowId），'row-null' 类兜底会产出重复键（debug 抛
/// Duplicate keys、release 元素错配）——异常分支掺入 index 保唯一
/// （正常行零变化，前插稳定性不受影响）。
String chatItemKey(ChatItem item, int index) => switch (item) {
  UserItem(:final row) => _rowKeyOf(row, index),
  TimelineMarkerItem(:final row) => _rowKeyOf(row, index),
  FileSummaryItem(:final header) => header == null
      ? 'fcard-null-$index'
      : _rowKeyOf(header, index).replaceFirst('row-', 'fcard-'),
  TurnBarItem() => () {
    final headerRowId = intOf(item.work.header?['rowId']);
    if (headerRowId != null) {
 // guided 多段回合共享同轮 header rowId——键只
 // 用 header 会碰撞（debug 抛 Duplicate keys、release 元素错配）。
 // 段序轮内单调且不随前插漂移（a78941e 键稳定语义保持）。
      final seg = item.work.segmentIndex;
      return seg == 0 ? 'turn-h$headerRowId' : 'turn-h$headerRowId-seg$seg';
    }
    final tail = item.work.work.isEmpty
        ? null
        : intOf(item.work.work.last['rowId']);
    return tail != null
        ? 'turn-tail-$tail'
        : 'turn-tail-null-$index-${item.work.segmentIndex}';
  }(),
};

String _rowKeyOf(Map<String, dynamic> row, int index) {
 // （D-8 ）：String 数字容忍——退化到 row-null-$index 会在
 // 前插历史时变键（a78941e 修掉的跳转/锚点丢失同类症状）。
  final id = intOf(row['rowId']);
  return id != null ? 'row-$id' : 'row-null-$index';
}

/// 按码元截断并避开代理对劈开（72/60 字截断下刀在
/// emoji/生僻字中间会渲染 replacement 字形——截点落在前导代理上时
/// 回退一位）。
String clipTailSafe(String s, int max) {
  if (s.length <= max) return s;
  var end = max;
  if (end > 0 && _isLeadSurrogate(s.codeUnitAt(end - 1))) end -= 1;
  return '${s.substring(0, end)}…';
}

/// 截头版（保尾摘要：`…` + 尾段）——截点落在前导代理上时前进一位
/// （首码元是尾随代理=代理对被劈开）。
String clipHeadSafe(String s, int max) {
  if (s.length <= max) return s;
  var start = s.length - max;
  if (start < s.length && _isTrailSurrogate(s.codeUnitAt(start))) start += 1;
  return '…${s.substring(start)}';
}

bool _isLeadSurrogate(int cu) => cu >= 0xD800 && cu <= 0xDBFF;
bool _isTrailSurrogate(int cu) => cu >= 0xDC00 && cu <= 0xDFFF;

/// 行序列 → 渲染条目序列（纯函数）。
/// 数字/Map 字段守卫读取统一走 core/payload_guard（批C 组3
/// 铺满：zod 保证 number，但服务端形态漂移（String 数字）会打断整页
/// build（release=灰屏）——畸形形态安全兜底，正常路径零变化）。

/// 长度稳定的大小写折叠（三路）：
/// Dart 的 toLowerCase() 遵循 Unicode 全映射，U+0130（İ）等字符会
/// 扩长（1 码元 → 'i'+U+0307 共 2 个码元）——折叠串下标无法映射回
/// 原串，用它切片原串会错位甚至 RangeError（搜索高亮在 build 期崩
/// 溃、snippet 越界）。本函数保证折叠串与原串逐码元等长：先走快路
/// 径（整串折叠等长直接复用），漂移时逐码元折叠取首码元（İ→i，尾
/// 随 combining mark 丢弃），匹配语义保持「大小写不敏感」主旨且
/// 命中下标恒在原串坐标系。搜索索引（conversation_search）与高亮
/// （buildSearchHighlightSpans）共用单源。
String foldCaseStable(String s) {
  final folded = s.toLowerCase();
  if (folded.length == s.length) return folded;
  final buf = StringBuffer();
  for (final cu in s.codeUnits) {
    final lower = String.fromCharCode(cu).toLowerCase();
    buf.writeCharCode(lower.isEmpty ? cu : lower.codeUnitAt(0));
  }
  return buf.toString();
}
List<ChatItem> buildChatItems(List<Map<String, dynamic>> rows) {
  final items = <ChatItem>[];
  TurnWork? open;

 /// 轮级正文累积（guided 切段继承——轮尾复制=整轮合并，B1）。
  String turnTextCarry = '';

 /// 当前用户消息所属轮的 header（wire 上 turnHeader 先于 userInput 到达）。
  Map<String, dynamic>? turnHeader;

 /// B9（2026-10-24 修复批）：当前段下一段 guided 触发行与段序——
 /// 新段构造时带入（首段 trigger=null/index=0），新轮到达时复位。
  Map<String, dynamic>? guidedTriggerRow;
  int guidedSegmentIndex = 0;

 /// 轮级子代理计数（旧实现只数 closeTurn 时刻
 /// open 里的末段——guided 多段轮的前段子代理行漏计，「N 个子代理」
 /// 胶囊偏小；配对聚合本就按轮，计数同口径）。
  var turnSubagentCount = 0;

  void closeTurn() {
    final lastSeg = open;
    final subagents = turnSubagentCount;
    open = null;
 // 轮结束：轮尾文件变更卡（桌面=最终正文之后的内联折叠卡）。
 // 数字守卫（B2 首立，批C 组3 铺满）：fileChanges
 // 自身与 files 计数都过守卫——String/非 Map 形态漂移不再打断 build。
    final files = intOrZero(mapOf(turnHeader?['fileChanges'])?['files']);
    final hasEntity = '${turnHeader?['entityId'] ?? ''}'.trim().isNotEmpty;
 // H1（审计）：fileChanges/rewind 的 target 必须带 entityId（官方
 // ConversationFileSummaryPanel 在缺失时直接不渲染入口）。
 // 子代理胶囊挂本卡（B6）：只读不改文件的轮（files==0
 // 但 subagents>0）也发卡——胶囊不得随文件数消失。
    if (turnHeader != null && (files > 0 || subagents > 0) && hasEntity) {
 // 操作行随卡（2026-10-24 用户验收：对齐官方 deferAssistantActions
 // 顺序——文件卡在前、动作行紧随卡后，消除"正文→按钮→卡"sandwich
 // 与过大间距；仅正常完成轮的末段携带）。
      final ok =
          lastSeg != null && lastSeg.completedOk && lastSeg.isLastSegment;
      if (ok) lastSeg.hasSummaryCard = true;
      items.add(
        FileSummaryItem(
          turnHeader,
          subagentCount: subagents,
          tailRow: ok ? lastSeg.visibleTextRow : null,
          tailCopyText: ok ? lastSeg.allTextJoined : null,
        ),
      );
    }
    turnHeader = null;
    turnTextCarry = '';
    guidedTriggerRow = null;
    guidedSegmentIndex = 0;
    turnSubagentCount = 0;
  }

  for (final row in rows) {
    switch (row['kind']) {
      case 'timelineMarker':
        final parsed = timelineMarkerLabelOf(row);
        if (parsed == null) break;
        final (label, running) = parsed;
 // （lane 语义，官方 product-projection.ts:4943-4945/
 // 5015）：compact=assistantWork——「归属：marker 落在事件到达时的
 // 行尾，客户端零归属逻辑」。auto-compact 在回合进行中插入时，
 // marker 行按 row.appended 落在 turnHeader 与后续工作行之间——
 // 此前一律 closeTurn 会把运行中轮劈成两半（文件卡提前投出、后续
 // 工作行成无头段假「已处理」）。assistantWork lane 且当前轮开着
 // 时 marker 落进当前回合内部（段内行，渲染层画内嵌标记线）；
 // goalVerify=turnTailBoundary、modelChange/forkNotice=
 // lightBoundary=轮边界，维持关轮+顶层分隔线；无头兜底（marker
 // 先于 header 的异常序/旧快照缺 lane）维持现行为。
        final lane = '${row['lane'] ?? ''}';
        if (lane == 'assistantWork' && open != null) {
          open!.work.add(row);
        } else {
          closeTurn();
          items.add(TimelineMarkerItem(label, row, running: running));
        }
      case 'userInput':
 // 官方切段规则（splitVisualWorkSegments:83-95）：guided 输入切
 // 独立工作段（共享同轮 header，不发轮尾文件卡）。
 // 普通 userInput 不在这里关轮：wire 上本轮 turnHeader 先于
 // userInput 到达（product-projection.ts 先 append header 再
 // append input），此刻 turnHeader 已是本轮的——在这里清掉会让
 // 全部回合拿空 header（真机实锤"已处理"+运行中被判完成默认
 // 收起，2026-10-22 验收③）；上一轮在下一个 turnHeader 到达时关。
        if (row['guided'] == true && open != null) {
 // guided 切段（B1/B2）：前段不是轮尾段；前段正文
 // 计入轮级累积，新段继承（轮尾复制=整轮合并口径）。
          open!.isLastSegment = false;
 // B9：前段进入多段口径（工时按段）；结束边界=本触发行
 // createdAt（旧快照无 workSegments 事实时的兜底边界）。
          open!.isMultiSegment = true;
          open!.nextTriggerAt = intOf(row['createdAt']);
          final carried = open!.allTextJoined;
          turnTextCarry = carried.isEmpty ? turnTextCarry : carried;
          open = null;
          guidedTriggerRow = row;
          guidedSegmentIndex += 1;
        } else if (turnHeader == null && open != null) {
 // 异常数据兜底：未见本轮 header（分页窗口起点/缺行）且上一段
 // 还开着——在用户消息处收口，防止上一段的行吞掉本轮工作行。
          closeTurn();
        }
        items.add(UserItem('${row['text'] ?? ''}', row));
      case 'turnHeader':
 // 新轮开始：关上一轮（发其文件卡）再挂本轮 header。
        closeTurn();
        turnHeader = row;
      case 'reasoning':
      case 'toolCall':
      case 'subagent':
 // B4：artifact 行（动态工作流产物，rows.ts:250-261）
 // 此前落 default 静默丢弃——进工作段按通用行渲染（displayName
 // 由渲染层映射），不再不可见。
      case 'artifact':
 // 收敛（2026-10-22，官方 isVisibleAssistantWorkRow +
 // shouldDeferUnclassifiedShellToolCall）：空终态思考行不渲染
 // （首个 delta 前的流式空行同略）；EnterPlanMode 是内部模式切换
 // 边界不算工具；shell 命令参数还没流出（inputText 空）时整行
 // 延后出现，消除空预览行闪现。
        if (row['kind'] == 'reasoning' &&
            row['state'] != 'streaming' &&
            '${row['text'] ?? ''}'.trim().isEmpty) {
          break;
        }
        if (row['kind'] == 'toolCall') {
          if ('${row['toolName'] ?? row['name'] ?? ''}' == 'EnterPlanMode') {
            break;
          }
          final status = '${row['status'] ?? ''}';
          if ('${row['toolName'] ?? ''}' == 'Bash' &&
              '${row['inputText'] ?? ''}'.trim().isEmpty &&
              const [
                'running',
                'inputStreaming',
                'pending',
                'waiting',
              ].contains(status)) {
            break;
          }
        }
        if (open == null) {
 // 工作条 = agent 段头部（用户消息之后、首个工作行之前）。
          open = TurnWork(
            turnHeader,
            prefixText: turnTextCarry,
            triggerRow: guidedTriggerRow,
            segmentIndex: guidedSegmentIndex,
          );
          items.add(TurnBarItem(open!));
        }
        open!.work.add(row);
        if (row['kind'] == 'subagent') turnSubagentCount += 1;
      case 'assistantText':
 // 官方语义：正文不打断工作段——正文行按时间序进段；收起态只
 // 外置「可见正文」（TurnWork.visibleTextRow，条外仍可见）。
        final text = '${row['text'] ?? ''}';
        final streaming = row['state'] == 'streaming';
        if (text.isEmpty && !streaming) break;
        if (open == null) {
          open = TurnWork(
            turnHeader,
            prefixText: turnTextCarry,
            triggerRow: guidedTriggerRow,
            segmentIndex: guidedSegmentIndex,
          );
          items.add(TurnBarItem(open!));
        }
        open!.work.add(row);
      default:
        break;
    }
  }
  closeTurn();
  pairSubagentRowsForTurnItems(items);
  return items;
}

/// 轮级子代理配对（H12 2026-10-25，官方 pairSubagentRows 同构）：
/// Agent/Task/subagent 工具行 × subagent 行按 parentToolCallId 精确配对
/// （同一 spawn 的两条 wire 行），合并卡渲染在工具行原位置、后置
/// subagent 行撤销。与官方逐条对齐：
/// - 配对按**轮**（guided 切段共享 header——段间也会配对，修复"Agent
/// 在段一、subagent 在段二仍双渲染"）；
/// - 历史兜底=轮内未配对 Agent 与无 parentToolCallId 的 subagent 各剩
/// 恰好一条才配（多对多保双渲染，宁重复不张冠李戴）；
/// - rowId 缺失（-1 哨兵，协议异常防御路径）不参与配对——不让哨兵
/// 误吞多行。
void pairSubagentRowsForTurnItems(List<ChatItem> items) {
  const agentToolNames = {'agent', 'task', 'subagent'};
  int rowIdOf(Map<String, dynamic> r) => intOf(r['rowId']) ?? -1;

 // 按 header 实例分组=同一轮（guided 段共享同一 header Map）。
  final turns = <Map, List<TurnWork>>{};
  for (final item in items) {
    if (item is! TurnBarItem) continue;
    final header = item.work.header;
    if (header == null) continue; // 异常数据兜底轮：不配对（fail-open）
    turns.putIfAbsent(header, () => []).add(item.work);
  }
  for (final works in turns.values) {
    final agentToolByCallId = <String, Map<String, dynamic>>{};
    final agentTools = <Map<String, dynamic>>[];
    final subs = <Map<String, dynamic>>[];
    final legacySubs = <Map<String, dynamic>>[];
    for (final w in works) {
      for (final row in w.work) {
        if (row['kind'] == 'toolCall') {
          if (!agentToolNames.contains(
            '${row['toolName'] ?? row['name'] ?? ''}'.toLowerCase(),
          )) {
            continue;
          }
          if (rowIdOf(row) < 0) continue; // -1 哨兵不参与
          agentTools.add(row);
          agentToolByCallId['${row['toolCallId'] ?? ''}'] = row;
        } else if (row['kind'] == 'subagent') {
          if (rowIdOf(row) < 0) continue;
          if ('${row['parentToolCallId'] ?? ''}'.trim().isNotEmpty) {
            subs.add(row);
          } else {
            legacySubs.add(row);
          }
        }
      }
    }
    final paired = <int, Map<String, dynamic>>{};
    final claimed = <int>{};
    for (final s in subs) {
      final host = agentToolByCallId['${s['parentToolCallId'] ?? ''}'];
      if (host != null && !paired.containsKey(rowIdOf(host))) {
        paired[rowIdOf(host)] = s;
        claimed.add(rowIdOf(s));
      }
    }
 // 历史兜底：轮内双方各剩恰好一条才配。
    final remTools = agentTools
        .where((t) => !paired.containsKey(rowIdOf(t)))
        .toList();
    final remSubs = legacySubs
        .where((s) => !claimed.contains(rowIdOf(s)))
        .toList();
    if (remTools.length == 1 && remSubs.length == 1) {
      paired[rowIdOf(remTools.first)] = remSubs.first;
      claimed.add(rowIdOf(remSubs.first));
    }
    if (paired.isEmpty) continue;
    for (final w in works) {
      w.pairedSubagentByToolRowId = paired;
      w.claimedSubagentRowIds = claimed;
    }
  }
}

/// 「已工作 X 分 Y 秒」格式（官方 workDuration.ts 对齐：秒四舍五入、
/// 至少 1 秒；只写非零单位；最多两段——有时+分时不再写秒；空格分隔）。
String formatWorkDuration(int ms) {
  var s = (ms / 1000).round();
  if (s < 1) s = 1;
  if (s < 60) return '$s 秒';
  final m = s ~/ 60;
  final remS = s % 60;
  if (m < 60) return remS == 0 ? '$m 分' : '$m 分 $remS 秒';
  final h = m ~/ 60;
  final remM = m % 60;
  if (h < 24) return remM == 0 ? '$h 时' : '$h 时 $remM 分';
  final d = h ~/ 24;
  final remH = h % 24;
  return remH == 0 ? '$d 天' : '$d 天 $remH 时';
}

/// 工作条标签（官方三态 + 中断两态；纯函数供 _TurnBar 与单测共用）。
/// [nowMs] 供测试注入；运行中用 startedAt 实时计时。
String workBarLabel(TurnWork work, {int? nowMs}) {
  switch (work.stateLabel) {
    case 'running':
      final started = work.startedAtMs;
      if (started == null) return '工作中';
      final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
      final elapsed = now - started;
 // B2（pattern 占位不递归 tr 同根因）：时长片段拼接前先
 // tr（'3 分 20 秒'→'3m 20s'），整串再由官方 pattern 译出
 // 'Working for 3m 20s'。
      return '工作中 ${elapsed > 0 ? tr(formatWorkDuration(elapsed)) : tr('1 秒')}';
    case 'interrupted':
 // B 保留（2026-10-22 勘误）：官方此文案专属 bot 群投递的
 // newMessage 中断；我方借用于 editRerun——编辑重发确实是被新消息
 // 打断，信息更准，非官方同条件对齐。
      return '已被新消息中断';
    case 'stopped':
      return '已停止';
    case 'failed':
      return '失败';
    default:
      final active = work.activeMs;
      return active != null
          ? '已工作 ${tr(formatWorkDuration(active))}'
          : '已处理';
  }
}

/// ③（2026-10-20 真机二轮澄清，对齐桌面三层折叠语义）：
/// L1 完成后收起为「已工作 X 分 X 秒」；L2 展开显示每个子步骤的
/// 一行摘要（工具卡/思考条均为收起态）；L3 点具体步骤展开其细节。
/// **展开已工作条不受"工具调用显示"开关限制**（开关只控制运行中的
/// 实时展示）——用户显式点开=想看步骤列表，展开永远有内容；只有
/// 真正没有工作行的轮（work 为空）才不可展开。
bool turnWorkExpandable(List<Map<String, dynamic>> work) => work.isNotEmpty;

/// 思考条标签（官方 reasoning.tsx 文案；纯函数供 _ReasoningTile 与单测）。
/// [measuredMs]：流式期间客户端实测时长（2-1 修复，2026-10-22：
/// 服务端从不下发 reasoning durationMs——官方 reasoning.tsx:129-133 在
/// 完成边沿用秒表实测值定稿；此前我方测到的值被整体丢弃退化「几秒」）。
/// 优先级：服务端 durationMs（预留）> measuredMs > 「几秒」兜底。
String reasoningLabel({
  required bool streaming,
  required bool expanded,
  int? durationMs,
  int? measuredMs,
  DateTime? firstSeen,
  DateTime? now,
}) {
  if (streaming && !expanded) return '正在思考';
  if (streaming) {
    final n = now ?? DateTime.now();
    final elapsed = firstSeen == null
        ? null
        : n.difference(firstSeen).inMilliseconds;
 // 时长片段拼接前先 tr（'思考 · ' 前缀无整键无
 // pattern，占位也不递归——预译片段后整串走 custom pattern）。
    return '思考 · 持续了 '
        '${elapsed != null && elapsed > 0 ? tr(formatWorkDuration(elapsed)) : tr('几秒')}';
  }
  final total = durationMs ?? measuredMs;
  return total != null
      ? '思考 · 持续了 ${tr(formatWorkDuration(total))}'
      : '思考 · 持续了几秒';
}

/// 工具行状态词（官方词表 + 回合终态兜底；纯函数供 _ToolCallTile 与单测）。
String toolStatusLabel(String rawStatus, {required bool turnRunning}) {
  var status = rawStatus;
  if (!turnRunning &&
      const [
        'running',
        'inputStreaming',
        'pending',
        'waiting',
      ].contains(status)) {
    status = 'cancelled'; // 盲审 #11：服务端未补终态时渲染层兜底
  }
  return switch (status) {
 // 官方词表（toolCallRowAdapter pending + zh-CN 5567）：参数流式
 // 写入中=「等待中」，仅真正开始执行才是「执行中」。
    'pending' || 'waiting' || 'inputStreaming' => '等待中',
    'running' => '执行中',
    'pendingApproval' => '等待确认',
    'error' => '执行失败',
    'rejected' => '已拒绝',
    'cancelled' => '已停止',
    _ => '已执行',
  };
}

/// V2 折叠策略（2026-10-22 审美优化轮，官方行为补交付，评审 2.6a）：
/// 总原则——运行中=进度可见但不刷屏；完成=收；异常=展；**用户手动
/// 交互优先于一切自动行为**（官方 userInteracted 锁语义）。

/// 工具行展开判定：手动记忆（openByRow）> 失败/被拒自动展开 > 默认收起。
/// 官方对位：命令非零退出/工具 error 默认可见错误输出（fail-closed），
/// 用户点收后 manualOpen=false 永久让位。
bool toolOpenDecision(bool? manualOpen, String statusLabel) =>
    manualOpen ?? (statusLabel == '执行失败' || statusLabel == '已拒绝');

/// 思考条完成时是否自动收起：仅用户未手动交互过才收
/// （官方 reasoning.tsx shouldAutoCollapseReasoning 的 userInteracted 锁
/// ——用户点开过的思考条，回合结束不得被自动收起）。
bool reasoningAutoCollapse({required bool userToggled}) => !userToggled;

/// 工具行摘要：名称中文化 + 输入首行预览。
String toolDisplayName(String name) => switch (name) {
  'Edit' || 'edit' => '编辑',
  'Write' || 'write' => '写入',
  'Read' || 'read' => '读取',
  'Bash' || 'bash' => '运行命令',
  'Grep' || 'grep' => '搜索',
  'Glob' || 'glob' => '查找文件',
  'WebSearch' || 'web_search' => '联网搜索',
  'WebFetch' || 'web_fetch' => '抓取网页',
  'Agent' || 'Task' || 'agent' => '子智能体',
 // B12（2026-10-24 修复批）：子代理任务输出读取工具（官方 schema
 // name=TaskOutput——此前裸名直显）。
  'TaskOutput' => '子智能体输出',
  'artifact' => '产物',
  _ => name,
};

/// 工具入参取值（对齐官方 toolCallRowAdapter.ts:36-54 的优先级）：
/// 优先 row.input（结构化入参，进入 running 的 upsert 即携带——协议
/// spec rows.ts input 字段），退 inputText+jsonDecode。注意 replayable
/// 档（手机被桌面强制）inputText 不流式增量、定稿时随 upsert 整体
/// 到达（core.ts DELIVERY_PROFILES 服务端过滤），两条路在"进入执行
/// 态"那一刻都会就绪。
Map<String, dynamic>? toolInputArgs(Map<String, dynamic> row) {
  final structured = row['input'];
  if (structured is Map) {
    return structured.cast<String, dynamic>();
  }
  final input = '${row['inputText'] ?? ''}'.trim();
  if (input.isEmpty) return null;
  try {
    final decoded = jsonDecode(input);
    return decoded is Map ? decoded.cast<String, dynamic>() : null;
  } catch (_) {
    return null;
  }
}

/// ExitPlanMode 计划正文与计划文件路径（优化批 #11，官方
/// planToolCall.ts extractPlanToolCallContent 取值链的手机版）：
/// input（plan/text/content 三键首个非空，或裸字符串）→ inputText
/// JSON 解析后同键 → output 同键；planFilePath 同源读取（官方对相对
/// 路径做 workspace join，手机渲染只用叶子名，原样透传即可）。
/// null=三路全空（流式 inputText 未就绪/失败态）——调用方回落通用
/// 工具行（官方 SwitchModeToolCallBlock 同款兜底语义）。供 _PlanModeCard
/// 与 TurnWork.allTextJoined（B10 轮尾复制）共用单源。
({String markdown, String planFilePath})? extractPlanToolCallContent(
  Map<String, dynamic> row,
) {
  String? planFilePath;
  ({String markdown, String planFilePath})? read(Object? source) {
    if (source is String) {
      final t = source.trim();
      return t.isEmpty
          ? null
          : (markdown: t, planFilePath: planFilePath ?? '');
    }
    if (source is! Map) return null;
    final p = source['planFilePath'];
    if (p is String && p.trim().isNotEmpty) planFilePath = p.trim();
    for (final k in ['plan', 'text', 'content']) {
      final v = source[k];
      if (v is String && v.trim().isNotEmpty) {
        return (markdown: v.trim(), planFilePath: planFilePath ?? '');
      }
    }
    return null;
  }

  final input = read(row['input']);
  if (input != null) return input;
  final inputText = '${row['inputText'] ?? ''}'.trim();
  if (inputText.isNotEmpty) {
    try {
      final decoded = jsonDecode(inputText);
      if (decoded is Map || decoded is String) {
        final fromText = read(decoded);
        if (fromText != null) return fromText;
      }
    } catch (_) {
 // 流式半截 JSON——官方同款静默，继续走 output 兜底。
    }
  }
  return read(row['output']);
}

/// 工具行参数预览（用户拍板 2026-10-22：不显示 {"file_path":…} 原始
/// JSON，直白可读——「读取 · G:/xxx.dart」式，同类应用同款思路）：
/// 优先把 inputText 按 JSON 参数解析，按语义取关键字段（文件路径 >
/// 命令 > 搜索词 > 查询 > 首个字符串值）；非 JSON（纯文本命令等）取
/// 首行原样。超长截断 72。inputText 未到而结构化 input 已随 running
/// upsert 到达时（replayable 档常态），预览也能立即出。
String toolPreview(Map<String, dynamic> row) {
  final input = '${row['inputText'] ?? ''}'.trim();
  if (input.isEmpty) {
    final args = toolInputArgs(row);
    return args == null ? '' : (_previewFromArgs(args, row) ?? '');
  }
  final firstLine = input.split('\n').first.trim();
 // pretty-printed JSON（含换行的工具入参）首行是
 // 孤立 "{"——首行解析失败时对全文再试一次，仍非 JSON 才按纯文本。
  String? previewOf(String candidate) {
    try {
      final decoded = jsonDecode(candidate);
      if (decoded is Map) {
        return _previewFromArgs(decoded.cast<String, dynamic>(), row);
      }
    } catch (_) {
 // 非 JSON（纯文本命令等）。
    }
    return null;
  }

  final fromFirstLine = previewOf(firstLine) ?? previewOf(input);
  if (fromFirstLine != null) return fromFirstLine;
  return clipTailSafe(firstLine, 72);
}

/// 从工具参数表提取可读预览；无命中返回 null。
String? _previewFromArgs(
  Map<String, dynamic> args,
  Map<String, dynamic> row, {
  String Function(String)? clipFn,
}) {
 // 默认截断走代理对安全版（劈开 emoji=replacement 字形）。
  String clip(String s) => clipFn?.call(s) ?? clipTailSafe(s, 72);
  String? pick(List<String> keys) {
    for (final k in keys) {
      final v = args[k];
      if (v is String && v.trim().isNotEmpty) return v.trim();
    }
    return null;
  }

 // 搜索类工具（Grep/Glob）的 path 是搜索目录不是文件——pattern
 // 语义优先（同名键不同义，按工具名消歧）。
  final name = '${row['toolName'] ?? row['name'] ?? ''}'.toLowerCase();
  if (name.contains('grep') || name.contains('glob')) {
    final pattern = pick(['pattern', 'query']);
    if (pattern != null) return clip('"$pattern"');
  }
 // 2026-11-05 反馈①：Agent 工具行预览前置子代理类型（官方
 // agentHelpers.getAgentKindLabel 三段式「子智能体 · 类型 · 描述」——
 // 此前只有「子智能体 · 描述」，类型不可见）。类型取入参
 // subagent_type/agent_type（官方解析同款键序）。
  if (name == 'agent' || name == 'task') {
    final type = pick(['subagent_type', 'agentType', 'agent_type']);
    final desc = pick(['description', 'prompt']);
    if (type != null && desc != null) return clip('$type · $desc');
    if (type != null) return clip(type);
  }
 // AskUserQuestion：参数是 questions 数组（无字符串键可取，此前
 // 落到裸 JSON 首行）——取首题问题文本。
  if (name.contains('askuserquestion')) {
    final qs = args['questions'];
    if (qs is List && qs.isNotEmpty && qs.first is Map) {
      final q = '${(qs.first as Map)['question'] ?? ''}'.trim();
      if (q.isNotEmpty) return clip(q);
    }
  }

  final file = pick([
    'file_path',
    'filePath',
    'path',
    'notebook_path',
    'absolute_path',
  ]);
  if (file != null) {
 // 3-8（2026-10-22）：文件名为主——官方 renderFileChip
 // 取叶子名、目录路径窄屏隐藏；手机常态即窄容器，全路径截断
 // 可读性差。
    final leaf = file
        .replaceAll(String.fromCharCode(92), '/')
        .split('/')
        .last
        .trim();
    return clip(leaf.isNotEmpty ? leaf : file);
  }
  final cmd = pick(['command', 'cmd', 'script', 'shellCommand']);
  if (cmd != null) return clip(cmd);
  final pattern = pick(['pattern']);
  if (pattern != null) return clip('"$pattern"');
  final query = pick(['query', 'search', 'url', 'description']);
  if (query != null) return clip(query);
  for (final v in args.values) {
    if (v is String && v.trim().isNotEmpty) return clip(v.trim());
  }
  return null;
}

/// 思考条时长：完成态用 durationMs，流式态由渲染层以本地首见时间计时。
int? reasoningDurationMs(Map<String, dynamic> row) => intOf(row['durationMs']);

/// 轮尾时间标签（优化批 #27）：今天 HH:mm、今年 M月d日、往年
/// yyyy/M/d。纯日期数字（年月日为 zh 日期书写符号，en 经 tr
/// 的日期形态自动转「Oct 5」），无新增文案。无时间戳/非法
/// 值返回 null（不显示）。[now] 供测试注入。
String? turnTailTimestampLabel(int? ms, {DateTime? now}) {
  if (ms == null || ms <= 0) return null;
  final t = DateTime.fromMillisecondsSinceEpoch(ms);
  final n = now ?? DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  final sameDay = t.year == n.year && t.month == n.month && t.day == n.day;
  if (sameDay) return '${two(t.hour)}:${two(t.minute)}';
  if (t.year == n.year) return '${t.month}月${t.day}日';
  return '${t.year}/${t.month}/${t.day}';
}

/// 轮开始时刻（轮尾时间标签数据源，优化批 #27）：协议
/// turnHeader 行基座含 createdAt（与 startedAt 同值，projection-rows.ts:74）；
/// 旧快照/测试夹具缺年旧行只剩 startedAt 时兑底，都无→ null 不显示。
int? turnHeaderCreatedAt(Map<String, dynamic>? header) {
  final created = intOf(header?['createdAt']);
  if (created != null && created > 0) return created;
  return intOf(header?['startedAt']);
}

/// 工作区渲染单元：普通行 / 连续同类工具组。
sealed class WorkUnit {}

class RowUnit extends WorkUnit {
  final Map<String, dynamic> row;
  RowUnit(this.row);
}

enum GroupFamily { explore, terminal }

class GroupUnit extends WorkUnit {
  final GroupFamily family;
  final List<Map<String, dynamic>> rows;

  GroupUnit(this.family, this.rows);

 /// 组身份锚定首行 rowId（官方 conversationAssistantWorkItems.ts:158-160
 /// 踩坑注释：身份含数量会让流式追加丢展开状态）。
  int get anchorRowId => intOf(rows.first['rowId']) ?? 0;
}

/// 官方 exploreToolCall 族分类的简化版（只读命令归查阅组暂不做——
/// 需命令语义判定，先按工具名，差异已在审查归档记录）。
GroupFamily? _toolGroupFamily(String name) {
  final n = name.toLowerCase();
  if (n == 'bash') return GroupFamily.terminal;
  if (const [
    'read',
    'grep',
    'glob',
    'websearch',
    'web_search',
    'webfetch',
    'web_fetch',
  ].contains(n)) {
    return GroupFamily.explore;
  }
  return null;
}

/// 渲染单元投影（纯函数供单测）：连续同族工具 ≥2 成组、单条保持原样。
/// 子代理合并（2026-10-25 H12，官方 conversationAssistantWorkItems
/// .ts:203-269/:316-330 对位）：配对成功的 Agent 工具行在**其原位置**渲染
/// 合并卡（SubagentPairUnit，含工具状态），后置 subagent 行撤销；未配对
/// 的工具行/subagent 行照常各渲染一次（fail-open 不丢可见性）。配对结果
/// 由轮级 [pairSubagentRowsForTurnItems] 预计算传入（guided 跨段共享）。
List<WorkUnit> buildWorkUnits(
  List<Map<String, dynamic>> rows, {
  Map<int, Map<String, dynamic>>? pairedSubagentByToolRowId,
  Set<int>? claimedSubagentRowIds,
}) {
  final units = <WorkUnit>[];
  GroupUnit? pending;
  void flush() {
    if (pending == null) return;
    if (pending!.rows.length == 1) {
      units.add(RowUnit(pending!.rows.first));
    } else {
      units.add(pending!);
    }
    pending = null;
  }

  int rowIdOf(Map<String, dynamic> r) => intOf(r['rowId']) ?? -1;

  for (final row in rows) {
    if (row['kind'] != 'toolCall') {
 // 已并入合并卡的 subagent 行：撤销（flush 保持分组边界语义——
 // 原该位置就是非工具行的边界）。
      if (row['kind'] == 'subagent' &&
          claimedSubagentRowIds?.contains(rowIdOf(row)) == true) {
        flush();
        continue;
      }
      flush();
      units.add(RowUnit(row));
      continue;
    }
    final pairedSub = pairedSubagentByToolRowId?[rowIdOf(row)];
    if (pairedSub != null) {
 // 合并卡=Agent 工具行原位置（官方 agentToolCall 项）。
      flush();
      units.add(SubagentPairUnit(row, pairedSub));
      continue;
    }
    final family = _toolGroupFamily('${row['toolName'] ?? row['name'] ?? ''}');
    if (family == null) {
      flush();
      units.add(RowUnit(row));
      continue;
    }
    if (pending != null && pending!.family != family) flush();
    pending = (pending ?? GroupUnit(family, []));
    if (!pending!.rows.any((r) => identical(r, row))) {
      pending!.rows.add(row);
    }
  }
  flush();
  return units;
}

/// 配对合并卡（H12 ）：Agent 工具行+其 subagent 行，渲染在工具行
/// 原位置（官方 agentToolCall 渲染项对位）。
class SubagentPairUnit extends WorkUnit {
  final Map<String, dynamic> toolRow;
  final Map<String, dynamic> subagentRow;
  SubagentPairUnit(this.toolRow, this.subagentRow);
}
