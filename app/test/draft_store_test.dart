import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/state/draft_store.dart';

DraftIdentity _identity({
  String device = 'device-a',
  String account = 'account-a',
  String workspace = 'workspace-a',
  String session = 'session-a',
}) => DraftIdentity.session(
  deviceSid: device,
  accountId: account,
  workspaceKey: workspace,
  sessionId: session,
);

ComposerDraft _draft(
  DraftIdentity identity, {
  String text = '保留这段输入',
  String? unsent,
  int revision = 1,
  bool inFlight = false,
  List<DraftAttachment> attachments = const [],
}) => ComposerDraft(
  identity: identity,
  text: text,
  unsentText: unsent,
  attachments: attachments,
  updatedAt: 1000 + revision,
  revision: revision,
  submissionInFlight: inFlight,
);

void main() {
  late Directory dir;
  late DraftStore store;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('composer-draft-test');
    store = DraftStore(dir, debounce: const Duration(hours: 1));
  });

  tearDown(() async {
    await store.close();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('重启后恢复正文/失败暂存/附件引用与最后编辑信息', () async {
    final id = _identity();
    await store.save(
      _draft(
        id,
        unsent: '等待期原文',
        attachments: const [
          DraftAttachment(
            fileName: 'ready.png',
            mime: 'image/png',
            byteSize: 128,
            reference: {
              'ref': 'att-ready',
              'fileName': 'ready.png',
              'mime': 'image/png',
              'bytes': 128,
            },
          ),
          DraftAttachment(
            fileName: 'local.txt',
            mime: 'text/plain',
            byteSize: 32,
          ),
        ],
      ),
    );
    await store.flush();
    expect((await store.read(id))?.text, '保留这段输入');

    final restarted = DraftStore(dir, debounce: const Duration(hours: 1));
    final restored = await restarted.read(id);
    expect(restored?.text, '保留这段输入');
    expect(restored?.unsentText, '等待期原文');
    expect(restored?.updatedAt, 1001);
    expect(restored?.attachments, hasLength(2));
    expect(restored?.attachments[0].reference?['ref'], 'att-ready');
    expect(restored?.attachments[1].reference, isNull);
    await restarted.close();
  });

  test('电脑/账号/工作区/会话四维隔离，同路径身份不同也不串稿', () async {
    final base = _identity();
    final variants = [
      base,
      _identity(device: 'device-b'),
      _identity(account: 'account-b'),
      _identity(workspace: 'workspace-b'),
      _identity(session: 'session-b'),
    ];
    for (var i = 0; i < variants.length; i++) {
      await store.save(_draft(variants[i], text: 'draft-$i'));
    }
    await store.flush();
    for (var i = 0; i < variants.length; i++) {
      expect((await store.read(variants[i]))?.text, 'draft-$i');
    }
  });

  test('空正文且无失败暂存会删稿；过期条件删除不能吃掉新修订', () async {
    final id = _identity();
    await store.save(_draft(id, revision: 7));
    await store.delete(id, expectedRevision: 6);
    expect((await store.read(id))?.text, '保留这段输入');
    await store.save(_draft(id, text: '', revision: 8));
    expect(await store.read(id), isNull);

    await store.save(_draft(id, text: '', unsent: '失败原文仍在', revision: 9));
    expect((await store.read(id))?.unsentText, '失败原文仍在');
  });

  test('连续输入合并落盘后是最后修订，删设备与删会话只清目标', () async {
    final id = _identity();
    for (var revision = 1; revision <= 30; revision++) {
      await store.save(
        _draft(id, text: 'revision-$revision', revision: revision),
      );
    }
    await store.flush();
    final restarted = DraftStore(dir);
    expect((await restarted.read(id))?.text, 'revision-30');

    final otherDevice = _identity(device: 'device-b');
    final otherSession = _identity(session: 'session-b');
    await restarted.save(_draft(otherDevice));
    await restarted.save(_draft(otherSession));
    await restarted.removeSession(id.deviceSid, 'session-a');
    expect(await restarted.read(id), isNull);
    expect(await restarted.read(otherSession), isNotNull);
    await restarted.removeDevice('device-b');
    expect(await restarted.read(otherDevice), isNull);
    await restarted.close();
  });

  test('损坏文件按无草稿处理，不阻断读取', () async {
    await File('${dir.path}${Platform.pathSeparator}composer-drafts.json')
        .writeAsString('{not-json');
    expect(await store.read(_identity()), isNull);
  });

  test('附件-only 与发送结果未知标记均可跨重启恢复', () async {
    final id = _identity();
    await store.save(
      _draft(
        id,
        text: '',
        inFlight: true,
        attachments: const [
          DraftAttachment(
            fileName: 'only.txt',
            mime: 'text/plain',
            byteSize: 5,
            reference: {'ref': 'only-ref'},
          ),
        ],
      ),
    );
    await store.flush();
    final restarted = DraftStore(dir);
    final restored = await restarted.read(id);
    expect(restored?.attachments.single.reference?['ref'], 'only-ref');
    expect(restored?.submissionInFlight, isTrue);
    await restarted.close();
  });

  test('写盘失败保留待重试状态，下一次 flush 成功落盘', () async {
    var attempts = 0;
    final flaky = DraftStore(
      dir,
      beforeWrite: () async {
        attempts++;
        if (attempts == 1) throw StateError('injected write failure');
      },
    );
    await flaky.save(_draft(_identity()));
    await flaky.flush();
    expect(flaky.hasPendingWrites, isTrue);
    await flaky.flush();
    expect(flaky.hasPendingWrites, isFalse);
    expect((await flaky.read(_identity()))?.text, '保留这段输入');
    await flaky.close();
  });

  test('close 等待已经开始的写盘，不提前返回', () async {
    final started = Completer<void>();
    final gate = Completer<void>();
    final gated = DraftStore(
      dir,
      beforeWrite: () {
        if (!started.isCompleted) started.complete();
        return gate.future;
      },
    );
    await gated.save(_draft(_identity()));
    final closing = gated.close();
    await started.future;
    gate.complete();
    await closing;
    final restarted = DraftStore(dir);
    expect((await restarted.read(_identity()))?.text, '保留这段输入');
    await restarted.close();
  });

  test('单条坏记录不阻断其他草稿，后续写盘仍保留原始坏记录', () async {
    final id = _identity();
    final bad = {
      ..._draft(_identity(session: 'bad')).toJson(),
      'unsentText': 123,
    };
    await File('${dir.path}${Platform.pathSeparator}composer-drafts.json')
        .writeAsString(
          jsonEncode({
            'version': 1,
            'drafts': [_draft(id).toJson(), bad],
          }),
        );
    expect((await store.read(id))?.text, '保留这段输入');
    await store.save(_draft(_identity(session: 'new')));
    await store.flush();
    final decoded = jsonDecode(
      await File('${dir.path}${Platform.pathSeparator}composer-drafts.json')
          .readAsString(),
    ) as Map;
    expect(decoded['drafts'], hasLength(3));
    expect(
      (decoded['drafts'] as List).any(
        (raw) => raw is Map && raw['unsentText'] == 123,
      ),
      isTrue,
    );
  });
}
