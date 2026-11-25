import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:wencrypt/design/wencrypt_theme.dart';
import 'package:wencrypt/password_generator.dart';
import 'package:wencrypt/screenshot_import.dart';
import 'package:wencrypt/screenshot_import_dialog.dart';

// 2x2 RGBA PNG fixture used for widget image preview tests.
final _testPngBytes = Uint8List.fromList([
  0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00,
  0x00, 0x0d, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x02,
  0x00, 0x00, 0x00, 0x02, 0x08, 0x06, 0x00, 0x00, 0x00, 0x72,
  0xb6, 0x0d, 0x24, 0x00, 0x00, 0x00, 0x12, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9c, 0x63, 0xf8, 0xcf, 0xc0, 0xf0, 0x1f, 0x0c,
  0x81, 0x34, 0x18, 0x00, 0x00, 0x49, 0xc8, 0x09, 0xf7, 0xf9,
  0xab, 0xb6, 0x0d, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e,
  0x44, 0xae, 0x42, 0x60, 0x82,
]);

void main() {
  group('normalizeCjkSpacing & masked password detection', () {
    test('collapses Windows OCR spaces inside Chinese labels without breaking ASCII', () {
      expect(normalizeCjkSpacing('用 户 名 ： alice@example.com'), '用户名：alice@example.com');
      expect(normalizeCjkSpacing('确 认 密 码'), '确认密码');
      expect(normalizeCjkSpacing('Sign up for GitHub'), 'Sign up for GitHub');
    });

    test('detects masked password placeholders accurately', () {
      expect(isMaskedPasswordText('••••••••'), isTrue);
      expect(isMaskedPasswordText('******'), isTrue);
      expect(isMaskedPasswordText('●●●●●●'), isTrue);
      expect(isMaskedPasswordText('Pass#1234'), isFalse);
      expect(isMaskedPasswordText('密码 *'), isFalse);
    });
  });

  group('parseCredentialFromOcr & parseCredentialFromText', () {
    test('extracts inline Chinese fields and leaves unknown source empty', () {
      final parsed = parseCredentialFromText('''
14:32
5G
账号：alice@example.com
密码：Abc#98765
验证码：482910
请输入手机号
立即注册
''');
      expect(parsed.title, '');
      expect(parsed.username, 'alice@example.com');
      expect(parsed.password, 'Abc#98765');
      expect(parsed.passwordMasked, isFalse);
      expect(parsed.candidates, isNot(contains('482910')));
      expect(parsed.candidates, isNot(contains('立即注册')));
    });

    test('handles multi-pair single-line OCR blocks', () {
      final parsed = parseCredentialFromOcr([
        const OcrBlock(
          text: '账号：bob@company.org  密码：Z9#kL2!p',
          x: 0.1,
          y: 0.2,
          w: 0.8,
          h: 0.04,
        ),
      ]);
      expect(parsed.username, 'bob@company.org');
      expect(parsed.password, 'Z9#kL2!p');
    });

    test('extracts side-by-side spatial OCR blocks and heading title', () {
      final parsed = parseCredentialFromOcr([
        const OcrBlock(text: '注册 阿里云 账号', x: 0.2, y: 0.08, w: 0.6, h: 0.05),
        const OcrBlock(text: '用 户 名', x: 0.1, y: 0.25, w: 0.2, h: 0.04),
        const OcrBlock(text: 'cloud_admin', x: 0.36, y: 0.25, w: 0.4, h: 0.04),
        const OcrBlock(text: '密 码', x: 0.1, y: 0.35, w: 0.2, h: 0.04),
        const OcrBlock(text: 'Ali#2026Pass', x: 0.36, y: 0.35, w: 0.4, h: 0.04),
        const OcrBlock(text: '验 证 码', x: 0.1, y: 0.45, w: 0.2, h: 0.04),
        const OcrBlock(text: '918273', x: 0.36, y: 0.45, w: 0.2, h: 0.04),
        const OcrBlock(text: '获取验证码', x: 0.65, y: 0.45, w: 0.25, h: 0.04),
      ]);
      expect(parsed.title, '阿里云');
      expect(parsed.username, 'cloud_admin');
      expect(parsed.password, 'Ali#2026Pass');
      expect(parsed.candidates, isNot(contains('918273')));
    });

    test('extracts stacked English registration layout and infers domain title', () {
      final parsed = parseCredentialFromOcr([
        const OcrBlock(text: 'https://github.com/signup', x: 0.1, y: 0.05, w: 0.6, h: 0.03),
        const OcrBlock(text: 'Email', x: 0.12, y: 0.20, w: 0.2, h: 0.03),
        const OcrBlock(text: 'dev@example.net', x: 0.12, y: 0.26, w: 0.5, h: 0.04),
        const OcrBlock(text: 'Password', x: 0.12, y: 0.36, w: 0.2, h: 0.03),
        const OcrBlock(text: 'Gh#Strong99!', x: 0.12, y: 0.42, w: 0.5, h: 0.04),
        const OcrBlock(text: 'At least 8 characters', x: 0.12, y: 0.48, w: 0.5, h: 0.03),
        const OcrBlock(text: 'Create account', x: 0.12, y: 0.60, w: 0.7, h: 0.06),
      ]);
      expect(parsed.title, 'GitHub');
      expect(parsed.url, 'https://github.com/signup');
      expect(parsed.username, 'dev@example.net');
      expect(parsed.password, 'Gh#Strong99!');
    });

    test('flags masked passwords instead of inserting bullet dots', () {
      final parsed = parseCredentialFromText('''
Email: masked@example.org
Password: ••••••••
''');
      expect(parsed.username, 'masked@example.org');
      expect(parsed.password, '');
      expect(parsed.passwordMasked, isTrue);
    });

    test('normalizes full-width punctuation emitted next to CJK password labels', () {
      final parsed = parseCredentialFromText('''
用户名：alice.chen@example.com
密码：Abc#7890Xy！
''');
      expect(parsed.username, 'alice.chen@example.com');
      expect(parsed.password, 'Abc#7890Xy!');
    });

    test('falls back to unlabeled email and password token below it', () {
      final parsed = parseCredentialFromOcr([
        const OcrBlock(text: 'support@someportal.io', x: 0.1, y: 0.10, w: 0.5, h: 0.03),
        const OcrBlock(text: 'user.name@mail.com', x: 0.15, y: 0.30, w: 0.5, h: 0.04),
        const OcrBlock(text: 'Xy9!qW2#Lm', x: 0.15, y: 0.39, w: 0.4, h: 0.04),
      ]);
      expect(parsed.title, '');
      expect(parsed.username, 'user.name@mail.com');
      expect(parsed.password, 'Xy9!qW2#Lm');
    });
  });

  group('ScreenshotOcrService', () {
    test('maps ocr_unavailable errors cleanly', () async {
      const channel = MethodChannel('wencrypt.test.ocr');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'recognizeImage') {
              throw PlatformException(code: 'ocr_unavailable');
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );

      const service = ScreenshotOcrService(channel: channel);
      await expectLater(
        () => service.recognizeImage(_testPngBytes),
        throwsA(
          isA<ScreenshotOcrException>().having(
            (e) => e.message,
            'message',
            contains('OCR'),
          ),
        ),
      );
    });
  });

  group('showScreenshotImportDialog', () {
    testWidgets('auto-reads clipboard screenshot, autofocuses empty title, and saves', (
      tester,
    ) async {
      const channel = MethodChannel('wencrypt.test.ocr.dialog');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'readClipboardImage') return _testPngBytes;
            if (call.method == 'recognizeImage') {
              return {
                'text': '账号：reg_alice@example.com\n密码：P@ssw0rd!2026',
                'blocks': [
                  {
                    'text': '账号：reg_alice@example.com',
                    'x': 0.1,
                    'y': 0.2,
                    'w': 0.7,
                    'h': 0.05,
                  },
                  {
                    'text': '密码：P@ssw0rd!2026',
                    'x': 0.1,
                    'y': 0.35,
                    'w': 0.7,
                    'h': 0.05,
                  },
                ],
              };
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );

      Map<String, String>? saved;
      await tester.pumpWidget(
        MaterialApp(
          theme: wencryptTheme(Brightness.light),
          home: Builder(
            builder: (context) => Scaffold(
              body: FilledButton(
                onPressed: () async {
                  saved = await showScreenshotImportDialog(
                    context,
                    mobile: false,
                    groupOptions: const ['开发', '工作'],
                    initialGroup: '开发',
                    generatorOptions: const PasswordGeneratorOptions(),
                    ocrService: const ScreenshotOcrService(channel: channel),
                  );
                },
                child: const Text('截图导入'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('截图导入'));
      await tester.pumpAndSettle();

      // Plaintext password & username pre-filled; empty source name prompts validation.
      expect(find.text('reg_alice@example.com'), findsAtLeastNWidgets(1));
      expect(find.text('P@ssw0rd!2026'), findsAtLeastNWidgets(1));
      expect(find.textContaining('请填写「来源 / 名称」'), findsOneWidget);

      await tester.tap(find.text('保存账号'));
      await tester.pumpAndSettle();
      expect(find.text('请填写来源或名称'), findsOneWidget);

      await tester.enterText(find.byType(TextField).first, '测试服务');
      await tester.tap(find.text('保存账号'));
      await tester.pumpAndSettle();

      expect(saved, isNotNull);
      expect(saved!['title'], '测试服务');
      expect(saved!['username'], 'reg_alice@example.com');
      expect(saved!['password'], 'P@ssw0rd!2026');
      expect(saved!['tags'], '开发');
    });

    testWidgets('shows masked-password warning and supports candidate chip assignment', (
      tester,
    ) async {
      const channel = MethodChannel('wencrypt.test.ocr.masked');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'readClipboardImage') return null;
            if (call.method == 'recognizeImage') {
              return {
                'text': 'MyPortal\nEmail: masked@test.dev\nPassword: ••••••••',
                'blocks': [
                  {'text': 'MyPortal', 'x': 0.1, 'y': 0.1, 'w': 0.3, 'h': 0.04},
                  {
                    'text': 'Email: masked@test.dev',
                    'x': 0.1,
                    'y': 0.2,
                    'w': 0.6,
                    'h': 0.04,
                  },
                  {
                    'text': 'Password: ••••••••',
                    'x': 0.1,
                    'y': 0.3,
                    'w': 0.6,
                    'h': 0.04,
                  },
                ],
              };
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: wencryptTheme(Brightness.light),
          home: Builder(
            builder: (context) => Scaffold(
              body: FilledButton(
                onPressed: () async {
                  await showScreenshotImportDialog(
                    context,
                    mobile: false,
                    groupOptions: const [],
                    generatorOptions: const PasswordGeneratorOptions(),
                    initialImageBytes: _testPngBytes,
                    ocrService: const ScreenshotOcrService(channel: channel),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.textContaining('密码已被星号或圆点遮盖'), findsOneWidget);

      // Assign candidate chip `MyPortal` to title via popup menu.
      final chipFinder = find.widgetWithText(Chip, 'MyPortal');
      await tester.ensureVisible(chipFinder);
      await tester.pumpAndSettle();
      await tester.tap(chipFinder);
      await tester.pumpAndSettle();
      await tester.tap(find.text('填入来源 / 名称'));
      await tester.pumpAndSettle();

      final titleField = tester.widget<TextField>(find.byType(TextField).first);
      expect(titleField.controller?.text, 'MyPortal');
    });

    testWidgets('mobile landing screen imports plain clipboard text cleanly at 390px', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      const channel = MethodChannel('wencrypt.test.ocr.mobile');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async => null);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.getData') {
              return <String, dynamic>{
                'text': 'https://gitlab.com/users/sign_up\nUsername: m_user\nPassword: MobilePass!99',
              };
            }
            return null;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
      });

      await tester.pumpWidget(
        MaterialApp(
          theme: wencryptTheme(Brightness.light),
          home: Builder(
            builder: (context) => Scaffold(
              body: FilledButton(
                onPressed: () async {
                  await showScreenshotImportDialog(
                    context,
                    mobile: true,
                    groupOptions: const [],
                    generatorOptions: const PasswordGeneratorOptions(),
                    ocrService: const ScreenshotOcrService(channel: channel),
                  );
                },
                child: const Text('mobile_open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('mobile_open'));
      await tester.pumpAndSettle();

      expect(find.text('识别剪贴板文字'), findsOneWidget);
      await tester.tap(find.text('识别剪贴板文字'));
      await tester.pumpAndSettle();

      expect(find.text('GitLab'), findsAtLeastNWidgets(1));
      expect(find.text('m_user'), findsAtLeastNWidgets(1));
      expect(find.text('MobilePass!99'), findsAtLeastNWidgets(1));
      expect(tester.takeException(), isNull);
    });
  });
}
