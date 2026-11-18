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

class _VaultPageState extends State<VaultPage> with WidgetsBindingObserver {
  static const _pinTag = '置顶';
  static const _presetGroups = ['工作', '财务', '社交', '开发', '购物', '生活'];
  static const device = MethodChannel('org.wencrypt.device/vault');

  final master = TextEditingController();
  final confirm = TextEditingController();
  final searchController = TextEditingController();

  String? path, token, binding, vaultId, syncUsername;
  String message = '正在加载…', query = '', selectedGroup = '__all__';
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
    searchController.dispose();
    idle?.cancel();
    clipboard?.cancel();
    autoTimer?.cancel();
    activeSync?.cancel();
    super.dispose();
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
    autoTimer?.cancel();
    activeSync?.cancel();
    device.invokeMethod<Object?>('cancel').catchError((Object _) => null);
    token = null;
    entries = [];
    syncTargets = [];
    syncUsername = null;
    vaultId = null;
    selectedGroup = '__all__';
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
      if (e.reason == 'invalid_remote_folder') {
        return '坚果云同步目录名称不能包含斜杠或超过 32 个字符。';
      }
      return e.toString();
    }
    if (text.contains('biometric')) {
      return '指纹认证取消、密钥失效或设备保护不可用。请用主密码解锁；需要时重新启用指纹。';
    }
    if (text.contains('backup_limit')) return '超出 Alpha 的 2 MiB 备份上限，导出已停止。';
    if (text.contains('free_budget')) return '已达到本机免费流量或请求预算，请稍后再试。';
    if (text.contains('remote_missing')) return '云端副本缺失，已停止同步；本地数据仍保留。';
    if (text.contains('directory_limit')) return '达到 Alpha 云目录上限，请先导出加密备份。';
    if (text.contains('entry_changed')) return '条目已被修改，请重新打开后编辑。';
    if (text.contains('authentication')) return '主密码不正确或文件已损坏。';
    if (text.contains('password_length')) return '主密码至少需要 12 个字符。';
    if (text.contains('session') || text.contains('locked')) {
      return '密码库已锁定，请重新解锁。';
    }
    return '操作未完成，请检查文件、网络或输入后重试。';
  }

  Future<void> unlock() => action(() async {
    if (!exists && master.text != confirm.text) {
      setState(() => message = '两次主密码不一致');
      return;
    }
    final epoch = generation;
    final result = await core({
      'op': exists ? 'unlock' : 'create',
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
        message = data['pending'] == 0 ? '已保存在本机' : '存在缺失的历史版本，请完成同步';
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

  String _defaultFolderName() =>
      vaultId != null && vaultId!.length >= 16
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
          },
      ];
    }
    return [
      {'id': 'default', 'name': '默认主备份', 'folder': '', 'enabled': true},
    ];
  }

  Future<void> loadAuto() async {
    final settings =
        (await request('sync_settings_get'))['settings']
            as Map<String, dynamic>?;
    if (!mounted) return;
    setState(() {
      syncConfigured = settings != null;
      syncUsername = settings?['username'] as String?;
      autoEnabled = settings?['auto'] == true;
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
    setState(() => syncing = true);
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
          if (savedSettings == null) return;
          username = savedSettings['username'] as String;
          password = savedSettings['password'] as String;
        }
      }
      final targets = targetsOverride ??
          _normalizeTargets(savedSettings?['targets'] ?? syncTargets);
      final enabledTargets =
          targets.where((t) => t['enabled'] == true).toList();
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
      for (final target in enabledTargets) {
        if (current != generation || !foreground) return;
        final syncClient = NutstoreSync(File(path!).parent, request);
        activeSync = syncClient;
        final folder = (target['folder'] as String? ?? '').trim();
        final res = await syncClient.sync(
          username,
          password,
          remoteFolder: folder.isEmpty ? null : folder,
        );
        summaries.add('${target['name']}: $res');
      }
      if (current != generation) return;
      await refresh();
      failures = 0;
      if (mounted) {
        setState(
          () => message = enabledTargets.length == 1
              ? summaries.single
              : '已完成 ${enabledTargets.length} 个备份目标同步',
        );
      }
    } catch (e) {
      failures = (failures + 1).clamp(1, 4);
      if (current == generation && mounted) {
        setState(() {
          message = e is DavFailure && (e.status == 401 || e.status == 403)
              ? '${friendly(e)}。请在「坚果云设置」检查账号和应用密码。'
              : friendly(e);
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

  List<String> _splitTags(String raw) => raw
      .split(RegExp(r'[,，;；]+'))
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();

  bool _isPinned(Map<String, dynamic> revision) {
    final raw = (revision['data']?['tags'] as String?) ?? '';
    return _splitTags(raw).any((t) => t == _pinTag || t == 'pinned');
  }

  List<String> _entryGroups(Map<String, dynamic> revision) {
    final raw = (revision['data']?['tags'] as String?) ?? '';
    return _splitTags(
      raw,
    ).where((t) => t != _pinTag && t != 'pinned').toList();
  }

  Future<void> _togglePin(Map<String, dynamic> revision) async {
    touch();
    final epoch = generation;
    final group = entries.where((r) => r['entry'] == revision['entry']).toList();
    final data = Map<String, dynamic>.from(revision['data'] as Map);
    final tags = _splitTags((data['tags'] as String?) ?? '');
    final currentlyPinned = tags.any((t) => t == _pinTag || t == 'pinned');
    final nextTags = currentlyPinned
        ? tags.where((t) => t != _pinTag && t != 'pinned').toList()
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
    var pinned = initialTags.any((t) => t == _pinTag || t == 'pinned');
    final initialGroupText = initialTags
        .where((t) => t != _pinTag && t != 'pinned')
        .join(', ');

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
    bool reveal = false;
    final result = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) {
          final currentGroups = _splitTags(controllers['tags']!.text);
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
                          onChanged: key == 'tags'
                              ? (_) => setLocal(() {})
                              : null,
                          decoration: InputDecoration(
                            labelText: const {
                              'title': '名称',
                              'username': '用户名',
                              'password': '密码',
                              'url': '网址',
                              'tags': '分类 / 分组（逗号分隔）',
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
                                          controllers['password']!
                                              .text = List.generate(
                                            24,
                                            (_) => chars[rng.nextInt(chars.length)],
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
                          child: Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              for (final preset in _presetGroups)
                                FilterChip(
                                  label: Text(preset),
                                  selected: currentGroups.contains(preset),
                                  visualDensity: VisualDensity.compact,
                                  onSelected: (selected) {
                                    final next = List<String>.from(
                                      currentGroups,
                                    );
                                    if (selected) {
                                      if (!next.contains(preset)) {
                                        next.add(preset);
                                      }
                                    } else {
                                      next.remove(preset);
                                    }
                                    controllers['tags']!.text = next.join(', ');
                                    setLocal(() {});
                                  },
                                ),
                            ],
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
    if (result != null && epoch == generation) {
      final cleanedGroups = _splitTags(
        controllers['tags']!.text,
      ).where((t) => t != _pinTag && t != 'pinned').toList();
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
      c.clear();
      c.dispose();
    }
  }

  Future<String?> passwordPrompt() async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认主密码'),
        content: TextField(
          controller: controller,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          decoration: const InputDecoration(labelText: '主密码'),
          onSubmitted: (_) => Navigator.pop(context, controller.text),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('确认'),
          ),
        ],
      ),
    );
    controller.clear();
    controller.dispose();
    return result;
  }

  Future<void> backup() async {
    final password = await passwordPrompt();
    if (password == null) return;
    await action(() async {
      final data = await request('export', {'password': password});
      final bytes = utf8.encode(jsonEncode(data));
      if (bytes.length > 2 * 1024 * 1024) {
        throw StateError('backup_limit');
      }
      if (Platform.isAndroid) {
        await const MethodChannel('org.wencrypt.files')
            .invokeMethod('saveBackup', {'bytes': Uint8List.fromList(bytes)});
      } else {
        final location = await getSaveLocation(
          suggestedName: 'wencrypt-backup.wenback',
        );
        if (location != null) {
          await XFile.fromData(Uint8List.fromList(bytes)).saveTo(location.path);
        }
      }
      if (mounted) setState(() => message = '备份导出操作已结束');
    });
  }

  Future<void> restore() async {
    final file = await openFile();
    if (file == null) return;
    if (await file.length() > 2 * 1024 * 1024) {
      setState(() => message = 'Alpha 备份文件上限 2 MiB');
      return;
    }
    final data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    if (!mounted) return;
    final password = await passwordPrompt();
    if (password == null) return;
    await action(() async {
      await core({
        'op': 'restore',
        'path': path,
        'password': password,
        'bootstrap': data['bootstrap'],
        'backup': data['backup'],
      });
      await initialize();
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
                  '选择浏览器后，Wencrypt 将打开其密码管理页并实时监听下载目录；你导出 CSV 后将自动导入并安全粉碎临时明文文件。',
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
      await launchBrowserForExport(choice, installed[choice]!);
      if (!mounted) return;

      final watchResult = await watchBrowserExportDialog(
        context,
        browser: choice,
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

        final selected = await selectPasswords(
          context,
          captured.export,
          entries,
          sourceFileName: fileName,
          shredAfterImport: shredAfterImport,
          onShredChanged: (v) => shredAfterImport = v,
        );
        if (selected == null || epoch != generation) return;

        await request('import', {'entries': selected});
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
            () => message = shredded
                ? '已自动导入 ${selected.length} 个账号，并已安全粉碎临时 CSV 文件'
                : '已自动导入 ${selected.length} 个账号（请记得手动删除临时 CSV 文件）',
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
    final selected = await selectPasswords(context, batch, entries);
    if (selected == null || epoch != generation) return;
    await request('import', {'entries': selected});
    await refresh();
    if (mounted && epoch == generation) {
      setState(() => message = '已导入 ${selected.length} 个账号');
    }
  });

  Future<void> sync({bool configure = false}) => action(() async {
    if (token == null || syncing) return;
    final epoch = generation;
    final existing =
        (await request('sync_settings_get'))['settings']
            as Map<String, dynamic>?;
    if (!mounted || epoch != generation) return;
    if (!configure && existing != null) {
      await runSync(
        automatic: false,
        username: existing['username'] as String,
        password: existing['password'] as String,
        targetsOverride: _normalizeTargets(existing['targets']),
      );
      return;
    }
    final user = TextEditingController(text: existing?['username'] as String?);
    final password = TextEditingController(
      text: existing?['password'] as String?,
    );
    var remember = true;
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
                        onChanged: (v) => setLocal(
                          () => targets[i]['enabled'] = v == true,
                        ),
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
                                onPressed: () => setLocal(
                                  () => targets.removeAt(i),
                                ),
                              )
                            : null,
                      ),
                    ),
                  const SizedBox(height: 4),
                  CheckboxListTile(
                    value: remember,
                    contentPadding: EdgeInsets.zero,
                    onChanged: (v) => setLocal(() {
                      remember = v == true;
                      if (!remember) automatic = false;
                    }),
                    title: const Text('在本机加密保存凭据与备份目标'),
                    subtitle: const Text('之后可直接一键同步已勾选的备份目录'),
                  ),
                  CheckboxListTile(
                    value: automatic,
                    contentPadding: EdgeInsets.zero,
                    onChanged: remember
                        ? (v) => setLocal(() => automatic = v == true)
                        : null,
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
              child: Text(remember ? '保存并同步' : '仅同步本次'),
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

    if (remember) {
      await request('sync_settings_set', {
        'settings': {
          'username': username,
          'password': appPassword,
          'auto': automatic,
          'targets': targets,
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
    }
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
    final text = busy
        ? '正在处理…'
        : syncing
        ? '正在同步坚果云…'
        : message;
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
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: fg,
                fontWeight: FontWeight.w600,
              ),
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
              enabled.isEmpty ? Icons.cloud_off_outlined : Icons.cloud_done_outlined,
              size: 18,
              color: enabled.isEmpty ? scheme.error : scheme.primary,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '坚果云已配置（${syncUsername ?? '已保存'}）· $targetSummary${autoEnabled ? ' · 自动同步已开' : ''}',
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

  Widget _buildLockedView(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

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
                      exists ? '解锁密码库' : '创建你的密码库',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: scheme.secondaryContainer.withValues(
                            alpha: 0.65,
                          ),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          '端到端本地加密 · 离线可用',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.onSecondaryContainer,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Alpha 测试版 · 请先使用测试数据\n主密码无法找回，请妥善保存独立加密备份。',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 24),
                    TextField(
                      controller: master,
                      obscureText: !revealMaster,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: InputDecoration(
                        labelText: '主密码（至少 12 个字符）',
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
                            onPressed: () =>
                                setState(() => revealConfirm = !revealConfirm),
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
                    if (!exists) ...[
                      const SizedBox(height: 8),
                      TextButton.icon(
                        onPressed: busy || path == null ? null : restore,
                        icon: const Icon(Icons.restore_page_outlined, size: 18),
                        label: const Text('从加密备份恢复'),
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
    var pinnedCount = 0;
    var ungroupedCount = 0;
    for (final r in baseList) {
      if (_isPinned(r)) pinnedCount++;
      final groups = _entryGroups(r);
      if (groups.isEmpty) {
        ungroupedCount++;
      } else {
        for (final g in groups) {
          groupCounts[g] = (groupCounts[g] ?? 0) + 1;
        }
      }
    }
    final sortedGroups = groupCounts.keys.toList()..sort();

    final filtered = baseList.where((r) {
      final matchesQuery = query.isEmpty ||
          ['title', 'username', 'url', 'tags', 'notes'].any(
            (k) => r['data'][k]
                .toString()
                .toLowerCase()
                .contains(query.toLowerCase()),
          );
      if (!matchesQuery) return false;
      if (selectedGroup == '__all__') return true;
      if (selectedGroup == '__pinned__') return _isPinned(r);
      if (selectedGroup == '__ungrouped__') return _entryGroups(r).isEmpty;
      return _entryGroups(r).contains(selectedGroup);
    }).toList()
      ..sort((a, b) {
        final pa = _isPinned(a) ? 0 : 1;
        final pb = _isPinned(b) ? 0 : 1;
        if (pa != pb) return pa.compareTo(pb);
        return (a['data']['title'] as String? ?? '').toLowerCase().compareTo(
          (b['data']['title'] as String? ?? '').toLowerCase(),
        );
      });

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
                      onChanged: (v) {
                        touch();
                        setState(() => query = v);
                      },
                      decoration: InputDecoration(
                        prefixIcon: const Icon(Icons.search),
                        hintText: '搜索名称、用户名、网址、分组或备注',
                        suffixIcon: query.isNotEmpty
                            ? IconButton(
                                icon: const Icon(Icons.close, size: 18),
                                onPressed: () {
                                  searchController.clear();
                                  setState(() => query = '');
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
                        selectedGroup = '__all__';
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
                        selected: selectedGroup == '__all__',
                        onSelected: (_) =>
                            setState(() => selectedGroup = '__all__'),
                      ),
                    ),
                    if (pinnedCount > 0)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          avatar: const Icon(Icons.push_pin, size: 15),
                          label: Text('已置顶 ($pinnedCount)'),
                          selected: selectedGroup == '__pinned__',
                          onSelected: (_) =>
                              setState(() => selectedGroup = '__pinned__'),
                        ),
                      ),
                    for (final g in sortedGroups)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text('$g (${groupCounts[g]})'),
                          selected: selectedGroup == g,
                          onSelected: (_) => setState(() => selectedGroup = g),
                        ),
                      ),
                    if (ungroupedCount > 0 && sortedGroups.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text('未分组 ($ungroupedCount)'),
                          selected: selectedGroup == '__ungrouped__',
                          onSelected: (_) =>
                              setState(() => selectedGroup = '__ungrouped__'),
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
                  Text(
                    '共 ${entries.length} 个历史修订',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
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
                                        selectedGroup != '__all__'
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
                                        selectedGroup != '__all__'
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
                                        selectedGroup != '__all__'
                                  ? '尝试切换分组或清空搜索条件'
                                  : '你可以手动新增，或直接从 Edge / Chrome 自动导入密码',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                            if (!trash &&
                                query.isEmpty &&
                                selectedGroup == '__all__') ...[
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
                        final username =
                            (data['username'] as String? ?? '').trim();
                        final url = (data['url'] as String? ?? '').trim();
                        final pinned = _isPinned(r);
                        final groups = _entryGroups(r);
                        final hasConflict =
                            entries
                                .where((v) => v['entry'] == r['entry'])
                                .length >
                            1;
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
                            onTap: busy ? null : () => edit(r),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 12,
                              ),
                              child: Row(
                                children: [
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
                                            for (final g in groups.take(3)) ...[
                                              const SizedBox(width: 6),
                                              Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 7,
                                                      vertical: 2,
                                                    ),
                                                decoration: BoxDecoration(
                                                  color: scheme
                                                      .surfaceContainerHighest,
                                                  borderRadius:
                                                      BorderRadius.circular(6),
                                                ),
                                                child: Text(
                                                  g,
                                                  style: theme
                                                      .textTheme
                                                      .labelSmall,
                                                ),
                                              ),
                                            ],
                                          ],
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
                                    icon: const Icon(Icons.more_horiz),
                                    onSelected: (v) {
                                      if (v == 'edit') {
                                        edit(r);
                                      } else if (v == 'history') {
                                        history(r);
                                      } else {
                                        copy(
                                          data[v] as String? ?? '',
                                          label: v == 'username' ? '用户名' : '密码',
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
                                    ],
                                  ),
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
                    child: Text(
                      syncConfigured ? '坚果云设置（已配置）' : '坚果云设置',
                    ),
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
