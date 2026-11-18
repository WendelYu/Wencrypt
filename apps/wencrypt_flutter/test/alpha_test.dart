import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wencrypt/main.dart';
import 'package:wencrypt/sync.dart';

void main() {
  testWidgets('first launch separates creation and joining', (tester) async {
    await tester.pumpWidget(const WencryptApp());
    await tester.pumpAndSettle();
    expect(find.text('欢迎使用 Wencrypt'), findsOneWidget);
    expect(find.text('新增账号'), findsNothing);
    expect(find.text('主密码（至少 12 个字符）'), findsNothing);

    await tester.tap(find.text('创建新库'));
    await tester.pumpAndSettle();
    expect(find.text('主密码（至少 12 个字符）'), findsOneWidget);
    expect(find.text('再次输入主密码'), findsOneWidget);
    expect(find.text('从加密备份恢复'), findsNothing);

    await tester.tap(find.text('返回'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('加入已有库'));
    await tester.pumpAndSettle();
    expect(find.text('从坚果云加入'), findsOneWidget);
    expect(find.text('从加密备份恢复'), findsOneWidget);
    expect(find.text('主密码（至少 12 个字符）'), findsNothing);
  });
  test('budget survives restarts and refuses excess requests', () async {
    final dir = await Directory.systemTemp.createTemp('wencrypt-budget-test');
    try {
      final file = File('${dir.path}/budget.json');
      for (var i = 0; i < 80; i++) {
        await SyncBudget(file).reserve(100, 200);
      }
      await expectLater(SyncBudget(file).reserve(100, 200), throwsStateError);
      final ledger =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      expect(ledger['up'], 8000);
      expect(ledger['down'], 16000);
    } finally {
      await dir.delete(recursive: true);
    }
  });
  test('oversize reservation does not spend either budget', () async {
    final dir = await Directory.systemTemp.createTemp('wencrypt-budget-test');
    try {
      final file = File('${dir.path}/budget.json');
      await expectLater(
        SyncBudget(file).reserve(101 * 1024 * 1024, 0),
        throwsStateError,
      );
      expect(await file.exists(), false);
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
