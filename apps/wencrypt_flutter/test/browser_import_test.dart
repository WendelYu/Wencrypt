import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:wencrypt/browser_import.dart';

void main() {
  testWidgets('identifies browser CSV and imports only selected rows', (
    tester,
  ) async {
    final batch = BrowserExport.parse(
      '\uFEFF"name","url","username","password"\r\n"A","https://a","alice","00123"\r\n"B","https://b","bob","p,2"',
    );
    expect(batch.source, contains('Chrome'));
    List<Map<String, String>>? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await selectPasswords(context, batch, [
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
    expect(find.text('选择要导入的账号（1/2）'), findsOneWidget);
    expect(find.text('00123'), findsNothing);
    await tester.tap(find.text('导入所选账号'));
    await tester.pumpAndSettle();
    expect(result?.single['password'], 'p,2');
    expect(batch.rows.first['password'], '00123');
  });
}
