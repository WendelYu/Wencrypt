import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:wencrypt/browser_import.dart';

void main() {
  testWidgets('combines browser exports and skips duplicates by default', (
    tester,
  ) async {
    final batch = BrowserExport.parse(
      '\uFEFF"name","url","username","password"\r\n"A","https://a","alice","00123"\r\n"B","https://b","bob","p,2"',
    );
    expect(batch.source, contains('Chrome'));
    final second = BrowserExport.parse(
      'name,url,username,password\nB,https://b,bob,"p,2"',
    );
    final combined = BrowserExport.combine([batch, second]);
    expect(combined.source, '2 份浏览器导出文件');
    List<Map<String, String>>? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await selectPasswords(context, combined, [
                {'data': batch.rows.first},
              ]);
            },
            child: const Text('preview'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('preview'));
    await tester.pumpAndSettle();
    expect(find.text('选择要导入的账号（1/3）'), findsOneWidget);
    expect(find.text('00123'), findsNothing);
    await tester.tap(find.text('导入所选账号'));
    await tester.pumpAndSettle();
    expect(result?.single['password'], 'p,2');
    expect(batch.rows.first['password'], '00123');
  });

  test(
    'watcher ignores existing and non-password CSVs, captures new browser CSV, and shredFile deletes it',
    () async {
      final sep = Platform.pathSeparator;
      final tempDir = await Directory.systemTemp.createTemp('wencrypt-watch-');
      try {
        // Pre-existing browser CSV should be ignored by baseline snapshot.
        final oldCsv = File('${tempDir.path}${sep}old-passwords.csv');
        await oldCsv.writeAsString(
          'name,url,username,password\nOld,https://old.example,olduser,oldpass\n',
          flush: true,
        );

        final watcher = BrowserCsvWatcher(
          [tempDir],
          pollInterval: const Duration(milliseconds: 50),
          stabilityDelay: const Duration(milliseconds: 30),
        );
        await watcher.start();

        final completer = Completer<CapturedBrowserCsv>();
        final sub = watcher.onCaptured.listen((captured) {
          if (!completer.isCompleted) completer.complete(captured);
        });

        // Unrelated CSV without url/username/password headers should be ignored.
        final unrelated = File('${tempDir.path}${sep}statement.csv');
        await unrelated.writeAsString(
          'date,amount,merchant\n2026-11-18,12.5,Cafe\n',
          flush: true,
        );

        await Future<void>.delayed(const Duration(milliseconds: 120));
        expect(completer.isCompleted, isFalse);

        // Newly exported Edge/Chrome CSV should be captured.
        final exported = File(
          '${tempDir.path}${sep}Microsoft Edge Passwords.csv',
        );
        await exported.writeAsString(
          'name,url,username,password\nGitHub,https://github.com,wen,s3cr3t!\n',
          flush: true,
        );

        final captured = await completer.future.timeout(
          const Duration(seconds: 5),
        );
        expect(
          captured.file.path.replaceAll('\\', '/'),
          exported.path.replaceAll('\\', '/'),
        );
        expect(captured.export.rows.single['title'], 'GitHub');
        expect(captured.export.rows.single['password'], 's3cr3t!');

        // Shredding should delete the temporary CSV file cleanly.
        await shredFile(captured.file);
        expect(await exported.exists(), isFalse);
        expect(await unrelated.exists(), isTrue);

        await sub.cancel();
        watcher.dispose();
      } finally {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      }
    },
  );
}
