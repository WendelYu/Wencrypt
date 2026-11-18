import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:csv/csv.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

class BrowserExport {
  BrowserExport(this.source, this.rows, this.skipped);
  final String source;
  final List<Map<String, String>> rows;
  final int skipped;

  static BrowserExport combine(List<BrowserExport> files) {
    final rows = [for (final file in files) ...file.rows];
    if (rows.length > 500) throw StateError('csv_limit');
    return BrowserExport(
      files.length == 1 ? files.single.source : '${files.length} 份浏览器导出文件',
      rows,
      files.fold<int>(0, (total, file) => total + file.skipped),
    );
  }

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

class CapturedBrowserCsv {
  CapturedBrowserCsv(this.file, this.export);
  final File file;
  final BrowserExport export;
}

class BrowserWatchResult {
  BrowserWatchResult.captured(this.captured) : manualFiles = const [];
  BrowserWatchResult.manual(this.manualFiles) : captured = null;
  final CapturedBrowserCsv? captured;
  final List<XFile> manualFiles;
}

const _browserChannel = MethodChannel('org.wencrypt.browser-import');
const _settings = {
  'Chrome': 'chrome://password-manager/settings',
  'Edge': 'edge://wallet/passwords',
  'Firefox': 'about:logins',
};

String browserSettingsUrl(String browser) =>
    _settings[browser] ?? 'chrome://password-manager/settings';

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

Future<List<Directory>> defaultWatchDirectories() async {
  final candidates = <String>[];
  if (Platform.isMacOS) {
    try {
      final dirs =
          await _browserChannel.invokeListMethod<String>('watchDirs') ?? [];
      candidates.addAll(dirs);
    } catch (_) {
      // Fallback to manual folder selection if native channel is unavailable.
    }
  } else if (Platform.isWindows) {
    final profile = Platform.environment['USERPROFILE'];
    if (profile != null && profile.isNotEmpty) {
      candidates.add('$profile\\Downloads');
      candidates.add('$profile\\Desktop');
    }
  } else if (Platform.isLinux) {
    final home = Platform.environment['HOME'];
    if (home != null && home.isNotEmpty) {
      candidates.add('$home/Downloads');
      candidates.add('$home/Desktop');
    }
  }

  final accessible = <Directory>[];
  for (final path in candidates.toSet()) {
    final dir = Directory(path);
    try {
      if (await dir.exists()) {
        // Verify read permission before adding to active watchers.
        await dir.list(followLinks: false).take(1).toList();
        accessible.add(dir);
      }
    } catch (_) {
      // Ignore directories blocked by OS sandbox.
    }
  }
  return accessible;
}

Future<void> launchBrowserForExport(String browser, String app) async {
  final address = browserSettingsUrl(browser);
  await Clipboard.setData(ClipboardData(text: address));
  if (Platform.isMacOS) {
    await _browserChannel.invokeMethod<void>('open', browser);
  } else if (Platform.isWindows) {
    await Process.start(app, [address], mode: ProcessStartMode.detached);
  }
}

Future<bool> openExportSettings(
  BuildContext context,
  String browser,
  String app,
) async {
  if (Platform.isMacOS) {
    final address = browserSettingsUrl(browser);
    final proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('从 $browser 导出密码'),
        content: Text(
          '打开浏览器后，将复制的地址粘贴到地址栏。'
          '在密码管理页面导出 CSV，再回到 Wencrypt 自动导入。\n\n$address',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('复制地址并打开 $browser'),
          ),
        ],
      ),
    );
    if (proceed != true) return false;
  }
  await launchBrowserForExport(browser, app);
  return true;
}

/// Watches one or more directories for newly written browser password CSV exports.
class BrowserCsvWatcher {
  BrowserCsvWatcher(
    List<Directory> directories, {
    this.pollInterval = const Duration(milliseconds: 600),
    this.stabilityDelay = const Duration(milliseconds: 180),
  }) : _directories = List<Directory>.from(directories);

  final List<Directory> _directories;
  final Duration pollInterval;
  final Duration stabilityDelay;

  final _controller = StreamController<CapturedBrowserCsv>.broadcast();
  final Map<String, String> _seenSignatures = {};
  Timer? _timer;
  bool _scanning = false;
  bool _disposed = false;

  List<Directory> get directories => List.unmodifiable(_directories);
  Stream<CapturedBrowserCsv> get onCaptured => _controller.stream;

  Future<void> start() async {
    await _snapshotExisting();
    if (_disposed) return;
    _timer = Timer.periodic(pollInterval, (_) => _scan());
  }

  Future<void> addDirectory(Directory directory) async {
    if (_directories.any((d) => d.path == directory.path)) return;
    _directories.add(directory);
    await _snapshotDirectory(directory);
  }

  Future<void> _snapshotExisting() async {
    for (final dir in _directories) {
      await _snapshotDirectory(dir);
    }
  }

  Future<void> _snapshotDirectory(Directory dir) async {
    try {
      if (!await dir.exists()) return;
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is File && _isCandidateCsv(entity.path)) {
          final stat = await entity.stat();
          _seenSignatures[entity.path] = _signature(stat);
        }
      }
    } catch (_) {
      // Directory may be inaccessible or removed.
    }
  }

  bool _isCandidateCsv(String path) {
    final lower = path.toLowerCase();
    return lower.endsWith('.csv') &&
        !lower.endsWith('.crdownload') &&
        !lower.endsWith('.tmp') &&
        !lower.endsWith('.part');
  }

  String _signature(FileStat stat) =>
      '${stat.size}:${stat.modified.millisecondsSinceEpoch}';

  Future<void> _scan() async {
    if (_scanning || _disposed) return;
    _scanning = true;
    try {
      for (final dir in List<Directory>.from(_directories)) {
        if (_disposed) return;
        try {
          if (!await dir.exists()) continue;
          await for (final entity in dir.list(followLinks: false)) {
            if (_disposed) return;
            if (entity is! File || !_isCandidateCsv(entity.path)) continue;
            final stat = await entity.stat();
            if (stat.size <= 0 || stat.size > 1024 * 1024) continue;
            final sig = _signature(stat);
            if (_seenSignatures[entity.path] == sig) continue;

            // Wait briefly to confirm browser finished flushing/renaming the file.
            await Future<void>.delayed(stabilityDelay);
            if (_disposed || !await entity.exists()) continue;
            final afterStat = await entity.stat();
            final afterSig = _signature(afterStat);
            if (afterSig != sig) continue;

            try {
              final content = await entity.readAsString();
              final parsed = BrowserExport.parse(content);
              _seenSignatures[entity.path] = afterSig;
              if (parsed.rows.isNotEmpty) {
                if (!_controller.isClosed) {
                  _controller.add(CapturedBrowserCsv(entity, parsed));
                }
                dispose();
                return;
              }
            } catch (_) {
              // Ignore non-password CSVs or incomplete writes; mark signature so we don't spin on unrelated files.
              _seenSignatures[entity.path] = afterSig;
            }
          }
        } catch (_) {
          // Ignore transient directory read errors.
        }
      }
    } finally {
      _scanning = false;
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    if (!_controller.isClosed) {
      _controller.close();
    }
  }
}

/// Overwrites file contents with random data and zeros before deleting from disk.
Future<void> shredFile(File file) async {
  if (!await file.exists()) return;
  final length = await file.length();
  if (length > 0) {
    final rng = Random.secure();
    final raf = await file.open(mode: FileMode.writeOnly);
    try {
      const chunkSize = 8192;
      final randomBuf = Uint8List(chunkSize);
      var remaining = length;
      await raf.setPosition(0);
      while (remaining > 0) {
        final count = remaining < chunkSize ? remaining : chunkSize;
        for (var i = 0; i < count; i++) {
          randomBuf[i] = rng.nextInt(256);
        }
        await raf.writeFrom(randomBuf, 0, count);
        remaining -= count;
      }
      await raf.flush();

      final zeroBuf = Uint8List(chunkSize);
      remaining = length;
      await raf.setPosition(0);
      while (remaining > 0) {
        final count = remaining < chunkSize ? remaining : chunkSize;
        await raf.writeFrom(zeroBuf, 0, count);
        remaining -= count;
      }
      await raf.flush();
    } finally {
      await raf.close();
    }
  }
  await file.delete();
}

Future<BrowserWatchResult?> watchBrowserExportDialog(
  BuildContext context, {
  required String browser,
  required List<Directory> initialDirs,
}) async {
  final watcher = BrowserCsvWatcher(initialDirs);
  await watcher.start();
  if (!context.mounted) {
    watcher.dispose();
    return null;
  }

  StreamSubscription<CapturedBrowserCsv>? sub;
  var popped = false;

  try {
    return await showDialog<BrowserWatchResult>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            sub ??= watcher.onCaptured.listen((captured) {
              if (!popped && ctx.mounted) {
                popped = true;
                Navigator.pop(ctx, BrowserWatchResult.captured(captured));
              }
            });

            final address = browserSettingsUrl(browser);
            final dirs = watcher.directories;

            return AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              title: Row(
                children: [
                  const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  ),
                  const SizedBox(width: 12),
                  Expanded(child: Text('等待 $browser 导出密码…')),
                ],
              ),
              content: SizedBox(
                width: 460,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: Theme.of(
                          ctx,
                        ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '已为你打开 $browser 并复制设置页地址：',
                            style: Theme.of(ctx).textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Row(
                            children: [
                              Expanded(
                                child: SelectableText(
                                  address,
                                  style: Theme.of(ctx).textTheme.bodySmall
                                      ?.copyWith(fontFamily: 'monospace'),
                                ),
                              ),
                              TextButton.icon(
                                onPressed: () async {
                                  await Clipboard.setData(
                                    ClipboardData(text: address),
                                  );
                                  if (ctx.mounted) {
                                    ScaffoldMessenger.of(ctx).showSnackBar(
                                      const SnackBar(
                                        content: Text('已复制地址，请到浏览器地址栏粘贴'),
                                        duration: Duration(seconds: 2),
                                      ),
                                    );
                                  }
                                },
                                icon: const Icon(Icons.copy, size: 16),
                                label: const Text('复制'),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            '1. 在浏览器地址栏粘贴并回车\n'
                            '2. 点击「导出密码」保存 CSV 文件到下载目录\n'
                            '3. Wencrypt 将自动捕获、导入并安全粉碎原文件',
                            style: TextStyle(height: 1.5),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      dirs.isEmpty
                          ? '未检测到可访问的默认下载目录，请授权监听目录或手动选择 CSV：'
                          : '正在实时监听以下目录中的新 CSV 文件：',
                      style: Theme.of(ctx).textTheme.labelMedium,
                    ),
                    const SizedBox(height: 6),
                    if (dirs.isNotEmpty)
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final d in dirs)
                            Chip(
                              avatar: const Icon(Icons.folder_outlined, size: 16),
                              label: Text(
                                d.path,
                                overflow: TextOverflow.ellipsis,
                              ),
                              visualDensity: VisualDensity.compact,
                            ),
                        ],
                      ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      children: [
                        OutlinedButton.icon(
                          onPressed: () async {
                            final chosen = await getDirectoryPath(
                              confirmButtonText: '监听此目录',
                            );
                            if (chosen != null) {
                              await watcher.addDirectory(Directory(chosen));
                              if (ctx.mounted) setLocal(() {});
                            }
                          },
                          icon: const Icon(Icons.create_new_folder_outlined, size: 18),
                          label: Text(dirs.isEmpty ? '选择监听目录' : '添加监听目录'),
                        ),
                        TextButton.icon(
                          onPressed: () async {
                            final files = await openFiles(
                              acceptedTypeGroups: const [
                                XTypeGroup(
                                  label: 'CSV',
                                  extensions: ['csv'],
                                  uniformTypeIdentifiers: [
                                    'public.comma-separated-values-text',
                                  ],
                                  mimeTypes: [
                                    'text/csv',
                                    'text/plain',
                                    'application/vnd.ms-excel',
                                  ],
                                ),
                              ],
                            );
                            if (files.isNotEmpty && !popped && ctx.mounted) {
                              popped = true;
                              Navigator.pop(
                                ctx,
                                BrowserWatchResult.manual(files),
                              );
                            }
                          },
                          icon: const Icon(Icons.file_open_outlined, size: 18),
                          label: const Text('手动选择 CSV'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    if (!popped) {
                      popped = true;
                      Navigator.pop(ctx);
                    }
                  },
                  child: const Text('取消等待'),
                ),
              ],
            );
          },
        );
      },
    );
  } finally {
    await sub?.cancel();
    watcher.dispose();
  }
}

Future<List<Map<String, String>>?> selectPasswords(
  BuildContext context,
  BrowserExport batch,
  List<Map<String, dynamic>> existing, {
  bool? shredAfterImport,
  ValueChanged<bool>? onShredChanged,
  String? sourceFileName,
}) {
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
  var shred = shredAfterImport ?? false;

  return showDialog<List<Map<String, String>>>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, update) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text('选择要导入的账号（${selected.length}/${batch.rows.length}）'),
        content: SizedBox(
          width: 520,
          height: 410,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (sourceFileName != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    '已自动捕获导出文件：$sourceFileName',
                    style: TextStyle(
                      color: Theme.of(ctx).colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              Text('已识别 ${batch.source}，跳过 ${batch.skipped} 条无效记录。'),
              const SizedBox(height: 4),
              Wrap(
                spacing: 8,
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
                child: ListView.separated(
                  itemCount: batch.rows.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
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
                      title: Text(
                        row['title']!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        [
                          if (duplicate[i]) '相同账号和密码（已存在）',
                          row['username']!,
                          row['url']!,
                        ].where((s) => s.isNotEmpty).join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    );
                  },
                ),
              ),
              if (onShredChanged != null) ...[
                const SizedBox(height: 8),
                CheckboxListTile(
                  value: shred,
                  contentPadding: EdgeInsets.zero,
                  onChanged: (v) {
                    final next = v == true;
                    update(() => shred = next);
                    onShredChanged(next);
                  },
                  title: const Text('导入后安全粉碎临时 CSV 文件（推荐）'),
                  subtitle: const Text('使用随机数据覆写后彻底删除明文文件'),
                ),
              ],
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
