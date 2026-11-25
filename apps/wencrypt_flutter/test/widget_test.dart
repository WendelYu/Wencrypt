import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:wencrypt/design/wencrypt_theme.dart';
import 'package:wencrypt/design/wencrypt_widgets.dart';
import 'package:wencrypt/main.dart';

void main() {
  testWidgets('WencryptApp renders first-run screen without diagnostics entry', (
    tester,
  ) async {
    await tester.pumpWidget(const WencryptApp());
    await tester.pumpAndSettle();
    expect(find.text('Wencrypt'), findsOneWidget);
    expect(find.text('创建新库'), findsOneWidget);
    expect(find.text('设备诊断'), findsNothing);
  });

  testWidgets('device diagnostics is absent from desktop and mobile settings', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: wencryptTheme(Brightness.light),
        home: const VaultPage(preview: VaultPreview(unlocked: true)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();
    expect(find.text('设备诊断'), findsNothing);
    expect(find.text('系统工具'), findsNothing);

    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: wencryptTheme(Brightness.light),
        home: const VaultPage(
          key: ValueKey('mobile-settings-no-probe'),
          preview: VaultPreview(
            unlocked: true,
            mobileLayout: true,
            showSettings: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('外观主题'), findsOneWidget);
    expect(find.text('设备诊断'), findsNothing);
  });

  testWidgets(
    'desktop group switch, search input/paste, and password reveal work with semantics enabled',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        tester.view.physicalSize = const Size(1100, 760);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          theme: wencryptTheme(Brightness.light),
          home: const VaultPage(
            key: ValueKey('desktop-semantics-regression'),
            preview: VaultPreview(
              unlocked: true,
              entries: [
                {
                  'id': 'rev-1',
                  'entry': 'entry-1',
                  'deleted': false,
                  'data': {
                    'title': 'GitHub',
                    'username': 'first@example.com',
                    'password': 'First-Password-123!',
                    'url': 'https://github.com',
                    'tags': '开发',
                    'notes': 'Primary account note',
                  },
                },
                {
                  'id': 'rev-2',
                  'entry': 'entry-2',
                  'deleted': false,
                  'data': {
                    'title': 'Linear',
                    'username': 'second@example.com',
                    'password': 'Second-Password-456!',
                    'url': 'https://linear.app',
                    'tags': '工作',
                    'notes': 'Secondary account note',
                  },
                },
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        tester.widget<WAccountDetailPanel>(find.byType(WAccountDetailPanel)).key,
        const ValueKey('rev-1'),
      );
      expect(find.text('first@example.com'), findsWidgets);

      final workGroup = find.ancestor(
        of: find.byIcon(Icons.folder_outlined),
        matching: find.widgetWithText(InkWell, '工作'),
      );
      expect(workGroup, findsOneWidget);
      await tester.tap(workGroup);
      await tester.pumpAndSettle();

      expect(
        tester.widget<WAccountDetailPanel>(find.byType(WAccountDetailPanel)).key,
        const ValueKey('rev-2'),
      );
      expect(find.text('second@example.com'), findsWidgets);
      expect(find.text('first@example.com'), findsNothing);

      final vaultAll = find.ancestor(
        of: find.byIcon(Icons.key_outlined),
        matching: find.widgetWithText(InkWell, '密码库'),
      );
      expect(vaultAll, findsOneWidget);
      await tester.tap(vaultAll);
      await tester.pumpAndSettle();
      expect(
        tester.widget<WAccountDetailPanel>(find.byType(WAccountDetailPanel)).key,
        const ValueKey('rev-1'),
      );

      final searchField = find.byType(TextField);
      expect(searchField, findsOneWidget);
      await tester.tap(searchField);
      await tester.enterText(searchField, 'Linear');
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();

      expect(
        tester.widget<WAccountDetailPanel>(find.byType(WAccountDetailPanel)).key,
        const ValueKey('rev-2'),
      );
      expect(find.text('second@example.com'), findsWidgets);
      expect(find.text('first@example.com'), findsNothing);

        await tester.tap(find.byTooltip('显示密码'));
        await tester.pumpAndSettle();
        expect(find.text('Second-Password-456!'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    },
  );
}
