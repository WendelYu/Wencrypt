import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:wencrypt/design/wencrypt_theme.dart';
import 'package:wencrypt/main.dart';
import 'package:wencrypt/sync.dart';
import 'package:wencrypt/vault_invite.dart';

void main() {
  test('Windows theme keeps Chinese and Latin text in the same UI family', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    for (final brightness in Brightness.values) {
      final theme = wencryptTheme(brightness);
      expect(theme.textTheme.bodyMedium?.fontFamily, 'Microsoft YaHei UI');
      expect(theme.textTheme.titleSmall?.fontFamily, 'Microsoft YaHei UI');
      expect(
        theme.textTheme.bodySmall?.fontFamilyFallback,
        contains('Microsoft YaHei'),
      );
      final colors = theme.extension<WColors>()!;
      final fg = colors.textTertiary.computeLuminance();
      final bg = colors.surfaceMuted.computeLuminance();
      final contrast = fg > bg
          ? (fg + 0.05) / (bg + 0.05)
          : (bg + 0.05) / (fg + 0.05);
      expect(contrast, greaterThanOrEqualTo(4.5));
    }
  });

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

  testWidgets('switching to notifications saves the mode without syncing', (
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
              {'id': 'fixture', 'folder': 'shared', 'enabled': true},
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('坚果云与多备份设置'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('坚果云设置与多备份管理'), findsOneWidget);
    final mode = find.byWidgetPredicate(
      (widget) => widget is DropdownButton<SyncMode>,
    );
    await tester.ensureVisible(mode);
    await tester.tap(mode);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('自动同步'), findsOneWidget);
    await tester.tap(find.text('仅提醒').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('前台解锁时检查云端，确认后传输账号修订。'), findsOneWidget);
    await tester.tap(find.text('保存设置'));
    await tester.pumpAndSettle();
    expect(find.text('已保存本机同步设置'), findsOneWidget);
    expect(find.text('正在连接坚果云…'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
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

  testWidgets(
    'wide desktop uses master-detail inspector without duplicate FAB',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          theme: wencryptTheme(Brightness.light),
          home: const VaultPage(
            preview: VaultPreview(
              unlocked: true,
              entries: [
                {
                  'id': 'rev-1',
                  'entry': 'entry-1',
                  'deleted': false,
                  'data': {
                    'title': 'GitHub',
                    'username': 'fixture@example.com',
                    'password': 'Fixture-Password-123!',
                    'url': 'https://github.com',
                    'tags': '开发',
                    'notes': 'Fixture note one',
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
                    'notes': '',
                  },
                },
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Only one primary "新增账号" CTA on desktop (no floating FAB duplicate).
      expect(find.text('新增账号'), findsOneWidget);
      // Right-hand inspector displays the first account with masked password.
      expect(find.text('Fixture note one'), findsOneWidget);
      expect(find.text('Fixture-Password-123!'), findsNothing);

      // Reveal password in inspector.
      await tester.tap(find.byTooltip('显示密码'));
      await tester.pumpAndSettle();
      expect(find.text('Fixture-Password-123!'), findsOneWidget);

      // Selecting the second account switches the inspector and re-masks password.
      await tester.tap(find.text('Linear'));
      await tester.pumpAndSettle();
      expect(find.text('second@example.com'), findsOneWidget);
      expect(find.text('Second-Password-456!'), findsNothing);
    },
  );

  testWidgets('narrow desktop sidebar renders without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(860, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: wencryptTheme(Brightness.light),
        home: const VaultPage(preview: VaultPreview(unlocked: true)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Wencrypt'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('parseJoinInvite handles legacy v1, encrypted v2, and LAN tickets', () {
    const vaultId = '0123456789abcdef0123456789abcdef';
    final legacy = parseJoinInvite('wencrypt://join?folder=work&vault=$vaultId');
    expect(legacy, isA<LegacyVaultInvite>());
    expect((legacy as LegacyVaultInvite).invite.folder, 'work');
    expect(legacy.vaultId, vaultId);

    final payload = Uint8List(234);
    payload.setRange(0, 8, utf8.encode('WENCINV2'));
    payload.setRange(8, 16, utf8.encode('WENCRYPT'));
    payload[16] = 1;
    payload[17] = 0;
    payload[18] = 1;
    for (var i = 0; i < 16; i++) {
      payload[19 + i] = i;
    }
    final expectedVaultHex = '000102030405060708090a0b0c0d0e0f';
    final b64Payload = base64Url.encode(payload).replaceAll('=', '');

    final encUri = parseJoinInvite('wencrypt://join?v=2&p=$b64Payload');
    expect(encUri, isA<EncryptedVaultInvite>());
    expect(encUri!.vaultId, expectedVaultHex);

    final encPrefix = parseJoinInvite('wencrypt-invite:v2:$b64Payload');
    expect(encPrefix, isA<EncryptedVaultInvite>());
    expect(encPrefix!.vaultId, expectedVaultHex);

    final badShort = base64Url.encode(payload.sublist(0, 200)).replaceAll('=', '');
    expect(parseJoinInvite('wencrypt://join?v=2&p=$badShort'), isNull);
    final badMagic = Uint8List.fromList(payload)..[0] = 0x58;
    expect(
      parseJoinInvite(
        'wencrypt://join?v=2&p=${base64Url.encode(badMagic).replaceAll('=', '')}',
      ),
      isNull,
    );

    String encodeLan(List<String> ips, int port) {
      final raw = utf8.encode(
        jsonEncode({
          'i': ips,
          'p': port,
          'k': base64Url.encode(List<int>.filled(32, 0x2a)).replaceAll('=', ''),
          't': base64Url.encode(List<int>.filled(16, 0x1b)).replaceAll('=', ''),
          'v': vaultId,
        }),
      );
      return 'wencrypt://join?v=2&lan=${base64Url.encode(raw).replaceAll('=', '')}';
    }

    final lan = parseJoinInvite(encodeLan(const ['192.168.1.20'], 45123));
    expect(lan, isA<LanTransferTicket>());
    final ticket = lan as LanTransferTicket;
    expect(ticket.ips, const ['192.168.1.20']);
    expect(ticket.port, 45123);
    expect(ticket.vaultId, vaultId);
    expect(parseJoinInvite(encodeLan(const ['127.0.0.1'], 45123)), isNull);
    expect(parseJoinInvite(encodeLan(const ['192.168.1.20'], 80)), isNull);
  });

  testWidgets('quick join and invite menu entries are visible in UI', (
    tester,
  ) async {
    await tester.pumpWidget(const WencryptApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('加入已有库'));
    await tester.pumpAndSettle();
    expect(find.text('快捷加入（邀请码 / 同 WiFi 配对）'), findsOneWidget);
    expect(find.text('从坚果云加入'), findsOneWidget);
    expect(find.text('从加密备份恢复'), findsOneWidget);

    await tester.pumpWidget(
      MaterialApp(
        theme: wencryptTheme(Brightness.light),
        home: const VaultPage(preview: VaultPreview(unlocked: true)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    expect(find.text('邀请新设备加入'), findsOneWidget);
  });

  testWidgets(
    'Android QR scan option invokes native scanQr and opens join dialog',
    (tester) async {
      final calls = <String>[];
      final payload = Uint8List(234);
      payload.setRange(0, 8, utf8.encode('WENCINV2'));
      payload.setRange(8, 16, utf8.encode('WENCRYPT'));
      payload[16] = 1;
      payload[17] = 0;
      payload[18] = 1;
      for (var i = 0; i < 16; i++) {
        payload[19 + i] = i;
      }
      final b64Payload = base64Url.encode(payload).replaceAll('=', '');
      final inviteUri = 'wencrypt://join?v=2&p=$b64Payload';

      const channel = MethodChannel('org.wencrypt.invite');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call.method);
            if (call.method == 'scanQr') return inviteUri;
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: wencryptTheme(Brightness.light),
          home: const VaultPage(
            preview: VaultPreview(exists: false, androidQrScan: true),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('加入已有库'));
      await tester.pumpAndSettle();
      expect(find.text('扫一扫加入'), findsOneWidget);
      expect(find.text('快捷加入（邀请码 / 同 WiFi 配对）'), findsOneWidget);

      await tester.tap(find.text('扫一扫加入'));
      await tester.pumpAndSettle();

      expect(calls, ['scanQr']);
      expect(find.text('通过离线加密邀请加入'), findsOneWidget);

      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
    },
  );
}
