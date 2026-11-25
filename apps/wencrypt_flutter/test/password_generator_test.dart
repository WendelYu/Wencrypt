import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:wencrypt/design/wencrypt_theme.dart';
import 'package:wencrypt/password_generator.dart';

void main() {
  group('PasswordGeneratorOptions & generateSecurePassword', () {
    test('clamps length and calculates positive entropy', () {
      const low = PasswordGeneratorOptions(length: 2);
      const high = PasswordGeneratorOptions(length: 120);
      expect(low.clampedLength, 8);
      expect(high.clampedLength, 64);
      expect(const PasswordGeneratorOptions().entropyBits, greaterThan(100));
    });

    test('throws ArgumentError when all character classes are disabled', () {
      const empty = PasswordGeneratorOptions(
        uppercase: false,
        lowercase: false,
        digits: false,
        symbols: false,
      );
      expect(() => generateSecurePassword(empty), throwsArgumentError);
    });

    test('includes every enabled character class and respects length', () {
      final rng = Random(42);
      for (final length in [8, 12, 20, 32, 64]) {
        final options = PasswordGeneratorOptions(
          length: length,
          excludeAmbiguous: false,
        );
        final password = generateSecurePassword(options, random: rng);
        expect(password.length, length);
        expect(RegExp(r'[A-Z]').hasMatch(password), isTrue);
        expect(RegExp(r'[a-z]').hasMatch(password), isTrue);
        expect(RegExp(r'[0-9]').hasMatch(password), isTrue);
        expect(RegExp(r'[!@#%&*+\-_=?]').hasMatch(password), isTrue);
      }
    });

    test('excludes ambiguous characters when excludeAmbiguous is enabled', () {
      final rng = Random(7);
      const options = PasswordGeneratorOptions(
        length: 64,
        excludeAmbiguous: true,
      );
      for (var i = 0; i < 20; i++) {
        final password = generateSecurePassword(options, random: rng);
        expect(RegExp(r'[0Oo1lI]').hasMatch(password), isFalse);
      }
    });

    test('buildStyledPasswordSpan color-codes letters, digits, and symbols', () {
      const base = TextStyle(fontSize: 16);
      final span = buildStyledPasswordSpan(
        'Ab12!@',
        colors: WColors.light,
        baseStyle: base,
      );
      expect(span.toPlainText(), 'Ab12!@');
      final children = span.children!.cast<TextSpan>();
      expect(children, hasLength(3));
      expect(children[0].text, 'Ab');
      expect(children[0].style?.color, WColors.light.textPrimary);
      expect(children[1].text, '12');
      expect(children[1].style?.color, WColors.light.brand);
      expect(children[2].text, '!@');
      expect(children[2].style?.color, WColors.light.warning);
    });
  });

  group('showPasswordGeneratorDialog', () {
    testWidgets('desktop standalone mode configures options and returns action', (
      tester,
    ) async {
      PasswordGeneratorResult? captured;

      await tester.pumpWidget(
        MaterialApp(
          theme: wencryptTheme(Brightness.light),
          home: Builder(
            builder: (context) => Scaffold(
              body: FilledButton(
                onPressed: () async {
                  captured = await showPasswordGeneratorDialog(
                    context,
                    initialOptions: const PasswordGeneratorOptions(length: 16),
                    mobile: false,
                  );
                },
                child: const Text('打开生成器'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('打开生成器'));
      await tester.pumpAndSettle();

      expect(find.text('随机密码生成器'), findsOneWidget);
      expect(find.text('16 位'), findsAtLeastNWidgets(1));

      await tester.tap(find.text('32 位'));
      await tester.pumpAndSettle();
      expect(find.text('32 位'), findsAtLeastNWidgets(2));

      // Disable 3 classes; the final remaining class cannot be disabled.
      await tester.tap(find.text('大写字母 (A-Z)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('小写字母 (a-z)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('特殊符号 (!@#…)'));
      await tester.pumpAndSettle();
      expect(find.text('至少保留一种字符类型'), findsOneWidget);

      await tester.tap(find.text('数字 (0-9)'));
      await tester.pumpAndSettle();
      final chip = tester.widget<FilterChip>(
        find.widgetWithText(FilterChip, '数字 (0-9)'),
      );
      expect(chip.selected, isTrue);

      await tester.tap(find.text('用此密码新增账号'));
      await tester.pumpAndSettle();

      expect(captured, isNotNull);
      expect(captured!.action, PasswordGeneratorAction.createAccount);
      expect(captured!.password, hasLength(32));
      expect(RegExp(r'^[2-9]+$').hasMatch(captured!.password), isTrue);
      expect(captured!.options.length, 32);
    });

    testWidgets('desktop copy action copies password and pops with copy action', (
      tester,
    ) async {
      String? copiedText;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              copiedText = (call.arguments as Map)['text'] as String?;
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );

      PasswordGeneratorResult? captured;
      await tester.pumpWidget(
        MaterialApp(
          theme: wencryptTheme(Brightness.light),
          home: Builder(
            builder: (context) => Scaffold(
              body: FilledButton(
                onPressed: () async {
                  captured = await showPasswordGeneratorDialog(
                    context,
                    initialOptions: const PasswordGeneratorOptions(),
                    mobile: false,
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
      await tester.tap(find.widgetWithText(OutlinedButton, '复制密码'));
      await tester.pumpAndSettle();

      expect(captured?.action, PasswordGeneratorAction.copy);
      expect(copiedText, captured?.password);
    });

    testWidgets('mobile picker mode renders cleanly at 390px and applies password', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      PasswordGeneratorResult? captured;
      await tester.pumpWidget(
        MaterialApp(
          theme: wencryptTheme(Brightness.light),
          home: Builder(
            builder: (context) => Scaffold(
              body: FilledButton(
                onPressed: () async {
                  captured = await showPasswordGeneratorDialog(
                    context,
                    initialOptions: const PasswordGeneratorOptions(length: 20),
                    mobile: true,
                    pickerMode: true,
                  );
                },
                child: const Text('picker'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('picker'));
      await tester.pumpAndSettle();

      expect(find.text('使用此密码'), findsOneWidget);
      await tester.tap(find.byTooltip('重新生成'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('使用此密码'));
      await tester.pumpAndSettle();

      expect(captured?.action, PasswordGeneratorAction.apply);
      expect(captured?.password, hasLength(20));
      expect(tester.takeException(), isNull);
    });
  });
}
