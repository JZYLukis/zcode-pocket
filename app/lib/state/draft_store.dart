import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// 输入草稿的唯一归属。正式会话使用 `session:<id>`；新建草稿使用
/// `draft:<projectId>`，并始终带电脑、账号和工作区，避免跨身份串稿。
class DraftIdentity {
  final String deviceSid;
  final String accountId;
  final String workspaceKey;
  final String scopeId;

  // 非 const：构造期 trim 归一（.trim() 非常量表达式，const 构造函数
  // 不允许方法调用； 修复保留 trim 语义）。
  DraftIdentity({
    required String deviceSid,
    required String accountId,
    required String workspaceKey,
    required String scopeId,
  })  : deviceSid = deviceSid.trim(),
        accountId = accountId.trim(),
        workspaceKey = workspaceKey.trim(),
        scopeId = scopeId.trim();

  /// 构造即 trim——与 [fromJson] 的 trim 对称，含
  /// 首尾空白的 scopeId 不再因存盘往返后 key 漂移而"草稿消失"。

  factory DraftIdentity.session({
    required String deviceSid,
    required String accountId,
    required String workspaceKey,
    required String sessionId,
  }) => DraftIdentity(
    deviceSid: deviceSid,
    accountId: accountId,
    workspaceKey: workspaceKey,
    scopeId: 'session:$sessionId',
  );

  factory DraftIdentity.newDraft({
    required String deviceSid,
    required String accountId,
    required String workspaceKey,
    required String? projectId,
  }) => DraftIdentity(
    deviceSid: deviceSid,
    accountId: accountId,
    workspaceKey: workspaceKey,
    scopeId:
        'draft:${projectId?.trim().isNotEmpty == true ? projectId : 'workspace'}',
  );

  DraftIdentity forSession(String sessionId) => DraftIdentity.session(
    deviceSid: deviceSid,
    accountId: accountId,
    workspaceKey: workspaceKey,
    sessionId: sessionId,
  );

  String get key => jsonEncode([deviceSid, accountId, workspaceKey, scopeId]);

  Map<String, dynamic> toJson() => {
    'deviceSid': deviceSid,
    'accountId': accountId,
    'workspaceKey': workspaceKey,
    'scopeId': scopeId,
  };

  static DraftIdentity? fromJson(Map<String, dynamic> json) {
    final values = [
      json['deviceSid'],
      json['accountId'],
      json['workspaceKey'],
      json['scopeId'],
    ];
    if (values.any((v) => v is! String || v.trim().isEmpty)) return null;
    return DraftIdentity(
      deviceSid: (values[0] as String).trim(),
      accountId: (values[1] as String).trim(),
      workspaceKey: (values[2] as String).trim(),
      scopeId: (values[3] as String).trim(),
    );
  }
}

/// 草稿附件只保存上传引用和展示元数据，不把本地文件字节写进 JSON。
/// 没有上传引用的本地附件恢复后会明确要求重新选择。
class DraftAttachment {
  final String fileName;
  final String mime;
  final int byteSize;
  final Map<String, dynamic>? reference;

  const DraftAttachment({
    required this.fileName,
    required this.mime,
    required this.byteSize,
    this.reference,
  });

  Map<String, dynamic> toJson() => {
    'fileName': fileName,
    'mime': mime,
    'byteSize': byteSize,
    if (reference != null) 'reference': reference,
  };

  static DraftAttachment? fromJson(Map<String, dynamic> json) {
    final fileName = json['fileName'];
    if (fileName is! String || fileName.trim().isEmpty) return null;
    final rawRef = json['reference'];
    Map<String, dynamic>? ref;
    if (rawRef is Map) {
      final candidate = rawRef.cast<String, dynamic>();
      if ('${candidate['ref'] ?? ''}'.trim().isNotEmpty) ref = candidate;
    }
    return DraftAttachment(
      fileName: fileName,
      mime: '${json['mime'] ?? 'application/octet-stream'}',
      byteSize: (json['byteSize'] as num?)?.toInt() ?? 0,
      reference: ref,
    );
  }
}

class ComposerDraft {
  final DraftIdentity identity;
  final String text;
  final String? unsentText;
  final List<DraftAttachment> attachments;
  final int updatedAt;
  final int revision;

  /// 进程退出时上一条发送尚无权威结果；恢复后提示先核对，不静默当失败。
  final bool submissionInFlight;

  const ComposerDraft({
    required this.identity,
    required this.text,
    required this.attachments,
    required this.updatedAt,
    required this.revision,
    this.unsentText,
    this.submissionInFlight = false,
  });

  bool get hasRecoverableContent =>
      text.trim().isNotEmpty ||
      (unsentText?.trim().isNotEmpty ?? false) ||
      attachments.isNotEmpty;

  Map<String, dynamic> toJson() => {
    'identity': identity.toJson(),
    'text': text,
    if (unsentText != null) 'unsentText': unsentText,
    'attachments': [for (final a in attachments) a.toJson()],
    'updatedAt': updatedAt,
    'revision': revision,
    if (submissionInFlight) 'submissionInFlight': true,
  };

  static ComposerDraft? fromJson(Map<String, dynamic> json) {
    final rawIdentity = json['identity'];
    if (rawIdentity is! Map) return null;
    final identity = DraftIdentity.fromJson(
      rawIdentity.cast<String, dynamic>(),
    );
    if (identity == null) return null;
    final text = json['text'];
    final revision = json['revision'];
    final updatedAt = json['updatedAt'];
    final unsentText = json['unsentText'];
    if (text is! String ||
        revision is! num ||
        updatedAt is! num ||
        (unsentText != null && unsentText is! String)) {
      return null;
    }
    final attachments = <DraftAttachment>[];
    final rawAttachments = json['attachments'];
    if (rawAttachments is List) {
      for (final raw in rawAttachments.whereType<Map>()) {
        final attachment = DraftAttachment.fromJson(
          raw.cast<String, dynamic>(),
        );
        if (attachment != null) attachments.add(attachment);
      }
    }
    final draft = ComposerDraft(
      identity: identity,
      text: text,
      unsentText: unsentText as String?,
      attachments: attachments,
      updatedAt: updatedAt.toInt(),
      revision: revision.toInt(),
      submissionInFlight: json['submissionInFlight'] == true,
    );
    return draft.hasRecoverableContent ? draft : null;
  }
}

/// 应用私有目录中的草稿库：单文件原子替换、350ms 写盘合并、操作串行化。
/// 输入路径只更新内存并排队，磁盘故障不阻塞输入，也不输出草稿内容。
class DraftStore {
  DraftStore(
    this.baseDir, {
    this.debounce = const Duration(milliseconds: 350),
    @visibleForTesting this.beforeWrite,
  });

  static Future<DraftStore> createDefault() async {
    final dir = await getApplicationSupportDirectory();
    final root = Directory('${dir.path}${Platform.pathSeparator}drafts');
    await root.create(recursive: true);
    await _sweepTmp(root);
    return DraftStore(root);
  }

  /// 崩溃残留 .tmp（write 与 rename
  /// 之间进程死亡，唯一后缀会逐次累积）启动时顺手清扫；失败不阻塞。
  static Future<void> _sweepTmp(Directory root) async {
    try {
      if (!await root.exists()) return;
      await for (final e in root.list(followLinks: false)) {
        if (e is File && e.path.endsWith('.tmp')) {
          await e.delete().catchError((_) => e);
        }
      }
    } on Object {
      // 清扫失败不阻塞启动。
    }
  }

  final Directory baseDir;
  final Duration debounce;
  final Future<void> Function()? beforeWrite;
  final Map<String, ComposerDraft> _entries = {};
  final List<dynamic> _unparsedDrafts = [];
  Future<void> _operations = Future.value();
  Future<void> _diskOperations = Future.value();
  Timer? _debounce;
  bool _loaded = false;
  bool _dirty = false;
  bool _closed = false;
  int _mutationVersion = 0;
  int _tmpSeq = 0;

  @visibleForTesting
  bool get hasPendingWrites => _dirty;

  File get _file =>
      File('${baseDir.path}${Platform.pathSeparator}composer-drafts.json');

  Future<T> _serial<T>(FutureOr<T> Function() action) {
    final previous = _operations;
    final completer = Completer<T>();
    _operations = previous.catchError((_) {}).then((_) async {
      try {
        await _ensureLoaded();
        completer.complete(await action());
      } catch (error, stack) {
        completer.completeError(error, stack);
      }
    });
    return completer.future;
  }

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    if (!await _file.exists()) {
      _loaded = true;
      return;
    }
    try {
      final decoded = jsonDecode(await _file.readAsString());
      if (decoded is! Map || decoded['version'] != 1) {
        throw const FormatException('unsupported composer draft store');
      }
      final drafts = decoded['drafts'];
      if (drafts is! List) throw const FormatException('missing draft list');
      for (final raw in drafts) {
        try {
          if (raw is! Map) {
            _unparsedDrafts.add(raw);
            continue;
          }
          final draft = ComposerDraft.fromJson(raw.cast<String, dynamic>());
          if (draft == null) {
            _unparsedDrafts.add(raw);
          } else {
            _entries[draft.identity.key] = draft;
          }
        } on Object {
          // 单条形态异常保留原文，其他有效草稿仍可读取；后续写盘原样带回。
          _unparsedDrafts.add(raw);
        }
      }
    } on Object catch (error) {
      // （库损坏静默失效三路）：
      // 整库级解析失败（版本不识别/JSON 畸形）此前不置 loaded → 每次
      // 操作重读坏文件、save 全部静默丢弃、零日志，草稿功能整体死亡
      // 直到人工清数据。隔离自愈：坏文件改名 .corrupt 保留（人工可
      // 找回），以空库继续服务；rename 失败（原文件动不了）保持失败
      // 态——绝不拿空库覆盖原文件。
      try {
        await _file.rename('${_file.path}.corrupt');
      } on Object {
        debugPrint('[draft] store corrupt; quarantine failed, offline: $error');
        rethrow;
      }
      debugPrint('[draft] store corrupt; quarantined .corrupt, reset: $error');
      _loaded = true;
      return;
    }
    _loaded = true;
  }

  Future<ComposerDraft?> read(DraftIdentity identity) =>
      _serial<ComposerDraft?>(() => _entries[identity.key])
          .catchError((_) => null);

  Future<void> save(ComposerDraft draft) => _serial<void>(() {
    if (_closed) return;
    final current = _entries[draft.identity.key];
    if (current != null && draft.revision < current.revision) return;
    if (draft.hasRecoverableContent) {
      _entries[draft.identity.key] = draft;
    } else {
      _entries.remove(draft.identity.key);
    }
    _scheduleWrite();
  }).catchError((_) {});

  Future<void> delete(DraftIdentity identity, {int? expectedRevision}) =>
      _serial<void>(() {
        if (_closed) return;
        final key = identity.key;
        final current = _entries[key];
        if (expectedRevision != null && current?.revision != expectedRevision) {
          return;
        }
        if (_entries.remove(key) != null) _scheduleWrite();
      }).catchError((_) {});

  Future<void> removeDevice(String deviceSid) => _serial<void>(() {
    if (_closed) return;
    final before = _entries.length;
    _entries.removeWhere((_, draft) => draft.identity.deviceSid == deviceSid);
    if (_entries.length != before) _scheduleWrite();
  }).catchError((_) {});

  Future<void> removeSession(String deviceSid, String sessionId) =>
      _serial<void>(() {
        if (_closed) return;
        final scope = 'session:$sessionId';
        final before = _entries.length;
        _entries.removeWhere(
          (_, draft) =>
              draft.identity.deviceSid == deviceSid &&
              draft.identity.scopeId == scope,
        );
        if (_entries.length != before) _scheduleWrite();
      }).catchError((_) {});

  void _scheduleWrite() {
    _mutationVersion++;
    _dirty = true;
    _debounce?.cancel();
    _debounce = Timer(debounce, () => unawaited(flush()));
  }

  Future<void> flush() async {
    await _operations;
    _debounce?.cancel();
    // 即使 dirty 已在写盘开始时被消费，也要等待在途 rename 完成。
    await _diskOperations;
    if (_closed || !_dirty) return;
    final previous = _diskOperations;
    final completer = Completer<void>();
    _diskOperations = previous.catchError((_) {}).then((_) async {
      while (_dirty) {
        final version = _mutationVersion;
        try {
          await _writeSnapshot();
        } on Object catch (error) {
          _dirty = true;
          debugPrint('[draft] write failed; retry scheduled: $error');
          // 写盘失败不再只挂"下一次 flush 触发"
          //（磁盘满恢复后若用户不再动草稿，改动到进程死亡都不落盘）——
          // 低频重试节拍兜底，成功或 close 才停。
          _scheduleWriteRetry();
          break;
        }
        if (version == _mutationVersion) _dirty = false;
      }
      completer.complete();
    });
    await completer.future;
  }

  static const _writeRetryInterval = Duration(seconds: 30);
  Timer? _writeRetryTimer;

  void _scheduleWriteRetry() {
    _writeRetryTimer ??= Timer(_writeRetryInterval, () {
      _writeRetryTimer = null;
      if (_dirty && !_closed) unawaited(flush());
    });
  }

  /// 草稿条目软上限（无容量上限+每次变更全量重写，
  /// "输入过又弃置"的会话草稿（含桌面删项目后的 draft:<projectId> 孤儿
  /// 桶）多年累积无界——按 updatedAt 最旧淘汰收敛）。
  static const maxDraftEntries = 200;

  Future<void> _writeSnapshot() async {
    await beforeWrite?.call();
    if (_entries.length > maxDraftEntries) {
      final sorted = _entries.values.toList()
        ..sort((a, b) => a.updatedAt.compareTo(b.updatedAt));
      for (final stale
          in sorted.take(sorted.length - maxDraftEntries)) {
        _entries.remove(stale.identity.key);
      }
    }
    final drafts = _entries.values.toList()
      ..sort((a, b) => a.identity.key.compareTo(b.identity.key));
    if (drafts.isEmpty && _unparsedDrafts.isEmpty) {
      if (await _file.exists()) await _file.delete();
      return;
    }
    await baseDir.create(recursive: true);
    final content = jsonEncode({
      'version': 1,
      'drafts': [
        for (final draft in drafts) draft.toJson(),
        ..._unparsedDrafts,
      ],
    });
    final tmp = File('${_file.path}.${_tmpSeq++}.tmp');
    await tmp.writeAsString(content, flush: true);
    await tmp.rename(_file.path);
  }

  Future<void> close() async {
    if (_closed) return;
    await flush();
    // flush 的 await 让出窗口内到达的 save 会
    // 重置 _dirty 并排新定时器——直接关门=取消定时器吞掉最后一次保存。
    // 有限轮复查（磁盘持续失败时 flush 不收敛，不无限自旋）。
    for (var i = 0; i < 3 && _dirty; i++) {
      await flush();
    }
    _closed = true;
    _debounce?.cancel();
    _writeRetryTimer?.cancel();
  }
}
