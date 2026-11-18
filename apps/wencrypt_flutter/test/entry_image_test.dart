import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:wencrypt/entry_image.dart';

void main() {
  testWidgets('account image preview requires opt-in to show the password', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
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

  testWidgets('desktop export produces a valid PNG', (tester) async {
    final result = Completer<Uint8List?>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result.complete(
                  await showDialog<Uint8List>(
                    context: context,
                    builder: (_) => const EntryImageDialog(
                      entry: {'title': '测试账号', 'username': 'sample'},
                      toAlbum: false,
                    ),
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

    await tester.runAsync(() async {
      await tester.tap(find.text('复制图片'));
      await tester.pump();
    });
    for (var attempt = 0; attempt < 40 && !result.isCompleted; attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump();
    }
    expect(result.isCompleted, isTrue);
    final png = await result.future;
    expect(png?.sublist(0, 8), const [137, 80, 78, 71, 13, 10, 26, 10]);
    await tester.pumpAndSettle();
  });
}
