import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:csv/csv.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'design/wencrypt_theme.dart';
import 'design/wencrypt_widgets.dart';

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
  'Edge': 'edge://settings/autofill/passwords',
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

class WatchDirectoryPreferences {
  WatchDirectoryPreferences(this.file);

  final File file;

  Future<List<String>> load() async {
    if (!await file.exists()) return [];
    final saved = jsonDecode(await file.readAsString()) as List;
    return saved.whereType<String>().toSet().toList();
  }

  Future<void> setDirectory(String path, {required bool remember}) async {
    final folders = (await load()).toSet();
    if (remember) {
      folders.add(path);
    } else {
      folders.remove(path);
    }
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(jsonEncode(folders.toList()), flush: true);
    await temp.rename(file.path);
  }
}

class SavedBrowserWatchFolders {
  SavedBrowserWatchFolders(Directory appData)
    : _preferences = WatchDirectoryPreferences(
        File('${appData.path}/browser-watch-dirs.json'),
      );

  final WatchDirectoryPreferences _preferences;

  Future<List<String>> load() async => Platform.isMacOS
      ? await _browserChannel.invokeListMethod<String>('savedWatchDirs') ?? []
      : _preferences.load();

  Future<String?> choose() async {
    if (Platform.isMacOS) {
      return _browserChannel.invokeMethod<String>('chooseWatchDir');
    }
    final selected = await getDirectoryPath(confirmButtonText: '记住目录');
    if (selected != null) {
      await _preferences.setDirectory(selected, remember: true);
    }
    return selected;
  }

  Future<void> forget(String path) => Platform.isMacOS
      ? _browserChannel.invokeMethod<void>('forgetWatchDir', path)
      : _preferences.setDirectory(path, remember: false);

  Future<void> close() async {
    if (Platform.isMacOS) {
      await _browserChannel.invokeMethod<void>('stopWatchAccess');
    }
  }
}

enum BrowserLaunch { settings, browserOnly, failed }

Future<BrowserLaunch> launchBrowserForExport(String browser, String app) async {
  final address = browserSettingsUrl(browser);
  try {
    if (Platform.isMacOS) {
      final opened = await _browserChannel.invokeMethod<bool>('open', browser);
      if (opened == true) return BrowserLaunch.settings;
      await Clipboard.setData(ClipboardData(text: address));
      return BrowserLaunch.browserOnly;
    }
    if (Platform.isWindows) {
      await Process.start(app, [address], mode: ProcessStartMode.detached);
      return BrowserLaunch.settings;
    }
  } catch (_) {
    return BrowserLaunch.failed;
  }
  return BrowserLaunch.failed;
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
    final target = _normPath(directory.path);
    if (_directories.any((d) => _normPath(d.path) == target)) return;
    await _snapshotDirectory(directory);
    if (!_disposed) _directories.add(directory);
  }

  void removeDirectory(String path) {
    _directories.removeWhere((dir) => _normPath(dir.path) == _normPath(path));
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
          if (stat.size > 0) {
            _seenSignatures[_normPath(entity.path)] = _signature(stat);
          }
        }
      }
    } catch (_) {
      // Directory may be inaccessible or removed.
    }
  }

  String _normPath(String path) =>
      path.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '');

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
            final key = _normPath(entity.path);
            final sig = _signature(stat);
            if (_seenSignatures[key] == sig) continue;

            // Wait briefly to confirm browser finished flushing/renaming the file.
            await Future<void>.delayed(stabilityDelay);
            if (_disposed || !await entity.exists()) continue;
            final afterStat = await entity.stat();
            if (afterStat.size <= 0) continue;
            final afterSig = _signature(afterStat);
            if (afterSig != sig) continue;

            String content;
            try {
              content = await entity.readAsString();
            } on FileSystemException {
              // On Windows the writer process may still hold an exclusive lock; retry on next tick.
              continue;
            }
            if (content.trim().isEmpty) continue;

            try {
              final parsed = BrowserExport.parse(content);
              _seenSignatures[key] = afterSig;
              if (parsed.rows.isNotEmpty) {
                if (!_directories.contains(dir)) break;
                if (!_controller.isClosed) {
                  _controller.add(CapturedBrowserCsv(entity, parsed));
                }
                dispose();
                return;
              }
            } catch (_) {
              // Non-password CSVs are marked so we don't re-parse them on every tick.
              _seenSignatures[key] = afterSig;
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
  required String app,
  required List<Directory> initialDirs,
  required List<String> rememberedDirs,
  required SavedBrowserWatchFolders savedFolders,
}) async {
  final remembered = rememberedDirs.toSet();
  final merged = {for (final dir in initialDirs) dir.path: dir};
  for (final path in remembered) {
    merged.putIfAbsent(path, () => Directory(path));
  }
  final watcher = BrowserCsvWatcher(merged.values.toList());
  await watcher.start();
  if (!context.mounted) {
    watcher.dispose();
    return null;
  }

  StreamSubscription<CapturedBrowserCsv>? sub;
  var popped = false;
  var launching = true;
  var changingDirectories = false;
  BrowserLaunch? launch;

  try {
    return await showDialog<BrowserWatchResult>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            Future<void> openBrowser() async {
              final result = await launchBrowserForExport(browser, app);
              if (ctx.mounted && !popped) {
                setLocal(() {
                  launch = result;
                  launching = false;
                });
              }
            }

            if (sub == null) {
              sub = watcher.onCaptured.listen((captured) {
                if (!popped && ctx.mounted) {
                  popped = true;
                  Navigator.pop(ctx, BrowserWatchResult.captured(captured));
                }
              });
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (ctx.mounted && !popped) unawaited(openBrowser());
              });
            }

            final address = browserSettingsUrl(browser);
            final dirs = watcher.directories;

            return WDialog(
              width: 520,
              icon: Icons.file_download_outlined,
              title: '等待 $browser 导出密码…',
              subtitle: 'Wencrypt 会监听下载目录，导出 CSV 后自动识别并预览。',
              headerTrailing: const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              bodyPadding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              footer: WDialogFooter(
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
              ),
              child: SizedBox(
                width: double.infinity,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: WColors.of(ctx).surfaceMuted,
                        borderRadius: BorderRadius.circular(WRadius.sm),
                        border: Border.all(color: WColors.of(ctx).border),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            launching
                                ? '正在打开 $browser…'
                                : switch (launch) {
                                    BrowserLaunch.settings =>
                                      '已向 $browser 发送密码管理页地址',
                                    BrowserLaunch.browserOnly =>
                                      '已打开 $browser 并复制地址',
                                    _ => '无法启动 $browser，可手动打开并粘贴地址',
                                  },
                            style: Theme.of(ctx).textTheme.bodyMedium
                                ?.copyWith(fontWeight: FontWeight.w600),
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
                            '如果未进入密码管理页，请在浏览器地址栏粘贴上方地址。\n'
                            '点击「导出密码」，将 CSV 保存到正在监听的目录。',
                            style: TextStyle(height: 1.5),
                          ),
                          if (launch == BrowserLaunch.failed && !launching)
                            TextButton(
                              onPressed: () {
                                setLocal(() => launching = true);
                                unawaited(openBrowser());
                              },
                              child: Text('重新打开 $browser'),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      dirs.isEmpty
                          ? '未检测到可访问的默认下载目录，请授权监听目录或手动选择 CSV：'
                          : '正在监听以下目录中的新 CSV 文件',
                      style: Theme.of(ctx).textTheme.labelMedium,
                    ),
                    const SizedBox(height: 6),
                    if (dirs.isNotEmpty)
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final d in dirs)
                            InputChip(
                              onDeleted:
                                  remembered.contains(d.path) &&
                                      !changingDirectories
                                  ? () async {
                                      setLocal(
                                        () => changingDirectories = true,
                                      );
                                      try {
                                        await savedFolders.forget(d.path);
                                        remembered.remove(d.path);
                                        if (!initialDirs.any(
                                          (dir) => dir.path == d.path,
                                        )) {
                                          watcher.removeDirectory(d.path);
                                        }
                                      } catch (_) {
                                        if (ctx.mounted) {
                                          ScaffoldMessenger.of(ctx)
                                              .showSnackBar(
                                                const SnackBar(
                                                  content: Text('无法移除已保存的目录'),
                                                ),
                                              );
                                        }
                                      } finally {
                                        if (ctx.mounted && !popped) {
                                          setLocal(
                                            () => changingDirectories = false,
                                          );
                                        }
                                      }
                                    }
                                  : null,
                              deleteButtonTooltipMessage: '忘记此监听目录',
                              avatar: const Icon(
                                Icons.folder_outlined,
                                size: 16,
                              ),
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
                          onPressed: changingDirectories
                              ? null
                              : () async {
                                  setLocal(() => changingDirectories = true);
                                  try {
                                    final chosen = await savedFolders.choose();
                                    if (chosen != null) {
                                      remembered.add(chosen);
                                      await watcher.addDirectory(
                                        Directory(chosen),
                                      );
                                    }
                                  } catch (_) {
                                    if (ctx.mounted) {
                                      ScaffoldMessenger.of(ctx).showSnackBar(
                                        const SnackBar(
                                          content: Text('无法记住此目录，请确认访问权限'),
                                        ),
                                      );
                                    }
                                  } finally {
                                    if (ctx.mounted && !popped) {
                                      setLocal(
                                        () => changingDirectories = false,
                                      );
                                    }
                                  }
                                },
                          icon: const Icon(
                            Icons.create_new_folder_outlined,
                            size: 18,
                          ),
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
  List<String> groups = const [],
  String? initialGroup,
}) {
  (String, String, String, String) identity(Map data) {
    final url = (data['url'] as String).trim();
    return (
      url,
      data['username'] as String,
      data['password'] as String,
      url.isEmpty ? (data['title'] as String).trim() : '',
    );
  }

  final known = {
    for (final r in existing)
      if (r['deleted'] != true) identity(r['data'] as Map),
  };
  final duplicate = [for (final r in batch.rows) !known.add(identity(r))];
  final selected = {for (var i = 0; i < batch.rows.length; i++) i};
  var shred = shredAfterImport ?? false;
  final customGroups = groups.where((name) => name != '导入').toList();
  var group = customGroups.contains(initialGroup) ? initialGroup! : '';

  return showDialog<List<Map<String, String>>>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, update) => WDialog(
        width: 560,
        icon: Icons.playlist_add_check_rounded,
        title: '选择要导入的账号（${selected.length}/${batch.rows.length}）',
        subtitle: '相同凭据会自动合并，取消勾选可跳过。',
        scrollable: false,
        bodyPadding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
        footer: WDialogFooter(
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: selected.isEmpty
                  ? null
                  : () => Navigator.pop(ctx, [
                      for (final i in selected.toList()..sort())
                        {...batch.rows[i], if (group.isNotEmpty) 'tags': group},
                    ]),
              child: const Text('导入所选账号'),
            ),
          ],
        ),
        child: SizedBox(
          width: double.infinity,
          height: 400,
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
              if (customGroups.isNotEmpty)
                DropdownButton<String>(
                  isExpanded: true,
                  value: group,
                  items: [
                    const DropdownMenuItem(value: '', child: Text('分组：导入')),
                    for (final name in customGroups)
                      DropdownMenuItem(
                        value: name,
                        child: Text(
                          '分组：$name',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (value) => update(() => group = value ?? ''),
                ),
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
                          if (duplicate[i]) '相同凭据会合并',
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
                  title: const Text('导入后覆盖并删除临时 CSV 文件'),
                ),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}
