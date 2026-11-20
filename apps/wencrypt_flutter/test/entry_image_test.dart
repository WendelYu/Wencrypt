import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:wencrypt/entry_image.dart';

void main() {
  testWidgets('account image preview requires opt-in to show the password', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EntryImageDialog(
            entry: {
              'title': '测试账号',
              'username': 'public-test-user',
              'url': 'https://example.invalid',
              'password': 'mock-password',
              'notes': 'private mock notes',
            },
            toAlbum: true,
            onExport: (_) async {},
          ),
        ),
      ),
    );
    expect(find.text('保存到相册'), findsOneWidget);
    expect(find.text('public-test-user'), findsOneWidget);
    expect(find.text('mock-password'), findsNothing);
    expect(find.text('private mock notes'), findsNothing);

    await tester.tap(find.text('在图片中包含密码'));
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
                await showDialog<bool>(
                  context: context,
                  builder: (_) => EntryImageDialog(
                    entry: const {'title': '测试账号', 'username': 'sample'},
                    toAlbum: false,
                    onExport: (png) async {
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
    expect(find.text('导出账号图片'), findsNothing);
  });
}
