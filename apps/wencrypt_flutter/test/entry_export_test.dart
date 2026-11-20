import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:wencrypt/entry_export.dart';

void main() {
  testWidgets('account image preview requires opt-in to show the password', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EntryExportDialog(
            entry: {
              'title': '测试账号',
              'username': 'public-test-user',
              'url': 'https://example.invalid',
              'password': 'mock-password',
              'notes': 'private mock notes',
            },
            toAlbum: true,
            onExportImage: (_) async {},
            onCopyText: (_) async {},
          ),
        ),
      ),
    );
    expect(find.text('保存到相册'), findsOneWidget);
    expect(find.text('public-test-user'), findsOneWidget);
    expect(find.text('mock-password'), findsNothing);
    expect(find.text('private mock notes'), findsNothing);

    await tester.tap(find.text('包含密码'));
    await tester.pumpAndSettle();
    expect(find.text('mock-password'), findsOneWidget);
    expect(find.text('private mock notes'), findsNothing);
  });

  testWidgets('desktop export stays open after clipboard failure and retries', (
    tester,
  ) async {
    Uint8List? savedPng;
    var attempts = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                await showDialog<EntryExportFormat>(
                  context: context,
                  builder: (_) => EntryExportDialog(
                    entry: const {'title': '测试账号', 'username': 'sample'},
                    toAlbum: false,
                    onCopyText: (_) async => fail('Unexpected text copy'),
                    onExportImage: (png) async {
                      if (++attempts == 1) {
                        throw PlatformException(code: 'clipboard_busy');
                      }
                      savedPng = Uint8List.fromList(png);
                    },
                  ),
                );
              },
              child: const Text('打开预览'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开预览'));
    await tester.pumpAndSettle();

    Future<void> export(int expectedAttempts) async {
      await tester.runAsync(() async {
        await tester.tap(find.text('复制图片'));
        await tester.pump();
      });
      for (var tick = 0; tick < 40 && attempts < expectedAttempts; tick++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 25)),
        );
        await tester.pump();
      }
      expect(attempts, expectedAttempts);
      await tester.pumpAndSettle();
    }

    await export(1);
    expect(find.textContaining('剪贴板正被其他应用占用'), findsOneWidget);
    await export(2);
    expect(savedPng?.sublist(0, 8), const [137, 80, 78, 71, 13, 10, 26, 10]);
    expect(find.text('导出账号'), findsNothing);
  });

  testWidgets('text export copies the preview and omits secrets by default', (
    tester,
  ) async {
    String? copied;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<EntryExportFormat>(
                context: context,
                builder: (_) => EntryExportDialog(
                  entry: const {
                    'title': '测试账号',
                    'username': 'sample',
                    'url': 'https://example.invalid',
                    'password': 'fixture-password',
                    'notes': 'private fixture notes',
                  },
                  toAlbum: false,
                  onExportImage: (_) async => fail('Unexpected image copy'),
                  onCopyText: (text) async {
                    copied = text;
                  },
                ),
              ),
              child: const Text('打开导出'),
            ),
          ),
        ),
      ),
    );
    Future<void> previewText() async {
      await tester.tap(find.text('打开导出'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('文字'));
      await tester.pumpAndSettle();
    }

    await previewText();
    expect(find.textContaining('fixture-password'), findsNothing);
    await tester.tap(find.text('复制文字'));
    await tester.pumpAndSettle();
    expect(copied, '账号名称：测试账号\n用户名：sample\n网址：https://example.invalid');
    await previewText();
    await tester.tap(find.text('包含密码'));
    await tester.pumpAndSettle();
    expect(find.textContaining('fixture-password'), findsOneWidget);
    await tester.tap(find.text('复制文字'));
    await tester.pumpAndSettle();
    expect(copied, contains('密码：fixture-password'));
    expect(copied, isNot(contains('private fixture notes')));
  });
}
