import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';

import 'browser_import.dart';
import 'core.dart';
import 'entry_image.dart';
import 'probe_page.dart' show WencryptProbeApp;
import 'sync.dart';

void main() => runApp(const WencryptApp());

class WencryptApp extends StatefulWidget {
  const WencryptApp({super.key});

  @override
  State<WencryptApp> createState() => _WencryptAppState();
}

class _WencryptAppState extends State<WencryptApp> {
  ThemeMode _themeMode = ThemeMode.system;

  void _cycleTheme() {
    setState(() {
      _themeMode = switch (_themeMode) {
        ThemeMode.system => ThemeMode.light,
        ThemeMode.light => ThemeMode.dark,
        ThemeMode.dark => ThemeMode.system,
      };
    });
  }

  ThemeData _buildTheme(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final colorScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xff2563eb),
      brightness: brightness,
      primary: isDark ? const Color(0xff60a5fa) : const Color(0xff2563eb),
      surface: isDark ? const Color(0xff111827) : Colors.white,
    );
    final borderColor = isDark
        ? const Color(0xff1f2937)
        : const Color(0xffe2e8f0);

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: isDark
          ? const Color(0xff0b1120)
          : const Color(0xfff3f6fb),
      appBarTheme: AppBarTheme(
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: isDark ? const Color(0xff111827) : Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: Border(bottom: BorderSide(color: borderColor)),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: isDark ? const Color(0xff111827) : Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: borderColor),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: isDark ? const Color(0xff111827) : Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isDark
            ? const Color(0xff1e293b).withValues(alpha: 0.65)
            : const Color(0xfff8fafc),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 14,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: borderColor),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: borderColor),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: colorScheme.primary, width: 1.6),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
          side: BorderSide(color: borderColor),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Wencrypt',
    debugShowCheckedModeBanner: false,
    themeMode: _themeMode,
    theme: _buildTheme(Brightness.light),
    darkTheme: _buildTheme(Brightness.dark),
    home: VaultPage(themeMode: _themeMode, onCycleTheme: _cycleTheme),
  );
}

class VaultPage extends StatefulWidget {
  const VaultPage({
    super.key,
    this.themeMode = ThemeMode.system,
    this.onCycleTheme,
  });

  final ThemeMode themeMode;
  final VoidCallback? onCycleTheme;

  @override
  State<VaultPage> createState() => _VaultPageState();
}

enum EntryFilter { all, pinned, ungrouped }

enum FirstRunStep { welcome, create, join }

class _VaultPageState extends State<VaultPage> with WidgetsBindingObserver {
  static const _pinTag = '置顶';
  static const _presetGroups = ['工作', '财务', '社交', '开发', '购物', '生活'];
  static const entryImage = MethodChannel('org.wencrypt.entry-image');
  static const device = MethodChannel('org.wencrypt.device/vault');

  final master = TextEditingController();
  final confirm = TextEditingController();
  final searchController = TextEditingController();
  Timer? _searchUpdate;

  String? path, token, binding, vaultId, syncUsername;
  String message = '正在加载…', query = '';
  Object selectedGroup = EntryFilter.all;
  FirstRunStep firstRunStep = FirstRunStep.welcome;
  bool initialSyncPending = false;
  int pendingRevisions = 0;
  Set<String>? deleteSelection;
  bool exists = false, busy = false, trash = false;
  bool revealMaster = false, revealConfirm = false;
  bool lockOnFocusLoss =
      !(Platform.isMacOS || Platform.isWindows || Platform.isLinux);
  int generation = 0;
  List<Map<String, dynamic>> entries = [];
  List<Map<String, dynamic>> syncTargets = [];
  Timer? idle, clipboard, autoTimer;
  bool biometricEnabled = false,
      authenticating = false,
      autoEnabled = false,
      syncConfigured = false,
      syncing = false;
  bool foreground = true;
  NutstoreSync? activeSync;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    searchController.addListener(_scheduleSearch);
    device.setMethodCallHandler((call) async {
      if (call.method == 'systemLocked') lock();
    });
    initialize();
  }

  Future<void> initialize() async {
    try {
      final dir = await getApplicationSupportDirectory();
      await dir.create(recursive: true);
      path = '${dir.path}/wencrypt-alpha.db';
      exists = await File(path!).exists();
      if (exists && (Platform.isMacOS || Platform.isAndroid)) {
        await deviceStatus();
      }
      if (mounted) setState(() => message = '本地加密 · 离线可用');
    } catch (_) {
      if (mounted) setState(() => message = '无法打开应用数据目录');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    master.dispose();
    confirm.dispose();
    _searchUpdate?.cancel();
    searchController.dispose();
    idle?.cancel();
    clipboard?.cancel();
    autoTimer?.cancel();
    activeSync?.cancel();
    super.dispose();
  }

  void _scheduleSearch() {
    _searchUpdate?.cancel();
    if (token == null) return;
    final value = searchController.value;
    if (value.composing.isValid && !value.composing.isCollapsed) return;
    if (value.text == query) return;
    touch();
    _searchUpdate = Timer(const Duration(milliseconds: 120), () {
      if (!mounted || token == null) return;
      setState(() {
        query = value.text;
        deleteSelection?.clear();
      });
    });
  }

  void touch() {
    idle?.cancel();
    if (token != null) idle = Timer(const Duration(minutes: 5), lock);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    if (state == AppLifecycleState.inactive && authenticating) return;
    final isDesktop =
        Platform.isMacOS || Platform.isWindows || Platform.isLinux;
    if (!lockOnFocusLoss &&
        isDesktop &&
        (state == AppLifecycleState.inactive ||
            state == AppLifecycleState.hidden)) {
      // Allow switching to browser/other apps while copying & filling passwords;
      // 5-min idle timer and OS screen lock still protect the vault.
      return;
    }
    if (state != AppLifecycleState.resumed) {
      lock();
    } else if (token != null) {
      scheduleAuto();
    }
  }

  void lock() {
    generation++;
    _searchUpdate?.cancel();
    autoTimer?.cancel();
    activeSync?.cancel();
    device.invokeMethod<Object?>('cancel').catchError((Object _) => null);
    token = null;
    initialSyncPending = false;
    pendingRevisions = 0;
    entries = [];
    syncTargets = [];
    syncUsername = null;
    vaultId = null;
    selectedGroup = EntryFilter.all;
    deleteSelection = null;
    master.clear();
    confirm.clear();
    searchController.clear();
    query = '';
    idle?.cancel();
    if (mounted) {
      Navigator.of(context).popUntil((r) => r.isFirst);
      setState(() => message = '密码库已锁定');
    }
    try {
      lockCore();
    } catch (_) {
      /* A missing core cannot hold an active vault. */
    }
  }

  Future<void> action(Future<void> Function() task) async {
    if (busy) return;
    setState(() {
      busy = true;
      message = '';
    });
    try {
      await task();
    } catch (e) {
      if (mounted) setState(() => message = friendly(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  String friendly(Object e) {
    final text = e.toString();
    if (text.contains('csv_limit')) return '请选择不超过 1 MiB、最多 500 条账号的 CSV 文件。';
    if (text.contains('csv_headers')) {
      return '未识别密码文件。需要 url、username 和 password 列。';
    }
    if (e is DavFailure) {
      return switch (e.reason) {
        'remote_missing' when token == null =>
          '没有找到已有密码库。请核对坚果云目录名，并在原设备先完成一次同步。',
        'remote_missing' => '云端副本缺失，已停止同步。本地数据仍保留。',
        'missing_credentials' => '请填写坚果云账号和 WebDAV 应用密码。',
        'invalid_remote_folder' => '请填写有效的坚果云同步目录名，最长 32 个字符。',
        'vault_identity_mismatch' => '所选目录属于另一个密码库。请核对原设备的同步目录。',
        'free_budget_reached' => '已达到本机同步额度，已传输内容会保留，请稍后继续。',
        'directory_limit' => '坚果云单个目录达到列举上限，同步已暂停。',
        _ when e.status == 401 || e.status == 403 =>
          '坚果云验证失败。请核对账号、WebDAV 应用密码和目录权限。',
        _ => e.toString(),
      };
    }
    if (text.contains('biometric')) {
      return '指纹认证取消、密钥失效或设备保护不可用。请用主密码解锁；需要时重新启用指纹。';
    }
    if (text.contains('image_export_failed')) return '无法导出账号图片，请重试。';
    if (text.contains('backup_limit')) return '超出 Alpha 的 2 MiB 备份上限，导出已停止。';
    if (text.contains('vault_already_exists')) return '这台设备已有密码库，请返回解锁。';
    if (text.contains('entry_changed')) return '条目已被修改，请重新打开后编辑。';
    if (text.contains('authentication')) return '主密码不正确或文件已损坏。';
    if (text.contains('password_length')) return '主密码至少需要 12 个字符。';
    if (text.contains('session') || text.contains('locked')) {
      return '密码库已锁定，请重新解锁。';
    }
    return '操作未完成，请检查文件、网络或输入后重试。';
  }

  Future<void> unlock() => action(() async {
    final creating = !exists;
    if (creating && master.text != confirm.text) {
      setState(() => message = '两次主密码不一致');
      return;
    }
    final epoch = generation;
    final result = await core({
      'op': creating ? 'create' : 'unlock',
      'path': path,
      'password': master.text,
    });
    master.clear();
    confirm.clear();
    if (epoch != generation) {
      await core({'op': 'lock'});
      return;
    }
    token = result['session'] as String;
    exists = true;
    touch();
    await refresh();
    await loadAuto();
    if (creating && mounted && epoch == generation) {
      setState(() => message = '密码库已创建。可在「坚果云设置」开启跨设备同步。');
    }
  });

  Future<Map<String, dynamic>> request(
    String op, [
    Map<String, dynamic> extra = const {},
  ]) async {
    final current = token;
    final epoch = generation;
    if (current == null) throw StateError('locked');
    final result = await core({'op': op, 'session': current, ...extra});
    if (epoch != generation) throw StateError('locked');
    return result;
  }

  Future<void> refresh() async {
    final data = await request('list');
    if (mounted) {
      setState(() {
        vaultId = data['vault'] as String?;
        entries = (data['entries'] as List).cast<Map<String, dynamic>>();
        if (selectedGroup case final String name) {
          if (!entries.any(
            (entry) =>
                entry['deleted'] == trash &&
                _entryGroups(entry).any((group) => group.toLowerCase() == name),
          )) {
            selectedGroup = EntryFilter.all;
          }
        }
        final available = entries.map((entry) => entry['id']).toSet();
        deleteSelection?.removeWhere((id) => !available.contains(id));
        pendingRevisions = data['pending'] as int;
        message = pendingRevisions == 0 ? '已保存在本机' : '存在缺失的历史版本，请完成同步';
      });
    }
  }

  Future<void> deviceStatus() async {
    final info = await core({'op': 'device_info', 'path': path});
    binding = info['binding'] as String;
    final state = await device.invokeMapMethod<String, dynamic>('status', {
      'binding': binding,
    });
    biometricEnabled = state?['enabled'] == true;
  }

  Future<void> enableBiometric() async {
    final password = await passwordPrompt();
    if (password == null) return;
    await action(() async {
      final snapshot = generation;
      final grant = await request('device_grant', {'password': password});
      binding = grant['binding'] as String;
      authenticating = true;
      try {
        final result = await device.invokeMapMethod<String, dynamic>('enable', {
          'binding': binding,
          'ticket': grant['ticket'],
        });
        if (snapshot != generation) throw StateError('locked');
        if (result?['enabled'] != true) throw StateError('biometric_failed');
        setState(() {
          biometricEnabled = true;
          message = '已启用本机指纹解锁；主密码仍可用于恢复。';
        });
      } finally {
        authenticating = false;
      }
    });
  }

  Future<void> biometricUnlock() => action(() async {
    final snapshot = generation;
    await deviceStatus();
    authenticating = true;
    try {
      final result = await device.invokeMapMethod<String, dynamic>('unlock', {
        'binding': binding,
        'path': path,
        'epoch': nativeEpoch,
      });
      if (snapshot != generation) {
        lockCore();
        return;
      }
      if (result?['session'] is! String) throw StateError('biometric_failed');
      token = result!['session'] as String;
      touch();
      await refresh();
      await loadAuto();
    } finally {
      authenticating = false;
    }
  });

  Future<void> disableBiometric() => action(() async {
    await deviceStatus();
    final state = await device.invokeMapMethod<String, dynamic>('disable', {
      'binding': binding,
    });
    if (state?['enabled'] != false) {
      throw StateError('biometric_failed');
    }
    setState(() {
      biometricEnabled = false;
      message = '已关闭本机指纹解锁';
    });
  });

  String _defaultFolderName() => vaultId != null && vaultId!.length >= 16
      ? 'wc-${vaultId!.substring(0, 16)}'
      : '默认主目录';

  List<Map<String, dynamic>> _normalizeTargets(dynamic rawTargets) {
    if (rawTargets is List && rawTargets.isNotEmpty) {
      return [
        for (final item in rawTargets.whereType<Map>())
          {
            'id': (item['id'] ?? '').toString().isEmpty
                ? 't-${DateTime.now().microsecondsSinceEpoch}'
                : item['id'].toString(),
            'name': (item['name'] ?? '备份目标').toString(),
            'folder': (item['folder'] ?? '').toString(),
            'enabled': item['enabled'] != false,
            if (item['existingOnly'] == true) 'existingOnly': true,
          },
      ];
    }
    return [
      {'id': 'default', 'name': '默认主备份', 'folder': '', 'enabled': true},
    ];
  }

  bool _hasSyncCredentials(Map<String, dynamic>? settings) {
    final username = settings?['username'];
    final password = settings?['password'];
    return username is String &&
        username.trim().isNotEmpty &&
        password is String &&
        password.isNotEmpty;
  }

  Future<void> loadAuto() async {
    final settings =
        (await request('sync_settings_get'))['settings']
            as Map<String, dynamic>?;
    if (!mounted) return;
    setState(() {
      syncConfigured = _hasSyncCredentials(settings);
      syncUsername = settings?['username'] as String?;
      autoEnabled = syncConfigured && settings?['auto'] == true;
      initialSyncPending = settings?['joinPending'] == true;
      if (initialSyncPending) message = '本机已加入已有库，首次同步尚未完成';
      syncTargets = settings == null
          ? []
          : _normalizeTargets(settings['targets']);
    });
    scheduleAuto();
  }

  void scheduleAuto() {
    autoTimer?.cancel();
    if (!autoEnabled || token == null || !foreground) return;
    autoTimer = Timer(
      const Duration(seconds: 30),
      () => runSync(automatic: true),
    );
  }

  Future<void> runSync({
    required bool automatic,
    String? username,
    String? password,
    List<Map<String, dynamic>>? targetsOverride,
  }) async {
    if (syncing ||
        token == null ||
        !foreground ||
        (automatic && !autoEnabled)) {
      return;
    }
    setState(() {
      syncing = true;
      message = '正在连接坚果云…';
    });
    final current = generation;
    final stateFile = File('${File(path!).parent.path}/auto-sync-state.json');
    var failures = 0;
    bool attempted = false;
    DateTime? next;
    try {
      if (await stateFile.exists()) {
        final state =
            jsonDecode(await stateFile.readAsString()) as Map<String, dynamic>;
        failures = state['failures'] as int? ?? 0;
        next = DateTime.tryParse(state['next'] as String? ?? '');
      }
      if (automatic && next != null && next.isAfter(DateTime.now().toUtc())) {
        autoTimer = Timer(
          next.difference(DateTime.now().toUtc()),
          () => runSync(automatic: true),
        );
        return;
      }
      if (busy && automatic) {
        scheduleAuto();
        return;
      }
      Map<String, dynamic>? savedSettings;
      if (username == null || password == null || targetsOverride == null) {
        savedSettings =
            (await request('sync_settings_get'))['settings']
                as Map<String, dynamic>?;
        if (username == null || password == null) {
          if (!_hasSyncCredentials(savedSettings)) {
            if (mounted) setState(() => message = '请先保存本机的坚果云同步配置');
            return;
          }
          username = savedSettings!['username'] as String;
          password = savedSettings['password'] as String;
        }
      }
      final targets =
          targetsOverride ??
          _normalizeTargets(savedSettings?['targets'] ?? syncTargets);
      final enabledTargets = targets
          .where((t) => t['enabled'] == true)
          .toList();
      if (enabledTargets.isEmpty) {
        if (mounted) {
          setState(() => message = '当前未启用任何坚果云备份目标，请在「坚果云设置」中勾选');
        }
        return;
      }
      if (current != generation) return;
      attempted = true;
      // Persist cooldown before network I/O so relaunching does not bypass pacing.
      await stateFile.writeAsString(
        jsonEncode({
          'next': DateTime.now()
              .toUtc()
              .add(const Duration(minutes: 15))
              .toIso8601String(),
          'failures': failures,
        }),
        flush: true,
      );
      if (current != generation || !foreground) return;

      final summaries = <String>[];
      var complete = true;
      for (final target in enabledTargets) {
        if (current != generation || !foreground) return;
        final syncClient = NutstoreSync(File(path!).parent, request);
        activeSync = syncClient;
        final folder = (target['folder'] as String? ?? '').trim();
        final res = await syncClient.sync(
          username,
          password,
          remoteFolder: folder.isEmpty ? null : folder,
          existingOnly: target['existingOnly'] == true,
          onProgress: (progress) {
            if (mounted && current == generation) {
              setState(() => message = '${target['name']} · $progress');
            }
          },
        );
        summaries.add('${target['name']} · ${res.message}');
        complete &= res.complete;
      }
      if (current != generation) return;
      await refresh();
      if (initialSyncPending &&
          complete &&
          pendingRevisions == 0 &&
          enabledTargets.any((target) => target['existingOnly'] == true)) {
        final settings =
            (await request('sync_settings_get'))['settings'] as Map?;
        if (settings != null) {
          await request('sync_settings_set', {
            'settings': {...settings, 'joinPending': false},
          });
          initialSyncPending = false;
        }
      }
      failures = 0;
      if (mounted && current == generation) {
        setState(
          () => message = [
            ...summaries,
            if (initialSyncPending) '首次同步尚未完成',
            if (pendingRevisions > 0) '存在缺失的历史版本',
          ].join('\n'),
        );
      }
    } catch (e) {
      failures = (failures + 1).clamp(1, 4);
      if (current == generation && mounted) {
        setState(() {
          message = friendly(e);
        });
      }
    } finally {
      username = null;
      password = null;
      activeSync = null;
      if (mounted) {
        setState(() => syncing = false);
      } else {
        syncing = false;
      }
      if (attempted && current == generation) {
        final minutes = failures == 0 ? 15 : 30 * (1 << (failures - 1));
        try {
          await stateFile.writeAsString(
            jsonEncode({
              'next': DateTime.now()
                  .toUtc()
                  .add(Duration(minutes: minutes))
                  .toIso8601String(),
              'failures': failures,
            }),
            flush: true,
          );
        } catch (_) {
          autoEnabled = false;
        }
        if (autoEnabled && token != null && foreground) {
          autoTimer = Timer(
            Duration(minutes: minutes),
            () => runSync(automatic: true),
          );
        }
      }
    }
  }

  Future<void> forgetSyncSettings() => action(() async {
    await request('sync_settings_clear');
    autoTimer?.cancel();
    setState(() {
      autoEnabled = false;
      syncConfigured = false;
      syncUsername = null;
      syncTargets = [];
      message = '已清除本机坚果云凭据';
    });
  });

  List<String> _splitTags(String raw) {
    final used = <String>{};
    return raw
        .split(RegExp(r'[,，;；]+'))
        .map((tag) => tag.trim())
        .where((tag) => tag.isNotEmpty && used.add(tag.toLowerCase()))
        .toList();
  }

  bool _isPinTag(String tag) => tag == _pinTag || tag.toLowerCase() == 'pinned';

  bool _isPinned(Map<String, dynamic> revision) =>
      _splitTags((revision['data']?['tags'] as String?) ?? '').any(_isPinTag);

  List<String> _entryGroups(Map<String, dynamic> revision) =>
      _splitTags((revision['data']?['tags'] as String?) ?? '')
          .where((tag) => !_isPinTag(tag))
          .toList();

  List<String> _groupOptions() {
    final groups = <String, String>{};
    for (final revision in entries) {
      if (revision['deleted'] == true) continue;
      for (final name in _entryGroups(revision)) {
        groups.putIfAbsent(name.toLowerCase(), () => name);
      }
    }
    return groups.values.toList()..sort();
  }

  String? _selectedNamedGroup(List<String> groups) {
    for (final group in groups) {
      if (group.toLowerCase() == selectedGroup) return group;
    }
    return null;
  }

  void _selectGroup(Object group) {
    touch();
    setState(() {
      selectedGroup = group;
      deleteSelection?.clear();
    });
  }

  Future<void> _setDeleted(
    List<String> heads, {
    required bool deleted,
    bool discard = false,
  }) async {
    if (heads.isEmpty || busy) return;
    touch();
    final epoch = generation;
    if (discard || heads.length > 1) {
      final verb = discard ? '从回收站清除' : '移入回收站';
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('$verb ${heads.length} 个账号？'),
          content: Text(
            discard ? '清除后无法从回收站恢复。已有密文历史和备份仍会保留。' : '可以在回收站恢复这些账号。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(verb),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted || generation != epoch) return;
    }
    await action(() async {
      await request(discard ? 'discard_trash' : 'set_deleted', {
        'heads': heads,
        if (!discard) 'deleted': deleted,
      });
      await refresh();
      if (!mounted || epoch != generation) return;
      final result = discard
          ? '已从回收站清除 ${heads.length} 个账号'
          : deleted
          ? '已将 ${heads.length} 个账号移入回收站'
          : '已恢复账号';
      setState(() {
        deleteSelection = null;
        message = result;
      });
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(result)));
    });
  }

  Future<void> _togglePin(Map<String, dynamic> revision) async {
    touch();
    final epoch = generation;
    final group = entries
        .where((r) => r['entry'] == revision['entry'])
        .toList();
    final data = Map<String, dynamic>.from(revision['data'] as Map);
    final tags = _splitTags((data['tags'] as String?) ?? '');
    final currentlyPinned = tags.any(_isPinTag);
    final nextTags = currentlyPinned
        ? tags.where((t) => !_isPinTag(t)).toList()
        : [_pinTag, ...tags];
    data['tags'] = nextTags.join(', ');
    await action(() async {
      if (epoch != generation) return;
      await request('save', {
        'data': data,
        'entry': revision['entry'],
        'parents': group.map((r) => r['id']).toList(),
        'deleted': revision['deleted'] == true,
      });
      await refresh();
      if (mounted && epoch == generation) {
        setState(
          () => message = currentlyPinned
              ? '已取消置顶「${data['title']}」'
              : '已置顶「${data['title']}」',
        );
      }
    });
  }

  Future<void> copy(String value, {String label = '内容'}) async {
    touch();
    if (Platform.isAndroid) {
      await const MethodChannel('org.wencrypt.files')
          .invokeMethod('copySensitive', {'text': value});
    } else {
      await Clipboard.setData(ClipboardData(text: value));
    }
    clipboard?.cancel();
    clipboard = Timer(const Duration(seconds: 20), () async {
      final current = await Clipboard.getData('text/plain');
      if (current?.text == value) {
        await Clipboard.setData(const ClipboardData(text: ''));
      }
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text('已复制$label，20 秒后自动清空剪贴板'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> edit(Map<String, dynamic>? revision) async {
    touch();
    final epoch = generation;
    final group = revision == null
        ? <Map<String, dynamic>>[]
        : entries.where((r) => r['entry'] == revision['entry']).toList();
    final initialTags = _splitTags(
      (revision?['data']?['tags'] as String?) ?? '',
    );
    var pinned = initialTags.any(_isPinTag);
    final knownGroups = _groupOptions();
    final initialGroupText = revision == null
        ? _selectedNamedGroup(knownGroups) ?? ''
        : initialTags.where((tag) => !_isPinTag(tag)).join(', ');
    final groupOptions = _splitTags(
      [...knownGroups, ..._presetGroups].join(', '),
    );

    final controllers = <String, TextEditingController>{
      for (final key in [
        'title',
        'username',
        'password',
        'url',
        'tags',
        'notes',
      ])
        key: TextEditingController(
          text: key == 'tags'
              ? initialGroupText
              : (revision?['data'][key] as String? ?? ''),
        ),
    };
    final tagController = controllers['tags']!;
    final committedTags = ValueNotifier(tagController.text);
    tagController.addListener(() {
      final value = tagController.value;
      if (!value.composing.isValid || value.composing.isCollapsed) {
        committedTags.value = value.text;
      }
    });
    bool reveal = false;
    final route = DialogRoute<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) {
          return AlertDialog(
            title: Row(
              children: [
                Icon(
                  revision == null
                      ? Icons.add_circle_outline
                      : group.length > 1
                      ? Icons.warning_amber_rounded
                      : Icons.edit_outlined,
                  color: group.length > 1
                      ? Colors.amber.shade700
                      : Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 10),
                Text(
                  revision == null
                      ? '新增账号'
                      : group.length > 1
                      ? '解决冲突（${group.length} 个版本）'
                      : '编辑账号',
                ),
              ],
            ),
            content: SizedBox(
              width: 520,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (group.length > 1) ...[
                      Container(
                        padding: const EdgeInsets.all(12),
                        margin: const EdgeInsets.only(bottom: 14),
                        decoration: BoxDecoration(
                          color: Colors.amber.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: Colors.amber.withValues(alpha: 0.4),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              '检测到并发修改，请选择一个版本作为基础后保存（历史版本仍会保留）：',
                              style: TextStyle(fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(height: 6),
                            for (final r in group)
                              TextButton(
                                onPressed: () {
                                  for (final key in controllers.keys) {
                                    controllers[key]!.text =
                                        r['data'][key] as String;
                                  }
                                  setLocal(() {});
                                },
                                child: Text(
                                  '${r['data']['title']} · ${r['deleted'] == true ? '删除版本' : r['data']['username']} · ${r['id'].toString().substring(0, 8)}',
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                    for (final key in controllers.keys) ...[
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: TextField(
                          controller: controllers[key],
                          obscureText: key == 'password' && !reveal,
                          autocorrect: false,
                          enableSuggestions: false,
                          maxLines: key == 'notes' ? 3 : 1,
                          decoration: InputDecoration(
                            labelText: const {
                              'title': '名称',
                              'username': '用户名',
                              'password': '密码',
                              'url': '网址',
                              'tags': '分组（可输入新分组，多个用逗号分隔）',
                              'notes': '备注',
                            }[key],
                            prefixIcon: Icon(
                              const {
                                'title': Icons.label_outline,
                                'username': Icons.person_outline,
                                'password': Icons.key_outlined,
                                'url': Icons.link,
                                'tags': Icons.folder_outlined,
                                'notes': Icons.notes_outlined,
                              }[key],
                              size: 20,
                            ),
                            suffixIcon: key == 'password'
                                ? Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      IconButton(
                                        tooltip: '生成 24 位随机密码',
                                        icon: const Icon(Icons.auto_fix_high),
                                        onPressed: () {
                                          const chars =
                                              'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!@#%&*+-_';
                                          final rng = Random.secure();
                                          controllers['password']!.text =
                                              List.generate(
                                                24,
                                                (_) =>
                                                    chars[rng.nextInt(
                                                      chars.length,
                                                    )],
                                              ).join();
                                          setLocal(() {});
                                        },
                                      ),
                                      IconButton(
                                        tooltip: reveal ? '隐藏密码' : '显示密码',
                                        icon: Icon(
                                          reveal
                                              ? Icons.visibility_off
                                              : Icons.visibility,
                                        ),
                                        onPressed: () =>
                                            setLocal(() => reveal = !reveal),
                                      ),
                                    ],
                                  )
                                : null,
                          ),
                        ),
                      ),
                      if (key == 'tags') ...[
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: ValueListenableBuilder<String>(
                            valueListenable: committedTags,
                            builder: (_, tags, _) {
                              final groups = _splitTags(tags);
                              final keys = groups
                                  .map((name) => name.toLowerCase())
                                  .toSet();
                              return Wrap(
                                spacing: 6,
                                runSpacing: 6,
                                children: [
                                  for (final preset in groupOptions)
                                    FilterChip(
                                      label: Text(preset),
                                      selected: keys.contains(
                                        preset.toLowerCase(),
                                      ),
                                      visualDensity: VisualDensity.compact,
                                      onSelected: (selected) {
                                        if (selected) {
                                          groups.add(preset);
                                        } else {
                                          groups.removeWhere(
                                            (name) =>
                                                name.toLowerCase() ==
                                                preset.toLowerCase(),
                                          );
                                        }
                                        tagController.text = groups.join(', ');
                                      },
                                    ),
                                ],
                              );
                            },
                          ),
                        ),
                      ],
                    ],
                    SwitchListTile(
                      value: pinned,
                      contentPadding: EdgeInsets.zero,
                      secondary: Icon(
                        pinned ? Icons.push_pin : Icons.push_pin_outlined,
                      ),
                      title: const Text('置顶此账号'),
                      subtitle: const Text('置顶账号会始终显示在列表最前方'),
                      onChanged: (v) => setLocal(() => pinned = v),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              if (revision != null)
                TextButton.icon(
                  onPressed: () =>
                      Navigator.pop(context, trash ? 'restore' : 'delete'),
                  icon: Icon(
                    trash ? Icons.restore : Icons.delete_outline,
                    color: trash ? null : Theme.of(context).colorScheme.error,
                  ),
                  label: Text(
                    trash ? '恢复' : '移入回收站',
                    style: TextStyle(
                      color: trash ? null : Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, 'save'),
                child: const Text('保存'),
              ),
            ],
          );
        },
      ),
    );
    final result = await Navigator.of(context).push(route);
    await route.completed;
    if (result != null && epoch == generation) {
      final cleanedGroups = _splitTags(controllers['tags']!.text)
          .where((t) => !_isPinTag(t))
          .toList();
      final finalTags = pinned ? [_pinTag, ...cleanedGroups] : cleanedGroups;
      final data = {
        for (final e in controllers.entries)
          e.key: e.key == 'tags' ? finalTags.join(', ') : e.value.text,
      };
      await action(() async {
        await request('save', {
          'data': data,
          if (revision != null) 'entry': revision['entry'],
          'parents': group.map((r) => r['id']).toList(),
          'deleted': result == 'delete',
        });
        await refresh();
      });
    }
    for (final c in controllers.values) {
      c.dispose();
    }
    committedTags.dispose();
  }

  Future<({String? password, bool fingerprint})?> _reauthenticate({
    bool allowFingerprint = false,
  }) async {
    final controller = TextEditingController();
    final route = DialogRoute<({String? password, bool fingerprint})>(
      context: context,
      builder: (context) {
        void confirm() => Navigator.pop(context, (
          password: controller.text,
          fingerprint: false,
        ));
        return AlertDialog(
          title: Text(allowFingerprint ? '授权导出加密备份' : '确认主密码'),
          content: TextField(
            controller: controller,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(labelText: '主密码'),
            onSubmitted: (_) => confirm(),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            if (allowFingerprint)
              OutlinedButton.icon(
                onPressed: () =>
                    Navigator.pop(context, (password: null, fingerprint: true)),
                icon: const Icon(Icons.fingerprint),
                label: const Text('使用指纹'),
              ),
            FilledButton(onPressed: confirm, child: const Text('确认主密码')),
          ],
        );
      },
    );
    final result = await Navigator.of(context).push(route);
    await route.completed;
    controller.dispose();
    return result;
  }

  Future<String?> passwordPrompt() async => (await _reauthenticate())?.password;

  Future<void> backup() async {
    final snapshot = generation;
    final authorization = await _reauthenticate(
      allowFingerprint:
          biometricEnabled && (Platform.isMacOS || Platform.isAndroid),
    );
    if (authorization == null || !mounted || snapshot != generation) return;
    await action(() async {
      final args = <String, dynamic>{};
      if (authorization.fingerprint) {
        authenticating = true;
        try {
          final result = await device.invokeMapMethod<String, dynamic>(
            'authorizeBackup',
            {'binding': binding, 'epoch': nativeEpoch},
          );
          if (!mounted || snapshot != generation) return;
          if (result?['ticket'] is! String) {
            throw StateError('biometric_failed');
          }
          args['biometric_ticket'] = result!['ticket'];
        } finally {
          authenticating = false;
        }
      } else {
        args['password'] = authorization.password;
      }
      final data = await request('export', args);
      final bytes = utf8.encode(jsonEncode(data));
      if (bytes.length > 2 * 1024 * 1024) {
        throw StateError('backup_limit');
      }
      bool saved;
      if (Platform.isAndroid) {
        saved =
            await const MethodChannel('org.wencrypt.files').invokeMethod<bool>(
              'saveBackup',
              {'bytes': Uint8List.fromList(bytes)},
            ) ==
            true;
      } else {
        final location = await getSaveLocation(
          suggestedName: 'wencrypt-backup.wenback',
        );
        saved = location != null;
        if (location != null) {
          await XFile.fromData(Uint8List.fromList(bytes)).saveTo(location.path);
        }
      }
      if (mounted && snapshot == generation) {
        setState(() => message = saved ? '已保存加密备份' : '已取消保存备份');
      }
    });
  }

  Future<void> _exportEntryImage(Map<String, dynamic> data) async {
    final epoch = generation;
    final toAlbum = Platform.isAndroid;
    touch();
    final png = await showDialog<Uint8List>(
      context: context,
      builder: (_) => EntryImageDialog(entry: data, toAlbum: toAlbum),
    );
    if (png == null) return;
    try {
      if (!mounted || epoch != generation || busy) return;
      await action(() async {
        final saved = await entryImage.invokeMethod<bool>(
          toAlbum ? 'savePng' : 'copyPng',
          png,
        );
        if (saved != true) throw StateError('image_export_failed');
        if (mounted && epoch == generation) {
          final result = toAlbum ? '图片已保存到 Wencrypt 相册' : '图片已复制到剪贴板';
          setState(() => message = result);
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(result)));
        }
      });
    } finally {
      png.fillRange(0, png.length, 0);
    }
  }

  Future<void> restore() async {
    if (exists || busy || path == null) return;
    try {
      final file = await openFile();
      if (file == null || !mounted || exists) return;
      final epoch = generation;
      if (await file.length() > 2 * 1024 * 1024) {
        if (mounted) setState(() => message = '备份文件超过本版本的 2 MiB 上限');
        return;
      }
      final data =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      if (!mounted || epoch != generation) return;
      final password = await passwordPrompt();
      if (password == null || !mounted || epoch != generation) return;
      await action(() async {
        await core({
          'op': 'restore',
          'path': path,
          'password': password,
          'bootstrap': data['bootstrap'],
          'backup': data['backup'],
        });
        await initialize();
        if (mounted) setState(() => message = '已恢复密码库。请用原主密码解锁。');
      });
    } catch (error) {
      if (mounted) setState(() => message = friendly(error));
    }
  }

  Future<void> joinCloudVault() async {
    if (exists || busy || path == null) return;
    final epoch = generation;
    final fields = {
      '坚果云账号': TextEditingController(),
      'WebDAV 应用密码': TextEditingController(),
      '同步目录名': TextEditingController(),
      '已有库的主密码': TextEditingController(),
    };
    final form = GlobalKey<FormState>();
    var automatic = true;
    final dialog = DialogRoute<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: const Text('从坚果云加入已有库'),
          content: SizedBox(
            width: 400,
            child: SingleChildScrollView(
              child: Form(
                key: form,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text('在原设备完成同步，再从「坚果云设置」找到同步目录名。'),
                    for (final entry in fields.entries)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: TextFormField(
                          controller: entry.value,
                          decoration: InputDecoration(labelText: entry.key),
                          obscureText: entry.key.contains('密码'),
                          enableSuggestions: false,
                          autocorrect: false,
                          validator: (value) {
                            final input = value ?? '';
                            final empty = entry.key.contains('密码')
                                ? input.isEmpty
                                : input.trim().isEmpty;
                            return empty ? '请填写此项' : null;
                          },
                        ),
                      ),
                    const SizedBox(height: 8),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: automatic,
                      onChanged: (value) =>
                          setLocal(() => automatic = value == true),
                      title: const Text('加入后自动同步'),
                      subtitle: const Text('WebDAV 凭据加密保存在本机'),
                    ),
                  ],
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                if (form.currentState!.validate()) Navigator.pop(context, true);
              },
              child: const Text('验证并加入'),
            ),
          ],
        ),
      ),
    );
    final accepted = await Navigator.of(context).push(dialog);
    await dialog.completed;
    final username = fields['坚果云账号']!.text.trim();
    final appPassword = fields['WebDAV 应用密码']!.text;
    final folder = fields['同步目录名']!.text.trim();
    final masterPassword = fields['已有库的主密码']!.text;
    for (final field in fields.values) {
      field.clear();
      field.dispose();
    }
    if (accepted != true || !mounted || epoch != generation || exists) return;
    await action(() async {
      final reader = NutstoreSync(File(path!).parent, request);
      activeSync = reader;
      final String bootstrap;
      try {
        bootstrap = await reader.readExistingBootstrap(
          username,
          appPassword,
          folder,
        );
      } finally {
        if (identical(activeSync, reader)) activeSync = null;
      }
      if (!mounted || epoch != generation) return;
      final targets = [
        {
          'id': 'joined',
          'name': '主同步目录',
          'folder': folder,
          'enabled': true,
          'existingOnly': true,
        },
      ];
      final opened = await core({
        'op': 'join',
        'path': path,
        'password': masterPassword,
        'bootstrap': bootstrap,
        'settings': {
          'username': username,
          'password': appPassword,
          'auto': automatic,
          'targets': targets,
          'joinPending': true,
        },
      });
      if (!mounted || epoch != generation) {
        if (mounted) await initialize();
        return;
      }
      token = opened['session'] as String;
      exists = true;
      touch();
      await refresh();
      await loadAuto();
      await runSync(
        automatic: false,
        username: username,
        password: appPassword,
        targetsOverride: targets,
      );
    });
  }

  Future<void> history(Map<String, dynamic> revision) async {
    await action(() async {
      final data = await request('history', {'entry': revision['entry']});
      if (!mounted) return;
      final revisions = (data['revisions'] as List).cast<Map<String, dynamic>>()
        ..sort(
          (a, b) => (b['updated_at'] as int).compareTo(a['updated_at'] as int),
        );
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('历史版本'),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final r in revisions)
                    ListTile(
                      leading: Icon(
                        r['deleted'] == true
                            ? Icons.delete_outline
                            : Icons.history,
                      ),
                      title: Text(
                        '${r['data']['title']} · ${r['deleted'] == true ? '已删除' : '已保存'}',
                      ),
                      subtitle: Text(
                        DateTime.fromMillisecondsSinceEpoch(
                          (r['updated_at'] as int) * 1000,
                        ).toLocal().toString().substring(0, 19),
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.copy),
                        tooltip: '复制此版本密码',
                        onPressed: () => copy(
                          r['data']['password'] as String,
                          label: '历史密码',
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
    });
  }

  Future<bool> _ensureUnlockedForImport() async {
    if (token != null) return true;
    final epoch = generation;
    final password = await passwordPrompt();
    if (password == null || epoch != generation) return false;
    final opened = await core({
      'op': 'unlock',
      'path': path,
      'password': password,
    });
    if (epoch != generation) {
      lockCore();
      return false;
    }
    token = opened['session'] as String;
    touch();
    await loadAuto();
    return true;
  }

  Future<void> importFromBrowser() async {
    if (busy) return;
    try {
      final installed = await installedBrowsers();
      if (!mounted) return;

      if (installed.isEmpty) {
        await importCsv();
        return;
      }

      final choice = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('从浏览器自动导入密码'),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '选择浏览器后，Wencrypt 会监听下载目录并打开密码管理页。'
                  '导出 CSV 后可预览、合并账号并删除临时文件。'
                  '${Platform.isMacOS ? 'macOS 首次打开 Chrome 或 Edge 设置页时可能要求授权。' : ''}',
                  style: Theme.of(ctx).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 16),
                for (final name in installed.keys)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(ctx, name),
                      style: OutlinedButton.styleFrom(
                        alignment: Alignment.centerLeft,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 14,
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            name == 'Edge'
                                ? Icons.language
                                : name == 'Chrome'
                                ? Icons.public
                                : Icons.local_fire_department_outlined,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '从 $name 导出并自动捕获',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                Text(
                                  browserSettingsUrl(name),
                                  style: Theme.of(ctx).textTheme.bodySmall,
                                ),
                              ],
                            ),
                          ),
                          const Icon(Icons.chevron_right),
                        ],
                      ),
                    ),
                  ),
                const Divider(height: 20),
                TextButton.icon(
                  onPressed: () => Navigator.pop(ctx, '__manual__'),
                  icon: const Icon(Icons.file_open_outlined),
                  label: const Text('我已导出，直接手动选择 CSV 文件'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
          ],
        ),
      );

      if (!mounted || choice == null) return;
      if (choice == '__manual__') {
        await importCsv();
        return;
      }

      final watchDirs = await defaultWatchDirectories();
      if (!mounted) return;

      final watchResult = await watchBrowserExportDialog(
        context,
        browser: choice,
        app: installed[choice]!,
        initialDirs: watchDirs,
      );
      if (!mounted || watchResult == null) return;

      if (watchResult.manualFiles.isNotEmpty) {
        await _importSelectedXFiles(watchResult.manualFiles);
        return;
      }

      final captured = watchResult.captured;
      if (captured == null) return;

      await action(() async {
        if (!await _ensureUnlockedForImport()) return;
        final epoch = generation;
        await refresh();
        if (!mounted || epoch != generation) return;

        var shredAfterImport = true;
        final fileName = captured.file.uri.pathSegments.lastWhere(
          (s) => s.isNotEmpty,
          orElse: () => captured.file.path,
        );

        final groups = _groupOptions();
        final selected = await selectPasswords(
          context,
          captured.export,
          entries,
          sourceFileName: fileName,
          groups: groups,
          initialGroup: _selectedNamedGroup(groups),
          shredAfterImport: shredAfterImport,
          onShredChanged: (v) => shredAfterImport = v,
        );
        if (selected == null || epoch != generation) return;

        final result = await request('import', {'entries': selected});
        var shredded = false;
        if (shredAfterImport) {
          try {
            await shredFile(captured.file);
            shredded = true;
          } catch (_) {
            shredded = false;
          }
        }
        await refresh();
        if (mounted && epoch == generation) {
          setState(
            () => message =
                '${_importSummary(result)}。'
                '${shredded ? '临时 CSV 已删除' : '临时 CSV 仍在原位置'}',
          );
        }
      });
    } catch (e) {
      if (mounted) setState(() => message = friendly(e));
    }
  }

  Future<void> importCsv() async {
    if (busy) return;
    try {
      final files = await openFiles(
        acceptedTypeGroups: const [
          XTypeGroup(
            label: 'CSV',
            extensions: ['csv'],
            uniformTypeIdentifiers: ['public.comma-separated-values-text'],
            mimeTypes: ['text/csv', 'text/plain', 'application/vnd.ms-excel'],
          ),
        ],
      );
      if (files.isEmpty || !mounted) return;
      await _importSelectedXFiles(files);
    } catch (e) {
      if (mounted) setState(() => message = friendly(e));
    }
  }

  Future<void> _importSelectedXFiles(List<XFile> files) => action(() async {
    final batches = <BrowserExport>[];
    var totalBytes = 0;
    for (final file in files) {
      totalBytes += await file.length();
      if (totalBytes > 1024 * 1024) throw StateError('csv_limit');
      batches.add(BrowserExport.parse(await file.readAsString()));
    }
    final batch = BrowserExport.combine(batches);
    if (!mounted) return;
    if (batch.rows.isEmpty) {
      setState(() => message = '所选文件中没有可导入的账号');
      return;
    }
    if (!await _ensureUnlockedForImport()) return;
    final epoch = generation;
    await refresh();
    if (!mounted || epoch != generation) return;
    final groups = _groupOptions();
    final selected = await selectPasswords(
      context,
      batch,
      entries,
      groups: groups,
      initialGroup: _selectedNamedGroup(groups),
    );
    if (selected == null || epoch != generation) return;
    final result = await request('import', {'entries': selected});
    await refresh();
    if (mounted && epoch == generation) {
      setState(() => message = _importSummary(result));
    }
  });

  String _importSummary(Map<String, dynamic> result) =>
      '新增 ${result['added']} 个账号，合并重复 ${result['duplicates']} 条'
      '（更新 ${result['updated']} 个现有账号）';

  Future<void> sync({bool configure = false}) => action(() async {
    if (token == null || syncing) return;
    final epoch = generation;
    final existing =
        (await request('sync_settings_get'))['settings']
            as Map<String, dynamic>?;
    if (!mounted || epoch != generation) return;
    final savedCredentials = _hasSyncCredentials(existing);
    if (!configure && savedCredentials) {
      await runSync(
        automatic: false,
        username: existing!['username'] as String,
        password: existing['password'] as String,
        targetsOverride: _normalizeTargets(existing['targets']),
      );
      return;
    }
    final user = TextEditingController(text: existing?['username'] as String?);
    final password = TextEditingController(
      text: existing?['password'] as String?,
    );
    var editCredentials = !savedCredentials;
    var automatic = existing?['auto'] == true;
    final targets = _normalizeTargets(existing?['targets'])
        .map((t) => Map<String, dynamic>.from(t))
        .toList();

    final dialog = DialogRoute<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: const Text('坚果云设置与多备份管理'),
          content: SizedBox(
            width: 500,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('使用坚果云生成的 WebDAV 应用密码。支持配置多个同步备份目录，自由勾选是否同步。'),
                  const SizedBox(height: 14),
                  if (editCredentials) ...[
                    TextField(
                      controller: user,
                      decoration: const InputDecoration(
                        labelText: '坚果云账号',
                        prefixIcon: Icon(Icons.cloud_outlined),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: password,
                      obscureText: true,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: const InputDecoration(
                        labelText: 'WebDAV 应用密码',
                        prefixIcon: Icon(Icons.key_outlined),
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text('凭据会加密保存在本机，下次同步自动使用。'),
                  ] else
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.lock_outline),
                      title: Text(user.text),
                      subtitle: const Text('凭据已加密保存在本机'),
                      trailing: TextButton(
                        onPressed: () => setLocal(() => editCredentials = true),
                        child: const Text('更换'),
                      ),
                    ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '同步备份目标（可多选）',
                          style: Theme.of(context).textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                      ),
                      TextButton.icon(
                        onPressed: () async {
                          final nameCtrl = TextEditingController(
                            text: '备份 ${targets.length + 1}',
                          );
                          final folderCtrl = TextEditingController(
                            text:
                                'wc-${(vaultId ?? 'vault').substring(0, (vaultId ?? 'vault').length >= 8 ? 8 : (vaultId ?? 'vault').length)}-b${targets.length + 1}',
                          );
                          final added = await showDialog<bool>(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              title: const Text('新增坚果云备份目录'),
                              content: SizedBox(
                                width: 380,
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    TextField(
                                      controller: nameCtrl,
                                      decoration: const InputDecoration(
                                        labelText: '备份名称（如：日常备份 / 异地存档）',
                                      ),
                                    ),
                                    const SizedBox(height: 12),
                                    TextField(
                                      controller: folderCtrl,
                                      decoration: const InputDecoration(
                                        labelText: '坚果云目录名（不超过 32 字符，不含 /）',
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(ctx, false),
                                  child: const Text('取消'),
                                ),
                                FilledButton(
                                  onPressed: () => Navigator.pop(ctx, true),
                                  child: const Text('添加'),
                                ),
                              ],
                            ),
                          );
                          if (added == true) {
                            final name = nameCtrl.text.trim();
                            final folder = folderCtrl.text
                                .trim()
                                .replaceAll('/', '')
                                .replaceAll('\\', '');
                            if (name.isNotEmpty &&
                                folder.isNotEmpty &&
                                folder.length <= 32) {
                              setLocal(() {
                                targets.add({
                                  'id':
                                      't-${DateTime.now().microsecondsSinceEpoch}',
                                  'name': name,
                                  'folder': folder,
                                  'enabled': true,
                                });
                              });
                            }
                          }
                          nameCtrl.dispose();
                          folderCtrl.dispose();
                        },
                        icon: const Icon(Icons.add, size: 18),
                        label: const Text('添加备份目录'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  for (var i = 0; i < targets.length; i++)
                    Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: Theme.of(context).dividerColor,
                        ),
                      ),
                      child: CheckboxListTile(
                        value: targets[i]['enabled'] == true,
                        onChanged: (v) =>
                            setLocal(() => targets[i]['enabled'] = v == true),
                        title: Text(targets[i]['name'] as String),
                        subtitle: Text(
                          (targets[i]['folder'] as String).isEmpty
                              ? '目录：/${_defaultFolderName()}/（默认主目录）'
                              : '目录：/${targets[i]['folder']}/',
                        ),
                        secondary: targets.length > 1
                            ? IconButton(
                                tooltip: '删除此备份目标',
                                icon: const Icon(Icons.delete_outline),
                                onPressed: () =>
                                    setLocal(() => targets.removeAt(i)),
                              )
                            : null,
                      ),
                    ),
                  const SizedBox(height: 4),
                  CheckboxListTile(
                    value: automatic,
                    contentPadding: EdgeInsets.zero,
                    onChanged: (v) => setLocal(() => automatic = v == true),
                    title: const Text('自动同步'),
                    subtitle: const Text('仅在前台解锁时运行'),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('保存并同步'),
            ),
          ],
        ),
      ),
    );
    final accepted = await Navigator.of(context).push(dialog);
    await dialog.completed;
    final username = user.text.trim();
    final appPassword = password.text;
    user.dispose();
    password.dispose();
    if (accepted != true || !mounted || epoch != generation) return;
    if (username.isEmpty || username.contains(':') || appPassword.isEmpty) {
      setState(() => message = '请填写坚果云账号和 WebDAV 应用密码');
      return;
    }

    await request('sync_settings_set', {
      'settings': {
        'username': username,
        'password': appPassword,
        'auto': automatic,
        'targets': targets,
        if (initialSyncPending) 'joinPending': true,
      },
    });
    if (!mounted || epoch != generation) return;
    setState(() {
      syncConfigured = true;
      syncUsername = username;
      autoEnabled = automatic;
      syncTargets = targets;
    });
    autoTimer?.cancel();
    await runSync(
      automatic: false,
      username: username,
      password: appPassword,
      targetsOverride: targets,
    );
  });

  Color _avatarColor(String seed, ColorScheme scheme) {
    const palette = [
      Color(0xff2563eb),
      Color(0xff059669),
      Color(0xff7c3aed),
      Color(0xffd97706),
      Color(0xffdb2777),
      Color(0xff0891b2),
    ];
    if (seed.isEmpty) return scheme.primary;
    final hash = seed.codeUnits.fold<int>(0, (acc, c) => acc + c);
    return palette[hash % palette.length];
  }

  String _hostLabel(String url) {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return '';
    final uri = Uri.tryParse(
      trimmed.contains('://') ? trimmed : 'https://$trimmed',
    );
    return uri != null && uri.host.isNotEmpty ? uri.host : trimmed;
  }

  Widget _buildStatusPill(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = busy && !syncing ? '正在处理…' : message;
    final isWarning =
        text.contains('缺失') ||
        text.contains('不正确') ||
        text.contains('失败') ||
        text.contains('未完成') ||
        text.contains('超出') ||
        text.contains('上限') ||
        text.contains('未启用');

    final bg = isWarning
        ? scheme.errorContainer.withValues(alpha: 0.7)
        : scheme.primaryContainer.withValues(alpha: 0.5);
    final fg = isWarning ? scheme.onErrorContainer : scheme.onPrimaryContainer;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (busy || syncing)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(strokeWidth: 2, color: fg),
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.only(right: 5),
              child: Icon(
                isWarning ? Icons.info_outline : Icons.verified_user_outlined,
                size: 14,
                color: fg,
              ),
            ),
          Flexible(
            child: Text(
              text,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall
                  ?.copyWith(color: fg, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSyncBanner(BuildContext context) {
    if (!syncConfigured) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final enabled = syncTargets.where((t) => t['enabled'] == true).toList();
    final targetSummary = enabled.isEmpty
        ? '未勾选同步目录'
        : enabled
              .map((t) {
                final f = (t['folder'] as String? ?? '').trim();
                final dirLabel = f.isEmpty ? _defaultFolderName() : f;
                return '${t['name']} (/$dirLabel/)';
              })
              .join(' · ');

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: theme.dividerColor.withValues(alpha: 0.4)),
        ),
        child: Row(
          children: [
            Icon(
              enabled.isEmpty
                  ? Icons.cloud_off_outlined
                  : Icons.cloud_done_outlined,
              size: 18,
              color: enabled.isEmpty ? scheme.error : scheme.primary,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                initialSyncPending
                    ? '首次同步尚未完成 · $targetSummary'
                    : '坚果云已配置（${syncUsername ?? '已保存'}）· $targetSummary'
                          '${autoEnabled ? ' · 自动同步已开' : ''}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            TextButton(
              onPressed: busy || syncing ? null : () => sync(configure: true),
              child: const Text('选择备份目录'),
            ),
            FilledButton.tonal(
              onPressed: busy || syncing ? null : () => sync(),
              child: Text(syncing ? '同步中…' : '立即同步'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _firstRunChoices() {
    if (firstRunStep == FirstRunStep.welcome) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FilledButton.icon(
            onPressed: busy
                ? null
                : () => setState(() => firstRunStep = FirstRunStep.create),
            icon: const Icon(Icons.lock_outline),
            label: const Text('创建新库'),
          ),
          const SizedBox(height: 6),
          const Text('第一次使用 Wencrypt，在这台设备设置主密码。'),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: busy
                ? null
                : () => setState(() => firstRunStep = FirstRunStep.join),
            icon: const Icon(Icons.devices_outlined),
            label: const Text('加入已有库'),
          ),
          const SizedBox(height: 6),
          const Text('已在其他设备使用 Wencrypt，沿用原来的密码库和主密码。'),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton.icon(
          onPressed: busy || path == null ? null : joinCloudVault,
          icon: const Icon(Icons.cloud_download_outlined),
          label: const Text('从坚果云加入'),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: busy || path == null ? null : restore,
          icon: const Icon(Icons.restore_page_outlined),
          label: const Text('从加密备份恢复'),
        ),
      ],
    );
  }

  void _backToWelcome() {
    master.clear();
    confirm.clear();
    setState(() {
      firstRunStep = FirstRunStep.welcome;
      revealMaster = false;
      revealConfirm = false;
      message = '';
    });
  }

  Widget _buildLockedView(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final showPassword = exists || firstRunStep == FirstRunStep.create;
    final title = exists
        ? '解锁密码库'
        : switch (firstRunStep) {
            FirstRunStep.welcome => '欢迎使用 Wencrypt',
            FirstRunStep.create => '创建新库',
            FirstRunStep.join => '加入已有库',
          };

    return Container(
      decoration: BoxDecoration(
        gradient: RadialGradient(
          center: const Alignment(0, -0.45),
          radius: 1.15,
          colors: isDark
              ? [
                  const Color(0xff172554).withValues(alpha: 0.45),
                  const Color(0xff0b1120),
                ]
              : [
                  const Color(0xffdbeafe).withValues(alpha: 0.7),
                  const Color(0xfff3f6fb),
                ],
        ),
      ),
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Card(
              elevation: isDark ? 0 : 2,
              shadowColor: Colors.black.withValues(alpha: 0.06),
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(20),
                        child: Image.asset(
                          'assets/brand/wencrypt-logo.png',
                          width: 84,
                          height: 84,
                        ),
                      ),
                    ),
                    const SizedBox(height: 18),
                    Text(
                      title,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (showPassword) ...[
                      const SizedBox(height: 12),
                      Text(
                        exists
                            ? '使用已有密码库的主密码解锁。'
                            : '请设置独立的长口令。Wencrypt 无法找回主密码，请妥善保存。',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                          height: 1.5,
                        ),
                      ),
                    ],
                    const SizedBox(height: 24),
                    if (!showPassword) _firstRunChoices(),
                    if (showPassword) ...[
                      TextField(
                        controller: master,
                        obscureText: !revealMaster,
                        autocorrect: false,
                        enableSuggestions: false,
                        decoration: InputDecoration(
                          labelText: exists ? '主密码' : '主密码（至少 12 个字符）',
                          prefixIcon: const Icon(Icons.lock_outline),
                          suffixIcon: IconButton(
                            icon: Icon(
                              revealMaster
                                  ? Icons.visibility_off
                                  : Icons.visibility,
                            ),
                            onPressed: () =>
                                setState(() => revealMaster = !revealMaster),
                          ),
                        ),
                        onSubmitted: (_) => busy ? null : unlock(),
                      ),
                      if (!exists) ...[
                        const SizedBox(height: 12),
                        TextField(
                          controller: confirm,
                          obscureText: !revealConfirm,
                          autocorrect: false,
                          enableSuggestions: false,
                          decoration: InputDecoration(
                            labelText: '再次输入主密码',
                            prefixIcon: const Icon(Icons.verified_outlined),
                            suffixIcon: IconButton(
                              icon: Icon(
                                revealConfirm
                                    ? Icons.visibility_off
                                    : Icons.visibility,
                              ),
                              onPressed: () => setState(
                                () => revealConfirm = !revealConfirm,
                              ),
                            ),
                          ),
                          onSubmitted: (_) => busy ? null : unlock(),
                        ),
                      ],
                      const SizedBox(height: 20),
                      FilledButton(
                        onPressed: busy || path == null ? null : unlock,
                        child: Text(
                          busy
                              ? '正在处理…'
                              : exists
                              ? '解锁'
                              : '创建密码库',
                        ),
                      ),
                      if (exists && biometricEnabled) ...[
                        const SizedBox(height: 10),
                        OutlinedButton.icon(
                          onPressed: busy ? null : biometricUnlock,
                          icon: const Icon(Icons.fingerprint),
                          label: const Text('使用指纹解锁'),
                        ),
                      ],
                    ],
                    if (!exists && firstRunStep != FirstRunStep.welcome) ...[
                      const SizedBox(height: 8),
                      TextButton(
                        onPressed: busy ? null : _backToWelcome,
                        child: const Text('返回'),
                      ),
                    ],
                    if (message.isNotEmpty) ...[
                      const SizedBox(height: 14),
                      Center(child: _buildStatusPill(context)),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildUnlockedView(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final baseList = entries.where((r) => r['deleted'] == trash).toList();
    final activeCount = entries.where((r) => r['deleted'] != true).length;
    final trashCount = entries.where((r) => r['deleted'] == true).length;

    final groupCounts = <String, int>{};
    final groupNames = <String, String>{};
    final revisionCounts = <String, int>{};
    for (final revision in entries) {
      final id = revision['entry'] as String;
      revisionCounts[id] = (revisionCounts[id] ?? 0) + 1;
    }
    var pinnedCount = 0;
    var ungroupedCount = 0;
    for (final r in baseList) {
      if (_isPinned(r)) pinnedCount++;
      final groups = _entryGroups(r);
      if (groups.isEmpty) {
        ungroupedCount++;
      } else {
        for (final g in groups) {
          final key = g.toLowerCase();
          groupNames.putIfAbsent(key, () => g);
          groupCounts[key] = (groupCounts[key] ?? 0) + 1;
        }
      }
    }
    final sortedGroups = groupNames.values.toList()..sort();

    final filtered =
        baseList.where((r) {
          final matchesQuery =
              query.isEmpty ||
              ['title', 'username', 'url', 'tags', 'notes'].any(
                (k) => r['data'][k].toString().toLowerCase().contains(
                  query.toLowerCase(),
                ),
              );
          if (!matchesQuery) return false;
          if (selectedGroup == EntryFilter.all) return true;
          if (selectedGroup == EntryFilter.pinned) return _isPinned(r);
          if (selectedGroup == EntryFilter.ungrouped) {
            return _entryGroups(r).isEmpty;
          }
          return _entryGroups(r)
              .any((group) => group.toLowerCase() == selectedGroup);
        }).toList()..sort((a, b) {
          final pa = _isPinned(a) ? 0 : 1;
          final pb = _isPinned(b) ? 0 : 1;
          if (pa != pb) return pa.compareTo(pb);
          return (a['data']['title'] as String? ?? '').toLowerCase().compareTo(
            (b['data']['title'] as String? ?? '').toLowerCase(),
          );
        });

    final visibleHeads = [
      for (final revision in filtered)
        if (revisionCounts[revision['entry']] == 1) revision['id'] as String,
    ];

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 940),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: searchController,
                      decoration: InputDecoration(
                        prefixIcon: const Icon(Icons.search),
                        hintText: '搜索名称、用户名、网址、分组或备注',
                        suffixIcon: query.isNotEmpty
                            ? IconButton(
                                icon: const Icon(Icons.close, size: 18),
                                onPressed: () {
                                  searchController.clear();
                                  setState(() {
                                    query = '';
                                    deleteSelection?.clear();
                                  });
                                },
                              )
                            : null,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  SegmentedButton<bool>(
                    showSelectedIcon: false,
                    segments: [
                      ButtonSegment(
                        value: false,
                        icon: const Icon(Icons.vpn_key_outlined, size: 18),
                        label: Text('全部 ($activeCount)'),
                      ),
                      ButtonSegment(
                        value: true,
                        icon: const Icon(Icons.delete_outline, size: 18),
                        label: Text('回收站 ($trashCount)'),
                      ),
                    ],
                    selected: {trash},
                    onSelectionChanged: (s) {
                      touch();
                      setState(() {
                        trash = s.first;
                        selectedGroup = EntryFilter.all;
                        deleteSelection = null;
                      });
                    },
                  ),
                ],
              ),
            ),
            if (baseList.isNotEmpty)
              SizedBox(
                height: 42,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text('全部 (${baseList.length})'),
                        selected: selectedGroup == EntryFilter.all,
                        onSelected: (_) => _selectGroup(EntryFilter.all),
                      ),
                    ),
                    if (pinnedCount > 0)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          avatar: const Icon(Icons.push_pin, size: 15),
                          label: Text('已置顶 ($pinnedCount)'),
                          selected: selectedGroup == EntryFilter.pinned,
                          onSelected: (_) => _selectGroup(EntryFilter.pinned),
                        ),
                      ),
                    for (final g in sortedGroups)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text('$g (${groupCounts[g.toLowerCase()]})'),
                          selected: selectedGroup == g.toLowerCase(),
                          onSelected: (_) => _selectGroup(g.toLowerCase()),
                        ),
                      ),
                    if (ungroupedCount > 0 && sortedGroups.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text('未分组 ($ungroupedCount)'),
                          selected: selectedGroup == EntryFilter.ungrouped,
                          onSelected: (_) =>
                              _selectGroup(EntryFilter.ungrouped),
                        ),
                      ),
                  ],
                ),
              ),
            _buildSyncBanner(context),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
              child: Row(
                children: [
                  Expanded(child: _buildStatusPill(context)),
                  const SizedBox(width: 12),
                  if (deleteSelection == null && visibleHeads.isNotEmpty)
                    TextButton.icon(
                      onPressed: busy
                          ? null
                          : () => setState(() => deleteSelection = {}),
                      icon: const Icon(Icons.checklist),
                      label: const Text('多选'),
                    ),
                ],
              ),
            ),
            if (deleteSelection case final selection?)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Wrap(
                  spacing: 8,
                  children: [
                    TextButton(
                      onPressed: busy || visibleHeads.isEmpty
                          ? null
                          : () =>
                                setState(() => selection.addAll(visibleHeads)),
                      child: const Text('全选当前列表'),
                    ),
                    TextButton(
                      onPressed: busy
                          ? null
                          : () => setState(() => deleteSelection = null),
                      child: const Text('退出多选'),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: busy || selection.isEmpty
                          ? null
                          : () => _setDeleted(
                              selection.toList(),
                              deleted: true,
                              discard: trash,
                            ),
                      icon: const Icon(Icons.delete_outline),
                      label: Text(
                        '${trash ? '从回收站清除' : '移入回收站'} (${selection.length})',
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 6),
            Expanded(
              child: filtered.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              trash
                                  ? Icons.delete_sweep_outlined
                                  : query.isNotEmpty ||
                                        selectedGroup != EntryFilter.all
                                  ? Icons.search_off
                                  : Icons.shield_outlined,
                              size: 52,
                              color: scheme.onSurfaceVariant.withValues(
                                alpha: 0.6,
                              ),
                            ),
                            const SizedBox(height: 14),
                            Text(
                              trash
                                  ? '回收站为空'
                                  : query.isNotEmpty ||
                                        selectedGroup != EntryFilter.all
                                  ? '当前筛选条件下没有账号'
                                  : '密码库还没有任何账号',
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              trash
                                  ? '移入回收站的账号会显示在这里'
                                  : query.isNotEmpty ||
                                        selectedGroup != EntryFilter.all
                                  ? '尝试切换分组或清空搜索条件'
                                  : '你可以手动新增，或直接从 Edge / Chrome 自动导入密码',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                            if (!trash &&
                                query.isEmpty &&
                                selectedGroup == EntryFilter.all) ...[
                              const SizedBox(height: 20),
                              Wrap(
                                spacing: 10,
                                runSpacing: 10,
                                alignment: WrapAlignment.center,
                                children: [
                                  if (Platform.isMacOS || Platform.isWindows)
                                    FilledButton.tonalIcon(
                                      onPressed: busy
                                          ? null
                                          : importFromBrowser,
                                      icon: const Icon(Icons.download_outlined),
                                      label: const Text('从 Edge / Chrome 导入'),
                                    ),
                                  FilledButton.icon(
                                    onPressed: busy ? null : () => edit(null),
                                    icon: const Icon(Icons.add),
                                    label: const Text('新增第一个账号'),
                                  ),
                                ],
                              ),
                            ],
                          ],
                        ),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(20, 4, 20, 96),
                      itemCount: filtered.length,
                      itemBuilder: (context, index) {
                        final r = filtered[index];
                        final data = r['data'] as Map<String, dynamic>;
                        final title = (data['title'] as String? ?? '').trim();
                        final username = (data['username'] as String? ?? '')
                            .trim();
                        final url = (data['url'] as String? ?? '').trim();
                        final pinned = _isPinned(r);
                        final groups = _entryGroups(r);
                        final hasConflict = revisionCounts[r['entry']]! > 1;
                        final revisionId = r['id'] as String;
                        final selection = deleteSelection;
                        void toggleSelection(bool selected) {
                          setState(() {
                            if (selected) {
                              selection?.add(revisionId);
                            } else {
                              selection?.remove(revisionId);
                            }
                          });
                        }

                        final host = _hostLabel(url);
                        final initial = title.isNotEmpty
                            ? title.characters.first.toUpperCase()
                            : '?';
                        final avatarBg = hasConflict
                            ? Colors.amber.shade700
                            : _avatarColor(title, scheme);

                        return Card(
                          margin: const EdgeInsets.only(bottom: 10),
                          shape: pinned
                              ? RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(16),
                                  side: BorderSide(
                                    color: scheme.primary.withValues(
                                      alpha: 0.45,
                                    ),
                                  ),
                                )
                              : null,
                          child: InkWell(
                            borderRadius: BorderRadius.circular(16),
                            onTap: busy
                                ? null
                                : selection == null
                                ? () => edit(r)
                                : hasConflict
                                ? null
                                : () => toggleSelection(
                                    !selection.contains(revisionId),
                                  ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 12,
                              ),
                              child: Row(
                                children: [
                                  if (selection != null)
                                    Checkbox(
                                      value: selection.contains(revisionId),
                                      onChanged: busy || hasConflict
                                          ? null
                                          : (value) =>
                                                toggleSelection(value == true),
                                    ),
                                  Container(
                                    width: 42,
                                    height: 42,
                                    decoration: BoxDecoration(
                                      color: avatarBg.withValues(alpha: 0.14),
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    alignment: Alignment.center,
                                    child: hasConflict
                                        ? Icon(
                                            Icons.warning_amber_rounded,
                                            color: avatarBg,
                                          )
                                        : Text(
                                            initial,
                                            style: TextStyle(
                                              color: avatarBg,
                                              fontSize: 18,
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                  ),
                                  const SizedBox(width: 14),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            if (pinned)
                                              Padding(
                                                padding: const EdgeInsets.only(
                                                  right: 5,
                                                ),
                                                child: Icon(
                                                  Icons.push_pin,
                                                  size: 14,
                                                  color: scheme.primary,
                                                ),
                                              ),
                                            Flexible(
                                              child: Text(
                                                title.isEmpty ? '未命名账号' : title,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: theme
                                                    .textTheme
                                                    .titleSmall
                                                    ?.copyWith(
                                                      fontWeight:
                                                          FontWeight.w600,
                                                    ),
                                              ),
                                            ),
                                          ],
                                        ),
                                        if (groups.isNotEmpty)
                                          Text(
                                            groups.join(' · '),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: theme.textTheme.labelSmall,
                                          ),
                                        const SizedBox(height: 3),
                                        Text(
                                          [
                                            if (username.isNotEmpty) username,
                                            if (host.isNotEmpty) host,
                                          ].join(' · '),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: theme.textTheme.bodySmall
                                              ?.copyWith(
                                                color: scheme.onSurfaceVariant,
                                              ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  if (selection == null) ...[
                                    if (trash)
                                      IconButton(
                                        tooltip: '从回收站清除',
                                        icon: const Icon(
                                          Icons.delete_forever_outlined,
                                          size: 20,
                                        ),
                                        onPressed: busy || hasConflict
                                            ? null
                                            : () => _setDeleted(
                                                [revisionId],
                                                deleted: true,
                                                discard: true,
                                              ),
                                      )
                                    else
                                      IconButton(
                                        tooltip: pinned ? '取消置顶' : '置顶',
                                        icon: Icon(
                                          pinned
                                              ? Icons.push_pin
                                              : Icons.push_pin_outlined,
                                          size: 20,
                                          color: pinned ? scheme.primary : null,
                                        ),
                                        onPressed: busy
                                            ? null
                                            : () => _togglePin(r),
                                      ),
                                    IconButton(
                                      tooltip: '复制用户名',
                                      icon: const Icon(
                                        Icons.person_outline,
                                        size: 20,
                                      ),
                                      onPressed: username.isEmpty
                                          ? null
                                          : () => copy(username, label: '用户名'),
                                    ),
                                    IconButton(
                                      tooltip: '复制密码',
                                      icon: const Icon(
                                        Icons.key_outlined,
                                        size: 20,
                                      ),
                                      onPressed: () => copy(
                                        data['password'] as String? ?? '',
                                        label: '密码',
                                      ),
                                    ),
                                    PopupMenuButton<String>(
                                      tooltip: '更多操作',
                                      enabled: !busy,
                                      icon: const Icon(Icons.more_horiz),
                                      onSelected: (v) {
                                        if (v == 'edit') {
                                          edit(r);
                                        } else if (v == 'history') {
                                          history(r);
                                        } else if (v == 'exportImage') {
                                          _exportEntryImage(data);
                                        } else if (v == 'trash') {
                                          _setDeleted([
                                            revisionId,
                                          ], deleted: !trash);
                                        } else {
                                          copy(
                                            data[v] as String? ?? '',
                                            label: v == 'username'
                                                ? '用户名'
                                                : '密码',
                                          );
                                        }
                                      },
                                      itemBuilder: (_) => [
                                        const PopupMenuItem(
                                          value: 'edit',
                                          child: Text('编辑详情'),
                                        ),
                                        const PopupMenuItem(
                                          value: 'username',
                                          child: Text('复制用户名'),
                                        ),
                                        const PopupMenuItem(
                                          value: 'password',
                                          child: Text('复制密码'),
                                        ),
                                        const PopupMenuItem(
                                          value: 'history',
                                          child: Text('历史版本'),
                                        ),
                                        if (!trash &&
                                            !hasConflict &&
                                            (Platform.isAndroid ||
                                                Platform.isMacOS ||
                                                Platform.isWindows))
                                          const PopupMenuItem(
                                            value: 'exportImage',
                                            child: Text('导出账号图片'),
                                          ),
                                        if (!hasConflict)
                                          PopupMenuItem(
                                            value: 'trash',
                                            child: Text(
                                              trash ? '恢复账号' : '移入回收站',
                                            ),
                                          ),
                                      ],
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final themeIcon = switch (widget.themeMode) {
      ThemeMode.system => Icons.brightness_auto_outlined,
      ThemeMode.light => Icons.light_mode_outlined,
      ThemeMode.dark => Icons.dark_mode_outlined,
    };

    return Listener(
      onPointerDown: (_) => touch(),
      child: Scaffold(
        appBar: AppBar(
          toolbarHeight: 64,
          title: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.asset(
                  'assets/brand/wencrypt-logo.png',
                  width: 28,
                  height: 28,
                ),
              ),
              const SizedBox(width: 10),
              const Text(
                'Wencrypt',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ],
          ),
          actions: [
            if (token != null && (Platform.isMacOS || Platform.isWindows))
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: FilledButton.tonalIcon(
                  onPressed: busy ? null : importFromBrowser,
                  icon: const Icon(Icons.download_outlined, size: 18),
                  label: const Text('从 Edge / Chrome 导入'),
                ),
              ),
            if (token != null)
              IconButton(
                onPressed: busy || syncing ? null : sync,
                icon: syncing
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.sync),
                tooltip: '坚果云同步',
              ),
            if (token != null)
              IconButton(
                onPressed: busy ? null : backup,
                icon: const Icon(Icons.save_alt),
                tooltip: '加密备份',
              ),
            if (token != null)
              IconButton(
                onPressed: lock,
                icon: const Icon(Icons.lock_outline),
                tooltip: '锁定',
              ),
            if (widget.onCycleTheme != null)
              IconButton(
                onPressed: widget.onCycleTheme,
                icon: Icon(themeIcon),
                tooltip: '切换浅色/深色主题',
              ),
            PopupMenuButton<String>(
              onSelected: (v) {
                if (v == 'biometric') enableBiometric();
                if (v == 'disableBiometric') disableBiometric();
                if (v == 'toggleFocusLock') {
                  setState(() {
                    lockOnFocusLoss = !lockOnFocusLoss;
                    message = lockOnFocusLoss
                        ? '已开启：切换窗口时自动锁定'
                        : '已开启：切换窗口时保持解锁（5 分钟无操作后锁定）';
                  });
                }
                if (v == 'syncSettings') sync(configure: true);
                if (v == 'forgetSync') forgetSyncSettings();
                if (v == 'browserImport') importFromBrowser();
                if (v == 'csv') importCsv();
                if (v == 'probe') {
                  lock();
                  Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => const WencryptProbeApp(),
                    ),
                  );
                }
              },
              itemBuilder: (_) => [
                if (Platform.isMacOS || Platform.isWindows || Platform.isLinux)
                  PopupMenuItem(
                    value: 'toggleFocusLock',
                    child: Text(
                      lockOnFocusLoss
                          ? '切换窗口时保持解锁（推荐填表时开启）'
                          : '✓ 切换窗口时保持解锁（点击改为失焦即锁）',
                    ),
                  ),
                if (token != null && (Platform.isMacOS || Platform.isAndroid))
                  PopupMenuItem(
                    value: 'biometric',
                    child: Text(biometricEnabled ? '重新绑定指纹解锁' : '启用指纹解锁'),
                  ),
                if (token != null && biometricEnabled)
                  const PopupMenuItem(
                    value: 'disableBiometric',
                    child: Text('关闭指纹解锁'),
                  ),
                if (token != null)
                  PopupMenuItem(
                    value: 'syncSettings',
                    enabled: !busy && !syncing,
                    child: Text(syncConfigured ? '坚果云设置（已配置）' : '坚果云设置'),
                  ),
                if (token != null && syncConfigured)
                  PopupMenuItem(
                    value: 'forgetSync',
                    enabled: !busy && !syncing,
                    child: const Text('清除坚果云凭据'),
                  ),
                if (exists && (Platform.isMacOS || Platform.isWindows))
                  PopupMenuItem(
                    value: 'browserImport',
                    enabled: !busy,
                    child: const Text('从 Edge / Chrome 自动导入'),
                  ),
                if (exists)
                  PopupMenuItem(
                    value: 'csv',
                    enabled: !busy,
                    child: const Text('手动导入浏览器 CSV'),
                  ),
                const PopupMenuItem(value: 'probe', child: Text('设备诊断')),
              ],
            ),
            const SizedBox(width: 6),
          ],
        ),
        body: token == null
            ? _buildLockedView(context)
            : _buildUnlockedView(context),
        floatingActionButton: token == null
            ? null
            : FloatingActionButton.extended(
                onPressed: busy ? null : () => edit(null),
                icon: const Icon(Icons.add),
                label: const Text('新增账号'),
              ),
      ),
    );
  }
}
