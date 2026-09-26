import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:pantrace/main.dart';
import 'package:pantrace/src/update.dart';
import 'package:flutter_test/flutter_test.dart';

/// A stand-in for api.github.com / github.com on localhost.
class _GitHub {
  late HttpServer server;
  String tag = 'v9.9.9';
  int status = 200;
  List<int> asset = utf8.encode('installer bytes');
  bool chunked = false; // no Content-Length, so no progress is possible

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      req.response.statusCode = status;
      if (status == 200 && req.uri.path.endsWith('/releases/latest')) {
        req.response.write(jsonEncode({'tag_name': tag}));
      } else if (status == 200) {
        if (!chunked) req.response.contentLength = asset.length;
        req.response.add(asset);
      }
      await req.response.close();
    });
    apiBase = downloadBase = 'http://127.0.0.1:${server.port}';
  }

  Future<void> stop() async {
    await server.close(force: true);
    apiBase = 'https://api.github.com';
    downloadBase = 'https://github.com';
  }
}

void main() {
  test('isNewer compares semver tags', () {
    expect(isNewer('v1.0.1', '1.0.0'), isTrue);
    expect(isNewer('v1.10.0', '1.9.9'), isTrue);
    expect(isNewer('2.0.0', 'v1.99.99'), isTrue);
    expect(isNewer('v1.0.0', '1.0.0'), isFalse);
    expect(isNewer('v0.9.0', '1.0.0'), isFalse);
    expect(isNewer('v1.0.0', '0.0.0'), isTrue); // unversioned dev build
  });

  group('against a local GitHub', () {
    final gh = _GitHub();
    HttpOverrides? mock;
    setUp(() {
      // flutter_test swaps HttpClient for a 400-everything mock; this group
      // wants the real one, talking to the local server.
      mock = HttpOverrides.current;
      HttpOverrides.global = null;
      gh
        ..status = 200
        ..tag = 'v9.9.9'
        ..chunked = false;
      return gh.start();
    });
    tearDown(() {
      HttpOverrides.global = mock;
      return gh.stop();
    });

    test('checkForUpdate reports a newer tag, nothing when current', () async {
      expect(await checkForUpdate(), 'v9.9.9');
      gh.tag = appVersion; // whatever this build is, it is not newer
      expect(await checkForUpdate(), isNull);
      gh.status = 403;
      await expectLater(checkForUpdate(), throwsA(isA<HttpException>()));
    });

    test('download streams to a file and reports progress', () async {
      final out = File('${Directory.systemTemp.createTempSync().path}/asset');
      final progress = <double>[];
      await download('$downloadBase/x', out, progress.add);
      expect(out.readAsStringSync(), 'installer bytes');
      expect(progress.last, 1.0);

      gh.chunked = true;
      progress.clear();
      await download('$downloadBase/x', out, progress.add);
      expect(progress, isEmpty);
      await download('$downloadBase/x', out, null);

      gh.status = 404;
      await expectLater(download('$downloadBase/x', out, null),
          throwsA(predicate((e) => '$e'.contains('download failed (404)'))));
    });

    test('a failed download leaves the running install alone', () async {
      gh.status = 500;
      os = 'macos';
      try {
        await expectLater(downloadAndInstall('v9.9.9'), throwsA(isA<HttpException>()));
      } finally {
        os = Platform.operatingSystem;
      }
    });
  });

  test('the platform decides between self-install and the browser', () {
    final calls = <String>[];
    final realLaunch = launch;
    launch = (cmd, args) async {
      calls.add('$cmd ${args.join(' ')}');
      return ProcessResult(0, 0, '', '');
    };
    try {
      os = 'windows';
      arch = 'x64';
      expect(canSelfInstall, isTrue);
      expect(assetUrl('v1.2.3'), endsWith('/v1.2.3/Pantrace-windows-x64-setup.exe'));
      arch = 'arm64';
      expect(assetUrl('v1.2.3'), endsWith('/v1.2.3/Pantrace-windows-arm64-setup.exe'));
      openReleasePage();
      os = 'macos';
      expect(assetUrl('v1.2.3'), endsWith('/v1.2.3/Pantrace-macos.dmg'));
      openReleasePage();
      os = 'linux';
      expect(canSelfInstall, isFalse);
      openReleasePage();
      expect(calls, [
        'cmd /c start  $releasesUrl',
        'open $releasesUrl',
        'xdg-open $releasesUrl',
      ]);
    } finally {
      os = Platform.operatingSystem;
      arch = archOf(Abi.current());
      launch = realLaunch;
    }
  });

  test('architectures map onto the asset names', () {
    expect(archOf(Abi.windowsArm64), 'arm64');
    expect(archOf(Abi.linuxArm64), 'arm64');
    expect(archOf(Abi.macosArm64), 'arm64');
    expect(archOf(Abi.windowsX64), 'x64');
    expect(archOf(Abi.linuxX64), 'x64');
  });

  test('the default launcher runs a real process', () async {
    expect((await launch('true', [])).exitCode, 0);
  });

  testWidgets('the overflow menu offers a manual update check', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 800));
    await tester.pumpWidget(const PantraceApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    expect(find.text('Check for updates'), findsOneWidget);

    // The check is offline in tests, so it must report the failure, not silence.
    await tester.tap(find.text('Check for updates'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Update check failed'), findsOneWidget);
  });

  test('shellQuote escapes single quotes for /bin/sh', () {
    expect(shellQuote('plain'), "'plain'");
    expect(shellQuote("it's a path"), r"'it'\''s a path'");
  });

  test('the install asset is one CI actually publishes', () {
    // Renaming a release asset would otherwise 404 only at install time.
    final ci = File('.github/workflows/ci.yml').readAsStringSync();
    final iss = File('windows/installer.iss').readAsStringSync();
    final installer = RegExp(r'OutputBaseFilename=(\S+)').firstMatch(iss)!.group(1)!;
    try {
      os = 'windows';
      for (final a in ['x64', 'arm64']) {
        arch = a;
        // The installer is built once per Windows architecture in the matrix.
        expect(ci, contains(RegExp('target: windows, *arch: $a')));
        expect('${installer.replaceAll('{#Arch}', a)}.exe', assetUrl('v1').split('/').last);
      }
      expect(ci, contains('Pantrace-macos.dmg'));
      os = 'macos';
      expect(assetUrl('v1.2.3'),
          matches(r'^https://github\.com/.+/releases/download/v1\.2\.3/Pantrace-'));
    } finally {
      os = Platform.operatingSystem;
      arch = archOf(Abi.current());
    }
  });
}
