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
import 'entry_export.dart';
import 'lan_transfer.dart';
import 'probe_page.dart' show WencryptProbeApp;
import 'qr_code.dart';
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
    this.exists = true,
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

  final bool exists, unlocked;
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
  bool remoteUpdateAvailable = false;
  bool cloudUpdatePending = false;
  bool _cloudPasswordPromptOpen = false;
  bool _inviteFlowOpen = false;
  JoinInvite? pendingInvite;
  LanTransferSender? _activeLanSender;
  Timer? _searchUpdate;

  String? path, token, binding, vaultId, syncUsername;
  String message = '正在加载…', query = '';
  Object selectedGroup = EntryFilter.all;
  String? selectedEntryId;
  bool detailRevealPassword = false;
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
  SyncMode syncMode = SyncMode.manual;
  bool biometricEnabled = false,
      authenticating = false,
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
      exists = preview.exists;
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
      if (exists) {
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
    _activeLanSender?.dispose();
    _activeLanSender = null;
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
    if (!foreground) autoTimer?.cancel();
    // There is no vault session to lock while filling out first-run forms.
    if (!exists && token == null) return;
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
    _activeLanSender?.dispose();
    _activeLanSender = null;
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
    selectedEntryId = null;
    detailRevealPassword = false;
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
        'cloud_password_changed' => '云端主密码已有更新，请输入新主密码后继续同步。',
        'bootstrap_update_unconfirmed' => '未能确认云端主密码更新，请重新同步。',
        'strong_etag_required' => '本机主密码已更新，云端未提供可用于安全更新的文件版本标识。',
        'bootstrap_update_busy' => '云端主密码正在更新，或上次更新中断。请稍后再同步。',
        'bootstrap_write_uncertain' => '未收到云端主密码写入确认，已保留更新锁。请查看使用说明。',
        'bootstrap_lock_cleanup_failed' => '云端主密码已更新，更新锁暂未清除。请查看使用说明。',
        'vault_identity_mismatch' => '所选目录属于另一个密码库。请核对原设备的同步目录。',
        'free_budget_reached' => '已达到本机同步额度，已传输内容会保留，请稍后继续。',
        'directory_limit' => '坚果云单个目录达到列举上限，同步已暂停。',
        'timeout' => '连接坚果云超时，请检查网络后重试。',
        'network_failed' => '无法连接坚果云，请检查网络后重试。',
        'tls_failed' => '无法验证坚果云的安全连接，请检查网络或系统时间。',
        'local_budget_storage_failed' => '无法保存本机同步记录，请检查磁盘空间和应用数据目录权限。',
        _ when e.status == 401 || e.status == 403 =>
          '坚果云验证失败。请核对账号、WebDAV 应用密码和目录权限。',
        _ => e.toString(),
      };
    }
    if (text.contains('biometric')) {
      return '指纹验证未通过。请使用主密码，每 72 小时仍需输入一次主密码。';
    }
    if (text.contains('invalid_recovery_file')) return '无法读取 Wencrypt 恢复文件。';
    if (text.contains('invalid_recovery_key')) return '恢复密钥与所选恢复文件不匹配。';
    if (text.contains('recovery_identity_unverified')) {
      return '无法确认恢复文件属于这台设备的密码库。';
    }
    if (text.contains('invitation_vault_mismatch')) return '邀请链接和云端密码库不匹配。';
    if (text.contains('join_master_password_invalid')) {
      return '无法用该主密码打开云端密码库。若刚修改主密码，请确认原设备已成功同步。';
    }
    if (text.contains('invalid_bootstrap')) {
      return '云端引导文件无法识别或已损坏。请核对原设备使用的同步目录。';
    }
    if (text.contains('install_permission_denied')) {
      return '系统拒绝写入本机密码库。请检查应用的数据目录权限。';
    }
    if (text.contains('install_filesystem_unsupported')) {
      return '应用的数据目录所在磁盘不支持当前的密码库安装方式。';
    }
    if (text.contains('install_failed') || text.contains('storage_failed')) {
      return '无法保存或打开本机密码库。请检查应用数据目录的权限和磁盘空间。';
    }
    if (text.contains('core_library_unavailable')) {
      return '加密组件无法加载。请使用对应系统的完整安装包，Windows 版需完整解压。';
    }
    if (text.contains('core_platform_unsupported')) {
      return '此系统不支持当前 Wencrypt 安装包。';
    }
    if (text.contains('invalid_settings')) {
      return '本机无法保存坚果云设置，请核对账号和 WebDAV 应用密码。';
    }
    if (text.contains('vault_identity_mismatch')) return '所选目录属于另一个密码库。';
    if (text.contains('sync_credentials_required')) {
      return '请先保存同步使用的坚果云账号和 WebDAV 应用密码。';
    }
    if (text.contains('sync_not_configured')) {
      return '请先完成坚果云同步配置并启用至少一个同步目录。';
    }
    if (text.contains('invalid_invite')) {
      return '邀请码无效或已损坏，请向发送方重新获取。';
    }
    if (text.contains('invalid_lan_bundle')) {
      return '局域网传输出错，传输数据未能通过安全校验。';
    }
    if (text.contains('lan_connect_failed')) {
      return '无法连接到原设备。请确认两台设备连接在同一 WiFi，或改用「离线加密邀请」。';
    }
    if (text.contains('lan_no_network')) {
      return '未检测到可用的局域网 IP 地址，请确认设备已连接到 WiFi。';
    }
    if (text.contains('lan_rejected')) {
      return '原设备已拒绝此次加入请求。';
    }
    if (text.contains('lan_timeout')) {
      return '局域网连接等待超时，请重试或改用「离线加密邀请」。';
    }
    if (text.contains('lan_auth_failed') || text.contains('lan_frame_invalid')) {
      return '局域网安全校验失败，请重新生成配对码后再试。';
    }
    if (text.contains('lan_cancelled')) {
      return '已取消局域网传输。';
    }
    if (text.contains('lan_connection_closed')) {
      return '与原设备的连接已中断，请重新发起配对。';
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
    final adopted = result['adopted_cloud_password'] == true;
    if (adopted) _didUpdateMasterPassword();
    touch();
    await refresh();
    await loadAuto();
    if (adopted && syncConfigured) {
      await runSync(automatic: false, promptForPasswordUpdate: false);
    }
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
    cloudUpdatePending = info['cloud_update_pending'] == true;
    if (!Platform.isMacOS && !Platform.isAndroid) return;
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
    final current = generation;
    final settings =
        (await request('sync_settings_get'))['settings']
            as Map<String, dynamic>?;
    if (!mounted || current != generation) return;
    setState(() {
      syncConfigured = _hasSyncCredentials(settings);
      syncUsername = settings?['username'] as String?;
      syncMode = SyncMode.fromSettings(settings);
      initialSyncPending = settings?['joinPending'] == true;
      if (initialSyncPending) message = '本机已加入已有库，首次同步尚未完成';
      syncTargets = settings == null
          ? []
          : _normalizeTargets(settings['targets']);
    });
    scheduleAuto();
  }

  void scheduleAuto([Duration delay = const Duration(seconds: 30)]) {
    autoTimer?.cancel();
    if (!mounted ||
        !syncConfigured ||
        syncMode == SyncMode.manual ||
        !syncTargets.any((target) => target['enabled'] == true) ||
        token == null ||
        !foreground) {
      return;
    }
    autoTimer = Timer(delay, () => runSync(automatic: true));
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
    bool promptForPasswordUpdate = true,
    bool recoveringPassword = false,
    String? username,
    String? password,
    List<Map<String, dynamic>>? targetsOverride,
  }) async {
    if (!mounted ||
        syncing ||
        token == null ||
        !foreground ||
        (automatic && (!syncConfigured || syncMode == SyncMode.manual))) {
      return;
    }
    final checkOnly = automatic && syncMode == SyncMode.notify;
    autoTimer?.cancel();
    setState(() => syncing = true);
    final current = generation;
    final stateFile = File('${File(path!).parent.path}/auto-sync-state.json');
    var failures = 0;
    var idleRounds = 0;
    bool attempted = false;
    DateTime? next;
    CloudPasswordChanged? passwordUpdate;
    Future<void> persistCooldown(Duration delay) async {
      final temporary = File('${stateFile.path}.$pid.tmp');
      await temporary.writeAsString(
        jsonEncode({
          'next': DateTime.now().toUtc().add(delay).toIso8601String(),
          'failures': failures,
          'idleRounds': idleRounds,
        }),
        flush: true,
      );
      await temporary.rename(stateFile.path);
    }

    try {
      if (await stateFile.exists()) {
        try {
          final state = jsonDecode(await stateFile.readAsString());
          if (state is Map) {
            if (state['failures'] case final int saved) failures = saved;
            if (state['idleRounds'] case final int saved) idleRounds = saved;
            if (state['next'] case final String saved) {
              next = DateTime.tryParse(saved);
            }
          }
        } on FormatException {
          // Recover incomplete cooldown files left by older versions. The
          // separate per-request budget still applies.
        }
      }
      final now = DateTime.now().toUtc();
      if (automatic && next != null && next.isAfter(now)) {
        scheduleAuto(next.difference(now));
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
      setState(() => message = checkOnly ? '正在检查云端更新…' : '正在连接坚果云…');
      attempted = true;
      // Persist cooldown before network I/O so relaunching does not bypass pacing.
      await persistCooldown(const Duration(minutes: 15));
      if (current != generation || !foreground) return;

      final summaries = <String>[];
      var complete = true;
      var changed = false;
      var foundRemoteUpdates = false;
      var foundLocalUpdates = false;
      for (final target in enabledTargets) {
        if (current != generation || !foreground) return;
        final syncClient = NutstoreSync(File(path!).parent, request);
        activeSync = syncClient;
        final folder = (target['folder'] as String? ?? '').trim();
        if (checkOnly) {
          final result = await syncClient.sync(
            username,
            password,
            remoteFolder: folder.isEmpty ? null : folder,
            existingOnly: target['existingOnly'] == true,
            checkOnly: true,
          );
          foundRemoteUpdates |= result.remoteChanges;
          foundLocalUpdates |= result.localChanges;
          continue;
        }
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
            recoveringPassword: recoveringPassword,
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
          changed |= res.hasChanges;
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
      if (!mounted || current != generation) return;
      failures = 0;
      if (checkOnly) {
        // Repeated checks of the same pending changes stay at the idle cadence.
        idleRounds = (idleRounds + 1).clamp(0, 2);
        setState(() {
          remoteUpdateAvailable = foundRemoteUpdates;
          message = foundRemoteUpdates
              ? '云端有更新，点击「立即同步」更新本机。'
              : foundLocalUpdates
              ? '本机有待上传的改动，点击「立即同步」更新云端。'
              : '云端暂无待同步的更新。';
        });
        return;
      }
      await refresh();
      if (!mounted || current != generation) return;
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
      idleRounds = automatic && complete && !changed
          ? (idleRounds + 1).clamp(0, 2)
          : 0;
      if (mounted && current == generation) {
        setState(() {
          if (complete && pendingRevisions == 0) remoteUpdateAvailable = false;
          message = [
            ...summaries,
            if (initialSyncPending) '首次同步尚未完成',
            if (pendingRevisions > 0) '存在缺失的历史版本',
          ].join('\n');
        });
      }
    } catch (e) {
      failures = (failures + 1).clamp(1, 4);
      idleRounds = 0;
      if (current == generation && mounted) {
        if (e is CloudPasswordChanged) {
          passwordUpdate = e;
          try {
            final staged = await request('stage_cloud_password', {
              'bootstrap': e.bootstrap,
            });
            if (staged['pending'] == true) cloudUpdatePending = true;
          } catch (_) {
            // An unlocked vault can still verify the downloaded update.
          }
        }
        if (!mounted || current != generation) return;
        setState(() {
          message = friendly(e);
        });
      }
    } finally {
      username = null;
      password = null;
      activeSync = null;
      if (attempted && current == generation) {
        final delay = syncPollInterval(
          failures: failures,
          idleRounds: idleRounds,
        );
        try {
          await persistCooldown(delay);
          if (current == generation) scheduleAuto(delay);
        } catch (_) {
          if (current == generation) autoTimer?.cancel();
        }
      }
      if (mounted) {
        setState(() => syncing = false);
      } else {
        syncing = false;
      }
    }
    if (promptForPasswordUpdate &&
        passwordUpdate != null &&
        mounted &&
        current == generation &&
        foreground &&
        await _confirmCloudPasswordUpdate(passwordUpdate, current)) {
      await runSync(automatic: false, promptForPasswordUpdate: false);
    }
  }

  Future<void> forgetSyncSettings() => action(() async {
    await request('sync_settings_clear');
    autoTimer?.cancel();
    setState(() {
      syncMode = SyncMode.manual;
      remoteUpdateAvailable = false;
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
                  style: TextButton.styleFrom(foregroundColor: c.textSecondary),
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
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: input(
                        'title',
                        '名称（必填）',
                        Icons.label_outline_rounded,
                        hint: '例如 GitHub、招商银行',
                        error: titleError,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: input(
                        'username',
                        '用户名',
                        Icons.person_outline_rounded,
                        hint: '登录账号或邮箱',
                      ),
                    ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: WLabeledField(
                    label: '密码（必填）',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        TextField(
                          controller: controllers['password'],
                          obscureText: !reveal,
                          autocorrect: false,
                          enableSuggestions: false,
                          onChanged: (_) => setLocal(() {}),
                          style: TextStyle(
                            fontSize: 12.8,
                            fontFamily: reveal ? wMonoFamily : null,
                            color: c.textPrimary,
                          ),
                          decoration: decoration(
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
                                    controllers['password']!.text =
                                        List.generate(
                                          24,
                                          (_) =>
                                              chars[rng.nextInt(chars.length)],
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
                                  onPressed: () =>
                                      setLocal(() => reveal = !reveal),
                                ),
                              ],
                            ),
                          ),
                        ),
                        if (controllers['password']!.text.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          WPasswordStrength(
                            password: controllers['password']!.text,
                          ),
                        ],
                      ],
                    ),
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

  Future<bool> _saveEncryptedFile(Uint8List bytes, String name) async {
    if (Platform.isAndroid) {
      return await const MethodChannel(
            'org.wencrypt.files',
          ).invokeMethod<bool>('saveBackup', {'bytes': bytes, 'name': name}) ==
          true;
    }
    final location = await getSaveLocation(suggestedName: name);
    if (location == null) return false;
    await XFile.fromData(bytes).saveTo(location.path);
    return true;
  }

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
      final saved = await _saveEncryptedFile(
        Uint8List.fromList(bytes),
        'wencrypt-backup.wenback',
      );
      if (mounted && snapshot == generation) {
        setState(() => message = saved ? '已保存加密备份' : '已取消保存备份');
      }
    });
  }

  Future<void> _createRecoveryKit() async {
    if (token == null || busy || syncing) return;
    final epoch = generation;
    final password = await passwordPrompt();
    if (password == null || !mounted || epoch != generation) return;
    await action(() async {
      final result = await request('make_recovery_kit', {'password': password});
      if (!mounted || epoch != generation) return;
      final key = result['recovery_key'] as String;
      final accepted = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: const Text('保存密码恢复材料'),
          content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('把下面的恢复密钥保存在纸上或另一处安全位置。恢复文件可上传到坚果云，密钥请与文件分开保存。'),
                  const SizedBox(height: 12),
                  SelectableText(
                    key.replaceAllMapped(
                      RegExp(r'.{8}(?=.)'),
                      (part) => '${part[0]} ',
                    ),
                    style: TextStyle(fontFamily: wMonoFamily),
                  ),
                  TextButton.icon(
                    onPressed: () => copy(key, label: '恢复密钥'),
                    icon: const Icon(Icons.copy),
                    label: const Text('复制恢复密钥'),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('已记下密钥，保存恢复文件'),
            ),
          ],
        ),
      );
      if (accepted != true || !mounted || epoch != generation) return;
      final bytes = utf8.encode(jsonEncode(result['kit']));
      final saved = await _saveEncryptedFile(
        Uint8List.fromList(bytes),
        recoveryFileName,
      );
      if (mounted && epoch == generation) {
        setState(() => message = saved ? '恢复文件已保存。' : '已取消保存恢复文件。');
      }
    });
  }

  Future<void> _recoverMasterPassword() async {
    if (!exists || token != null || busy || path == null) return;
    try {
      final proceed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('忘记主密码'),
          content: const Text(
            '如果之前创建过恢复文件，请从坚果云或其他保存位置下载 wencrypt-recovery.wenrecover，并准备单独保存的恢复密钥。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('选择恢复文件'),
            ),
          ],
        ),
      );
      if (proceed != true || !mounted || token != null || busy) return;
      final file = await openFile();
      if (file == null || !mounted || token != null) return;
      final epoch = generation;
      if (await file.length() > 4096) throw StateError('invalid_recovery_file');
      final Map<String, dynamic> kit;
      try {
        kit = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        if (kit['format'] != 'WENCRYPT-RECOVERY-1' ||
            kit['wrapped'] is! String) {
          throw const FormatException();
        }
      } catch (_) {
        throw StateError('invalid_recovery_file');
      }
      if (!mounted || epoch != generation) return;
      final recoveryKey = TextEditingController();
      final newPassword = TextEditingController();
      final confirmation = TextEditingController();
      final form = GlobalKey<FormState>();
      final dialog = DialogRoute<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('用恢复文件重置主密码'),
          content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
              child: Form(
                key: form,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '已选择 ${file.name}。输入单独保存的恢复密钥，然后设置新主密码。已绑定坚果云时，应用也会尝试更新云端主密码。',
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: recoveryKey,
                      obscureText: true,
                      enableSuggestions: false,
                      autocorrect: false,
                      decoration: const InputDecoration(labelText: '恢复密钥'),
                      validator: (value) =>
                          RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(
                            (value ?? '').replaceAll(RegExp(r'\s+'), ''),
                          )
                          ? null
                          : '请输入保存的 64 位恢复密钥',
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: newPassword,
                      obscureText: true,
                      enableSuggestions: false,
                      autocorrect: false,
                      decoration: const InputDecoration(labelText: '新主密码'),
                      validator: (value) => (value ?? '').runes.length >= 12
                          ? null
                          : '请至少输入 12 个字符',
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: confirmation,
                      obscureText: true,
                      enableSuggestions: false,
                      autocorrect: false,
                      decoration: const InputDecoration(labelText: '确认新主密码'),
                      validator: (value) =>
                          value == newPassword.text ? null : '两次输入不一致',
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
              child: const Text('重置并解锁'),
            ),
          ],
        ),
      );
      final accepted = await Navigator.of(context).push(dialog);
      await dialog.completed;
      final key = recoveryKey.text.replaceAll(RegExp(r'\s+'), '');
      final next = newPassword.text;
      recoveryKey.dispose();
      newPassword.dispose();
      confirmation.dispose();
      if (accepted != true || !mounted || epoch != generation) return;
      await action(() async {
        final result = await core({
          'op': 'recover_master_password',
          'path': path,
          'kit': kit,
          'recovery_key': key,
          'new_password': next,
        });
        if (!mounted || epoch != generation) return;
        token = result['session'] as String;
        _didUpdateMasterPassword();
        master.clear();
        touch();
        await refresh();
        await loadAuto();
        if (syncConfigured) {
          await runSync(
            automatic: false,
            promptForPasswordUpdate: false,
            recoveringPassword: true,
          );
        }
      });
    } catch (error) {
      if (mounted) setState(() => message = friendly(error));
    }
  }

  Future<void> _exportEntry(Map<String, dynamic> data) async {
    final epoch = generation;
    final toAlbum = Platform.isAndroid;
    touch();
    final format = await showDialog<EntryExportFormat>(
      context: context,
      barrierDismissible: false,
      builder: (_) => EntryExportDialog(
        entry: data,
        toAlbum: toAlbum,
        onCopyText: (text) async {
          if (!mounted || epoch != generation) {
            throw PlatformException(code: 'locked');
          }
          await copy(text, label: '账号文字');
        },
        onExportImage: (png) async {
          for (var attempt = 0; ; attempt++) {
            if (!mounted || epoch != generation) {
              throw PlatformException(code: 'locked');
            }
            try {
              final copied = await entryImage.invokeMethod<bool>(
                toAlbum ? 'savePng' : 'copyPng',
                png,
              );
              if (copied != true) {
                throw PlatformException(code: 'image_export_failed');
              }
              return;
            } on PlatformException catch (error) {
              if (error.code != 'clipboard_busy' || attempt == 4) rethrow;
              await Future<void>.delayed(const Duration(milliseconds: 60));
            }
          }
        },
      ),
    );
    if (format == null || !mounted || epoch != generation) return;
    if (format == EntryExportFormat.text) {
      setState(() => message = '账号文字已复制到剪贴板');
      return;
    }
    final result = toAlbum ? '图片已保存到 Wencrypt 相册' : '图片已复制到剪贴板';
    setState(() => message = result);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(result)));
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
    final invitation = parseJoinInvite(raw);
    if (exists || token != null) {
      setState(() => message = '邀请链接用于尚未建立密码库的设备。');
      return;
    }
    if (invitation == null) {
      setState(() => message = '邀请码无效，请向发送方核对。');
      return;
    }
    switch (invitation) {
      case LegacyVaultInvite():
        setState(() {
          pendingInvite = invitation;
          firstRunStep = FirstRunStep.join;
          message = '';
        });
      case EncryptedVaultInvite():
        setState(() {
          pendingInvite = invitation;
          firstRunStep = FirstRunStep.join;
          message = '';
        });
        unawaited(_joinEncryptedInvite(invitation));
      case LanTransferTicket():
        setState(() {
          pendingInvite = invitation;
          firstRunStep = FirstRunStep.join;
          message = '';
        });
        unawaited(_joinOverLan(invitation));
    }
  }

  Future<void> _pasteInvite() async {
    if (exists || token != null || busy || _inviteFlowOpen) return;
    final clip = await Clipboard.getData(Clipboard.kTextPlain);
    final clipText = (clip?.text ?? '').trim();
    if (!mounted) return;
    if (parseJoinInvite(clipText) != null) {
      _useInvite(clipText);
      return;
    }
    final ctrl = TextEditingController();
    String? inputError;
    final raw = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          final c = WColors.of(ctx);
          return WDialog(
            width: 480,
            icon: Icons.qr_code_2_rounded,
            title: '快捷加入已有密码库',
            subtitle: '粘贴另一台设备生成的「加密邀请码」或「同 WiFi 配对码」（也可直接用手机扫码打开）。',
            footer: WDialogFooter(
              leading: TextButton.icon(
                onPressed: () async {
                  final data = await Clipboard.getData(Clipboard.kTextPlain);
                  final text = (data?.text ?? '').trim();
                  if (text.isNotEmpty) {
                    ctrl.text = text;
                    setLocal(() => inputError = null);
                  }
                },
                icon: const Icon(Icons.content_paste_rounded, size: 15),
                label: const Text('从剪贴板粘贴'),
              ),
              actions: [
                TextButton(
                  style: TextButton.styleFrom(foregroundColor: c.textSecondary),
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () {
                    final val = ctrl.text.trim();
                    if (parseJoinInvite(val) == null) {
                      setLocal(() => inputError = '未能识别有效的邀请码或配对码，请完整粘贴后重试。');
                      return;
                    }
                    Navigator.pop(ctx, val);
                  },
                  child: const Text('下一步'),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                WLabeledField(
                  label: '邀请码 / 配对码',
                  child: TextField(
                    controller: ctrl,
                    autofocus: true,
                    minLines: 3,
                    maxLines: 5,
                    onChanged: (_) {
                      if (inputError != null) setLocal(() => inputError = null);
                    },
                    style: TextStyle(
                      fontFamily: wMonoFamily,
                      fontSize: 12,
                      color: c.textPrimary,
                    ),
                    decoration: InputDecoration(
                      hintText: 'wencrypt://join?v=2&...',
                      errorText: inputError,
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
    ctrl.dispose();
    if (mounted && raw != null) _useInvite(raw);
  }

  String _deviceDisplayLabel() {
    final host = Platform.localHostname.trim();
    if (host.isNotEmpty &&
        host.toLowerCase() != 'localhost' &&
        host != '127.0.0.1') {
      return host.replaceFirst(RegExp(r'\.local$'), '');
    }
    return switch (Platform.operatingSystem) {
      'macos' => 'Mac 设备',
      'windows' => 'Windows 设备',
      'android' => 'Android 手机',
      _ => '新设备',
    };
  }

  Future<void> _joinEncryptedInvite(EncryptedVaultInvite invitation) async {
    if (exists || busy || path == null || _inviteFlowOpen) return;
    _inviteFlowOpen = true;
    final epoch = generation;
    final password = TextEditingController();
    var mode = SyncMode.notify;
    var submitting = false;
    var reveal = false;
    String? joinError;
    ({
      String session,
      String username,
      String appPassword,
      List<Map<String, dynamic>> targets,
    })?
    joined;
    try {
      final dialog = DialogRoute<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) => StatefulBuilder(
          builder: (context, setLocal) {
            final c = WColors.of(context);
            bool canRespond() =>
                mounted && context.mounted && epoch == generation;

            Future<void> submit() async {
              if (submitting || !foreground || password.text.isEmpty) {
                if (password.text.isEmpty) {
                  setLocal(() => joinError = '请输入已有密码库的主密码');
                }
                return;
              }
              final navigator = Navigator.of(context);
              setLocal(() {
                submitting = true;
                joinError = null;
              });
              try {
                final opened = await core({
                  'op': 'join_encrypted_invite',
                  'path': path,
                  'password': password.text,
                  'payload': invitation.payloadHex,
                  'sync_mode': mode.name,
                });
                if (!canRespond()) {
                  if (mounted) await initialize();
                  return;
                }
                final targets = (opened['targets'] as List)
                    .cast<Map<String, dynamic>>();
                if (!foreground) {
                  exists = true;
                  lock();
                  setState(() => message = '已加入密码库，请输入主密码解锁后继续同步。');
                  return;
                }
                joined = (
                  session: opened['session'] as String,
                  username: opened['username'] as String,
                  appPassword: opened['password'] as String,
                  targets: targets,
                );
                navigator.pop(true);
              } catch (error) {
                if (!canRespond()) return;
                final detail = friendly(error);
                if (await File(path!).exists()) {
                  if (!canRespond()) return;
                  exists = true;
                  lock();
                  setState(() => message = '加入密码库失败。$detail');
                  return;
                }
                setLocal(() => joinError = detail);
              } finally {
                if (canRespond() && joined == null) {
                  setLocal(() => submitting = false);
                }
              }
            }

            return PopScope(
              canPop: !submitting,
              child: WDialog(
                width: 450,
                icon: Icons.verified_user_outlined,
                title: '通过离线加密邀请加入',
                subtitle: '只需输入 1 次原库主密码，坚果云账号、应用密码与同步目录会自动解密配置。',
                footer: WDialogFooter(
                  actions: [
                    TextButton(
                      style: TextButton.styleFrom(
                        foregroundColor: c.textSecondary,
                      ),
                      onPressed: submitting
                          ? null
                          : () => Navigator.pop(context, false),
                      child: const Text('取消'),
                    ),
                    FilledButton(
                      onPressed: submitting ? null : submit,
                      child: Text(submitting ? '正在解密并加入…' : '确认加入'),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    WNote(
                      tone: WTone.info,
                      icon: Icons.fingerprint_rounded,
                      child: Text(
                        '密码库标识：${invitation.vaultId.substring(0, 8)}…（仅支持原库主密码解封）',
                      ),
                    ),
                    const SizedBox(height: 12),
                    WLabeledField(
                      label: '已有库的主密码',
                      child: TextField(
                        controller: password,
                        enabled: !submitting,
                        autofocus: true,
                        obscureText: !reveal,
                        autocorrect: false,
                        enableSuggestions: false,
                        onSubmitted: (_) => submit(),
                        style: TextStyle(fontSize: 13, color: c.textPrimary),
                        decoration: InputDecoration(
                          hintText: '输入原密码库的主密码',
                          prefixIcon: const Icon(
                            Icons.lock_outline_rounded,
                            size: 16,
                          ),
                          suffixIcon: IconButton(
                            tooltip: reveal ? '隐藏主密码' : '显示主密码',
                            icon: Icon(
                              reveal
                                  ? Icons.visibility_off_outlined
                                  : Icons.visibility_outlined,
                              size: 17,
                            ),
                            onPressed: submitting
                                ? null
                                : () => setLocal(() => reveal = !reveal),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    _syncModePicker(
                      mode,
                      submitting ? null : (v) => setLocal(() => mode = v),
                    ),
                    if (joinError case final err?)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: WNote(tone: WTone.danger, child: Text(err)),
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
      password.clear();
      password.dispose();
      final result = joined;
      if (accepted != true ||
          result == null ||
          !mounted ||
          epoch != generation ||
          exists) {
        return;
      }
      await action(() async {
        token = result.session;
        exists = true;
        pendingInvite = null;
        touch();
        await refresh();
        await loadAuto();
        await runSync(
          automatic: false,
          username: result.username,
          password: result.appPassword,
          targetsOverride: result.targets,
        );
      });
    } finally {
      _inviteFlowOpen = false;
    }
  }

  Future<void> _joinOverLan(LanTransferTicket ticket) async {
    if (exists || busy || path == null || _inviteFlowOpen) return;
    _inviteFlowOpen = true;
    final epoch = generation;
    try {
      final result = await showDialog<LanJoinResult>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => _LanJoinDialog(
          ticket: ticket,
          vaultPath: path!,
          deviceLabel: _deviceDisplayLabel(),
          invoke: core,
          describeError: friendly,
        ),
      );
      if (result == null || !mounted || epoch != generation || exists) return;
      if (!foreground) {
        exists = true;
        lock();
        setState(() => message = '已通过同 WiFi 加入密码库，请解锁后使用。');
        return;
      }
      await action(() async {
        token = result.session;
        exists = true;
        pendingInvite = null;
        touch();
        await refresh();
        await loadAuto();
        if (mounted && epoch == generation) {
          setState(() {
            message = result.hasSync
                ? '已通过同 WiFi 加入密码库并同步坚果云配置（共 ${result.objectCount} 条修订）'
                : '已通过同 WiFi 加入密码库（共 ${result.objectCount} 条修订）';
          });
        }
      });
    } finally {
      _inviteFlowOpen = false;
    }
  }

  Future<void> _openInviteDialog() async {
    if (token == null || busy) return;
    touch();
    final epoch = generation;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _InviteDeviceDialog(
        vaultId: vaultId ?? '',
        sessionToken: token!,
        syncConfigured: syncConfigured,
        hasSyncTargets: syncTargets.any((t) => t['enabled'] == true),
        invoke: (req) {
          final op = req['op'] as String;
          final extra = Map<String, dynamic>.from(req)..remove('op');
          return request(op, extra);
        },
        onSenderChanged: (sender) {
          if (epoch == generation) _activeLanSender = sender;
        },
        onCopyCode: (value, label) => copy(value, label: label),
        onCopyLegacyLink: syncConfigured ? _copyVaultInvite : null,
        onActivity: touch,
        describeError: friendly,
      ),
    );
    _activeLanSender?.dispose();
    _activeLanSender = null;
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

  void _didUpdateMasterPassword() {
    setState(() {
      biometricEnabled = false;
      binding = null;
      cloudUpdatePending = false;
      message = '本机主密码已更新。';
    });
  }

  Future<bool> _confirmCloudPasswordUpdate(
    CloudPasswordChanged update,
    int epoch,
  ) async {
    if (_cloudPasswordPromptOpen) return false;
    _cloudPasswordPromptOpen = true;
    touch();
    final password = TextEditingController();
    var verifying = false;
    String? error;
    final dialog = DialogRoute<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) {
          Future<void> verify() async {
            if (verifying || epoch != generation) return;
            if (password.text.isEmpty) {
              setLocal(() => error = '请输入新主密码');
              return;
            }
            touch();
            setLocal(() {
              verifying = true;
              error = null;
            });
            final input = password.text;
            password.clear();
            try {
              final result = await request('adopt_cloud_password', {
                'new_password': input,
                'bootstrap': update.bootstrap,
              });
              if (!mounted || epoch != generation) return;
              if (result['changed'] == true) _didUpdateMasterPassword();
              if (context.mounted) Navigator.of(context).pop(true);
            } catch (failure) {
              if (!context.mounted || epoch != generation) return;
              setLocal(() {
                verifying = false;
                error = friendly(failure);
              });
            }
          }

          return AlertDialog(
            title: const Text('云端主密码已更新'),
            scrollable: true,
            content: SizedBox(
              width: 400,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('输入新主密码以更新本机并继续同步「${update.folder}」。'),
                  const SizedBox(height: 14),
                  TextField(
                    controller: password,
                    autofocus: true,
                    enabled: !verifying,
                    obscureText: true,
                    enableSuggestions: false,
                    autocorrect: false,
                    decoration: InputDecoration(
                      labelText: '新主密码',
                      errorText: error,
                    ),
                    onSubmitted: (_) => verify(),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: verifying
                    ? null
                    : () => Navigator.of(context).pop(false),
                child: const Text('稍后'),
              ),
              FilledButton(
                onPressed: verifying ? null : verify,
                child: Text(verifying ? '正在验证…' : '验证并继续同步'),
              ),
            ],
          );
        },
      ),
    );
    try {
      final accepted = await Navigator.of(context).push(dialog);
      await dialog.completed;
      return accepted == true && mounted && epoch == generation;
    } finally {
      _cloudPasswordPromptOpen = false;
      password.dispose();
    }
  }

  Widget _masterPasswordField({
    required TextEditingController controller,
    required String label,
    required String? Function(String?) validator,
  }) {
    var revealed = false;
    return StatefulBuilder(
      builder: (context, setFieldState) => TextFormField(
        controller: controller,
        obscureText: !revealed,
        enableSuggestions: false,
        autocorrect: false,
        decoration: InputDecoration(
          labelText: label,
          suffixIcon: IconButton(
            tooltip: revealed ? '隐藏$label' : '显示$label',
            icon: Icon(
              revealed
                  ? Icons.visibility_off_outlined
                  : Icons.visibility_outlined,
            ),
            onPressed: () => setFieldState(() => revealed = !revealed),
          ),
        ),
        validator: validator,
      ),
    );
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
                    _masterPasswordField(
                      controller: old,
                      label: '当前主密码',
                      validator: (value) =>
                          value?.isNotEmpty == true ? null : '请输入当前主密码',
                    ),
                    const SizedBox(height: 10),
                  ],
                  _masterPasswordField(
                    controller: password,
                    label: adopt ? '云端主密码' : '新主密码',
                    validator: (value) =>
                        (value ?? '').runes.length >= (adopt ? 1 : 12)
                        ? null
                        : adopt
                        ? '请输入云端主密码'
                        : '请至少输入 12 个字符',
                  ),
                  if (!adopt) ...[
                    const SizedBox(height: 10),
                    _masterPasswordField(
                      controller: confirmation,
                      label: '确认新主密码',
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
      _didUpdateMasterPassword();
      if (syncConfigured) await runSync(automatic: false);
    });
  }

  Future<void> joinCloudVault() async {
    if (exists || busy || path == null) return;
    final epoch = generation;
    final rawInvite = pendingInvite;
    final invitation = rawInvite is LegacyVaultInvite ? rawInvite.invite : null;
    final fields = {
      '坚果云账号': TextEditingController(),
      'WebDAV 应用密码': TextEditingController(),
      '同步目录名': TextEditingController(text: invitation?.folder),
      '已有库的主密码': TextEditingController(),
    };
    final form = GlobalKey<FormState>();
    var mode = SyncMode.notify;
    var submitting = false;
    final revealed = <String>{};
    String? joinError;
    ({
      String session,
      String username,
      String appPassword,
      List<Map<String, dynamic>> targets,
    })?
    joined;
    final dialog = DialogRoute<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) {
          final c = WColors.of(context);
          bool canRespond() =>
              mounted && context.mounted && epoch == generation;

          Future<void> submit() async {
            if (submitting || !foreground || !form.currentState!.validate()) {
              return;
            }
            final navigator = Navigator.of(context);
            final username = fields['坚果云账号']!.text.trim();
            final appPassword = fields['WebDAV 应用密码']!.text;
            final folder = invitation?.folder ?? fields['同步目录名']!.text.trim();
            final masterPassword = fields['已有库的主密码']!.text;
            setLocal(() {
              submitting = true;
              joinError = null;
            });
            var readingCloud = true;
            try {
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
              if (!canRespond()) return;
              if (!foreground) {
                setLocal(() => joinError = '已读取云端密码库，请返回 Wencrypt 后再点加入。');
                return;
              }
              readingCloud = false;
              final targets = <Map<String, dynamic>>[
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
                  'syncMode': mode.name,
                  'auto': mode == SyncMode.automatic,
                  'targets': targets,
                  'joinPending': true,
                },
              });
              if (!canRespond()) {
                if (mounted) await initialize();
                return;
              }
              if (!foreground) {
                exists = true;
                lock();
                setState(() => message = '已加入密码库，请输入主密码解锁后继续同步。');
                return;
              }
              joined = (
                session: opened['session'] as String,
                username: username,
                appPassword: appPassword,
                targets: targets,
              );
              navigator.pop(true);
            } catch (error) {
              if (!canRespond()) return;
              final detail = friendly(error);
              final step = readingCloud ? '读取云端密码库' : '验证主密码或保存本机密码库';
              if (!readingCloud && await File(path!).exists()) {
                if (!canRespond()) return;
                exists = true;
                lock();
                setState(() => message = '$step失败。$detail');
                return;
              }
              if (canRespond()) setLocal(() => joinError = '$step失败。$detail');
            } finally {
              if (canRespond() && joined == null) {
                setLocal(() => submitting = false);
              }
            }
          }

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
                  enabled: !submitting,
                  readOnly: invitation != null && label == '同步目录名',
                  obscureText: obscure && !revealed.contains(label),
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
                    suffixIcon: obscure
                        ? IconButton(
                            tooltip: revealed.contains(label)
                                ? '隐藏$label'
                                : '显示$label',
                            icon: Icon(
                              revealed.contains(label)
                                  ? Icons.visibility_off_outlined
                                  : Icons.visibility_outlined,
                              size: 17,
                            ),
                            onPressed: submitting
                                ? null
                                : () => setLocal(() {
                                    if (!revealed.remove(label)) {
                                      revealed.add(label);
                                    }
                                  }),
                          )
                        : null,
                  ),
                  validator: (value) => (value == null || value.trim().isEmpty)
                      ? '请填写$label'
                      : null,
                ),
              ),
            );
          }

          return PopScope(
            canPop: !submitting,
            child: WDialog(
              width: 470,
              icon: Icons.cloud_download_outlined,
              title: '加入已有密码库',
              subtitle: invitation == null
                  ? '输入坚果云 WebDAV 凭据与备份目录，使用原密码库的主密码完成加入。'
                  : '邀请指向目录 /${invitation.folder}/，输入凭据与原库主密码即可加入。',
              bodyPadding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
              footer: WDialogFooter(
                actions: [
                  TextButton(
                    onPressed: submitting
                        ? null
                        : () => Navigator.pop(context, false),
                    child: const Text('取消'),
                  ),
                  FilledButton(
                    onPressed: submitting ? null : submit,
                    child: Text(submitting ? '正在加入…' : '加入密码库'),
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
                    field(
                      '同步目录名',
                      Icons.folder_outlined,
                      hint: '仅填写目录名或粘贴复制的目录名',
                    ),
                    field(
                      '已有库的主密码',
                      Icons.lock_outline_rounded,
                      obscure: true,
                      hint: '原密码库的主密码',
                    ),
                    const SizedBox(height: 2),
                    _syncModePicker(
                      mode,
                      submitting ? null : (v) => setLocal(() => mode = v),
                    ),
                    if (joinError case final error?)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: WNote(tone: WTone.danger, child: Text(error)),
                      ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
    final accepted = await Navigator.of(context).push(dialog);
    await dialog.completed;
    for (final field in fields.values) {
      field.clear();
      field.dispose();
    }
    final result = joined;
    if (accepted != true ||
        result == null ||
        !mounted ||
        epoch != generation ||
        exists) {
      return;
    }
    if (!foreground) {
      exists = true;
      lock();
      setState(() => message = '已加入密码库，请输入主密码解锁后继续同步。');
      return;
    }
    await action(() async {
      token = result.session;
      exists = true;
      pendingInvite = null;
      touch();
      await refresh();
      await loadAuto();
      await runSync(
        automatic: false,
        username: result.username,
        password: result.appPassword,
        targetsOverride: result.targets,
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

  String _syncModeLabel(SyncMode mode) => switch (mode) {
    SyncMode.manual => '手动',
    SyncMode.notify => '仅提醒',
    SyncMode.automatic => '自动同步',
  };

  Widget _syncModePicker(SyncMode mode, ValueChanged<SyncMode>? onChanged) {
    final colors = WColors.of(context);
    final description = switch (mode) {
      SyncMode.manual => '平时只在你确认同步时连接坚果云。',
      SyncMode.notify => '前台解锁时检查云端，确认后传输账号修订。',
      SyncMode.automatic => '前台解锁时双向同步，空闲时减少检查频率。',
    };
    return WLabeledField(
      label: '本机同步方式',
      helper: description,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surfaceMuted,
          borderRadius: BorderRadius.circular(WRadius.sm),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<SyncMode>(
              value: mode,
              isExpanded: true,
              icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 16),
              items: [
                for (final option in SyncMode.values)
                  DropdownMenuItem(
                    value: option,
                    child: Text(_syncModeLabel(option)),
                  ),
              ],
              onChanged: onChanged == null
                  ? null
                  : (value) {
                      if (value != null) onChanged(value);
                    },
            ),
          ),
        ),
      ),
    );
  }

  Future<void> sync({bool configure = false}) => action(() async {
    if (token == null || syncing) return;
    touch();
    final epoch = generation;
    final existing =
        (await request('sync_settings_get'))['settings']
            as Map<String, dynamic>?;
    if (!mounted || epoch != generation) return;
    final savedCredentials = _hasSyncCredentials(existing);
    if (!configure && savedCredentials) {
      final targets = _normalizeTargets(existing!['targets']);
      final enabled = targets.where((target) => target['enabled'] == true);
      if (enabled.isEmpty) {
        setState(() => message = '请先在「坚果云设置」启用一个同步目录。');
        return;
      }
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('同步到坚果云？'),
          scrollable: true,
          content: Text(
            '将与以下目录双向同步加密数据：\n${enabled.map(_targetFolder).join('\n')}',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确认同步'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted || epoch != generation) return;
      await runSync(
        automatic: false,
        username: existing['username'] as String,
        password: existing['password'] as String,
        targetsOverride: targets,
      );
      return;
    }
    final user = TextEditingController(text: existing?['username'] as String?);
    final password = TextEditingController(
      text: existing?['password'] as String?,
    );
    var editCredentials = !savedCredentials;
    var mode = existing == null
        ? SyncMode.notify
        : SyncMode.fromSettings(existing);
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
                  style: TextButton.styleFrom(foregroundColor: c.textSecondary),
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: Text(savedCredentials ? '保存设置' : '保存并同步'),
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
                const SizedBox(height: 10),
                Divider(height: 1, color: c.border),
                const SizedBox(height: 14),
                _syncModePicker(mode, (v) => setLocal(() => mode = v)),
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
        'syncMode': mode.name,
        'auto': mode == SyncMode.automatic,
        'targets': targets,
        if (initialSyncPending) 'joinPending': true,
      },
    });
    if (!mounted || epoch != generation) return;
    setState(() {
      syncConfigured = true;
      syncUsername = username;
      syncMode = mode;
      remoteUpdateAvailable = false;
      syncTargets = targets;
      if (savedCredentials) message = '已保存本机同步设置';
    });
    autoTimer?.cancel();
    if (savedCredentials) {
      scheduleAuto();
      return;
    }
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

  bool get _hasActiveMessage {
    if (busy && !syncing) return true;
    final trimmed = message.trim();
    return trimmed.isNotEmpty && trimmed != '本地加密 · 离线可用';
  }

  Widget _buildStatusPill(BuildContext context, {bool dismissible = false}) {
    final text = busy && !syncing ? '正在处理…' : message;
    if (text.isEmpty) return const SizedBox.shrink();
    final c = WColors.of(context);
    final warning =
        text.contains('缺失') ||
        text.contains('不正确') ||
        text.contains('失败') ||
        text.contains('未完成') ||
        text.contains('超出') ||
        text.contains('上限') ||
        text.contains('未启用');
    final success =
        text.contains('已保存') ||
        text.contains('已同步') ||
        text.contains('已置顶') ||
        text.contains('新增') ||
        text.contains('已恢复');
    final pill = WStatusPill(
      label: text,
      busy: busy || syncing,
      tone: warning
          ? WTone.danger
          : success
          ? WTone.success
          : WTone.info,
      icon: warning
          ? Icons.error_outline_rounded
          : success
          ? Icons.check_circle_outline_rounded
          : Icons.info_outline_rounded,
    );
    if (!dismissible || busy) return pill;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(child: pill),
        const SizedBox(width: 4),
        WIconButton(
          icon: Icons.close_rounded,
          tooltip: '关闭提示',
          size: 20,
          iconSize: 13,
          color: c.textTertiary,
          onPressed: () => setState(() => message = ''),
        ),
      ],
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

  String _targetLabel(Map<String, dynamic> target) {
    final name = (target['name'] as String? ?? '').trim();
    return name.isNotEmpty ? name : _targetFolder(target);
  }

  Widget _buildSyncBanner(BuildContext context) {
    if (!syncConfigured) return const SizedBox.shrink();
    final c = WColors.of(context);
    final enabled = syncTargets
        .where((target) => target['enabled'] == true)
        .toList();
    final labels = enabled.map(_targetLabel).join(' · ');
    final folders = enabled.map(_targetFolder).join(' · ');
    final pending = initialSyncPending;
    final statusText = pending
        ? '首次同步尚未完成'
        : enabled.isEmpty
        ? '未启用同步目录'
        : labels;
    final dotColor = pending
        ? c.warning
        : remoteUpdateAvailable
        ? c.brand
        : enabled.isEmpty
        ? c.textTertiary
        : c.success;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: WSurface(
        radius: WRadius.md,
        padding: const EdgeInsets.fromLTRB(12, 5, 6, 5),
        color: pending ? c.warningSoft : c.surface,
        border: true,
        child: Row(
          children: [
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                color: dotColor,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '坚果云',
              style: TextStyle(
                fontSize: 11.8,
                fontWeight: FontWeight.w600,
                color: c.textPrimary,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Tooltip(
                message: folders.isEmpty ? statusText : folders,
                child: Text(
                  statusText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: pending ? c.warning : c.textSecondary,
                  ),
                ),
              ),
            ),
            if (remoteUpdateAvailable) ...[
              const SizedBox(width: 6),
              const WStatusPill(
                label: '云端有更新',
                tone: WTone.info,
                compact: true,
              ),
            ],
            const SizedBox(width: 6),
            TextButton(
              onPressed: busy || syncing ? null : () => sync(),
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 24),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                textStyle: Theme.of(
                  context,
                ).textTheme.labelLarge?.copyWith(fontSize: 11.5),
              ),
              child: syncing
                  ? const SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 1.6),
                    )
                  : const Text('立即同步'),
            ),
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
        color: c.canvas,
        gradient: RadialGradient(
          center: const Alignment(0, -0.55),
          radius: 1.15,
          colors: [
            c.brand.withValues(alpha: c.isDark ? 0.12 : 0.055),
            c.canvas,
          ],
        ),
      ),
      child: SizedBox.expand(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const WBrandMark(size: 30, radius: 8),
                      const SizedBox(width: 10),
                      Text(
                        'Wencrypt',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.3,
                          color: c.textPrimary,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  WSurface(
                    shadow: true,
                    radius: WRadius.xl,
                    padding: const EdgeInsets.fromLTRB(28, 28, 28, 24),
                    child: child,
                  ),
                  const SizedBox(height: 18),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.shield_outlined,
                        size: 13,
                        color: c.textTertiary,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '本地端到端加密 · 主密码不会离开这台设备',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: c.textTertiary,
                        ),
                      ),
                    ],
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
                  Expanded(
                    child: Text(switch (invitation) {
                      LegacyVaultInvite(:final invite) =>
                        '收到邀请：${invite.folder}',
                      EncryptedVaultInvite() => '已读取离线加密邀请，输入主密码即可加入',
                      LanTransferTicket(:final ips, :final port) =>
                        '收到同 WiFi 直连配对：${ips.first}:$port',
                    }),
                  ),
                  if (invitation is EncryptedVaultInvite ||
                      invitation is LanTransferTicket)
                    TextButton(
                      onPressed: busy
                          ? null
                          : () {
                              if (invitation is EncryptedVaultInvite) {
                                _joinEncryptedInvite(invitation);
                              } else if (invitation is LanTransferTicket) {
                                _joinOverLan(invitation);
                              }
                            },
                      child: const Text('立即加入'),
                    ),
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
          icon: Icons.qr_code_scanner_rounded,
          title: '快捷加入（邀请码 / 同 WiFi 配对）',
          description: '粘贴加密邀请码或局域网配对码，免输入坚果云账号密码快速加入。',
          onTap: busy ? null : _pasteInvite,
          primary: true,
        ),
        _authOption(
          icon: Icons.cloud_download_outlined,
          title: '从坚果云加入',
          description: '手动输入坚果云账号、应用密码与主密码加入。',
          onTap: busy || path == null ? null : joinCloudVault,
        ),
        _authOption(
          icon: Icons.restore_page_outlined,
          title: '从加密备份恢复',
          description: '选择此前导出的加密备份文件。',
          onTap: busy || path == null ? null : restore,
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
        ? cloudUpdatePending
              ? '检测到云端主密码更新，可直接输入新主密码解锁。'
              : '使用已有密码库的主密码解锁。'
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
            if (exists) ...[
              const SizedBox(height: 4),
              Center(
                child: TextButton(
                  style: TextButton.styleFrom(foregroundColor: c.textSecondary),
                  onPressed: busy ? null : _recoverMasterPassword,
                  child: const Text('忘记主密码？'),
                ),
              ),
            ],
          ],
          if (!exists && firstRunStep != FirstRunStep.welcome) ...[
            const SizedBox(height: 4),
            Center(
              child: TextButton(
                style: TextButton.styleFrom(foregroundColor: c.textSecondary),
                onPressed: busy ? null : _backToWelcome,
                child: const Text('返回'),
              ),
            ),
          ],
          if (_hasActiveMessage) ...[
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

    final splitView =
        desktop &&
        MediaQuery.sizeOf(context).width >= 1020 &&
        deleteSelection == null;

    Map<String, dynamic>? activeRevision;
    if (splitView && filtered.isNotEmpty) {
      activeRevision = filtered.firstWhere(
        (r) => r['id'] == selectedEntryId || r['entry'] == selectedEntryId,
        orElse: () => filtered.first,
      );
    }

    Widget buildRow(Map<String, dynamic> r) {
      final data = r['data'] as Map<String, dynamic>;
      final title = (data['title'] as String? ?? '').trim();
      final username = (data['username'] as String? ?? '').trim();
      final url = (data['url'] as String? ?? '').trim();
      final pinned = _isPinned(r);
      final groups = _entryGroups(r);
      final hasConflict = revisionCounts[r['entry']]! > 1;
      final revisionId = r['id'] as String;
      final entryId = r['entry'] as String;
      final selection = deleteSelection;
      final host = _hostLabel(url);
      final meta = [
        if (username.isNotEmpty) username,
        if (host.isNotEmpty) host,
        if (username.isEmpty && host.isEmpty) '未填写用户名',
      ].join(' · ');
      final isActive =
          splitView && activeRevision != null && activeRevision['id'] == revisionId;

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
        active: isActive,
        selected: selection?.contains(revisionId) == true,
        selectionMode: selection != null,
        showCheckbox: selection != null,
        showPin: !trash && selection == null,
        compactActions: splitView,
        avatar: hasConflict ? _conflictAvatar(context) : null,
        onOpen: busy
            ? null
            : () {
                if (splitView) {
                  touch();
                  setState(() {
                    if (selectedEntryId != entryId) {
                      detailRevealPassword = false;
                    }
                    selectedEntryId = entryId;
                  });
                } else {
                  edit(r);
                }
              },
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
                  label: '导出账号',
                  icon: Icons.image_outlined,
                  onTap: () => _exportEntry(data),
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
                  onTap: () => _setDeleted([revisionId], deleted: !trash),
                ),
              ],
            ),
        ],
      );
    }

    final emptyList = WEmptyState(
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
    );

    Widget listCard({EdgeInsets? padding}) => Padding(
      padding: padding ?? const EdgeInsets.fromLTRB(16, 4, 16, 14),
      child: Align(
        alignment: Alignment.topCenter,
        child: WSurface(
          radius: WRadius.lg,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(WRadius.lg),
            child: Scrollbar(
              child: ListView.builder(
                shrinkWrap: !splitView,
                padding: EdgeInsets.only(bottom: desktop ? 6 : 80),
                itemCount: filtered.length,
                itemBuilder: (context, index) => buildRow(filtered[index]),
              ),
            ),
          ),
        ),
      ),
    );

    Widget detailPane() {
      final r = activeRevision;
      if (r == null) {
        return WEmptyState(
          icon: Icons.touch_app_outlined,
          title: '选择一个账号查看详情',
          message: '点击左侧任意账号即可快速复制用户名与密码',
        );
      }
      final data = r['data'] as Map<String, dynamic>;
      final title = (data['title'] as String? ?? '').trim();
      final username = (data['username'] as String? ?? '').trim();
      final password = data['password'] as String? ?? '';
      final url = (data['url'] as String? ?? '').trim();
      final notes = data['notes'] as String? ?? '';
      final groups = _entryGroups(r);
      final pinned = _isPinned(r);
      final hasConflict = revisionCounts[r['entry']]! > 1;
      final revisionId = r['id'] as String;
      return WAccountDetailPanel(
        title: title,
        username: username,
        password: password,
        url: url,
        notes: notes,
        groups: groups,
        pinned: pinned,
        trash: trash,
        hasConflict: hasConflict,
        revealPassword: detailRevealPassword,
        busy: busy,
        avatar: hasConflict ? _conflictAvatar(context) : null,
        onToggleReveal: () {
          touch();
          setState(() => detailRevealPassword = !detailRevealPassword);
        },
        onCopyUsername: username.isEmpty
            ? null
            : () => copy(username, label: '用户名'),
        onCopyPassword: password.isEmpty
            ? null
            : () => copy(password, label: '密码'),
        onCopyUrl: url.isEmpty ? null : () => copy(url, label: '网址'),
        onCopyNotes: notes.trim().isEmpty
            ? null
            : () => copy(notes, label: '备注'),
        onTogglePin: () => _togglePin(r),
        onEdit: () => edit(r),
        onHistory: () => history(r),
        onExport: !trash &&
                !hasConflict &&
                (Platform.isAndroid || Platform.isMacOS || Platform.isWindows)
            ? () => _exportEntry(data)
            : null,
        onTrashOrRestore: !hasConflict
            ? () => _setDeleted([revisionId], deleted: !trash)
            : null,
        onPurge: trash && !hasConflict
            ? () => _setDeleted([revisionId], deleted: true, discard: true)
            : null,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!desktop) searchRow(),
        if (!desktop || trash) ...[const SizedBox(height: 8), chipRow()],
        _buildSyncBanner(context),
        if (_hasActiveMessage)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: _buildStatusPill(context, dismissible: true),
            ),
          ),
        if (deleteSelection case final selection?)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: WSurface(
              padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
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
                    style: TextButton.styleFrom(
                      foregroundColor: c.textSecondary,
                    ),
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
                        textStyle: Theme.of(
                          context,
                        ).textTheme.labelLarge?.copyWith(fontSize: 12),
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
        if (filtered.isEmpty)
          Expanded(child: emptyList)
        else if (splitView)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 0, 0),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    width: MediaQuery.sizeOf(context).width >= 1240 ? 360 : 316,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(4, 0, 2, 6),
                          child: Row(
                            children: [
                              Text(
                                '共 ${_countLabel(filtered.length)} 个账号',
                                style: TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w500,
                                  color: c.textTertiary,
                                ),
                              ),
                              const Spacer(),
                              if (visibleHeads.isNotEmpty)
                                TextButton.icon(
                                  onPressed: busy
                                      ? null
                                      : () =>
                                            setState(() => deleteSelection = {}),
                                  icon: const Icon(
                                    Icons.checklist_rounded,
                                    size: 14,
                                  ),
                                  label: const Text('多选'),
                                  style: TextButton.styleFrom(
                                    foregroundColor: c.textSecondary,
                                    minimumSize: const Size(0, 24),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 6,
                                    ),
                                    textStyle: Theme.of(context)
                                        .textTheme
                                        .labelLarge
                                        ?.copyWith(fontSize: 11.5),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.only(bottom: 16),
                            child: WSurface(
                              radius: WRadius.lg,
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(WRadius.lg),
                                child: Scrollbar(
                                  child: ListView.builder(
                                    padding: const EdgeInsets.only(bottom: 8),
                                    itemCount: filtered.length,
                                    itemBuilder: (context, index) =>
                                        buildRow(filtered[index]),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  VerticalDivider(width: 1, color: c.border),
                  Expanded(child: detailPane()),
                ],
              ),
            ),
          )
        else ...[
          if (deleteSelection == null && visibleHeads.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 16, 4),
              child: Row(
                children: [
                  Text(
                    '共 ${_countLabel(filtered.length)} 个账号',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w500,
                      color: c.textTertiary,
                    ),
                  ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: busy
                        ? null
                        : () => setState(() => deleteSelection = {}),
                    icon: const Icon(Icons.checklist_rounded, size: 14),
                    label: const Text('多选'),
                    style: TextButton.styleFrom(
                      foregroundColor: c.textSecondary,
                      minimumSize: const Size(0, 24),
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      textStyle: Theme.of(
                        context,
                      ).textTheme.labelLarge?.copyWith(fontSize: 11.5),
                    ),
                  ),
                ],
              ),
            ),
          Expanded(child: listCard()),
        ],
      ],
    );
  }

  String _countLabel(int count) => count > 999 ? '999+' : '$count';

  Widget _conflictAvatar(BuildContext context) {
    final c = WColors.of(context);
    return Container(
      width: 32,
      height: 32,
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
      selectedEntryId = null;
      detailRevealPassword = false;
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
      if (!busy)
        WorkspaceCommand(
          '邀请新设备加入',
          Icons.qr_code_2_rounded,
          _openInviteDialog,
        ),
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
  }) {
    final c = WColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: Material(
        color: selected ? c.brandSoft : Colors.transparent,
        borderRadius: BorderRadius.circular(WRadius.sm),
        child: InkWell(
          borderRadius: BorderRadius.circular(WRadius.sm),
          hoverColor: c.hover,
          onTap: onTap,
          child: Container(
            height: 30,
            padding: const EdgeInsets.symmetric(horizontal: 9),
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
                      fontSize: 12.5,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                      color: selected ? c.brand : c.textSecondary,
                    ),
                  ),
                ),
                if (count != null && count > 0) ...[
                  const SizedBox(width: 6),
                  Text(
                    _countLabel(count),
                    style: TextStyle(
                      fontSize: 11,
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
    final activeEntries = entries
        .where((row) => row['deleted'] != true)
        .toList();
    final vaultCount = activeEntries.length;
    final trashCount = entries.length - vaultCount;
    var pinnedCount = 0;
    var ungroupedCount = 0;
    final groupCounts = <String, int>{};
    final groupNames = <String, String>{};
    for (final row in activeEntries) {
      if (_isPinned(row)) pinnedCount++;
      final groups = _entryGroups(row);
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
    final sortedGroups = groupNames.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    final narrow = MediaQuery.sizeOf(context).width < 1020;
    final cmdShortcut = Platform.isMacOS ? '⌘K' : 'Ctrl+K';

    return Container(
      width: narrow ? 186 : 210,
      decoration: BoxDecoration(
        color: c.sidebar,
        border: Border(right: BorderSide(color: c.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
            child: Row(
              children: [
                const WBrandMark(size: 22, radius: 6),
                const SizedBox(width: 8),
                Text(
                  'Wencrypt',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.25,
                    color: c.textPrimary,
                  ),
                ),
                const Spacer(),
                Tooltip(
                  message: '打开命令面板 ($cmdShortcut)',
                  child: InkWell(
                    borderRadius: BorderRadius.circular(5),
                    onTap: token == null ? null : _openCommands,
                    child: WShortcutBadge(label: cmdShortcut),
                  ),
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
          if (pinnedCount > 0)
            _sidebarItem(
              label: '已置顶',
              icon: Icons.push_pin_outlined,
              selected:
                  !showSyncHistory &&
                  !trash &&
                  selectedGroup == EntryFilter.pinned,
              count: pinnedCount,
              onTap: () {
                _selectWorkspace(0);
                _selectGroup(EntryFilter.pinned);
              },
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
          if (sortedGroups.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(17, 16, 16, 6),
              child: Text(
                '分组',
                style: TextStyle(
                  fontSize: 10.8,
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
                  for (final entry in sortedGroups)
                    _sidebarItem(
                      label: entry.value,
                      icon: Icons.folder_outlined,
                      count: groupCounts[entry.key],
                      selected:
                          !showSyncHistory &&
                          !trash &&
                          selectedGroup == entry.key,
                      onTap: () {
                        _selectWorkspace(0);
                        _selectGroup(entry.key);
                      },
                    ),
                  if (ungroupedCount > 0)
                    _sidebarItem(
                      label: '未分组',
                      icon: Icons.label_off_outlined,
                      count: ungroupedCount,
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
                Icon(Icons.shield_outlined, size: 13.5, color: c.success),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '本地加密 · 离线可用',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: c.textTertiary),
                  ),
                ),
                WIconButton(
                  icon: Icons.lock_outline_rounded,
                  tooltip: '锁定密码库',
                  size: 26,
                  iconSize: 15,
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
          label: '主密码与恢复',
          entries: [
            WMenuEntry(
              label: '修改主密码',
              icon: Icons.password_rounded,
              enabled: !busy && !syncing,
              onTap: _changeMasterPassword,
            ),
            WMenuEntry(
              label: '创建主密码恢复文件',
              icon: Icons.vpn_key_outlined,
              enabled: !busy && !syncing,
              onTap: _createRecoveryKit,
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

  WCommandMenu _moreMenu() {
    final dangerEntries = <WMenuEntry>[
      if (token != null && biometricEnabled)
        WMenuEntry(
          label: '关闭指纹解锁',
          icon: Icons.fingerprint_rounded,
          danger: true,
          onTap: disableBiometric,
        ),
      if (token != null && syncConfigured)
        WMenuEntry(
          label: '清除坚果云凭据',
          icon: Icons.link_off_rounded,
          danger: true,
          enabled: !busy && !syncing,
          onTap: forgetSyncSettings,
        ),
    ];

    return WCommandMenu(
      width: 260,
      sections: [
        if (exists)
          WMenuSection(
            label: '数据与备份',
            entries: [
              if (Platform.isMacOS || Platform.isWindows)
                WMenuEntry(
                  label: '从 Edge / Chrome 自动导入',
                  icon: Icons.download_outlined,
                  enabled: !busy,
                  onTap: importFromBrowser,
                ),
              WMenuEntry(
                label: '手动导入浏览器 CSV',
                icon: Icons.file_open_outlined,
                enabled: !busy,
                onTap: importCsv,
              ),
              if (token != null)
                WMenuEntry(
                  label: '导出加密备份',
                  icon: Icons.save_alt_rounded,
                  enabled: !busy,
                  onTap: backup,
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
                label: '邀请新设备加入',
                icon: Icons.qr_code_2_rounded,
                enabled: !busy,
                onTap: _openInviteDialog,
              ),
            ],
          ),
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
          ],
        ),
        if (dangerEntries.isNotEmpty) WMenuSection(entries: dangerEntries),
      ],
      triggerBuilder: (context, controller, open) => WIconButton(
        icon: Icons.more_horiz_rounded,
        tooltip: '更多',
        active: open,
        onPressed: () => open ? controller.close() : controller.open(),
      ),
    );
  }

  Widget _headerActions(BuildContext context) {
    final c = WColors.of(context);
    final syncBadge = initialSyncPending
        ? c.warning
        : remoteUpdateAvailable
        ? c.brand
        : null;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!trash && !showSyncHistory) ...[
          SizedBox(
            height: 32,
            child: FilledButton.icon(
              onPressed: busy ? null : () => edit(null),
              icon: const Icon(Icons.add_rounded, size: 16),
              label: const Text('新增账号'),
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, 32),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                textStyle: Theme.of(
                  context,
                ).textTheme.labelLarge?.copyWith(fontSize: 12.2),
              ),
            ),
          ),
          const SizedBox(width: 8),
        ],
        WIconButton(
          icon: Icons.sync_rounded,
          tooltip: syncing ? '正在同步…' : '立即同步',
          busy: syncing,
          badgeColor: syncBadge,
          onPressed: busy || syncing ? null : sync,
        ),
        const SizedBox(width: 2),
        _settingsMenu(),
        const SizedBox(width: 2),
        _moreMenu(),
      ],
    );
  }

  String _activePageTitle() {
    if (showSyncHistory) return '同步记录';
    if (trash) return '回收站';
    if (selectedGroup == EntryFilter.pinned) return '已置顶';
    if (selectedGroup == EntryFilter.ungrouped) return '未分组';
    if (selectedGroup is String) {
      return _selectedNamedGroup(_groupOptions()) ?? selectedGroup as String;
    }
    return '密码库';
  }

  Widget _pageHeader(BuildContext context, String pageLabel) {
    final c = WColors.of(context);
    final searchShortcut = Platform.isMacOS ? '⌘F' : 'Ctrl+F';
    return Container(
      height: 54,
      padding: const EdgeInsets.symmetric(horizontal: 18),
      color: c.surface,
      child: Row(
        children: [
          Flexible(
            flex: 0,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 160),
              child: Text(
                pageLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.2,
                  color: c.textPrimary,
                ),
              ),
            ),
          ),
          const SizedBox(width: 18),
          if (!showSyncHistory)
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 360),
                  child: WSearchField(
                    controller: searchController,
                    focusNode: searchFocus,
                    hintText: '搜索名称、用户名、网址、分组或备注',
                    shortcutHint: query.isEmpty ? searchShortcut : null,
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
    final pageLabel = !unlocked ? 'Wencrypt' : _activePageTitle();
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
          badgeColor: initialSyncPending
              ? c.warning
              : remoteUpdateAvailable
              ? c.brand
              : null,
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
          if (unlocked && !busy)
            SingleActivator(LogicalKeyboardKey.keyN, meta: mac, control: !mac):
                () {
                  _selectWorkspace(0);
                  edit(null);
                },
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
                !desktop && unlocked && !trash && !showSyncHistory && !busy
                ? WFloatingAction(label: '新增账号', onPressed: () => edit(null))
                : null,
            floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
          ),
        ),
      ),
    );
  }
}

class _InviteDeviceDialog extends StatefulWidget {
  const _InviteDeviceDialog({
    required this.vaultId,
    required this.sessionToken,
    required this.syncConfigured,
    required this.hasSyncTargets,
    required this.invoke,
    required this.onSenderChanged,
    required this.onCopyCode,
    required this.onCopyLegacyLink,
    required this.onActivity,
    required this.describeError,
  });

  final String vaultId;
  final String sessionToken;
  final bool syncConfigured;
  final bool hasSyncTargets;
  final CoreInvoker invoke;
  final ValueChanged<LanTransferSender?> onSenderChanged;
  final Future<void> Function(String value, String label) onCopyCode;
  final Future<void> Function()? onCopyLegacyLink;
  final VoidCallback onActivity;
  final String Function(Object error) describeError;

  @override
  State<_InviteDeviceDialog> createState() => _InviteDeviceDialogState();
}

class _InviteDeviceDialogState extends State<_InviteDeviceDialog> {
  late int _mode; // 0 = offline encrypted invite, 1 = LAN direct

  // Offline invite state
  bool _loadingOffline = false;
  String? _offlineUri;
  int _offlineFolderCount = 0;
  String? _offlineError;

  // LAN transfer state
  bool _includeSync = true;
  bool _startingLan = false;
  LanTransferSender? _sender;
  String? _lanUri;
  String? _lanError;
  bool _lanExpired = false;
  bool _lanCompleted = false;
  int _remainingSeconds = 120;
  Timer? _countdown;
  LanPeerRequest? _pendingPeer;
  Completer<bool>? _peerDecision;
  LanTransferProgress? _lanProgress;

  @override
  void initState() {
    super.initState();
    _mode = widget.syncConfigured ? 0 : 1;
    _includeSync = widget.syncConfigured;
    if (_mode == 0) {
      unawaited(_loadOfflineInvite());
    } else {
      unawaited(_startLan());
    }
  }

  @override
  void dispose() {
    _countdown?.cancel();
    if (_peerDecision != null && !_peerDecision!.isCompleted) {
      _peerDecision!.complete(false);
    }
    _sender?.dispose();
    widget.onSenderChanged(null);
    super.dispose();
  }

  Future<void> _loadOfflineInvite() async {
    if (!widget.syncConfigured || _loadingOffline || _offlineUri != null) {
      return;
    }
    setState(() {
      _loadingOffline = true;
      _offlineError = null;
    });
    try {
      final res = await widget.invoke({'op': 'export_encrypted_invite'});
      final payloadHex = res['payload'] as String;
      final parsed = EncryptedVaultInvite.fromPayloadHex(payloadHex);
      if (parsed == null) throw StateError('invalid_invite');
      if (!mounted) return;
      setState(() {
        _offlineUri = parsed.toUri().toString();
        _offlineFolderCount = (res['folder_count'] as int?) ?? 1;
        _loadingOffline = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _offlineError = widget.describeError(e);
        _loadingOffline = false;
      });
    }
  }

  void _stopLan() {
    _countdown?.cancel();
    _countdown = null;
    if (_peerDecision != null && !_peerDecision!.isCompleted) {
      _peerDecision!.complete(false);
    }
    _peerDecision = null;
    _sender?.dispose();
    _sender = null;
    widget.onSenderChanged(null);
  }

  Future<void> _startLan() async {
    _stopLan();
    setState(() {
      _startingLan = true;
      _lanUri = null;
      _lanError = null;
      _lanExpired = false;
      _lanCompleted = false;
      _pendingPeer = null;
      _lanProgress = null;
      _remainingSeconds = 120;
    });
    try {
      final sender = await LanTransferSender.start(
        vaultId: widget.vaultId,
        sessionToken: widget.sessionToken,
        invoke: widget.invoke,
        includeSyncSettings: _includeSync && widget.syncConfigured,
        onPeerRequest: (peer) async {
          widget.onActivity();
          if (!mounted) return false;
          final decision = Completer<bool>();
          setState(() {
            _pendingPeer = peer;
            _peerDecision = decision;
          });
          return decision.future;
        },
        onProgress: (progress) {
          widget.onActivity();
          if (!mounted) return;
          setState(() => _lanProgress = progress);
        },
        onComplete: () {
          if (!mounted) return;
          _countdown?.cancel();
          setState(() {
            _lanCompleted = true;
            _pendingPeer = null;
          });
        },
        onExpired: () {
          if (_peerDecision != null && !_peerDecision!.isCompleted) {
            _peerDecision!.complete(false);
          }
          _peerDecision = null;
          if (!mounted) return;
          _countdown?.cancel();
          setState(() {
            _lanExpired = true;
            _pendingPeer = null;
            _lanUri = null;
          });
        },
        onError: (err) {
          if (_peerDecision != null && !_peerDecision!.isCompleted) {
            _peerDecision!.complete(false);
          }
          _peerDecision = null;
          if (!mounted) return;
          _countdown?.cancel();
          setState(() {
            _lanError = widget.describeError(err);
            _pendingPeer = null;
          });
        },
      );
      if (!mounted) {
        sender.dispose();
        return;
      }
      widget.onSenderChanged(sender);
      _countdown = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted || _sender == null) return;
        final left = _sender!.expiresAt.difference(DateTime.now()).inSeconds;
        setState(() => _remainingSeconds = left.clamp(0, 120));
      });
      setState(() {
        _sender = sender;
        _lanUri = sender.ticket.toUri().toString();
        _startingLan = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _lanError = widget.describeError(e);
        _startingLan = false;
      });
    }
  }

  void _switchMode(int next) {
    if (_mode == next) return;
    widget.onActivity();
    setState(() => _mode = next);
    if (next == 0) {
      _stopLan();
      unawaited(_loadOfflineInvite());
    } else if (_sender == null && !_lanCompleted) {
      unawaited(_startLan());
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = WColors.of(context);
    final theme = Theme.of(context);
    return WDialog(
      width: 520,
      icon: Icons.qr_code_2_rounded,
      title: '邀请新设备加入',
      subtitle: '免输入坚果云账号与应用密码，通过加密二维码或配对码安全添加设备。',
      footer: WDialogFooter(
        leading: _mode == 0 && widget.onCopyLegacyLink != null
            ? TextButton(
                style: TextButton.styleFrom(foregroundColor: c.textSecondary),
                onPressed: () async {
                  final nav = Navigator.of(context);
                  nav.pop();
                  await widget.onCopyLegacyLink!();
                },
                child: const Text('复制旧版目录链接'),
              )
            : null,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(_lanCompleted ? '完成' : '关闭'),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: WSegmented<int>(
              value: _mode,
              onChanged: _switchMode,
              segments: const [
                (0, '离线加密邀请', Icons.lock_outline_rounded),
                (1, '同 WiFi 直连', Icons.wifi_tethering_rounded),
              ],
            ),
          ),
          const SizedBox(height: 16),
          if (_mode == 0) _buildOfflineTab(c, theme) else _buildLanTab(c, theme),
        ],
      ),
    );
  }

  Widget _buildOfflineTab(WColors c, ThemeData theme) {
    if (!widget.syncConfigured) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const WNote(
            tone: WTone.warning,
            child: Text(
              '离线加密邀请需要将坚果云凭据用主密码加密打包。请先配置坚果云同步，或直接切换到上方「同 WiFi 直连」免云盘传输密码库。',
            ),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () => _switchMode(1),
            icon: const Icon(Icons.wifi_tethering_rounded, size: 16),
            label: const Text('改用同 WiFi 直连'),
          ),
        ],
      );
    }
    if (_loadingOffline) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 48),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    if (_offlineError != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          WNote(tone: WTone.danger, child: Text(_offlineError!)),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: _loadOfflineInvite,
            child: const Text('重试生成'),
          ),
        ],
      );
    }
    final uri = _offlineUri;
    if (uri == null) return const SizedBox.shrink();
    final canQr = utf8.encode(uri).length <= 858;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (canQr)
          WQrCode(data: uri, size: 204)
        else
          const WNote(
            tone: WTone.info,
            icon: Icons.info_outline_rounded,
            child: Text('同步目录较多，超出二维码单码容量，请直接点击下方按钮复制加密邀请码发送给新设备。'),
          ),
        const SizedBox(height: 12),
        Text(
          '已打包 $_offlineFolderCount 个已启用同步目录与加密凭据',
          style: theme.textTheme.bodySmall?.copyWith(
            color: c.textSecondary,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: () => widget.onCopyCode(uri, '加密邀请码'),
            icon: const Icon(Icons.copy_rounded, size: 16),
            label: const Text('复制加密邀请码'),
          ),
        ),
        const SizedBox(height: 12),
        const WNote(
          tone: WTone.info,
          icon: Icons.shield_outlined,
          child: Text(
            '新设备扫码或粘贴后仅需输入 1 次主密码即可自动同步。密文经过 Argon2id 与 AES-256-GCM 保护，通过微信或剪贴板转发同样安全。',
          ),
        ),
      ],
    );
  }

  Widget _buildLanTab(WColors c, ThemeData theme) {
    if (_lanCompleted) {
      return const WNote(
        tone: WTone.success,
        icon: Icons.check_circle_outline_rounded,
        child: Text('传输完成！新设备已安全加入此密码库，临时局域网通道与会话密钥已自动销毁。'),
      );
    }
    if (_pendingPeer case final peer?) {
      final transferring = _peerDecision?.isCompleted == true;
      final frac = _lanProgress?.fraction;
      return WSurface(
        radius: WRadius.lg,
        padding: const EdgeInsets.all(16),
        color: c.surfaceMuted,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.devices_rounded, size: 18, color: c.brand),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '新设备请求加入：${peer.deviceLabel}',
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                WMono(peer.remoteAddress, size: 11, color: c.textTertiary),
              ],
            ),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.symmetric(vertical: 14),
              decoration: BoxDecoration(
                color: c.surface,
                borderRadius: BorderRadius.circular(WRadius.md),
                border: Border.all(color: c.border),
              ),
              child: Column(
                children: [
                  Text(
                    '安全核对码',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: c.textTertiary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    peer.sas,
                    style: TextStyle(
                      fontFamily: wMonoFamily,
                      fontSize: 26,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 3,
                      color: c.brand,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            if (!transferring) ...[
              Text(
                '请确认新设备屏幕显示相同核对码。允许后将在加密信道中直接传输密钥与本地账号。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: c.textSecondary,
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () {
                        if (_peerDecision != null &&
                            !_peerDecision!.isCompleted) {
                          _peerDecision!.complete(false);
                        }
                        setState(() => _pendingPeer = null);
                      },
                      child: const Text('拒绝'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      onPressed: () {
                        if (_peerDecision != null &&
                            !_peerDecision!.isCompleted) {
                          _peerDecision!.complete(true);
                          setState(() {});
                        }
                      },
                      child: const Text('允许传输'),
                    ),
                  ),
                ],
              ),
            ] else ...[
              LinearProgressIndicator(value: frac),
              const SizedBox(height: 8),
              Text(
                _lanProgress == null
                    ? '正在加密打包密码库…'
                    : '正在安全传输 ${_lanProgress!.transferred}/${_lanProgress!.total} 条修订…',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: c.textSecondary,
                ),
              ),
            ],
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.syncConfigured)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: CheckboxListTile(
              dense: true,
              value: _includeSync,
              contentPadding: EdgeInsets.zero,
              onChanged: _startingLan
                  ? null
                  : (v) {
                      setState(() => _includeSync = v == true);
                      unawaited(_startLan());
                    },
              title: const Text('同时传输坚果云同步配置'),
            ),
          ),
        if (_startingLan)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 42),
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          )
        else if (_lanError != null) ...[
          WNote(tone: WTone.danger, child: Text(_lanError!)),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: _startLan,
            child: const Text('重新开启直连'),
          ),
        ] else if (_lanExpired || _lanUri == null) ...[
          const WNote(
            tone: WTone.warning,
            child: Text('本次局域网配对已超时关闭（120 秒），请重新生成一次性配对码。'),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _startLan,
            child: const Text('重新开启（120 秒）'),
          ),
        ] else ...[
          Center(child: WQrCode(data: _lanUri!, size: 196)),
          const SizedBox(height: 10),
          Center(
            child: WMono(
              '${_sender!.ticket.ips.join(' / ')} : ${_sender!.ticket.port} · 剩余 $_remainingSeconds 秒',
              size: 11,
              color: c.textSecondary,
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: () => widget.onCopyCode(_lanUri!, '局域网配对码'),
            icon: const Icon(Icons.copy_rounded, size: 16),
            label: const Text('复制局域网配对码'),
          ),
          const SizedBox(height: 10),
          const WNote(
            tone: WTone.info,
            icon: Icons.wifi_tethering_rounded,
            child: Text(
              '请确保两台设备在同一 WiFi 下。新设备扫码或粘贴后，本机将弹出 6 位安全核对码，确认后免输主密码直接完成加入。',
            ),
          ),
        ],
      ],
    );
  }
}

class _LanJoinDialog extends StatefulWidget {
  const _LanJoinDialog({
    required this.ticket,
    required this.vaultPath,
    required this.deviceLabel,
    required this.invoke,
    required this.describeError,
  });

  final LanTransferTicket ticket;
  final String vaultPath;
  final String deviceLabel;
  final CoreInvoker invoke;
  final String Function(Object error) describeError;

  @override
  State<_LanJoinDialog> createState() => _LanJoinDialogState();
}

class _LanJoinDialogState extends State<_LanJoinDialog> {
  bool _cancelled = false;
  String? _sas;
  LanTransferProgress? _progress;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  @override
  void dispose() {
    _cancelled = true;
    super.dispose();
  }

  Future<void> _run() async {
    try {
      final result = await LanTransferReceiver.join(
        ticket: widget.ticket,
        vaultPath: widget.vaultPath,
        deviceLabel: widget.deviceLabel,
        invoke: widget.invoke,
        onSasReady: (sas) {
          if (mounted) setState(() => _sas = sas);
        },
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
        isCancelled: () => _cancelled || !mounted,
      );
      if (mounted && !_cancelled) {
        Navigator.of(context).pop(result);
      }
    } catch (e) {
      if (!mounted || _cancelled) return;
      setState(() => _error = widget.describeError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = WColors.of(context);
    final theme = Theme.of(context);
    final finished = _error != null;
    return PopScope(
      canPop: finished,
      child: WDialog(
        width: 440,
        icon: Icons.wifi_tethering_rounded,
        title: '同 WiFi 快捷加入',
        subtitle: '端到端加密通道已建立，无需输入主密码或坚果云凭据。',
        footer: WDialogFooter(
          actions: [
            TextButton(
              onPressed: () {
                _cancelled = true;
                Navigator.of(context).pop();
              },
              child: Text(finished ? '关闭' : '取消'),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_error case final err?)
              WNote(tone: WTone.danger, child: Text(err))
            else ...[
              if (_sas case final sas?) ...[
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  decoration: BoxDecoration(
                    color: c.surfaceMuted,
                    borderRadius: BorderRadius.circular(WRadius.md),
                    border: Border.all(color: c.border),
                  ),
                  child: Column(
                    children: [
                      Text(
                        '安全核对码',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: c.textTertiary,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        sas,
                        style: TextStyle(
                          fontFamily: wMonoFamily,
                          fontSize: 26,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 3,
                          color: c.brand,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
              ],
              LinearProgressIndicator(value: _progress?.fraction),
              const SizedBox(height: 10),
              Text(
                _progress != null
                    ? '正在安全接收密码数据 (${_progress!.transferred}/${_progress!.total})…'
                    : _sas != null
                    ? '正在等待原设备核对并允许传输…'
                    : '正在连接原设备 (${widget.ticket.ips.first}:${widget.ticket.port})…',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: c.textSecondary,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
