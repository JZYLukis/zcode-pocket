/// 协议漂移哨兵：关键载荷的**骨架字段**缺席时打一行
/// `[protocol-drift]` 日志——桌面协议变化从"静默坏"变"logcat 可见信号"。
///
/// 设计约束：只观察、不拦截——缺席字段走各消费点既有的空值容错路径
/// （本 app 的解析全部宽松），哨兵仅负责把变化暴露出来。骨架字段清单
/// 与登记义务见 。
library;

import 'package:flutter/foundation.dart';

/// 检查 [source] 是否含 [requiredKeys]；缺席的打一行漂移日志。
/// [source] 为 null 表示整个载荷/对象缺席（更严重的漂移）。
void noteProtocolDrift(
  String context,
  Map? source,
  List<String> requiredKeys, {
  void Function(String line)? onLog,
}) {
  void emit(String line) {
    debugPrint('[protocol-drift] $line');
    onLog?.call(line);
  }

  if (source == null) {
    emit('$context: 载荷/对象整体缺席');
    return;
  }
  for (final key in requiredKeys) {
    if (!source.containsKey(key)) {
      emit('$context: 字段缺席 $key');
    }
  }
}
