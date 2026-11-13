// 应用内更新（早前批次）：版本比较/ABI 选择/digest 解析/
// markdown 剥离纯函数 + HttpServer mock 的下载（Range 续传/镜像兜底/
// SHA256 校验拒篡改）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/update_check.dart';
import 'package:zcode_pocket/core/update_download.dart';

void main() {
  group('版本比较', () {
    test('tag vs versionName（-sha 后缀）矩阵', () {
      expect(isNewerVersion('v1.0.5', '1.0.4-4b3215ce5e15'), isTrue);
      expect(isNewerVersion('v1.0.5', '1.0.5-abc123def456'), isFalse);
      expect(isNewerVersion('v1.0.4', '1.0.5-abc'), isFalse);
      expect(isNewerVersion('v1.1.0', '1.0.99-zzz'), isTrue);
      expect(isNewerVersion('v2.0.0', '1.9.9-a'), isTrue);
    });
    test('不合法输入恒 false（fail-safe 不误报更新）', () {
      expect(isNewerVersion('garbage', '1.0.4-x'), isFalse);
      expect(isNewerVersion('v1.0.5', 'unknown'), isFalse);
      expect(isNewerVersion('', '1.0.4'), isFalse);
    });
    test('semverOf 三段式解析', () {
      expect(semverOf('v1.2.3'), [1, 2, 3]);
      expect(semverOf('1.2.3-abcdef123456'), [1, 2, 3]);
      expect(semverOf('1.2'), isNull);
      expect(semverOf('1.2.x'), isNull);
    });
  });

  group('ABI 与 digest', () {
    final assets = [
      UpdateAsset('早前批次.0.5-arm64-v8a.apk', 'u1', 'a' * 64),
      UpdateAsset('早前批次.0.5-armeabi-v7a.apk', 'u2', 'b' * 64),
      UpdateAsset('早前批次.0.5-x86_64.apk', 'u3', 'c' * 64),
    ];
    test('按设备 ABI 选择资产（含别名归一）', () {
      expect(pickAssetForAbi(assets, 'arm64-v8a')?.name,
          contains('arm64-v8a'));
      expect(pickAssetForAbi(assets, 'arm64')?.name, contains('arm64-v8a'));
      expect(pickAssetForAbi(assets, 'x86')?.name, contains('x86_64'));
      expect(pickAssetForAbi(assets, 'mips'), isNull);
    });
    test('digest 解析', () {
      expect(parseDigest('sha256:${'a' * 64}'), 'a' * 64);
      expect(parseDigest('a' * 64), 'a' * 64);
      expect(parseDigest('sha1:${'a' * 40}'), isNull);
      expect(parseDigest(null), isNull);
      expect(parseDigest('short'), isNull);
    });
  });

  test('markdown 剥离：标题/链接/加粗/表格/列表', () {
    const body = '''## 1.0.5

### Added

- **应用锁**：可选（见 [设置](settings)）
- 常规修复

| a | b |
|---|---|

> 引用行
''';
    final out = stripMarkdownNotes(body);
    expect(out, contains('1.0.5'));
    expect(out, contains('Added'));
    expect(out, contains('· 应用锁：可选（见 设置）'));
    expect(out, isNot(contains('##')));
    expect(out, isNot(contains('| a |')));
    expect(out, isNot(contains('**')));
  });

  group('parseReleaseJson', () {
    test('正常解析（digest 提取+无 digest 资产剔除）', () {
      final json = jsonEncode({
        'tag_name': 'v1.0.5',
        'body': '## 说明\\n- 修复',
        'assets': [
          {
            'name': '早前批次.0.5-arm64-v8a.apk',
            'browser_download_url': 'https://example.com/a.apk',
            'digest': 'sha256:${'a' * 64}',
          },
          {'name': 'SHA256SUMS', 'browser_download_url': 'u', 'digest': null},
        ],
      });
      final info = parseReleaseJson(json);
      expect(info.version, '1.0.5');
      expect(info.assets, hasLength(1));
      expect(info.assets.first.sha256Hex, 'a' * 64);
      expect(info.notes, contains('说明'));
    });
    test('坏 JSON/缺 tag 抛 UpdateCheckException', () {
      expect(() => parseReleaseJson('not json'), throwsA(isA<UpdateCheckException>()));
      expect(() => parseReleaseJson('{}'), throwsA(isA<UpdateCheckException>()));
    });
  });

  group('下载（本机 HttpServer）', () {
    late HttpServer server;
    late Directory tmpDir;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      tmpDir = await Directory.systemTemp.createTemp('zp_update_test');
    });

    tearDown(() async {
      await server.close(force: true);
      await tmpDir.delete(recursive: true);
    });

    Future<File> tmpFile() async =>
        File('${tmpDir.path}/apk-${DateTime.now().microsecondsSinceEpoch}');

    test('流式下载+进度+SHA256 校验通过', () async {
      final payload = List<int>.generate(256 * 1024, (i) => i % 251);
      server.listen((req) async {
        req.response.add(payload);
        await req.response.close();
      });
      final f = await tmpFile();
      final dl = UpdateDownload();
      var lastReceived = 0;
      await dl.download(
        'http://127.0.0.1:${server.port}/a.apk',
        f,
        onProgress: (r, t) => lastReceived = r,
      );
      expect(await f.length(), payload.length);
      expect(lastReceived, payload.length);
      final digest = await UpdateDownload.sha256OfFile(f);
      expect(digest, hasLength(64));
      // verify 走通（用真 digest）。
      expect(await UpdateDownload.verifyAndCleanup(f, digest), isTrue);
      expect(await f.exists(), isTrue, reason: '校验通过不删文件');
    });

    test('Range 断点续传（206 从偏移续）', () async {
      final payload = List<int>.generate(100 * 1024, (i) => i % 7);
      server.listen((req) async {
        final range = req.headers.value(HttpHeaders.rangeHeader);
        if (range != null) {
          final start = int.parse(range.replaceAll(RegExp(r'[^0-9]'), ''));
          req.response.statusCode = 206;
          req.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes $start-${payload.length - 1}/${payload.length}',
          );
          req.response.add(payload.sublist(start));
        } else {
          req.response.add(payload);
        }
        await req.response.close();
      });
      final f = await tmpFile();
      // 预置前半段（模拟上次中断）。
      await f.writeAsBytes(payload.sublist(0, 50 * 1024));
      final dl = UpdateDownload();
      await dl.download('http://127.0.0.1:${server.port}/b.apk', f);
      expect(await f.length(), payload.length);
      expect(await f.readAsBytes(), payload, reason: '续传后完整一致');
    });

    test('SHA 不符拒装且删文件', () async {
      final payload = List<int>.filled(1024, 1);
      server.listen((req) async {
        req.response.add(payload);
        await req.response.close();
      });
      final f = await tmpFile();
      final dl = UpdateDownload();
      await dl.download('http://127.0.0.1:${server.port}/c.apk', f);
      final ok = await UpdateDownload.verifyAndCleanup(f, '0' * 64);
      expect(ok, isFalse);
      expect(await f.exists(), isFalse, reason: '校验失败删文件防误装');
    });

    test('直连失败切镜像兜底', () async {
      final payload = List<int>.filled(2048, 3);
      final mirrorCalls = <String>[];
      server.listen((req) async {
        mirrorCalls.add(req.uri.path);
        req.response.add(payload);
        await req.response.close();
      });
      debugMirrorPrefixOverride = 'http://127.0.0.1:${server.port}/mirror/';
      addTearDown(() => debugMirrorPrefixOverride = null);
      final f = await tmpFile();
      final dl = UpdateDownload();
      // 直连指向必然失败的端口。
      await dl.download('http://127.0.0.1:1/x.apk', f);
      expect(mirrorCalls.first, startsWith('/mirror/http://'), reason: '镜像=前缀+完整 URL（ghproxy 形态）');
      expect(await f.length(), payload.length);
    });

    test('②M3：416=本地已完整——isRangeSatisfied 可判（重试不再死循环）', () async {
      server.listen((req) async {
        req.response.statusCode = 416;
        await req.response.close();
      });
      final f = await tmpFile();
      await f.writeAsBytes(List<int>.filled(1024, 1)); // 本地已有内容。
      final dl = UpdateDownload();
      try {
        await dl.download('http://127.0.0.1:${server.port}/e.apk', f);
        fail('应抛 UpdateDownloadException');
      } on UpdateDownloadException catch (e) {
        expect(UpdateDownload.isRangeSatisfied(e), isTrue,
            reason: '416 映射为可判定的"本地已≥资源"——调用方走校验复用');
      }
      expect(await f.exists(), isTrue, reason: '416 不删本地文件（待校验）');
    });

    test('②M5：超大小上限即停并删文件', () async {
      final chunk = List<int>.filled(64 * 1024, 5);
      server.listen((req) async {
        // 无 Content-Length 也持续输出（模拟异常大流）。
        for (var i = 0; i < 4000; i++) {
          req.response.add(chunk);
          await req.response.flush();
        }
        await req.response.close();
      });
      final f = await tmpFile();
      final dl = UpdateDownload();
      try {
        await dl.download('http://127.0.0.1:${server.port}/big.apk', f);
        fail('应抛 oversized');
      } on UpdateDownloadException catch (e) {
        expect(e.reason, 'oversized');
      }
      expect(await f.exists(), isFalse, reason: '超限文件删除防占盘');
    });

    test('取消中断下载且抛 cancelled', () async {
      final chunk = List<int>.filled(64 * 1024, 9);
      late StreamSubscription<HttpRequest> sub;
      sub = server.listen((req) async {
        // 慢速分块，保证取消窗口。
        for (var i = 0; i < 20; i++) {
          req.response.add(chunk);
          await req.response.flush();
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        await req.response.close();
      });
      addTearDown(() => sub.cancel());
      final f = await tmpFile();
      final dl = UpdateDownload();
      final task = dl.download('http://127.0.0.1:${server.port}/d.apk', f);
      Future<void>.delayed(const Duration(milliseconds: 60), dl.cancel);
      await expectLater(task, throwsA(isA<UpdateDownloadException>()));
      expect(await f.exists(), isTrue, reason: '残留文件供断点续传复用');
    });
  });
}
