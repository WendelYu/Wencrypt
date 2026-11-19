import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:wencrypt/design/wencrypt_theme.dart';
import 'package:wencrypt/main.dart';
import 'package:wencrypt/sync.dart';

void main() {
  testWidgets('manual sync lists enabled folders and can be cancelled', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: wencryptTheme(Brightness.light),
        home: const VaultPage(
          preview: VaultPreview(
            unlocked: true,
            syncConfigured: true,
            syncTargets: [
              {'folder': 'fixture-active', 'enabled': true},
              {'folder': 'fixture-disabled', 'enabled': false},
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('立即同步'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final dialog = find.byType(AlertDialog);
    expect(find.text('同步到坚果云？'), findsOneWidget);
    expect(
      find.descendant(
        of: dialog,
        matching: find.textContaining('fixture-active'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: dialog,
        matching: find.textContaining('fixture-disabled'),
      ),
      findsNothing,
    );
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    expect(dialog, findsNothing);
    expect(find.byTooltip('正在同步…'), findsNothing);
  });

  testWidgets('each change-password field can reveal and hide its own value', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: wencryptTheme(Brightness.light),
        home: const VaultPage(preview: VaultPreview(unlocked: true)),
      ),
    );
    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('修改主密码'));
    await tester.pumpAndSettle();
    final fields = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(EditableText),
    );
    expect(tester.widgetList<EditableText>(fields).map((e) => e.obscureText), [
      true,
      true,
      true,
    ]);
    await tester.enterText(fields.at(1), 'fixture-only password');
    await tester.tap(find.byTooltip('显示新主密码'));
    await tester.pumpAndSettle();
    expect(tester.widgetList<EditableText>(fields).map((e) => e.obscureText), [
      true,
      false,
      true,
    ]);
    await tester.tap(find.byTooltip('隐藏新主密码'));
    await tester.pumpAndSettle();
    final field = tester.widget<EditableText>(fields.at(1));
    expect(field.obscureText, isTrue);
    expect(field.controller.text, 'fixture-only password');
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
  });

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

  testWidgets(
    'join keeps pasted values when switching apps and shows errors in place',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: wencryptTheme(Brightness.light),
          home: const VaultPage(preview: VaultPreview(exists: false)),
        ),
      );
      await tester.tap(find.text('加入已有库'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('从坚果云加入'));
      await tester.pumpAndSettle();
      final fields = find.byType(TextFormField);
      await tester.enterText(fields.at(0), 'fixture@example.com');
      await tester.enterText(fields.at(1), 'fixture-app-password');
      await tester.enterText(
        fields.at(2),
        'https://example.com/invalid-folder',
      );
      await tester.enterText(fields.at(3), 'fixture master password');
      await tester.tap(find.byTooltip('显示WebDAV 应用密码'));
      await tester.pumpAndSettle();
      final inputs = find.byType(EditableText);
      expect(tester.widget<EditableText>(inputs.at(1)).obscureText, isFalse);
      expect(tester.widget<EditableText>(inputs.at(3)).obscureText, isTrue);
      await tester.tap(find.byTooltip('显示已有库的主密码'));
      await tester.pumpAndSettle();

      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pump();
      for (final state in [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pumpAndSettle();
      expect(
        tester.widget<EditableText>(inputs.at(1)).controller.text,
        'fixture-app-password',
      );
      expect(
        tester.widget<EditableText>(inputs.at(3)).controller.text,
        'fixture master password',
      );
      expect(tester.widget<EditableText>(inputs.at(3)).obscureText, isFalse);

      await tester.tap(find.widgetWithText(FilledButton, '加入密码库'));
      await tester.pumpAndSettle();
      expect(find.textContaining('读取云端密码库失败。请填写有效的'), findsOneWidget);
      expect(
        tester.widget<EditableText>(inputs.at(3)).controller.text,
        'fixture master password',
      );
    },
  );

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
