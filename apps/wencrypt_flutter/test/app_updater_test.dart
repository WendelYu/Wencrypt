import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:wencrypt/about_update_view.dart';
import 'package:wencrypt/app_updater.dart';
import 'package:wencrypt/design/wencrypt_theme.dart';
import 'package:wencrypt/main.dart';

class _DirectHttpOverrides extends HttpOverrides {}

class _FakeUpdaterBridge implements AppUpdaterBridge {
  _FakeUpdaterBridge({required this.runtimeInfo});

  final AppRuntimeInfo runtimeInfo;
  String? openedDirectory;
  String? openedUrl;
  String? installedArchivePath;
  String? installedSha256;
  bool installReturnValue = true;

  @override
  Future<AppRuntimeInfo> getAppInfo() async => runtimeInfo;

  @override
  Future<bool> openDirectory(String path) async {
    openedDirectory = path;
    return true;
  }

  @override
  Future<bool> openUrl(String url) async {
    openedUrl = url;
    return true;
  }

  @override
  Future<bool> installAndRestart({
    required String archivePath,
    required String expectedSha256,
  }) async {
    installedArchivePath = archivePath;
    installedSha256 = expectedSha256;
    return installReturnValue;
  }
}

void main() {
  test('Sha256Sink matches NIST FIPS 180-4 vectors across chunk sizes', () {
    expect(
      sha256Hex(const []),
      'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
    );
    expect(
      sha256Hex(utf8.encode('abc')),
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    );

    final twoBlock = utf8.encode(
      'abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq',
    );
    final sink = Sha256Sink()
      ..add(twoBlock.sublist(0, 7))
      ..add(twoBlock.sublist(7, 29))
      ..add(twoBlock.sublist(29));
    expect(
      sink.closeAndHex(),
      '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1',
    );
  });

  test('AppVersion compares releases accurately', () {
    expect(
      AppVersion.tryParse('v0.3.10')!.isNewerThan(
        AppVersion.tryParse('0.3.9')!,
      ),
      isTrue,
    );
    expect(
      AppVersion.tryParse('0.4.0')!.isNewerThan(
        AppVersion.tryParse('0.4.0-rc.1')!,
      ),
      isTrue,
    );
    expect(
      AppVersion.tryParse('0.3.9+99')!.isNewerThan(
        AppVersion.tryParse('0.3.9+21')!,
      ),
      isFalse,
    );
    expect(AppVersion.tryParse('not-a-version'), isNull);
  });

  test('parseSha256Sums parses release checksum lines cleanly', () {
    const sample = '''
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA  wencrypt-v0.4.0-macos-arm64.zip
bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb *dir/wencrypt-v0.4.0-windows-x64.zip
invalid line
''';
    final parsed = parseSha256Sums(sample);
    expect(
      parsed['wencrypt-v0.4.0-macos-arm64.zip'],
      'a' * 64,
    );
    expect(
      parsed['wencrypt-v0.4.0-windows-x64.zip'],
      'b' * 64,
    );
    expect(parsed.length, 2);
  });

  test('isTrustedGitHubUrl accepts only official HTTPS GitHub hosts', () {
    expect(
      isTrustedGitHubUrl(
        Uri.parse('https://api.github.com/repos/WendelYu/Wencrypt/releases/latest'),
      ),
      isTrue,
    );
    expect(
      isTrustedGitHubUrl(
        Uri.parse('https://objects.githubusercontent.com/github-production/app.zip'),
      ),
      isTrue,
    );
    expect(
      isTrustedGitHubUrl(Uri.parse('http://github.com/WendelYu/Wencrypt')),
      isFalse,
    );
    expect(
      isTrustedGitHubUrl(Uri.parse('https://evil-github.com/app.zip')),
      isFalse,
    );
    expect(
      isTrustedGitHubUrl(Uri.parse('https://user:pass@github.com/app.zip')),
      isFalse,
    );
  });

  test('selectReleaseAsset picks platform installer packages properly', () {
    final assets = [
      {
        'name': 'SHA256SUMS.txt',
        'browser_download_url': 'https://github.com/a/SHA256SUMS.txt',
        'size': 256,
      },
      {
        'name': 'wencrypt-v0.4.0-macos-arm64.dmg',
        'browser_download_url': 'https://github.com/a/mac.dmg',
        'size': 24000000,
      },
      {
        'name': 'wencrypt-v0.4.0-macos-arm64.zip',
        'browser_download_url': 'https://github.com/a/mac.zip',
        'size': 23000000,
      },
      {
        'name': 'wencrypt-v0.4.0-windows-x64.zip',
        'browser_download_url': 'https://github.com/a/win.zip',
        'size': 14000000,
      },
      {
        'name': 'wencrypt-v0.4.0-android-arm64.apk',
        'browser_download_url': 'https://github.com/a/app.apk',
        'size': 22000000,
      },
    ];

    final mac = selectReleaseAsset(assets, UpdatePlatform.macos);
    expect(mac.assetName, 'wencrypt-v0.4.0-macos-arm64.dmg');
    expect(mac.canInstallAsset, isTrue);
    expect(mac.sha256AssetUrl, isNotNull);

    final macZipFallback = selectReleaseAsset(
      assets.where((a) => !a['name'].toString().endsWith('.dmg')).toList(),
      UpdatePlatform.macos,
    );
    expect(macZipFallback.assetName, 'wencrypt-v0.4.0-macos-arm64.zip');
    expect(macZipFallback.canInstallAsset, isTrue);

    final win = selectReleaseAsset(assets, UpdatePlatform.windows);
    expect(win.assetName, 'wencrypt-v0.4.0-windows-x64.zip');
    expect(win.canInstallAsset, isTrue);

    final android = selectReleaseAsset(assets, UpdatePlatform.android);
    expect(android.assetName, 'wencrypt-v0.4.0-android-arm64.apk');
    expect(android.canInstallAsset, isFalse);
  });

  test('AppUpdateController checks, downloads, verifies SHA-256, and fails closed on mismatch', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final payloadBytes = Uint8List.fromList(utf8.encode('fake-zip-archive-payload'));
      final validSha = sha256Hex(payloadBytes);
      var serveCorruptArchive = false;
      var omitChecksumFile = false;

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));

      server.listen((req) async {
        final origin = 'http://127.0.0.1:${server.port}';
        if (req.uri.path == '/latest') {
          req.response.statusCode = 200;
          req.response.headers.contentType = ContentType.json;
          req.response.write(
            jsonEncode({
              'tag_name': 'v0.4.0',
              'html_url': '$origin/releases/tag/v0.4.0',
              'body': 'Fix macOS accessibility crash\nAdd in-app updater',
              'assets': [
                if (!omitChecksumFile)
                  {
                    'name': 'SHA256SUMS.txt',
                    'browser_download_url': '$origin/SHA256SUMS.txt',
                    'size': 128,
                  },
                {
                  'name': 'wencrypt-v0.4.0-macos-arm64.dmg',
                  'browser_download_url': '$origin/app.dmg',
                  'size': payloadBytes.length,
                },
              ],
            }),
          );
        } else if (req.uri.path == '/SHA256SUMS.txt') {
          req.response.statusCode = 200;
          req.response.write('$validSha  wencrypt-v0.4.0-macos-arm64.dmg\n');
        } else if (req.uri.path == '/app.dmg') {
          req.response.statusCode = 200;
          if (serveCorruptArchive) {
            req.response.add(utf8.encode('tampered-archive-bytes'));
          } else {
            req.response.add(payloadBytes);
          }
        } else {
          req.response.statusCode = 404;
        }
        await req.response.close();
      });

      final tmpDir = await Directory.systemTemp.createTemp('wencrypt-upd-test-');
      addTearDown(() async {
        if (await tmpDir.exists()) await tmpDir.delete(recursive: true);
      });
      final dataDir = Directory('${tmpDir.path}/data');
      final dlTempDir = Directory('${tmpDir.path}/downloads');

      final bridge = _FakeUpdaterBridge(
        runtimeInfo: const AppRuntimeInfo(
          version: '0.3.9',
          installPath: '/Applications/wencrypt.app',
          canAutoInstall: true,
          isSandboxed: false,
        ),
      );
      final controller = AppUpdateController(
        bridge: bridge,
        platformOverride: UpdatePlatform.macos,
        tempDirProvider: () async => dlTempDir,
        latestReleaseApiUri: Uri.parse('http://127.0.0.1:${server.port}/latest'),
        allowUntrustedHostsForTest: true,
      );
      addTearDown(controller.dispose);

      await controller.initialize(dataDir);
      expect(controller.autoCheckEnabled, isTrue);
      await controller.setAutoCheckEnabled(false);
      final reloaded = await UpdatePreferences.load(dataDir);
      expect(reloaded.autoCheckEnabled, isFalse);

      await controller.checkForUpdates();
      expect(controller.status, UpdateStatus.available);
      expect(controller.hasUpdate, isTrue);
      expect(controller.canInstallInApp, isTrue);

      // 1. Corrupt archive must fail closed and delete downloaded file.
      serveCorruptArchive = true;
      var lockCalled = false;
      final corruptResult = await controller.downloadAndInstallUpdate(
        beforeRestart: () async => lockCalled = true,
      );
      expect(corruptResult, isFalse);
      expect(controller.status, UpdateStatus.error);
      expect(lockCalled, isFalse);
      expect(bridge.installedArchivePath, isNull);
      if (await dlTempDir.exists()) {
        expect(dlTempDir.listSync(), isEmpty);
      }

      // 2. Missing SHA256SUMS.txt refuses install.
      omitChecksumFile = true;
      await controller.checkForUpdates();
      expect(controller.canInstallInApp, isFalse);
      expect(await controller.downloadAndInstallUpdate(), isFalse);
      expect(controller.status, UpdateStatus.error);

      // 3. Valid archive verifies SHA-256, calls beforeRestart, and invokes native install.
      omitChecksumFile = false;
      serveCorruptArchive = false;
      await controller.checkForUpdates();
      final okResult = await controller.downloadAndInstallUpdate(
        beforeRestart: () async => lockCalled = true,
      );
      expect(okResult, isTrue);
      expect(controller.status, UpdateStatus.installing);
      expect(lockCalled, isTrue);
      expect(bridge.installedSha256, validSha);
      expect(bridge.installedArchivePath, isNotNull);
      expect(File(bridge.installedArchivePath!).existsSync(), isTrue);
    }, _DirectHttpOverrides());
  });

  testWidgets('AboutUpdateView renders status, toggle, paths, and available update action', (
    tester,
  ) async {
    final bridge = _FakeUpdaterBridge(
      runtimeInfo: const AppRuntimeInfo(
        version: '0.3.9',
        installPath: '/Applications/wencrypt.app',
        canAutoInstall: true,
      ),
    );
    final upToDate = AppUpdateController.preview(
      platformOverride: UpdatePlatform.macos,
      currentVersion: '0.3.9',
      status: UpdateStatus.upToDate,
      autoCheckEnabled: true,
      dataDirectoryPath: '/Users/demo/Library/Application Support/org.wencrypt.wencrypt',
      installPath: '/Applications/wencrypt.app',
      bridge: bridge,
    );
    addTearDown(upToDate.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: wencryptTheme(Brightness.light),
        home: Scaffold(body: AboutUpdateView(controller: upToDate)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Wencrypt'), findsOneWidget);
    expect(find.text('v0.3.9'), findsOneWidget);
    expect(find.text('已是最新版本'), findsOneWidget);
    expect(find.text('检查更新'), findsOneWidget);
    expect(find.text('自动检查更新'), findsOneWidget);
    expect(find.text('在访达中显示'), findsOneWidget);
    expect(find.text('GitHub Releases'), findsOneWidget);
    expect(find.text('GitHub'), findsOneWidget);

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(upToDate.autoCheckEnabled, isFalse);

    await tester.tap(find.text('在访达中显示'));
    await tester.pump();
    expect(
      bridge.openedDirectory,
      '/Users/demo/Library/Application Support/org.wencrypt.wencrypt',
    );

    await tester.tap(find.text('GitHub'));
    await tester.pump();
    expect(bridge.openedUrl, kGitHubReleasesUrl);

    final available = AppUpdateController.preview(
      platformOverride: UpdatePlatform.macos,
      currentVersion: '0.3.9',
      status: UpdateStatus.available,
      canAutoInstall: true,
      latestRelease: UpdateReleaseInfo(
        version: AppVersion.tryParse('0.4.0')!,
        tagName: 'v0.4.0',
        releaseUrl: '$kGitHubReleasesUrl/tag/v0.4.0',
        notes: '支持应用内一键自动更新',
        assetName: 'wencrypt-v0.4.0-macos-arm64.dmg',
        downloadUrl: '$kGitHubReleasesUrl/download/v0.4.0/wencrypt-v0.4.0-macos-arm64.dmg',
        sha256AssetUrl: '$kGitHubReleasesUrl/download/v0.4.0/SHA256SUMS.txt',
        canInstallAsset: true,
      ),
    );
    addTearDown(available.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: wencryptTheme(Brightness.light),
        home: Scaffold(body: AboutUpdateView(controller: available)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('发现新版本 v0.4.0'), findsOneWidget);
    expect(find.text('下载并更新'), findsOneWidget);
    expect(find.textContaining('支持应用内一键自动更新'), findsOneWidget);
  });

  testWidgets('VaultPage navigates to AboutUpdateView on desktop and mobile cleanly', (
    tester,
  ) async {
    final previewUpdater = AppUpdateController.preview(
      platformOverride: UpdatePlatform.macos,
      currentVersion: '0.3.9',
      status: UpdateStatus.upToDate,
    );
    addTearDown(previewUpdater.dispose);

    tester.view.physicalSize = const Size(1100, 760);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: wencryptTheme(Brightness.light),
        home: VaultPage(
          preview: VaultPreview(
            unlocked: true,
            updateController: previewUpdater,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('关于与更新'), findsOneWidget);
    await tester.tap(find.text('关于与更新'));
    await tester.pumpAndSettle();

    expect(find.text('已是最新版本'), findsOneWidget);
    expect(find.text('GitHub Releases'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // Verify 390px mobile settings entry and navigation without overflow.
    tester.view.physicalSize = const Size(390, 844);
    await tester.pumpWidget(
      MaterialApp(
        theme: wencryptTheme(Brightness.light),
        home: VaultPage(
          key: const ValueKey('mobile-about-settings'),
          preview: VaultPreview(
            unlocked: true,
            mobileLayout: true,
            showSettings: true,
            updateController: previewUpdater,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.drag(find.byType(ListView), const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(find.text('关于与更新'), findsOneWidget);
    await tester.tap(find.text('关于与更新'));
    await tester.pumpAndSettle();
    expect(find.text('已是最新版本'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
