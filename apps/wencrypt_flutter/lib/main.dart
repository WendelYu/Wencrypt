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
import 'design/wencrypt_theme.dart';
import 'design/wencrypt_widgets.dart';
import 'entry_image.dart';
import 'probe_page.dart' show WencryptProbeApp;
import 'sync.dart';
import 'sync_history.dart';
import 'vault_invite.dart';
import 'workspace.dart';

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

  ThemeData _buildTheme(Brightness brightness) => wencryptTheme(brightness);

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
    this.preview,
  });

  final ThemeMode themeMode;
  final VoidCallback? onCycleTheme;

  /// Seeds the vault screen with fictitious data so design previews and golden
  /// screenshots can render every state without touching a real vault, the
  /// native core, or stored credentials. Never set by the running app.
  final VaultPreview? preview;

  @override
  State<VaultPage> createState() => _VaultPageState();
}

/// Design-preview seed for [VaultPage]. Test-only: nothing in the shipped app
/// constructs this, and it never reaches the encryption or sync layers.
class VaultPreview {
  const VaultPreview({
    this.unlocked = false,
    this.trash = false,
    this.showSyncHistory = false,
    this.entries = const [],
    this.syncTargets = const [],
    this.syncConfigured = false,
    this.syncUsername,
    this.biometricEnabled = false,
    this.message = '本地加密 · 离线可用',
  });

  final bool unlocked;
  final bool trash;
  final bool showSyncHistory;
  final List<Map<String, dynamic>> entries;
  final List<Map<String, dynamic>> syncTargets;
  final bool syncConfigured;
  final String? syncUsername;
  final bool biometricEnabled;
  final String message;
}

enum EntryFilter { all, pinned, ungrouped }

enum FirstRunStep { welcome, create, join }

class _VaultPageState extends State<VaultPage> with WidgetsBindingObserver {
  static const _pinTag = '置顶';
  static const _presetGroups = ['工作', '财务', '社交', '开发', '购物', '生活'];
  static const invites = MethodChannel('org.wencrypt.invite');
  static const entryImage = MethodChannel('org.wencrypt.entry-image');
  static const device = MethodChannel('org.wencrypt.device/vault');

  final master = TextEditingController();
  final confirm = TextEditingController();
  final searchController = TextEditingController();
  final searchFocus = FocusNode();
  bool showSyncHistory = false;
  int syncHistoryRevision = 0;
  String? runningSyncRecord;
  VaultInvite? pendingInvite;
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
  bool _browserImportActive = false;
  NutstoreSync? activeSync;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    searchController.addListener(_scheduleSearch);
    if (widget.preview case final VaultPreview preview) {
      token = preview.unlocked ? 'preview' : null;
      path = '/preview/wencrypt.db';
      exists = true;
      trash = preview.trash;
      showSyncHistory = preview.showSyncHistory;
      entries = preview.entries;
      syncTargets = preview.syncTargets;
      syncUsername = preview.syncUsername;
      syncConfigured = preview.syncConfigured;
      biometricEnabled = preview.biometricEnabled;
      message = preview.message;
      return;
    }
    device.setMethodCallHandler((call) async {
      if (call.method == 'systemLocked') lock();
    });
    invites.setMethodCallHandler((_) async => _readNativeInvite());
    unawaited(initialize().then((_) => _readNativeInvite()));
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
    invites.setMethodCallHandler(null);
    master.dispose();
    confirm.dispose();
    _searchUpdate?.cancel();
    searchController.dispose();
    searchFocus.dispose();
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
    showSyncHistory = false;
    runningSyncRecord = null;
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
        'cloud_password_changed' => '云端主密码已有更新，请从菜单选择「采用云端主密码」。',
        'strong_etag_required' => '本机主密码已更新，云端未提供可用于安全更新的文件版本标识。',
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
    if (text.contains('invitation_vault_mismatch')) return '邀请链接和云端密码库不匹配。';
    if (text.contains('vault_identity_mismatch')) return '所选目录属于另一个密码库。';
    if (text.contains('sync_credentials_required')) {
      return '请先保存同步使用的坚果云账号和 WebDAV 应用密码。';
    }
    if (text.contains('password_unchanged')) return '请输入不同于当前主密码的新密码。';
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
    if (widget.preview case final VaultPreview preview) {
      return _previewResponse(preview, op);
    }
    final current = token;
    final epoch = generation;
    if (current == null) throw StateError('locked');
    final result = await core({'op': op, 'session': current, ...extra});
    if (epoch != generation) throw StateError('locked');
    return result;
  }

  /// Canned core replies for [VaultPreview] so design previews and golden
  /// screenshots can open every dialog without a vault, native core or stored
  /// credentials. The shipped app never sets a preview, so this is unreachable
  /// in production builds.
  Map<String, dynamic> _previewResponse(VaultPreview preview, String op) {
    switch (op) {
      case 'list':
        return {'vault': 'preview', 'entries': preview.entries};
      case 'sync_settings_get':
        return {
          'settings': preview.syncConfigured
              ? {
                  'username': preview.syncUsername ?? 'demo@example.com',
                  'password': 'preview-only',
                  'targets': preview.syncTargets,
                  'auto': false,
                }
              : null,
        };
      default:
        return const {'ok': true};
    }
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

  String _targetFolder(Map<String, dynamic> target) {
    final folder = (target['folder'] as String? ?? '').trim();
    return folder.isEmpty
        ? _defaultFolderName()
        : folder.replaceAll(RegExp(r'^/+|/+$'), '');
  }

  String _historyIssue(Map<String, dynamic> issue) {
    final phase = issue['stage'] as String;
    final reason = issue['reason'] as String;
    final http = issue['http_status'] as int?;
    final description = friendly(DavFailure(phase, reason, http));
    return description.contains(phase)
        ? description
        : '$description · $phase${http == null ? '' : ' · HTTP $http'}';
  }

  Future<void> _updateSyncRecord(
    String? id,
    SyncReport report,
    String outcome,
    int epoch, {
    DavFailure? issue,
  }) async {
    if (id == null || epoch != generation || !mounted) return;
    try {
      await request('sync_history_update', {
        'id': id,
        'uploaded': report.uploaded,
        'downloaded': report.downloaded,
        'outcome': outcome,
        if (issue != null) 'issue': issue.diagnostic,
      });
      if (mounted && epoch == generation) setState(() => syncHistoryRevision++);
    } catch (_) {
      // A history write must never cancel committed vault transfers.
    }
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
        String? recordId;
        try {
          final started = await request('sync_history_start', {
            'folder': _targetFolder(target),
            'automatic': automatic,
          });
          recordId = started['id'] as String;
        } catch (_) {
          // Synchronization is still available if the journal cannot be written.
        }
        if (!mounted || current != generation) return;
        setState(() {
          runningSyncRecord = recordId;
          syncHistoryRevision++;
        });
        var progress = const SyncReport(0, 0);
        try {
          final res = await syncClient.sync(
            username,
            password,
            remoteFolder: folder.isEmpty ? null : folder,
            existingOnly: target['existingOnly'] == true,
            onProgress: (report) async {
              progress = report;
              if (mounted && current == generation) {
                setState(
                  () => message = '${target['name']} · ${report.message}',
                );
              }
              await _updateSyncRecord(recordId, report, 'running', current);
            },
          );
          await _updateSyncRecord(
            recordId,
            res,
            res.complete ? 'success' : 'partial',
            current,
          );
          summaries.add('${target['name']} · ${res.message}');
          complete &= res.complete;
        } catch (error) {
          final issue = error is DavFailure
              ? error
              : const DavFailure('sync', 'validation_failed');
          await _updateSyncRecord(
            recordId,
            progress,
            issue.reason == 'cancelled' ? 'interrupted' : 'failed',
            current,
            issue: issue,
          );
          rethrow;
        } finally {
          if (current == generation && mounted) {
            setState(() {
              runningSyncRecord = null;
              syncHistoryRevision++;
            });
          }
        }
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
    String? titleError;
    String? passwordError;
    final route = DialogRoute<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) {
          final c = WColors.of(context);
          Widget gap([double size = 12]) => SizedBox(height: size);
          InputDecoration decoration(
            IconData? icon, {
            String? hint,
            Widget? suffix,
            String? error,
            bool multiline = false,
          }) => InputDecoration(
            hintText: hint,
            isDense: true,
            prefixIcon: icon == null ? null : Icon(icon, size: 16),
            prefixIconConstraints: icon == null
                ? null
                : const BoxConstraints(minWidth: 36, minHeight: 36),
            suffixIcon: suffix,
            suffixIconConstraints: const BoxConstraints(minWidth: 36),
            errorText: error,
          );
          Widget input(
            String key,
            String label,
            IconData icon, {
            String? hint,
            int maxLines = 1,
            Widget? suffix,
            String? error,
            bool iconInField = true,
          }) => Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: WLabeledField(
              label: label,
              child: TextField(
                controller: controllers[key],
                obscureText: key == 'password' && !reveal,
                autocorrect: false,
                enableSuggestions: key != 'notes',
                minLines: maxLines > 1 ? maxLines : null,
                maxLines: maxLines,
                style: TextStyle(fontSize: 12.8, color: c.textPrimary),
                decoration: decoration(
                  iconInField ? icon : null,
                  hint: hint,
                  suffix: suffix,
                  error: error,
                  multiline: maxLines > 1,
                ),
              ),
            ),
          );
          return WDialog(
            width: 540,
            icon: revision == null
                ? Icons.add_rounded
                : group.length > 1
                ? Icons.warning_amber_rounded
                : Icons.edit_outlined,
            title: revision == null
                ? '新增账号'
                : group.length > 1
                ? '解决冲突（${group.length} 个版本）'
                : '编辑账号',
            subtitle: revision == null
                ? '填写账号信息，保存后会加密写入本机密码库。'
                : '修改后会生成新的历史版本，旧版本仍可在「历史版本」中查看。',
            footer: WDialogFooter(
              leading: revision == null
                  ? null
                  : TextButton.icon(
                      onPressed: () =>
                          Navigator.pop(context, trash ? 'restore' : 'delete'),
                      icon: Icon(
                        trash
                            ? Icons.restore_rounded
                            : Icons.delete_outline_rounded,
                        size: 15,
                      ),
                      label: Text(trash ? '恢复' : '移入回收站'),
                      style: TextButton.styleFrom(
                        foregroundColor: trash ? null : c.danger,
                      ),
                    ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () {
                    final title = controllers['title']!.text.trim();
                    final password = controllers['password']!.text;
                    setLocal(() {
                      titleError = title.isEmpty ? '请填写名称' : null;
                      passwordError = password.isEmpty ? '请填写或生成密码' : null;
                    });
                    if (titleError != null || passwordError != null) return;
                    Navigator.pop(context, 'save');
                  },
                  child: Text(revision == null ? '保存账号' : '保存修改'),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (group.length > 1) ...[
                  WNote(
                    tone: WTone.warning,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '检测到并发修改，请选择一个版本作为基础后保存（历史版本仍会保留）：',
                          style: TextStyle(
                            fontSize: 11.8,
                            fontWeight: FontWeight.w600,
                            height: 1.4,
                          ),
                        ),
                        const SizedBox(height: 4),
                        for (final r in group)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(WRadius.xs),
                              onTap: () {
                                for (final key in controllers.keys) {
                                  controllers[key]!.text =
                                      r['data'][key] as String;
                                }
                                setLocal(() {});
                              },
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                  vertical: 4,
                                ),
                                child: Text(
                                  '${r['data']['title']} · ${r['deleted'] == true ? '删除版本' : r['data']['username']} · ${r['id'].toString().substring(0, 8)}',
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    color: c.textSecondary,
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  gap(16),
                ],
                input(
                  'title',
                  '名称（必填）',
                  Icons.label_outline_rounded,
                  hint: '例如 GitHub、招商银行',
                  error: titleError,
                ),
                input(
                  'username',
                  '用户名',
                  Icons.person_outline_rounded,
                  hint: '登录账号或邮箱',
                ),
                input(
                  'password',
                  '密码（必填）',
                  Icons.key_outlined,
                  hint: '输入或生成密码',
                  error: passwordError,
                  suffix: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: '生成 24 位随机密码',
                        iconSize: 17,
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.auto_fix_high_rounded),
                        onPressed: () {
                          const chars =
                              'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!@#%&*+-_';
                          final rng = Random.secure();
                          controllers['password']!.text = List.generate(
                            24,
                            (_) => chars[rng.nextInt(chars.length)],
                          ).join();
                          setLocal(() {});
                        },
                      ),
                      IconButton(
                        tooltip: reveal ? '隐藏密码' : '显示密码',
                        iconSize: 17,
                        visualDensity: VisualDensity.compact,
                        icon: Icon(
                          reveal
                              ? Icons.visibility_off_outlined
                              : Icons.visibility_outlined,
                        ),
                        onPressed: () => setLocal(() => reveal = !reveal),
                      ),
                    ],
                  ),
                ),
                input('url', '网址', Icons.link_rounded, hint: 'https://'),
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: WLabeledField(
                    label: '分组',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        TextField(
                          controller: tagController,
                          style: TextStyle(
                            fontSize: 12.8,
                            color: c.textPrimary,
                          ),
                          decoration: decoration(
                            Icons.folder_outlined,
                            hint: '可输入新分组，多个用逗号分隔',
                          ),
                        ),
                        const SizedBox(height: 8),
                        ValueListenableBuilder<String>(
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
                                    labelStyle: const TextStyle(fontSize: 11),
                                    materialTapTargetSize:
                                        MaterialTapTargetSize.shrinkWrap,
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
                      ],
                    ),
                  ),
                ),
                gap(4),
                input(
                  'notes',
                  '备注',
                  Icons.notes_rounded,
                  hint: '可选，例如安全问题、恢复码',
                  maxLines: 3,
                  iconInField: false,
                ),
                Container(
                  padding: const EdgeInsets.fromLTRB(10, 4, 6, 4),
                  decoration: BoxDecoration(
                    color: c.surfaceMuted,
                    borderRadius: BorderRadius.circular(WRadius.sm),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        pinned
                            ? Icons.push_pin_rounded
                            : Icons.push_pin_outlined,
                        size: 15,
                        color: c.textSecondary,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '置顶此账号',
                              style: TextStyle(
                                fontSize: 12.2,
                                fontWeight: FontWeight.w600,
                                color: c.textPrimary,
                              ),
                            ),
                            Text(
                              '置顶账号会始终显示在列表最前方',
                              style: TextStyle(
                                fontSize: 10.8,
                                color: c.textTertiary,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Switch.adaptive(
                        value: pinned,
                        onChanged: (v) => setLocal(() => pinned = v),
                      ),
                    ],
                  ),
                ),
              ],
            ),
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
        final c = WColors.of(context);
        void confirm() => Navigator.pop(context, (
          password: controller.text,
          fingerprint: false,
        ));
        return WDialog(
          width: 404,
          icon: Icons.lock_outline_rounded,
          title: allowFingerprint ? '授权导出加密备份' : '确认主密码',
          subtitle: allowFingerprint
              ? '将生成加密备份文件，需要再次验证主密码。'
              : '请输入主密码以继续本次操作。',
          scrollable: false,
          bodyPadding: const EdgeInsets.fromLTRB(20, 8, 20, 18),
          footer: WDialogFooter(
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              if (allowFingerprint)
                OutlinedButton.icon(
                  onPressed: () => Navigator.pop(context, (
                    password: null,
                    fingerprint: true,
                  )),
                  icon: const Icon(Icons.fingerprint_rounded, size: 16),
                  label: const Text('使用指纹'),
                ),
              FilledButton(onPressed: confirm, child: const Text('确认')),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              WLabeledField(
                label: '主密码',
                child: TextField(
                  controller: controller,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  autofocus: true,
                  style: TextStyle(fontSize: 12.8, color: c.textPrimary),
                  decoration: const InputDecoration(
                    hintText: '输入主密码',
                    isDense: true,
                    prefixIcon: Icon(Icons.key_outlined, size: 16),
                    prefixIconConstraints: BoxConstraints(
                      minWidth: 36,
                      minHeight: 36,
                    ),
                  ),
                  onSubmitted: (_) => confirm(),
                ),
              ),
              const SizedBox(height: 12),
              WNote(
                tone: WTone.neutral,
                icon: Icons.shield_outlined,
                child: const Text(
                  '主密码仅用于本次验证，不会写入日志，也不会离开本机。',
                  style: TextStyle(fontSize: 11.3, height: 1.4),
                ),
              ),
            ],
          ),
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

  Future<void> _readNativeInvite() async {
    if (!mounted ||
        path == null ||
        (!Platform.isMacOS && !Platform.isAndroid)) {
      return;
    }
    try {
      final raw = await invites.invokeMethod<String>('takePending');
      if (mounted && raw != null) _useInvite(raw);
    } on MissingPluginException {
      // The clipboard entry remains available in the Flutter UI.
    }
  }

  void _useInvite(String raw) {
    final invitation = VaultInvite.parse(raw);
    setState(() {
      if (exists || token != null) {
        message = '邀请链接用于尚未建立密码库的设备。';
      } else if (invitation == null) {
        message = '邀请链接无效，请向发送方核对。';
      } else {
        pendingInvite = invitation;
        firstRunStep = FirstRunStep.join;
        message = '';
      }
    });
  }

  Future<void> _pasteInvite() async {
    final invitation = await Clipboard.getData(Clipboard.kTextPlain);
    if (mounted) _useInvite(invitation?.text ?? '');
  }

  Future<Map<String, dynamic>?> _pickSyncTarget(String title) async {
    if (syncTargets.isEmpty) return null;
    if (syncTargets.length == 1) return syncTargets.single;
    return showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) {
        final c = WColors.of(context);
        return WDialog(
          width: 420,
          icon: Icons.folder_outlined,
          title: title,
          bodyPadding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          footer: WDialogFooter(
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final target in syncTargets)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: WSurface(
                    radius: WRadius.sm,
                    border: false,
                    color: c.surfaceMuted.withValues(alpha: 0.6),
                    padding: EdgeInsets.zero,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(WRadius.sm),
                      onTap: () => Navigator.pop(context, target),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(10, 9, 10, 9),
                        child: Row(
                          children: [
                            Icon(
                              Icons.folder_outlined,
                              size: 16,
                              color: c.textSecondary,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '${target['name']}',
                                    style: TextStyle(
                                      fontSize: 12.3,
                                      fontWeight: FontWeight.w600,
                                      color: c.textPrimary,
                                    ),
                                  ),
                                  const SizedBox(height: 1),
                                  WMono(
                                    _targetFolder(target),
                                    size: 10.8,
                                    color: c.textTertiary,
                                  ),
                                ],
                              ),
                            ),
                            Icon(
                              Icons.chevron_right_rounded,
                              size: 16,
                              color: c.textTertiary,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _copyVaultInvite() async {
    final epoch = generation;
    final id = vaultId;
    if (id == null || !syncConfigured) return;
    final target = await _pickSyncTarget('选择邀请使用的同步目录');
    if (!mounted || epoch != generation || target == null) return;
    final invitation = VaultInvite(folder: _targetFolder(target), vault: id);
    await copy(invitation.toUri().toString(), label: '邀请链接');
  }

  Future<void> _changeMasterPassword({bool adopt = false}) async {
    if (token == null || busy || syncing) return;
    touch();
    final epoch = generation;
    final target = adopt ? await _pickSyncTarget('选择云端密码库目录') : null;
    if (!mounted || epoch != generation || (adopt && target == null)) return;
    final old = TextEditingController();
    final password = TextEditingController();
    final confirmation = TextEditingController();
    final form = GlobalKey<FormState>();
    final dialog = DialogRoute<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(adopt ? '采用云端主密码' : '修改主密码'),
        content: SizedBox(
          width: 400,
          child: Form(
            key: form,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    adopt
                        ? '输入云端最新的主密码。${_targetFolder(target!)}'
                        : '修改后，本机指纹需要重新绑定。以前导出的备份仍使用导出时的主密码。',
                  ),
                  const SizedBox(height: 14),
                  if (!adopt) ...[
                    TextFormField(
                      controller: old,
                      obscureText: true,
                      enableSuggestions: false,
                      autocorrect: false,
                      decoration: const InputDecoration(labelText: '当前主密码'),
                      validator: (value) =>
                          value?.isNotEmpty == true ? null : '请输入当前主密码',
                    ),
                    const SizedBox(height: 10),
                  ],
                  TextFormField(
                    controller: password,
                    obscureText: true,
                    enableSuggestions: false,
                    autocorrect: false,
                    decoration: InputDecoration(
                      labelText: adopt ? '云端主密码' : '新主密码',
                    ),
                    validator: (value) =>
                        (value ?? '').runes.length >= (adopt ? 1 : 12)
                        ? null
                        : adopt
                        ? '请输入云端主密码'
                        : '请至少输入 12 个字符',
                  ),
                  if (!adopt) ...[
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: confirmation,
                      obscureText: true,
                      enableSuggestions: false,
                      autocorrect: false,
                      decoration: const InputDecoration(labelText: '确认新主密码'),
                      validator: (value) =>
                          value == password.text ? null : '两次输入不一致',
                    ),
                  ],
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
            child: Text(adopt ? '验证并采用' : '修改'),
          ),
        ],
      ),
    );
    final accepted = await Navigator.of(context).push(dialog);
    await dialog.completed;
    final currentPassword = old.text;
    final newPassword = password.text;
    old.dispose();
    password.dispose();
    confirmation.dispose();
    if (accepted != true || !mounted || epoch != generation) return;
    await action(() async {
      String? cloudBootstrap;
      if (adopt) {
        final settings =
            (await request('sync_settings_get'))['settings']
                as Map<String, dynamic>?;
        if (!_hasSyncCredentials(settings)) {
          throw StateError('sync_credentials_required');
        }
        final transport = NutstoreSync(File(path!).parent, request);
        activeSync = transport;
        try {
          cloudBootstrap = await transport.readExistingBootstrap(
            settings!['username'] as String,
            settings['password'] as String,
            _targetFolder(target!),
          );
        } finally {
          if (identical(activeSync, transport)) activeSync = null;
        }
        if (!mounted || epoch != generation) return;
      }
      final result = await request(
        adopt ? 'adopt_cloud_password' : 'change_master_password',
        {
          'old_password': currentPassword,
          'new_password': newPassword,
          'bootstrap': ?cloudBootstrap,
        },
      );
      if (!mounted || epoch != generation) return;
      if (result['changed'] != true) {
        setState(() => message = '本机已经使用该主密码。');
        return;
      }
      setState(() {
        biometricEnabled = false;
        binding = null;
        message = '本机主密码已更新。';
      });
      if (syncConfigured) await runSync(automatic: false);
    });
  }

  Future<void> joinCloudVault() async {
    if (exists || busy || path == null) return;
    final epoch = generation;
    final invitation = pendingInvite;
    final fields = {
      '坚果云账号': TextEditingController(),
      'WebDAV 应用密码': TextEditingController(),
      '同步目录名': TextEditingController(text: invitation?.folder),
      '已有库的主密码': TextEditingController(),
    };
    final form = GlobalKey<FormState>();
    var automatic = true;
    final dialog = DialogRoute<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) {
          final c = WColors.of(context);
          Widget field(
            String label,
            IconData icon, {
            bool obscure = false,
            String? hint,
          }) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: WLabeledField(
                label: label,
                child: TextFormField(
                  controller: fields[label],
                  obscureText: obscure,
                  autocorrect: false,
                  enableSuggestions: !obscure,
                  style: TextStyle(fontSize: 12.8, color: c.textPrimary),
                  decoration: InputDecoration(
                    hintText: hint,
                    isDense: true,
                    prefixIcon: Icon(icon, size: 16),
                    prefixIconConstraints: const BoxConstraints(
                      minWidth: 36,
                      minHeight: 36,
                    ),
                  ),
                  validator: (value) => (value == null || value.trim().isEmpty)
                      ? '请填写$label'
                      : null,
                ),
              ),
            );
          }

          return WDialog(
            width: 470,
            icon: Icons.cloud_download_outlined,
            title: '加入已有密码库',
            subtitle: invitation == null
                ? '输入坚果云 WebDAV 凭据与备份目录，使用原密码库的主密码完成加入。'
                : '邀请指向目录 /${invitation.folder}/，输入凭据与原库主密码即可加入。',
            scrollable: false,
            bodyPadding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
            footer: WDialogFooter(
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () {
                    if (form.currentState!.validate()) {
                      Navigator.pop(context, true);
                    }
                  },
                  child: const Text('加入密码库'),
                ),
              ],
            ),
            child: Form(
              key: form,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  field(
                    '坚果云账号',
                    Icons.alternate_email_rounded,
                    hint: 'name@example.com',
                  ),
                  field(
                    'WebDAV 应用密码',
                    Icons.key_outlined,
                    obscure: true,
                    hint: '坚果云「安全选项」中生成',
                  ),
                  field('同步目录名', Icons.folder_outlined, hint: '坚果云中的备份目录'),
                  field(
                    '已有库的主密码',
                    Icons.lock_outline_rounded,
                    obscure: true,
                    hint: '原密码库的主密码',
                  ),
                  const SizedBox(height: 2),
                  Container(
                    padding: const EdgeInsets.fromLTRB(10, 4, 6, 4),
                    decoration: BoxDecoration(
                      color: c.surfaceMuted,
                      borderRadius: BorderRadius.circular(WRadius.sm),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.schedule_rounded,
                          size: 15,
                          color: c.textSecondary,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '自动同步',
                                style: TextStyle(
                                  fontSize: 12.2,
                                  fontWeight: FontWeight.w600,
                                  color: c.textPrimary,
                                ),
                              ),
                              Text(
                                '仅在前台解锁时运行',
                                style: TextStyle(
                                  fontSize: 10.8,
                                  color: c.textTertiary,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Switch.adaptive(
                          value: automatic,
                          onChanged: (v) => setLocal(() => automatic = v),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
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
        if (invitation != null) 'expected_vault': invitation.vault,
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
      pendingInvite = null;
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
        builder: (context) {
          final c = WColors.of(context);
          final theme = Theme.of(context);
          String stamp(Map<String, dynamic> r) =>
              DateTime.fromMillisecondsSinceEpoch(
                (r['updated_at'] as int) * 1000,
              ).toLocal().toString().substring(0, 19);
          return WDialog(
            width: 470,
            icon: Icons.history_rounded,
            title: '历史版本',
            subtitle: '每次保存都会留下记录，可随时复制旧密码。',
            bodyPadding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            footer: WDialogFooter(
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('关闭'),
                ),
              ],
            ),
            child: revisions.isEmpty
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(child: Text('暂无历史版本')),
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final r in revisions)
                        WSurface(
                          radius: WRadius.sm,
                          border: false,
                          color: Colors.transparent,
                          padding: const EdgeInsets.fromLTRB(8, 7, 4, 7),
                          child: Row(
                            children: [
                              Container(
                                width: 26,
                                height: 26,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: r['deleted'] == true
                                      ? c.dangerSoft
                                      : c.surfaceMuted,
                                  borderRadius: BorderRadius.circular(
                                    WRadius.xs,
                                  ),
                                ),
                                child: Icon(
                                  r['deleted'] == true
                                      ? Icons.delete_outline_rounded
                                      : Icons.history_rounded,
                                  size: 14,
                                  color: r['deleted'] == true
                                      ? c.danger
                                      : c.textSecondary,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '${r['data']['title']} · ${r['deleted'] == true ? '已删除' : '已保存'}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: theme.textTheme.titleSmall
                                          ?.copyWith(fontSize: 12.3),
                                    ),
                                    const SizedBox(height: 1),
                                    WMono(
                                      stamp(r),
                                      size: 10.8,
                                      color: c.textTertiary,
                                    ),
                                  ],
                                ),
                              ),
                              WIconButton(
                                icon: Icons.copy_rounded,
                                tooltip: '复制此版本密码',
                                size: 26,
                                iconSize: 14,
                                onPressed: () => copy(
                                  r['data']['password'] as String,
                                  label: '历史密码',
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
          );
        },
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
    if (busy || _browserImportActive || path == null) return;
    _browserImportActive = true;
    SavedBrowserWatchFolders? savedFolders;
    try {
      final installed = await installedBrowsers();
      if (!mounted) return;

      if (installed.isEmpty) {
        await importCsv();
        return;
      }

      final choice = await showDialog<String>(
        context: context,
        builder: (ctx) {
          final c = WColors.of(ctx);
          Widget tile(String name) {
            final icon = name == 'Edge'
                ? Icons.language_rounded
                : name == 'Chrome'
                ? Icons.public_rounded
                : Icons.local_fire_department_outlined;
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Material(
                color: c.surfaceMuted,
                borderRadius: BorderRadius.circular(WRadius.sm),
                child: InkWell(
                  borderRadius: BorderRadius.circular(WRadius.sm),
                  hoverColor: c.hover,
                  onTap: () => Navigator.pop(ctx, name),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 9,
                    ),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(WRadius.sm),
                      border: Border.all(color: c.border),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 26,
                          height: 26,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: c.surface,
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: c.border),
                          ),
                          child: Icon(icon, size: 14, color: c.textSecondary),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '从 $name 导出并自动捕获',
                                style: TextStyle(
                                  fontSize: 12.3,
                                  fontWeight: FontWeight.w600,
                                  color: c.textPrimary,
                                ),
                              ),
                              const SizedBox(height: 1),
                              Text(
                                browserSettingsUrl(name),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontFamily: wMonoFamily,
                                  fontSize: 10.4,
                                  color: c.textTertiary,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Icon(
                          Icons.chevron_right_rounded,
                          size: 16,
                          color: c.textTertiary,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          }

          return WDialog(
            width: 452,
            icon: Icons.download_outlined,
            title: '从浏览器自动导入密码',
            subtitle:
                '选择浏览器后，Wencrypt 会监听下载目录并打开密码管理页；'
                '导出 CSV 后可预览、合并账号并删除临时文件。',
            scrollable: false,
            bodyPadding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
            footer: WDialogFooter(
              leading: TextButton.icon(
                onPressed: () => Navigator.pop(ctx, '__manual__'),
                icon: const Icon(Icons.file_open_outlined, size: 15),
                label: const Text('手动选择 CSV'),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('取消'),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final name in installed.keys) tile(name),
                if (Platform.isMacOS) ...[
                  const SizedBox(height: 2),
                  WNote(
                    tone: WTone.neutral,
                    icon: Icons.info_outline_rounded,
                    child: const Text(
                      'macOS 首次打开 Chrome 或 Edge 设置页时可能要求授权。',
                      style: TextStyle(fontSize: 11.3, height: 1.4),
                    ),
                  ),
                ],
              ],
            ),
          );
        },
      );
      if (!mounted || choice == null) return;
      if (choice == '__manual__') {
        await importCsv();
        return;
      }

      final watchDirs = await defaultWatchDirectories();
      savedFolders = SavedBrowserWatchFolders(File(path!).parent);
      final rememberedDirs = await savedFolders.load();
      if (!mounted) return;

      final watchResult = await watchBrowserExportDialog(
        context,
        browser: choice,
        app: installed[choice]!,
        initialDirs: watchDirs,
        rememberedDirs: rememberedDirs,
        savedFolders: savedFolders,
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
    } finally {
      try {
        await savedFolders?.close();
      } finally {
        _browserImportActive = false;
      }
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
        builder: (context, setLocal) {
          final c = WColors.of(context);
          return WDialog(
            width: 520,
            icon: Icons.cloud_outlined,
            title: '坚果云设置与多备份管理',
            subtitle: '使用坚果云生成的 WebDAV 应用密码；可配置多个同步备份目录并自由勾选是否同步。',
            bodyPadding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
            footer: WDialogFooter(
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
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const WSectionLabel(label: '账号凭据'),
                if (editCredentials) ...[
                  WLabeledField(
                    label: '坚果云账号',
                    child: TextField(
                      controller: user,
                      style: TextStyle(fontSize: 12.8, color: c.textPrimary),
                      decoration: const InputDecoration(
                        hintText: 'name@example.com',
                        isDense: true,
                        prefixIcon: Icon(
                          Icons.alternate_email_rounded,
                          size: 16,
                        ),
                        prefixIconConstraints: BoxConstraints(
                          minWidth: 36,
                          minHeight: 36,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  WLabeledField(
                    label: 'WebDAV 应用密码',
                    helper: '凭据会加密保存在本机，下次同步自动使用。',
                    child: TextField(
                      controller: password,
                      obscureText: true,
                      autocorrect: false,
                      enableSuggestions: false,
                      style: TextStyle(fontSize: 12.8, color: c.textPrimary),
                      decoration: const InputDecoration(
                        hintText: '坚果云「安全选项」中生成',
                        isDense: true,
                        prefixIcon: Icon(Icons.key_outlined, size: 16),
                        prefixIconConstraints: BoxConstraints(
                          minWidth: 36,
                          minHeight: 36,
                        ),
                      ),
                    ),
                  ),
                ] else
                  Container(
                    padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
                    decoration: BoxDecoration(
                      color: c.surfaceMuted,
                      borderRadius: BorderRadius.circular(WRadius.sm),
                      border: Border.all(color: c.border),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.lock_outline_rounded,
                          size: 15,
                          color: c.textTertiary,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                user.text,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12.3,
                                  fontWeight: FontWeight.w600,
                                  color: c.textPrimary,
                                ),
                              ),
                              const SizedBox(height: 1),
                              Text(
                                '凭据已加密保存在本机',
                                style: TextStyle(
                                  fontSize: 10.8,
                                  color: c.textTertiary,
                                ),
                              ),
                            ],
                          ),
                        ),
                        TextButton(
                          onPressed: () =>
                              setLocal(() => editCredentials = true),
                          child: const Text('更换'),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    const Expanded(child: WSectionLabel(label: '同步备份目标')),
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
                          builder: (ctx) => WDialog(
                            width: 420,
                            icon: Icons.create_new_folder_outlined,
                            title: '新增坚果云备份目录',
                            subtitle: '每个目录对应坚果云中的一个文件夹，可分别勾选是否需要同步。',
                            scrollable: false,
                            bodyPadding: const EdgeInsets.fromLTRB(
                              20,
                              10,
                              20,
                              16,
                            ),
                            footer: WDialogFooter(
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
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                WLabeledField(
                                  label: '备份名称',
                                  child: TextField(
                                    controller: nameCtrl,
                                    decoration: const InputDecoration(
                                      hintText: '如：日常备份 / 异地存档',
                                      isDense: true,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 10),
                                WLabeledField(
                                  label: '坚果云目录名',
                                  helper: '不超过 32 个字符，不能包含 /',
                                  child: TextField(
                                    controller: folderCtrl,
                                    style: TextStyle(
                                      fontSize: 12.8,
                                      fontFamily: wMonoFamily,
                                      color: c.textPrimary,
                                    ),
                                    decoration: const InputDecoration(
                                      isDense: true,
                                    ),
                                  ),
                                ),
                              ],
                            ),
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
                      icon: const Icon(Icons.add_rounded, size: 16),
                      label: const Text('添加目录'),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                for (var i = 0; i < targets.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(6, 4, 4, 4),
                      decoration: BoxDecoration(
                        color: targets[i]['enabled'] == true
                            ? c.brandSoft.withValues(alpha: 0.55)
                            : c.surfaceMuted,
                        borderRadius: BorderRadius.circular(WRadius.sm),
                        border: Border.all(
                          color: targets[i]['enabled'] == true
                              ? c.brand.withValues(alpha: 0.32)
                              : c.border,
                        ),
                      ),
                      child: Row(
                        children: [
                          Checkbox(
                            value: targets[i]['enabled'] == true,
                            visualDensity: VisualDensity.compact,
                            onChanged: (v) => setLocal(
                              () => targets[i]['enabled'] = v == true,
                            ),
                          ),
                          const SizedBox(width: 2),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Flexible(
                                      child: Text(
                                        targets[i]['name'] as String,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 12.2,
                                          fontWeight: FontWeight.w600,
                                          color: c.textPrimary,
                                        ),
                                      ),
                                    ),
                                    if ((targets[i]['folder'] as String)
                                        .isEmpty)
                                      Padding(
                                        padding: const EdgeInsets.only(left: 6),
                                        child: WStatusPill(
                                          label: '主目录',
                                          compact: true,
                                        ),
                                      ),
                                  ],
                                ),
                                const SizedBox(height: 1),
                                Text(
                                  (targets[i]['folder'] as String).isEmpty
                                      ? '目录：/${_defaultFolderName()}/（默认主目录）'
                                      : '目录：/${targets[i]['folder']}/',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontFamily: wMonoFamily,
                                    fontSize: 10.4,
                                    color: c.textTertiary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          WIconButton(
                            icon: Icons.copy_rounded,
                            tooltip: '复制目录名',
                            size: 26,
                            iconSize: 14,
                            onPressed: () =>
                                copy(_targetFolder(targets[i]), label: '目录名'),
                          ),
                          if (targets.length > 1)
                            WIconButton(
                              icon: Icons.delete_outline_rounded,
                              tooltip: '删除此备份目标',
                              size: 26,
                              iconSize: 14,
                              onPressed: () =>
                                  setLocal(() => targets.removeAt(i)),
                            ),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(height: 6),
                Container(
                  padding: const EdgeInsets.fromLTRB(10, 4, 6, 4),
                  decoration: BoxDecoration(
                    color: c.surfaceMuted,
                    borderRadius: BorderRadius.circular(WRadius.sm),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.schedule_rounded,
                        size: 15,
                        color: c.textSecondary,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '自动同步',
                              style: TextStyle(
                                fontSize: 12.2,
                                fontWeight: FontWeight.w600,
                                color: c.textPrimary,
                              ),
                            ),
                            Text(
                              '仅在前台解锁时运行',
                              style: TextStyle(
                                fontSize: 10.8,
                                color: c.textTertiary,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Switch.adaptive(
                        value: automatic,
                        onChanged: (v) => setLocal(() => automatic = v),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
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

  String _hostLabel(String url) {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return '';
    final uri = Uri.tryParse(
      trimmed.contains('://') ? trimmed : 'https://$trimmed',
    );
    return uri != null && uri.host.isNotEmpty ? uri.host : trimmed;
  }

  Widget _buildStatusPill(BuildContext context) {
    final text = busy && !syncing ? '正在处理…' : message;
    if (text.isEmpty) return const SizedBox.shrink();
    final warning =
        text.contains('缺失') ||
        text.contains('不正确') ||
        text.contains('失败') ||
        text.contains('未完成') ||
        text.contains('超出') ||
        text.contains('上限') ||
        text.contains('未启用');
    final ready =
        text.contains('本地加密') ||
        text.contains('已保存') ||
        text.contains('已同步') ||
        text.contains('已置顶');
    return WStatusPill(
      label: text,
      busy: busy || syncing,
      tone: warning
          ? WTone.danger
          : ready
          ? WTone.info
          : WTone.neutral,
      icon: warning
          ? Icons.error_outline_rounded
          : ready
          ? Icons.shield_outlined
          : Icons.info_outline_rounded,
    );
  }

  Widget _copyFolderAction() {
    if (syncTargets.isEmpty) return const SizedBox.shrink();
    if (syncTargets.length == 1) {
      return WIconButton(
        icon: Icons.copy_outlined,
        tooltip: '复制目录名',
        size: 24,
        iconSize: 14,
        onPressed: () => copy(_targetFolder(syncTargets.single), label: '目录名'),
      );
    }
    return WCommandMenu(
      width: 216,
      sections: [
        WMenuSection(
          label: '同步目录',
          entries: [
            for (final target in syncTargets)
              WMenuEntry(
                label: _targetFolder(target),
                icon: Icons.folder_outlined,
                onTap: () => copy(_targetFolder(target), label: '目录名'),
              ),
          ],
        ),
      ],
      triggerBuilder: (context, controller, open) => WIconButton(
        icon: Icons.copy_outlined,
        tooltip: '复制目录名',
        size: 24,
        iconSize: 14,
        active: open,
        onPressed: () => open ? controller.close() : controller.open(),
      ),
    );
  }

  Widget _buildSyncBanner(BuildContext context) {
    if (!syncConfigured) return const SizedBox.shrink();
    final c = WColors.of(context);
    final enabled = syncTargets.where((target) => target['enabled'] == true);
    final folders = enabled.map(_targetFolder).join('   ·   ');
    final pending = initialSyncPending;
    final status = pending
        ? '首次同步尚未完成'
        : folders.isEmpty
        ? '未启用任何同步目录'
        : folders;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 10, 18, 0),
      child: WSurface(
        radius: WRadius.md,
        padding: const EdgeInsets.fromLTRB(10, 5, 6, 5),
        color: pending ? c.warningSoft : c.surfaceMuted.withValues(alpha: 0.5),
        border: !pending,
        child: Row(
          children: [
            Icon(
              pending ? Icons.cloud_off_outlined : Icons.cloud_done_outlined,
              size: 15,
              color: pending ? c.warning : c.textSecondary,
            ),
            const SizedBox(width: 8),
            Text(
              '坚果云',
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: c.textSecondary,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: WMono(
                status,
                size: 11.5,
                color: pending ? c.warning : c.textTertiary,
              ),
            ),
            const SizedBox(width: 6),
            TextButton(
              onPressed: busy || syncing ? null : () => sync(),
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 24),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                textStyle: Theme.of(context).textTheme.labelLarge
                    ?.copyWith(fontSize: 11.5),
              ),
              child: syncing
                  ? const SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 1.6),
                    )
                  : const Text('立即同步'),
            ),
            const SizedBox(width: 2),
            _copyFolderAction(),
            WIconButton(
              icon: Icons.tune_rounded,
              tooltip: '坚果云与多备份设置',
              size: 24,
              iconSize: 15,
              onPressed: busy || syncing ? null : () => sync(configure: true),
            ),
          ],
        ),
      ),
    );
  }

  /// Shared shell for the unlock / first-run screens.
  Widget _authShell({required Widget child}) {
    final c = WColors.of(context);
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            c.brand.withValues(alpha: c.isDark ? 0.10 : 0.035),
            c.canvas,
            c.canvas,
          ],
          stops: const [0, 0.30, 1],
        ),
      ),
      child: SizedBox.expand(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 396),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const WBrandMark(size: 26, radius: 7),
                      const SizedBox(width: 9),
                      Text(
                        'Wencrypt',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.2,
                          color: c.textPrimary,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 22),
                  WSurface(
                    shadow: true,
                    radius: WRadius.xl,
                    padding: const EdgeInsets.fromLTRB(26, 26, 26, 22),
                    child: child,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    '主密码不会离开这台设备',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: c.textTertiary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _authOption({
    required IconData icon,
    required String title,
    required String description,
    required VoidCallback? onTap,
    bool primary = false,
  }) {
    final c = WColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: primary ? c.brandSoft : Colors.transparent,
        borderRadius: BorderRadius.circular(WRadius.md),
        child: InkWell(
          borderRadius: BorderRadius.circular(WRadius.md),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(WRadius.md),
              border: Border.all(
                color: primary ? c.brand.withValues(alpha: 0.28) : c.border,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 17,
                  color: primary ? c.brand : c.textSecondary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        style: Theme.of(context).textTheme.titleSmall
                            ?.copyWith(fontSize: 12.5, color: c.textPrimary),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        description,
                        style: Theme.of(context).textTheme.labelSmall
                            ?.copyWith(color: c.textSecondary, height: 1.35),
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.chevron_right_rounded,
                  size: 16,
                  color: onTap == null ? c.border : c.textTertiary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _lockField({
    required TextEditingController controller,
    required String hint,
    required IconData icon,
    required bool explore,
    required bool reveal,
    required ValueChanged<bool> onToggleReveal,
    ValueChanged<String>? onSubmitted,
  }) {
    final c = WColors.of(context);
    return SizedBox(
      height: 38,
      child: TextField(
        controller: controller,
        obscureText: explore ? !reveal : false,
        autocorrect: false,
        enableSuggestions: false,
        onSubmitted: onSubmitted,
        style: TextStyle(
          fontSize: 13,
          color: c.textPrimary,
          letterSpacing: explore && !reveal ? 1.2 : 0,
        ),
        decoration: InputDecoration(
          hintText: hint,
          fillColor: c.surfaceMuted,
          prefixIcon: Icon(icon, size: 16, color: c.textTertiary),
          prefixIconConstraints: const BoxConstraints(
            minWidth: 34,
            minHeight: 34,
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 10,
            vertical: 8,
          ),
          suffixIcon: SizedBox(
            width: 32,
            child: IconButton(
              tooltip: reveal ? '隐藏密码' : '显示密码',
              icon: Icon(
                reveal
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
                size: 16,
              ),
              onPressed: () => onToggleReveal(!reveal),
            ),
          ),
        ),
      ),
    );
  }

  Widget _firstRunChoices() {
    if (firstRunStep == FirstRunStep.welcome) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _authOption(
            icon: Icons.add_circle_outline_rounded,
            title: '创建新库',
            description: '在这台设备上设置主密码，开始使用 Wencrypt。',
            onTap: busy
                ? null
                : () => setState(() => firstRunStep = FirstRunStep.create),
            primary: true,
          ),
          _authOption(
            icon: Icons.devices_outlined,
            title: '加入已有库',
            description: '已在其他设备使用 Wencrypt，沿用原来的密码库与主密码。',
            onTap: busy
                ? null
                : () => setState(() => firstRunStep = FirstRunStep.join),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (pendingInvite case final invitation?)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: WNote(
              tone: WTone.info,
              icon: Icons.link_rounded,
              child: Row(
                children: [
                  Expanded(child: Text('收到邀请：${invitation.folder}')),
                  WIconButton(
                    icon: Icons.close_rounded,
                    tooltip: '移除邀请',
                    size: 22,
                    iconSize: 14,
                    onPressed: () => setState(() => pendingInvite = null),
                  ),
                ],
              ),
            ),
          ),
        _authOption(
          icon: Icons.cloud_download_outlined,
          title: '从坚果云加入',
          description: '使用坚果云 WebDAV 上已有的加密备份。',
          onTap: busy || path == null ? null : joinCloudVault,
          primary: true,
        ),
        _authOption(
          icon: Icons.restore_page_outlined,
          title: '从加密备份恢复',
          description: '选择此前导出的加密备份文件。',
          onTap: busy || path == null ? null : restore,
        ),
        _authOption(
          icon: Icons.link_rounded,
          title: '粘贴邀请链接',
          description: '使用其他设备复制来的邀请链接加入。',
          onTap: busy ? null : _pasteInvite,
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
    final c = WColors.of(context);
    final showPassword = exists || firstRunStep == FirstRunStep.create;
    final title = exists
        ? '解锁密码库'
        : switch (firstRunStep) {
            FirstRunStep.welcome => '欢迎使用 Wencrypt',
            FirstRunStep.create => '创建密码库',
            FirstRunStep.join => '加入已有密码库',
          };
    final subtitle = exists
        ? '使用已有密码库的主密码解锁。'
        : switch (firstRunStep) {
            FirstRunStep.welcome => '本地加密、离线可用。所有密码只保存在这台设备上。',
            FirstRunStep.create => '请设置独立的长口令。Wencrypt 无法找回主密码，请妥善保存。',
            FirstRunStep.join => '沿用其他设备上的密码库与主密码。',
          };

    return _authShell(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            textAlign: TextAlign.center,
            style: theme.textTheme.displaySmall?.copyWith(
              fontSize: 21,
              letterSpacing: -0.3,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: c.textSecondary,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 20),
          if (!showPassword) _firstRunChoices(),
          if (showPassword) ...[
            _lockField(
              controller: master,
              hint: exists ? '输入主密码' : '主密码（至少 12 个字符）',
              icon: Icons.lock_outline_rounded,
              explore: true,
              reveal: revealMaster,
              onToggleReveal: (value) => setState(() => revealMaster = value),
              onSubmitted: (_) => busy ? null : unlock(),
            ),
            if (!exists) ...[
              const SizedBox(height: 9),
              _lockField(
                controller: confirm,
                hint: '再次输入主密码',
                icon: Icons.verified_outlined,
                explore: true,
                reveal: revealConfirm,
                onToggleReveal: (value) =>
                    setState(() => revealConfirm = value),
                onSubmitted: (_) => busy ? null : unlock(),
              ),
            ],
            const SizedBox(height: 16),
            SizedBox(
              height: 38,
              child: FilledButton(
                onPressed: busy || path == null ? null : unlock,
                child: Text(
                  busy
                      ? '正在处理…'
                      : exists
                      ? '解锁'
                      : '创建密码库',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            if (exists && biometricEnabled) ...[
              const SizedBox(height: 8),
              SizedBox(
                height: 38,
                child: OutlinedButton.icon(
                  onPressed: busy ? null : biometricUnlock,
                  icon: const Icon(Icons.fingerprint_rounded, size: 17),
                  label: const Text('使用指纹解锁'),
                ),
              ),
            ],
          ],
          if (!exists && firstRunStep != FirstRunStep.welcome) ...[
            const SizedBox(height: 4),
            Center(
              child: TextButton(
                onPressed: busy ? null : _backToWelcome,
                child: const Text('返回'),
              ),
            ),
          ],
          if (message.isNotEmpty) ...[
            const SizedBox(height: 14),
            Center(child: _buildStatusPill(context)),
          ],
        ],
      ),
    );
  }

  Widget _buildUnlockedView(BuildContext context, {required bool desktop}) {
    final baseList = entries.where((r) => r['deleted'] == trash).toList();

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

    final c = WColors.of(context);
    final filters = <Object>[
      EntryFilter.all,
      if (pinnedCount > 0) EntryFilter.pinned,
      for (final g in sortedGroups) g.toLowerCase(),
      if (ungroupedCount > 0 && sortedGroups.isNotEmpty) EntryFilter.ungrouped,
    ];
    final filterLabels = <String>[
      '全部 ${_countLabel(baseList.length)}',
      if (pinnedCount > 0) '已置顶 · $pinnedCount',
      for (final g in sortedGroups) '${groupNames[g] ?? g} · ${groupCounts[g]}',
      if (ungroupedCount > 0 && sortedGroups.isNotEmpty)
        '未分组 · $ungroupedCount',
    ];
    final selectedFilterIndex = filters.indexWhere((f) {
      if (f == selectedGroup) return true;
      return f is String && selectedGroup is String && f == selectedGroup;
    });

    Widget chipRow() => Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 0),
      child: WFilterChips(
        labels: filterLabels,
        selectedIndex: selectedFilterIndex < 0 ? 0 : selectedFilterIndex,
        onSelected: (index) => _selectGroup(filters[index]),
      ),
    );

    Widget searchRow() => Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
      child: Row(
        children: [
          Expanded(
            child: WSearchField(
              controller: searchController,
              focusNode: searchFocus,
              hintText: '搜索名称、用户名、网址、分组或备注',
              trailing: query.isEmpty
                  ? null
                  : SizedBox(
                      width: 26,
                      child: IconButton(
                        icon: const Icon(Icons.close_rounded, size: 14),
                        tooltip: '清空搜索',
                        onPressed: () {
                          searchController.clear();
                          setState(() {
                            query = '';
                            deleteSelection?.clear();
                          });
                        },
                      ),
                    ),
            ),
          ),
        ],
      ),
    );

    final list = filtered.isEmpty
        ? WEmptyState(
            icon: trash
                ? Icons.delete_sweep_outlined
                : query.isNotEmpty || selectedGroup != EntryFilter.all
                ? Icons.search_off_rounded
                : Icons.shield_outlined,
            title: trash
                ? '回收站为空'
                : query.isNotEmpty || selectedGroup != EntryFilter.all
                ? '当前筛选条件下没有账号'
                : '密码库还没有任何账号',
            message: trash
                ? '移入回收站的账号会显示在这里'
                : query.isNotEmpty || selectedGroup != EntryFilter.all
                ? '尝试切换分组或清空搜索条件'
                : '你可以手动新增，或直接从 Edge / Chrome 自动导入密码',
            action: !trash && query.isEmpty && selectedGroup == EntryFilter.all
                ? Wrap(
                    spacing: 8,
                    alignment: WrapAlignment.center,
                    children: [
                      if (Platform.isMacOS || Platform.isWindows)
                        OutlinedButton.icon(
                          onPressed: busy ? null : importFromBrowser,
                          icon: const Icon(Icons.download_outlined, size: 16),
                          label: const Text('从 Edge / Chrome 导入'),
                        ),
                      FilledButton.icon(
                        onPressed: busy ? null : () => edit(null),
                        icon: const Icon(Icons.add_rounded, size: 16),
                        label: const Text('新增第一个账号'),
                      ),
                    ],
                  )
                : null,
          )
        : Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: WSurface(
              radius: WRadius.lg,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(WRadius.lg),
                child: Scrollbar(
                  child: ListView.builder(
                    padding: EdgeInsets.only(bottom: desktop ? 12 : 84),
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
                      final host = _hostLabel(url);
                      final meta = [
                        if (username.isNotEmpty) username,
                        if (host.isNotEmpty) host,
                        if (username.isEmpty && host.isEmpty) '未填写用户名',
                      ].join('   ·   ');
                      void toggleSelection() {
                        setState(() {
                          if (selection?.contains(revisionId) == true) {
                            selection?.remove(revisionId);
                          } else {
                            selection?.add(revisionId);
                          }
                        });
                      }

                      return WAccountRow(
                        title: title.isEmpty ? '未命名账号' : title,
                        meta: meta,
                        group: groups.isEmpty ? null : groups.first,
                        pinned: pinned,
                        selected: selection?.contains(revisionId) == true,
                        selectionMode: selection != null,
                        showCheckbox: selection != null,
                        showPin: !trash && selection == null,
                        avatar: hasConflict ? _conflictAvatar(context) : null,
                        onOpen: busy ? null : () => edit(r),
                        onToggleSelect: selection == null || hasConflict || busy
                            ? null
                            : toggleSelection,
                        onTogglePin: busy ? null : () => _togglePin(r),
                        onCopyPassword: () => copy(
                          data['password'] as String? ?? '',
                          label: '密码',
                        ),
                        onCopyUsername: username.isEmpty
                            ? null
                            : () => copy(username, label: '用户名'),
                        onEdit: busy ? null : () => edit(r),
                        onPurge: trash && !hasConflict
                            ? () => _setDeleted(
                                [revisionId],
                                deleted: true,
                                discard: true,
                              )
                            : null,
                        menuSections: [
                          WMenuSection(
                            entries: [
                              WMenuEntry(
                                label: '编辑详情',
                                icon: Icons.edit_outlined,
                                onTap: () => edit(r),
                              ),
                              WMenuEntry(
                                label: '复制用户名',
                                icon: Icons.person_outline_rounded,
                                enabled: username.isNotEmpty,
                                onTap: () => copy(username, label: '用户名'),
                              ),
                              WMenuEntry(
                                label: '复制密码',
                                icon: Icons.key_outlined,
                                onTap: () => copy(
                                  data['password'] as String? ?? '',
                                  label: '密码',
                                ),
                              ),
                              WMenuEntry(
                                label: '历史版本',
                                icon: Icons.history_rounded,
                                onTap: () => history(r),
                              ),
                              if (!trash &&
                                  !hasConflict &&
                                  (Platform.isAndroid ||
                                      Platform.isMacOS ||
                                      Platform.isWindows))
                                WMenuEntry(
                                  label: '导出账号图片',
                                  icon: Icons.image_outlined,
                                  onTap: () => _exportEntryImage(data),
                                ),
                            ],
                          ),
                          if (!hasConflict)
                            WMenuSection(
                              entries: [
                                WMenuEntry(
                                  label: trash ? '恢复账号' : '移入回收站',
                                  icon: trash
                                      ? Icons.restore_rounded
                                      : Icons.delete_outline_rounded,
                                  danger: !trash,
                                  onTap: () => _setDeleted([
                                    revisionId,
                                  ], deleted: !trash),
                                ),
                              ],
                            ),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
          );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!desktop) searchRow(),
        if (!desktop || trash) ...[const SizedBox(height: 8), chipRow()],
        if (desktop) const SizedBox(height: 8),
        _buildSyncBanner(context),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 8, 14, 6),
          child: Row(
            children: [
              Expanded(child: _buildStatusPill(context)),
              if (deleteSelection == null && visibleHeads.isNotEmpty)
                TextButton.icon(
                  onPressed: busy
                      ? null
                      : () => setState(() => deleteSelection = {}),
                  icon: const Icon(Icons.checklist_rounded, size: 15),
                  label: const Text('多选'),
                  style: TextButton.styleFrom(
                    foregroundColor: c.textSecondary,
                    textStyle: Theme.of(context).textTheme.labelLarge
                        ?.copyWith(fontSize: 12),
                  ),
                ),
            ],
          ),
        ),
        if (deleteSelection case final selection?)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: WSurface(
              padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
              radius: WRadius.sm,
              color: c.brandSoft,
              border: false,
              child: Row(
                children: [
                  Icon(Icons.checklist_rounded, size: 15, color: c.brand),
                  const SizedBox(width: 7),
                  Text(
                    '已选择 ${selection.length} 项',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: c.brand,
                    ),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: busy || visibleHeads.isEmpty
                        ? null
                        : () => setState(() => selection.addAll(visibleHeads)),
                    child: const Text('全选当前列表'),
                  ),
                  TextButton(
                    onPressed: busy
                        ? null
                        : () => setState(() => deleteSelection = null),
                    child: const Text('退出多选'),
                  ),
                  SizedBox(
                    height: 28,
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: c.danger,
                        minimumSize: const Size(0, 28),
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        textStyle: Theme.of(context).textTheme.labelLarge
                            ?.copyWith(fontSize: 12),
                      ),
                      onPressed: busy || selection.isEmpty
                          ? null
                          : () => _setDeleted(
                              selection.toList(),
                              deleted: true,
                              discard: trash,
                            ),
                      child: Text(
                        '${trash ? '从回收站清除' : '移入回收站'} (${selection.length})',
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        Expanded(child: list),
      ],
    );
  }

  String _countLabel(int count) => count > 999 ? '999+' : '$count';

  Widget _conflictAvatar(BuildContext context) {
    final c = WColors.of(context);
    return Container(
      width: 30,
      height: 30,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: c.warningSoft,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.warning.withValues(alpha: 0.3)),
      ),
      child: Icon(Icons.warning_amber_rounded, size: 16, color: c.warning),
    );
  }

  void _selectWorkspace(int index) {
    touch();
    setState(() {
      showSyncHistory = index == 2;
      trash = index == 1;
      selectedGroup = EntryFilter.all;
      deleteSelection = null;
    });
  }

  Future<void> _openCommands() async {
    if (token == null) return;
    final epoch = generation;
    final canSync = !busy && !syncing;
    final command = await showWorkspaceCommands(context, [
      WorkspaceCommand('搜索账号', Icons.search, _focusVaultSearch),
      if (!busy)
        WorkspaceCommand('新增账号', Icons.add, () {
          _selectWorkspace(0);
          edit(null);
        }),
      if (canSync) WorkspaceCommand('立即同步', Icons.sync, sync),
      WorkspaceCommand('查看同步记录', Icons.history, () => _selectWorkspace(2)),
      if (canSync)
        WorkspaceCommand(
          '坚果云设置',
          Icons.settings_outlined,
          () => sync(configure: true),
        ),
      for (final target in syncTargets)
        WorkspaceCommand(
          '复制目录名 · ${_targetFolder(target)}',
          Icons.copy_outlined,
          () => copy(_targetFolder(target), label: '目录名'),
        ),
      if (syncConfigured)
        WorkspaceCommand('复制加入邀请链接', Icons.link, _copyVaultInvite),
      if (canSync)
        WorkspaceCommand(
          '修改主密码',
          Icons.password_outlined,
          _changeMasterPassword,
        ),
      if (!busy) WorkspaceCommand('导出加密备份', Icons.download_outlined, backup),
      WorkspaceCommand('锁定密码库', Icons.lock_outline, lock),
    ]);
    if (mounted && generation == epoch) command?.run();
  }

  void _focusVaultSearch() {
    if (showSyncHistory) _selectWorkspace(0);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && token != null) searchFocus.requestFocus();
    });
  }

  Widget _sidebarItem({
    required String label,
    required bool selected,
    required VoidCallback onTap,
    IconData? icon,
    int? count,
    bool indented = false,
  }) {
    final c = WColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: Material(
        color: selected ? c.brandSoft : Colors.transparent,
        borderRadius: BorderRadius.circular(WRadius.xs),
        child: InkWell(
          borderRadius: BorderRadius.circular(WRadius.xs),
          hoverColor: c.hover,
          onTap: onTap,
          child: Container(
            height: 27,
            padding: EdgeInsets.only(left: indented ? 27 : 8, right: 8),
            child: Row(
              children: [
                if (icon != null) ...[
                  Icon(
                    icon,
                    size: 15,
                    color: selected ? c.brand : c.textTertiary,
                  ),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.3,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                      color: selected ? c.brand : c.textSecondary,
                    ),
                  ),
                ),
                if (count != null) ...[
                  const SizedBox(width: 6),
                  Text(
                    _countLabel(count),
                    style: TextStyle(
                      fontSize: 10.8,
                      fontWeight: FontWeight.w500,
                      color: selected ? c.brand : c.textTertiary,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _workspaceSidebar() {
    final c = WColors.of(context);
    final filters = [
      if (entries.any((row) => row['deleted'] != true && _isPinned(row)))
        (EntryFilter.pinned as Object, '已置顶', Icons.push_pin_outlined),
      for (final group in _groupOptions())
        (group.toLowerCase() as Object, group, Icons.folder_outlined),
    ];
    final vaultCount = entries.where((row) => row['deleted'] != true).length;
    final trashCount = entries.where((row) => row['deleted'] == true).length;
    final narrow = MediaQuery.sizeOf(context).width < 1000;
    return Container(
      width: narrow ? 188 : 214,
      decoration: BoxDecoration(
        color: c.sidebar,
        border: Border(right: BorderSide(color: c.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 11, 8, 10),
            child: Row(
              children: [
                const WBrandMark(size: 22, radius: 6),
                const SizedBox(width: 8),
                Text(
                  'Wencrypt',
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.2,
                    color: c.textPrimary,
                  ),
                ),
                const Spacer(),
                WIconButton(
                  icon: Icons.bolt_outlined,
                  tooltip: '命令  ${Platform.isMacOS ? '⌘K' : 'Ctrl+K'}',
                  size: 24,
                  iconSize: 15,
                  onPressed: token == null ? null : _openCommands,
                ),
              ],
            ),
          ),
          _sidebarItem(
            label: '密码库',
            icon: Icons.key_outlined,
            selected:
                !showSyncHistory && !trash && selectedGroup == EntryFilter.all,
            count: vaultCount,
            onTap: () => _selectWorkspace(0),
          ),
          _sidebarItem(
            label: '回收站',
            icon: Icons.delete_outline_rounded,
            selected: !showSyncHistory && trash,
            count: trashCount,
            onTap: () => _selectWorkspace(1),
          ),
          _sidebarItem(
            label: '同步记录',
            icon: Icons.history_rounded,
            selected: showSyncHistory,
            onTap: () => _selectWorkspace(2),
          ),
          if (filters.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 5),
              child: Text(
                '分组',
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.4,
                  color: c.textTertiary,
                ),
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.only(bottom: 8),
                children: [
                  for (final (filter, label, _) in filters)
                    _sidebarItem(
                      label: label,
                      indented: true,
                      selected:
                          !showSyncHistory && !trash && selectedGroup == filter,
                      onTap: () {
                        _selectWorkspace(0);
                        _selectGroup(filter);
                      },
                    ),
                  if (entries.any(
                    (row) =>
                        row['deleted'] != true && _entryGroups(row).isEmpty,
                  ))
                    _sidebarItem(
                      label: '未分组',
                      indented: true,
                      selected:
                          !showSyncHistory &&
                          !trash &&
                          selectedGroup == EntryFilter.ungrouped,
                      onTap: () {
                        _selectWorkspace(0);
                        _selectGroup(EntryFilter.ungrouped);
                      },
                    ),
                ],
              ),
            ),
          ] else
            const Spacer(),
          Divider(height: 1, color: c.border),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 8, 9),
            child: Row(
              children: [
                Icon(Icons.shield_outlined, size: 13, color: c.textTertiary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '本地加密 · 离线可用',
                    style: TextStyle(fontSize: 10.8, color: c.textTertiary),
                  ),
                ),
                WIconButton(
                  icon: Icons.lock_outline_rounded,
                  tooltip: '锁定密码库',
                  size: 22,
                  iconSize: 14,
                  onPressed: lock,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _toggleFocusLock() {
    setState(() {
      lockOnFocusLoss = !lockOnFocusLoss;
      message = lockOnFocusLoss ? '已开启：切换窗口时自动锁定' : '已开启：切换窗口时保持解锁（5 分钟无操作后锁定）';
    });
  }

  void _openProbe() {
    lock();
    Navigator.push(
      context,
      MaterialPageRoute<void>(builder: (_) => const WencryptProbeApp()),
    );
  }

  WCommandMenu _settingsMenu() => WCommandMenu(
    width: 248,
    sections: [
      WMenuSection(
        label: '外观',
        entries: [
          WMenuEntry(
            label: '外观',
            icon: Icons.contrast_rounded,
            trailing: switch (widget.themeMode) {
              ThemeMode.system => '跟随系统',
              ThemeMode.light => '浅色',
              ThemeMode.dark => '深色',
            },
            onTap: widget.onCycleTheme,
          ),
        ],
      ),
      if (token != null)
        WMenuSection(
          label: '安全',
          entries: [
            WMenuEntry(
              label: '修改主密码',
              icon: Icons.password_rounded,
              enabled: !busy && !syncing,
              onTap: _changeMasterPassword,
            ),
            if (syncConfigured)
              WMenuEntry(
                label: '采用云端主密码',
                icon: Icons.cloud_sync_outlined,
                enabled: !busy && !syncing,
                onTap: () => _changeMasterPassword(adopt: true),
              ),
          ],
        ),
      WMenuSection(
        label: '系统工具',
        entries: [
          WMenuEntry(
            label: '设备诊断',
            icon: Icons.monitor_heart_outlined,
            enabled: token != null,
            onTap: token == null ? null : _openProbe,
          ),
        ],
      ),
    ],
    triggerBuilder: (context, controller, open) => WIconButton(
      icon: Icons.settings_outlined,
      tooltip: '设置',
      active: open,
      onPressed: () => open ? controller.close() : controller.open(),
    ),
  );

  WCommandMenu _moreMenu() => WCommandMenu(
    width: 264,
    sections: [
      WMenuSection(
        label: '安全设置',
        entries: [
          if (Platform.isMacOS || Platform.isWindows || Platform.isLinux)
            WMenuEntry(
              label: '切换窗口时保持解锁',
              icon: Icons.lock_clock_rounded,
              checked: !lockOnFocusLoss,
              onTap: _toggleFocusLock,
            ),
          if (token != null && (Platform.isMacOS || Platform.isAndroid))
            WMenuEntry(
              label: biometricEnabled ? '重新绑定指纹解锁' : '启用指纹解锁',
              icon: Icons.fingerprint_rounded,
              onTap: enableBiometric,
            ),
          if (token != null && biometricEnabled)
            WMenuEntry(
              label: '关闭指纹解锁',
              icon: Icons.fingerprint_rounded,
              danger: true,
              onTap: disableBiometric,
            ),
        ],
      ),
      if (token != null)
        WMenuSection(
          label: '云同步',
          entries: [
            WMenuEntry(
              label: syncConfigured ? '坚果云设置（已配置）' : '坚果云设置',
              icon: Icons.cloud_outlined,
              enabled: !busy && !syncing,
              onTap: () => sync(configure: true),
            ),
            WMenuEntry(
              label: '同步记录',
              icon: Icons.history_rounded,
              onTap: () => _selectWorkspace(2),
            ),
            if (syncConfigured)
              WMenuEntry(
                label: '复制加入邀请链接',
                icon: Icons.link_rounded,
                onTap: _copyVaultInvite,
              ),
            if (syncConfigured)
              WMenuEntry(
                label: '清除坚果云凭据',
                icon: Icons.link_off_rounded,
                danger: true,
                enabled: !busy && !syncing,
                onTap: forgetSyncSettings,
              ),
          ],
        ),
      WMenuSection(
        label: '数据管理',
        entries: [
          if (exists && (Platform.isMacOS || Platform.isWindows))
            WMenuEntry(
              label: '从 Edge / Chrome 自动导入',
              icon: Icons.download_outlined,
              enabled: !busy,
              onTap: importFromBrowser,
            ),
          if (exists)
            WMenuEntry(
              label: '手动导入浏览器 CSV',
              icon: Icons.file_open_outlined,
              enabled: !busy,
              onTap: importCsv,
            ),
        ],
      ),
      WMenuSection(
        label: '系统工具',
        entries: [
          WMenuEntry(
            label: '设备诊断',
            icon: Icons.monitor_heart_outlined,
            onTap: token == null ? null : _openProbe,
            enabled: token != null,
          ),
        ],
      ),
    ],
    triggerBuilder: (context, controller, open) => WIconButton(
      icon: Icons.more_horiz_rounded,
      tooltip: '更多',
      active: open,
      onPressed: () => open ? controller.close() : controller.open(),
    ),
  );

  Widget _headerActions(BuildContext context) {
    final c = WColors.of(context);
    Widget gap() => const SizedBox(width: 2);
    Widget separator() => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Container(width: 1, height: 18, color: c.border),
    );
    final canImport =
        exists && (Platform.isMacOS || Platform.isWindows || Platform.isLinux);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!trash && !showSyncHistory) ...[
          SizedBox(
            height: 30,
            child: FilledButton.icon(
              onPressed: busy ? null : () => edit(null),
              icon: const Icon(Icons.add_rounded, size: 16),
              label: const Text('新增账号'),
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, 30),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                textStyle: Theme.of(context).textTheme.labelLarge
                    ?.copyWith(fontSize: 12),
              ),
            ),
          ),
          const SizedBox(width: 8),
        ],
        WCommandMenu(
          width: 226,
          sections: [
            WMenuSection(
              label: '导入密码',
              entries: [
                if (Platform.isMacOS || Platform.isWindows)
                  WMenuEntry(
                    label: '从 Edge / Chrome 自动导入',
                    icon: Icons.download_outlined,
                    enabled: canImport && !busy,
                    onTap: importFromBrowser,
                  ),
                WMenuEntry(
                  label: '手动导入浏览器 CSV',
                  icon: Icons.file_open_outlined,
                  enabled: canImport && !busy,
                  onTap: importCsv,
                ),
              ],
            ),
          ],
          triggerBuilder: (context, controller, open) => WIconButton(
            icon: Icons.download_outlined,
            tooltip: '导入密码',
            active: open,
            onPressed: () => open ? controller.close() : controller.open(),
          ),
        ),
        gap(),
        WIconButton(
          icon: Icons.sync_rounded,
          tooltip: syncing ? '正在同步…' : '立即同步',
          busy: syncing,
          onPressed: busy || syncing ? null : sync,
        ),
        gap(),
        WIconButton(
          icon: Icons.save_alt_rounded,
          tooltip: '导出加密备份',
          onPressed: busy ? null : backup,
        ),
        separator(),
        WIconButton(
          icon: Icons.lock_outline_rounded,
          tooltip: '锁定密码库',
          onPressed: lock,
        ),
        _settingsMenu(),
        _moreMenu(),
      ],
    );
  }

  Widget _pageHeader(BuildContext context, String pageLabel) {
    final c = WColors.of(context);
    final count = showSyncHistory
        ? null
        : entries.where((row) => row['deleted'] == trash).length;
    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      color: c.surface,
      child: Row(
        children: [
          Text(
            pageLabel,
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.1,
              color: c.textPrimary,
            ),
          ),
          if (count != null) ...[
            const SizedBox(width: 8),
            WStatusPill(label: _countLabel(count), compact: true),
          ],
          const SizedBox(width: 16),
          if (!showSyncHistory)
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 330),
                  child: WSearchField(
                    controller: searchController,
                    focusNode: searchFocus,
                    hintText: '搜索名称、用户名、网址、分组或备注',
                    trailing: query.isEmpty
                        ? null
                        : SizedBox(
                            width: 26,
                            child: IconButton(
                              icon: const Icon(Icons.close_rounded, size: 14),
                              tooltip: '清空搜索',
                              onPressed: () {
                                searchController.clear();
                                setState(() {
                                  query = '';
                                  deleteSelection?.clear();
                                });
                              },
                            ),
                          ),
                  ),
                ),
              ),
            )
          else
            const Spacer(),
          const SizedBox(width: 12),
          _headerActions(context),
        ],
      ),
    );
  }

  Widget _historyPage() => SyncHistoryView(
    key: ValueKey(generation),
    load: (before) => request('sync_history_list', {'before': before}),
    revision: syncHistoryRevision,
    runningId: runningSyncRecord,
    copyDirectory: (folder) => copy(folder, label: '目录名'),
    describeIssue: _historyIssue,
  );

  @override
  Widget build(BuildContext context) {
    final unlocked = token != null;
    final desktop =
        unlocked &&
        !Platform.isAndroid &&
        MediaQuery.sizeOf(context).width >= 860;
    final c = WColors.of(context);
    final mac = Platform.isMacOS;
    final pageLabel = !unlocked
        ? 'Wencrypt'
        : showSyncHistory
        ? '同步记录'
        : trash
        ? '回收站'
        : '密码库';
    final page = !unlocked
        ? _buildLockedView(context)
        : showSyncHistory
        ? _historyPage()
        : _buildUnlockedView(context, desktop: desktop);
    final mobileActions = <Widget>[
      if (unlocked)
        WIconButton(
          icon: Icons.sync_rounded,
          tooltip: syncing ? '正在同步…' : '立即同步',
          busy: syncing,
          onPressed: busy || syncing ? null : sync,
        ),
      if (unlocked)
        WIconButton(
          icon: Icons.lock_outline_rounded,
          tooltip: '锁定密码库',
          onPressed: lock,
        ),
      if (unlocked) _settingsMenu(),
      _moreMenu(),
    ];
    return Listener(
      onPointerDown: (_) => touch(),
      child: CallbackShortcuts(
        bindings: {
          if (unlocked)
            SingleActivator(LogicalKeyboardKey.keyK, meta: mac, control: !mac):
                _openCommands,
          if (unlocked)
            SingleActivator(LogicalKeyboardKey.keyF, meta: mac, control: !mac):
                _focusVaultSearch,
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            backgroundColor: c.canvas,
            appBar: !unlocked || desktop
                ? null
                : AppBar(
                    title: Text(pageLabel),
                    actions: mobileActions,
                    actionsPadding: const EdgeInsets.only(right: 10),
                    backgroundColor: c.surface,
                    elevation: 0,
                    scrolledUnderElevation: 0,
                  ),
            bottomNavigationBar: !unlocked || desktop
                ? null
                : NavigationBar(
                    selectedIndex: showSyncHistory
                        ? 2
                        : trash
                        ? 1
                        : 0,
                    onDestinationSelected: _selectWorkspace,
                    destinations: const [
                      NavigationDestination(
                        icon: Icon(Icons.key_outlined),
                        label: '密码库',
                      ),
                      NavigationDestination(
                        icon: Icon(Icons.delete_outline_rounded),
                        label: '回收站',
                      ),
                      NavigationDestination(
                        icon: Icon(Icons.history_rounded),
                        label: '同步记录',
                      ),
                    ],
                  ),
            body: desktop
                ? Row(
                    children: [
                      _workspaceSidebar(),
                      Expanded(
                        child: Column(
                          children: [
                            _pageHeader(context, pageLabel),
                            Divider(height: 1, color: c.border),
                            Expanded(child: page),
                          ],
                        ),
                      ),
                    ],
                  )
                : page,
            floatingActionButton:
                unlocked && !trash && !showSyncHistory && !busy
                ? WFloatingAction(label: '新增账号', onPressed: () => edit(null))
                : null,
            floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
          ),
        ),
      ),
    );
  }
}
