import 'dart:convert';
import 'dart:io' show File, Platform;

import 'package:flutter/foundation.dart' show visibleForTesting, debugPrint;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import '../transport/connection_params.dart';
import '../transport/z_transport.dart';

/// 凭据存储：远控 URL = 电脑钥匙，必须落 Android Keystore 加密存储
/// （docs/PROJECT_PLAN.md 风险表：凭据安全）。
///
/// 档案唯一键 = deviceSid（同一桌面刷新二维码后 sid 会变，视为新档案）。
/// 双栈（ADR 0032）：同一列表存 V1（{url,…}，无 kind 字段=向后兼容）与
/// V2 账号档案（{kind:'v2', sid, mid, name,…}）。
///
/// 批次 2（2026-10-19 审查）加固：
/// - B1 逐条容错：单条坏数据跳过+计数（不再一条坏→全量抛→界面全清空）；
/// - B3 串行化：读-改-写全部经同一队列（原毫秒级交错窗口可丢一次更新）；
/// - 存储可注入（测试缝：内存 FlutterSecureStorage 替身）。
///
/// 18087 黑屏批加固（V2 明文冗余备份+自救）：真机实证配对成功 ~1.3s 后
/// 被外部系统进程强杀（华为 am_kill by app），且**刚写入的 relay.list 在
/// 加密存储的异步落盘窗口内丢失**（老键全在、唯新键消失=apply 未及
/// flush 的签名）→ 重启回到空配对页（用户看到"黑屏要大退"的半个根因）。
/// V2 档案描述符（sid/mid/name/app_version/accountId/label/addedAt——
/// **不含任何凭据**，凭据仍在加密存储）同步写一份明文文件（dart:io
/// flush 直达页缓存，进程击杀不丢）；读取时发现加密列表缺失而备份在
/// 的 V2 档案自动回补。V1 档案（含 hash=链接即凭据）**绝不**入明文备份。
///
/// 串行化实现注意：公开方法只包一层 `_serialized`，内部互调走 `_*Raw`
/// （重入 `_serialized` 会自锁——队列尾部在等自己）。
class ProfileStore {
  ProfileStore({FlutterSecureStorage? storage, this.debugBackupPath})
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;
  static const _prefix = 'profile.';

  /// 测试缝：明文备份文件路径覆写（生产走应用支持目录）。
  @visibleForTesting
  final String? debugBackupPath;

  /// 备份层是否可用：显式覆写路径（本批单测）恒可用；flutter test 环境
  /// 无覆写时旁路（18088 教训：getApplicationSupportDirectory 在全量
  /// 测试并发下经 MethodChannel 挂起=整个门卡死，单文件跑则抛异常被
  /// 吞——统一旁路最干净）；其余环境（真机/模拟器）可用。
  bool get _backupAvailable =>
      debugBackupPath != null ||
      !Platform.environment.containsKey('FLUTTER_TEST');

  // -------------------------------------------------------- B3 串行队列

  Future<void> _tail = Future.value();

  Future<T> _serialized<T>(Future<T> Function() op) {
    final result = _tail.then((_) => op());
    // 尾巴吞错：单个操作失败不阻塞后续排队者；错误由调用方收到。
    _tail = result.then((_) {}, onError: (Object _) {});
    return result;
  }

  // --------------------------------------------------------------- 读

  Future<List<DeviceProfile>> listProfiles() async =>
      (await listProfilesDetailed()).profiles;

  /// B1：逐条解码，坏条目跳过并计数（界面提示"N 个档案损坏"）。
  Future<({List<DeviceProfile> profiles, int skipped})>
  listProfilesDetailed() => _serialized(_readRaw);

  Future<({List<DeviceProfile> profiles, int skipped})> _readRaw() async {
    final json = await _storage.read(key: '${_prefix}relay.list');
    var result = (profiles: <DeviceProfile>[], skipped: 0);
    if (json != null) {
      try {
        result = decodeProfileList(json);
      } catch (e) {
        // 顶层 JSON 畸形（存储截断/加密层损坏出非 JSON 串，开源审查
        // K1 P2-4/K2 P2-1）：此前 jsonDecode 抛出直接冲出 _readRaw，
        // 18088 明文备份自救层被整体短路——合法备份就在旁边却不参与
        // 回补。按空列表落位，让 rescue 用空 known 集走正常回补路径
        // （回补会重写合法 blob，顺带自愈损坏值；V1 本就不可救属已拍板
        // 边界）。
        debugPrint('[profiles] relay.list decode failed (rescue will run): $e');
        result = (profiles: <DeviceProfile>[], skipped: 1);
      }
    }
    // 18087 自救：加密列表缺失而明文备份在的 V2 档案回补（外部强杀
    // 吃掉 apply 窗口内新键的场景）——回补成功后用户重启直接回首页。
    try {
      final rescued = await _rescueFromBackup(result.profiles);
      if (rescued.isNotEmpty) result = (profiles: [...result.profiles, ...rescued], skipped: result.skipped);
    } catch (e) {
      debugPrint('[profiles] backup rescue failed (contained): $e');
    }
    return result;
  }

  Future<File> _backupFile() async {
    final override = debugBackupPath;
    if (override != null) return File(override);
    final dir = await getApplicationSupportDirectory();
    return File(
      '${dir.path}${Platform.pathSeparator}profiles-v2-backup.json',
    );
  }

  /// V2 档案描述符写明文备份（flush=true 直达页缓存，进程击杀不丢；
  /// V1 含 hash 凭据绝不含入）。备份层不可用视为成功（跳过）。
  /// 返回是否落定（开源审查 K1-P3-5/K2-P2-3：删除路径需要真实结果来
  /// 决定是否继续——备份写失败时继续删加密列表会让已删档案被陈旧
  /// 备份"自救复活"）。
  Future<bool> _writeBackup(List<DeviceProfile> profiles) async {
    if (!_backupAvailable) return true;
    try {
      final v2 = profiles
          .whereType<AccountV2Profile>()
          .map(_encodeProfile)
          .toList(growable: false);
      final file = await _backupFile();
      await file.writeAsString(jsonEncode(v2), flush: true);
      _backupKnownAbsent = false;
      return true;
    } catch (e) {
      debugPrint('[profiles] backup write failed (contained): $e');
      return false;
    }
  }

  /// 备份文件缺失探测缓存（开源审查 K2-P3-5：常态缺失时每次档案读取
  /// 都 exists()+readAsString 白付 IO；写入成功后复位）。
  bool _backupKnownAbsent = false;

  /// 加密列表缺、备份有的 V2 档案 → 回补进加密存储并返回补回集合。
  Future<List<DeviceProfile>> _rescueFromBackup(
    List<DeviceProfile> secureProfiles,
  ) async {
    if (!_backupAvailable) return const [];
    if (_backupKnownAbsent) return const [];
    final file = await _backupFile();
    if (!await file.exists()) {
      _backupKnownAbsent = true;
      return const [];
    }
    final raw = await file.readAsString();
    if (raw.trim().isEmpty) return const [];
    final decoded = decodeProfileList(raw);
    final known = secureProfiles.map((p) => p.deviceSid).toSet();
    final missing = decoded.profiles
        .whereType<AccountV2Profile>()
        .where((p) => !known.contains(p.deviceSid))
        .toList();
    if (missing.isEmpty) return const [];
    debugPrint(
      '[profiles] backup rescue: ${missing.map((p) => p.deviceSid).toList()}',
    );
    // 回补进加密存储（同 upsert 的写路径），下次读取自然命中。
    final merged = [...secureProfiles, ...missing];
    await _storage.write(
      key: '${_prefix}relay.list',
      value: jsonEncode(merged.map(_encodeProfile).toList()),
    );
    return missing;
  }

  /// 新增（或替换）一台电脑：同 deviceSid 覆盖（重扫后旧档案复活，
  /// invalid 清除）。写后同步刷新明文备份（18087 击杀防丢层）。
  Future<DeviceProfile> upsertProfile(DeviceProfile profile) =>
      _serialized(() async {
        final list = [
          ...(await _readRaw())
              .profiles
              .where((p) => p.deviceSid != profile.deviceSid),
        ];
        final merged = profile.copyWith(invalid: false);
        list.add(merged);
        await _storage.write(
          key: '${_prefix}relay.list',
          value: jsonEncode(list.map(_encodeProfile).toList()),
        );
        await _writeBackup(list);
        return merged;
      });

  Future<void> updateProfile(DeviceProfile profile) => _serialized(() async {
        final list = (await _readRaw()).profiles;
        final replaced = list
            .map((p) => p.deviceSid == profile.deviceSid ? profile : p)
            .toList();
        await _storage.write(
          key: '${_prefix}relay.list',
          value: jsonEncode(replaced.map(_encodeProfile).toList()),
        );
        await _writeBackup(replaced);
      });

  Future<void> removeProfile(String deviceSid) => _serialized(() async {
    final list = (await _readRaw())
        .profiles
        .where((p) => p.deviceSid != deviceSid)
        .toList();
    // 开源审查 K1-P3-5/K2-P2-3：删除路径备份先行（关键态先行原则）——
    // 备份写失败（磁盘满/IO 异常）时中止删除：加密列表保持原样，用户
    // 重试即可；反之先删加密列表、备份刷新失败会让已删档案被陈旧备份
    // "自救复活"（删掉的电脑自己回来）。
    if (!await _writeBackup(list)) {
      throw const FormatException('备份写失败，本次删除已取消，请重试');
    }
    await _storage.write(
      key: '${_prefix}relay.list',
      value: jsonEncode(list.map(_encodeProfile).toList()),
    );
    if (await _storage.read(key: '${_prefix}relay.active') == deviceSid) {
      await _storage.delete(key: '${_prefix}relay.active');
    }
  });

  Future<String?> activeDeviceSid() =>
      _serialized(() => _storage.read(key: '${_prefix}relay.active'));

  Future<void> setActiveDeviceSid(String? deviceSid) => _serialized(() async {
    if (deviceSid == null) {
      await _storage.delete(key: '${_prefix}relay.active');
    } else {
      await _storage.write(
        key: '${_prefix}relay.active',
        value: deviceSid,
      );
    }
  });

  Map<String, dynamic> _encodeProfile(DeviceProfile p) => switch (p) {
    RelayProfile v1 => {
      'url': v1.params.source.toString(),
      'label': v1.label,
      'addedAt': v1.addedAt.millisecondsSinceEpoch,
      'invalid': v1.invalid,
      if (v1.lastWorkspaceKey != null) 'lastWorkspaceKey': v1.lastWorkspaceKey,
    },
    AccountV2Profile v2 => {
      'kind': 'v2',
      'sid': v2.deviceSid,
      if (v2.deviceMid != null) 'mid': v2.deviceMid,
      if (v2.deviceName != null) 'name': v2.deviceName,
      if (v2.appVersion != null) 'appVersion': v2.appVersion,
      // 多账号批（2026-10-25）：null=未迁移/未绑定（读取方退最近使用）。
      if (v2.accountId != null) 'accountId': v2.accountId,
      'label': v2.label,
      'addedAt': v2.addedAt.millisecondsSinceEpoch,
      'invalid': v2.invalid,
      if (v2.lastWorkspaceKey != null) 'lastWorkspaceKey': v2.lastWorkspaceKey,
    },
    _ => throw const FormatException('unsupported profile kind'),
  };

  DeviceProfile _decodeProfile(Map<String, dynamic> m) {
    if (m['kind'] == 'v2') {
      final sid = (m['sid'] as String?)?.trim() ?? '';
      if (sid.isEmpty) throw const FormatException('v2 profile missing sid');
      return AccountV2Profile(
        deviceSid: sid,
        deviceMid: m['mid'] as String?,
        deviceName: m['name'] as String?,
        appVersion: m['appVersion'] as String?,
        accountId: (m['accountId'] as String?)?.trim().isEmpty == true
            ? null
            : m['accountId'] as String?,
        label: m['label'] as String? ?? m['name'] as String? ?? sid,
        // 开源审查 K1-P3-14：字段缺失回退固定 0（排序垫底、稳定）——
        // now() 使"纯函数"解码不确定且排序展示抖动。
        addedAt: DateTime.fromMillisecondsSinceEpoch(
          (m['addedAt'] as num?)?.toInt() ?? 0,
        ),
        invalid: m['invalid'] == true,
        lastWorkspaceKey: m['lastWorkspaceKey'] as String?,
      );
    }
    final params = CompanionConnectionParams.parse(m['url'] as String? ?? '');
    if (params == null) {
      throw const FormatException('invalid connection url');
    }
    return RelayProfile(
      params: params,
      label: m['label'] as String? ?? params.deviceName ?? '桌面',
      addedAt: DateTime.fromMillisecondsSinceEpoch(
        (m['addedAt'] as num?)?.toInt() ?? 0,
      ),
      invalid: m['invalid'] == true,
      lastWorkspaceKey: m['lastWorkspaceKey'] as String?,
    );
  }

  /// B1 纯函数（单测靶）：坏条目跳过+计数，好条目保留——原实现任一条
  /// 抛出即整体失败（app_state catch → profiles=const [] 全清空）。
  @visibleForTesting
  ({List<DeviceProfile> profiles, int skipped}) decodeProfileList(String json) {
    final decoded = jsonDecode(json);
    final list = decoded is List ? decoded : const [];
    final profiles = <DeviceProfile>[];
    var skipped = 0;
    for (final e in list) {
      if (e is! Map) {
        skipped++;
        continue;
      }
      try {
        profiles.add(_decodeProfile(e.cast<String, dynamic>()));
      } on Object {
        skipped++;
      }
    }
    return (profiles: profiles, skipped: skipped);
  }
}
