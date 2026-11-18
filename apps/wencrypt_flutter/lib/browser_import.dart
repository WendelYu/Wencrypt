import 'dart:io';

import 'package:csv/csv.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

class BrowserExport {
  BrowserExport(this.source, this.rows, this.skipped);
  final String source;
  final List<Map<String, String>> rows;
  final int skipped;

  static BrowserExport parse(String text) {
    final records = csv.decode(text.replaceFirst(RegExp(r'^\uFEFF'), ''));
    if (records.isEmpty || records.length > 501) throw StateError('csv_limit');
    final headers = records.first
        .map((v) => v.toString().trim().toLowerCase())
        .toList();
    if (!['username', 'password', 'url'].every(headers.contains) ||
        headers.toSet().length != headers.length) {
      throw StateError('csv_headers');
    }
    final source = headers.contains('httprealm')
        ? 'Firefox'
        : headers.contains('otpauth')
        ? 'Safari / Apple 密码'
        : 'Chrome / Edge 兼容格式';
    final rows = <Map<String, String>>[];
    var skipped = 0;
    for (final row in records.skip(1)) {
      if (row.every((v) => v.toString().isEmpty)) continue;
      String get(String key) {
        final index = headers.indexOf(key);
        return index < 0 || index >= row.length ? '' : row[index].toString();
      }

      if (get('password').isEmpty || row.length != headers.length) {
        skipped++;
        continue;
      }
      final names = [get('name'), get('title'), get('url')];
      rows.add({
        'title': names.firstWhere(
          (s) => s.trim().isNotEmpty,
          orElse: () => '导入账号',
        ),
        'url': get('url'),
        'username': get('username'),
        'password': get('password'),
        'notes': get('note').isEmpty ? get('notes') : get('note'),
        'tags': '导入',
      });
    }
    return BrowserExport(source, rows, skipped);
  }
}

const _browserChannel = MethodChannel('org.wencrypt.browser-import');
const _settings = {
  'Chrome': 'chrome://password-manager/settings',
  'Edge': 'edge://wallet/passwords',
  'Firefox': 'about:logins',
};
Future<Map<String, String>> installedBrowsers() async {
  if (Platform.isMacOS) {
    final names =
        await _browserChannel.invokeListMethod<String>('installed') ?? [];
    return {for (final name in names) name: name};
  }
  final found = <String, String>{};
  if (Platform.isWindows) {
    for (final root in [
      'ProgramFiles',
      'ProgramFiles(x86)',
      'LOCALAPPDATA',
    ].map((k) => Platform.environment[k]).whereType<String>()) {
      for (final e in {
        'Chrome': 'Google/Chrome/Application/chrome.exe',
        'Edge': 'Microsoft/Edge/Application/msedge.exe',
        'Firefox': 'Mozilla Firefox/firefox.exe',
      }.entries) {
        final exe = File('$root/${e.value}');
        if (await exe.exists()) {
          found[e.key] = exe.path;
        }
      }
    }
  }
  return found;
}

Future<void> openExportSettings(String browser, String app) async {
  if (Platform.isMacOS) {
    await _browserChannel.invokeMethod<void>('open', browser);
  }
  if (Platform.isWindows) {
    await Process.start(app, [
      _settings[browser]!,
    ], mode: ProcessStartMode.detached);
  }
}

Future<List<Map<String, String>>?> selectPasswords(
  BuildContext context,
  BrowserExport batch,
  List<Map<String, dynamic>> existing,
) {
  (String, String, String) identity(Map data) => (
    data['url'] as String,
    data['username'] as String,
    data['password'] as String,
  );
  final known = {
    for (final r in existing)
      if (r['deleted'] != true) identity(r['data'] as Map),
  };
  final duplicate = [for (final r in batch.rows) !known.add(identity(r))];
  final selected = {
    for (var i = 0; i < duplicate.length; i++)
      if (!duplicate[i]) i,
  };
  return showDialog<List<Map<String, String>>>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, update) => AlertDialog(
        title: Text('选择要导入的账号（${selected.length}/${batch.rows.length}）'),
        content: SizedBox(
          width: 500,
          height: 380,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('已识别 ${batch.source}，跳过 ${batch.skipped} 条无效记录。'),
              Wrap(
                children: [
                  TextButton(
                    onPressed: () => update(
                      () => selected.addAll(
                        List.generate(batch.rows.length, (i) => i),
                      ),
                    ),
                    child: const Text('全选'),
                  ),
                  TextButton(
                    onPressed: () => update(selected.clear),
                    child: const Text('清空选择'),
                  ),
                ],
              ),
              Expanded(
                child: ListView.builder(
                  itemCount: batch.rows.length,
                  itemBuilder: (_, i) {
                    final row = batch.rows[i];
                    return CheckboxListTile(
                      value: selected.contains(i),
                      onChanged: (v) => update(() {
                        if (v == true) {
                          selected.add(i);
                        } else {
                          selected.remove(i);
                        }
                      }),
                      title: Text(row['title']!),
                      subtitle: Text(
                        [
                          if (duplicate[i]) '相同账号和密码',
                          row['username']!,
                          row['url']!,
                        ].where((s) => s.isNotEmpty).join(' · '),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: selected.isEmpty
                ? null
                : () => Navigator.pop(ctx, [
                    for (final i in selected) batch.rows[i],
                  ]),
            child: const Text('导入所选账号'),
          ),
        ],
      ),
    ),
  );
}
