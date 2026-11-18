import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:wencrypt/browser_import.dart';
import 'package:wencrypt/sync_history.dart';
import 'package:wencrypt/vault_invite.dart';
import 'package:wencrypt/workspace.dart';

void main() {
  test(
    'an invite round trips a directory and an identity with no credentials',
    () {
      const invite = VaultInvite(
        folder: '团队共享',
        vault: '0123456789abcdef0123456789abcdef',
      );
      final link = invite.toUri().toString();
      final parsed = VaultInvite.parse(link);
      expect(parsed?.folder, invite.folder);
      expect(parsed?.vault, invite.vault);
      expect(VaultInvite.parse('$link&folder=another'), isNull);
      expect(VaultInvite.parse('$link&password=untrusted'), isNull);
      expect(
        VaultInvite.parse(link.replaceFirst('wencrypt:', 'https:')),
        isNull,
      );
      expect(
        VaultInvite.parse(link.replaceFirst('join?', 'join/redirect?')),
        isNull,
      );
      expect(
        VaultInvite.parse(
          link.replaceFirst(RegExp(r'folder=[^&]+'), 'folder=..%2Foutside'),
        ),
        isNull,
      );
      expect(
        VaultInvite.parse(
          link.replaceFirst(RegExp(r'folder=[^&]+'), 'folder=%FF'),
        ),
        isNull,
      );
    },
  );

  test('watch directories survive reopening and can be forgotten', () async {
    final temp = await Directory.systemTemp.createTemp();
    addTearDown(() => temp.delete(recursive: true));
    final file = File('${temp.path}/watch.json');
    final first = WatchDirectoryPreferences(file);
    await first.setDirectory('selected-directory', remember: true);
    await first.setDirectory('selected-directory', remember: true);
    final reopened = WatchDirectoryPreferences(file);
    expect(await reopened.load(), ['selected-directory']);
    await reopened.setDirectory('selected-directory', remember: false);
    expect(await first.load(), isEmpty);
  });

  testWidgets('history shows the result and copies the exact folder', (
    tester,
  ) async {
    String? copied;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SyncHistoryView(
            revision: 0,
            runningId: null,
            copyDirectory: (folder) => copied = folder,
            describeIssue: (issue) => '上传失败 · HTTP ${issue['http_status']}',
            load: (_) async => {
              'records': [
                {
                  'sequence': 1,
                  'record': {
                    'id': 'history-test',
                    'folder': '部门同步目录',
                    'started_at': 1765000000,
                    'uploaded': 7,
                    'downloaded': 3,
                    'outcome': 'failed',
                    'automatic': false,
                    'issue': {
                      'stage': 'upload_pack',
                      'reason': 'http_error',
                      'http_status': 503,
                    },
                  },
                },
              ],
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('部门同步目录'), findsOneWidget);
    expect(find.text('上传失败 · HTTP 503'), findsOneWidget);
    expect(find.text('7'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(find.text('手动同步'), findsOneWidget);
    await tester.tap(find.byTooltip('复制目录名'));
    expect(copied, '部门同步目录');
  });

  testWidgets('command filtering supports Enter without the pointer', (
    tester,
  ) async {
    String? ran;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                final command = await showWorkspaceCommands(context, [
                  WorkspaceCommand('立即同步', Icons.sync, () => ran = 'sync'),
                  WorkspaceCommand('复制目录名', Icons.copy, () => ran = 'copy'),
                ]);
                command?.run();
              },
              child: const Text('打开命令'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开命令'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '复制');
    await tester.pumpAndSettle();
    expect(find.text('立即同步'), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(ran, 'copy');
  });
}
