import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const String kDefaultAppVersion = '0.3.11';
const String kGitHubOwner = 'WendelYu';
const String kGitHubRepo = 'Wencrypt';
const String kGitHubReleasesUrl =
    'https://github.com/$kGitHubOwner/$kGitHubRepo/releases';
const String kGitHubLatestReleaseApiUrl =
    'https://api.github.com/repos/$kGitHubOwner/$kGitHubRepo/releases/latest';
const int kMaxUpdateArchiveBytes = 256 * 1024 * 1024;
const int _kMaxCheckBytes = 1024 * 1024;
const int _kMaxSumsBytes = 256 * 1024;
const int _kMaxRedirects = 5;

enum UpdatePlatform { macos, windows, android, other }

enum UpdateStatus {
  idle,
  checking,
  upToDate,
  available,
  downloading,
  verifying,
  installing,
  error,
}

UpdatePlatform currentUpdatePlatform() {
  if (Platform.isMacOS) return UpdatePlatform.macos;
  if (Platform.isWindows) return UpdatePlatform.windows;
  if (Platform.isAndroid) return UpdatePlatform.android;
  return UpdatePlatform.other;
}

/// Incremental pure-Dart FIPS 180-4 SHA-256 digest implementation.
class Sha256Sink {
  static const List<int> _k = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
    0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
    0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
    0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
    0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
    0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
  ];

  final Uint32List _state = Uint32List.fromList([
    0x6a09e667,
    0xbb67ae85,
    0x3c6ef372,
    0xa54ff53a,
    0x510e527f,
    0x9b05688c,
    0x1f83d9ab,
    0x5be0cd19,
  ]);
  final Uint8List _buffer = Uint8List(64);
  final Uint32List _w = Uint32List(64);
  int _bufferLength = 0;
  int _totalBytes = 0;
  bool _closed = false;

  static int _rotr(int x, int n) =>
      ((x >>> n) | (x << (32 - n))) & 0xffffffff;

  void add(List<int> data) {
    if (_closed) {
      throw StateError('Sha256Sink is already closed');
    }
    var offset = 0;
    final length = data.length;
    _totalBytes += length;

    if (_bufferLength > 0) {
      final take = (64 - _bufferLength).clamp(0, length);
      for (var i = 0; i < take; i++) {
        _buffer[_bufferLength + i] = data[offset + i] & 0xff;
      }
      _bufferLength += take;
      offset += take;
      if (_bufferLength == 64) {
        _transform(_buffer, 0);
        _bufferLength = 0;
      }
    }

    while (offset + 64 <= length) {
      _transform(data, offset);
      offset += 64;
    }

    if (offset < length) {
      for (var i = 0; offset + i < length; i++) {
        _buffer[i] = data[offset + i] & 0xff;
      }
      _bufferLength = length - offset;
    }
  }

  void _transform(List<int> block, int offset) {
    for (var i = 0; i < 16; i++) {
      final j = offset + (i * 4);
      _w[i] = ((block[j] & 0xff) << 24) |
          ((block[j + 1] & 0xff) << 16) |
          ((block[j + 2] & 0xff) << 8) |
          (block[j + 3] & 0xff);
    }
    for (var i = 16; i < 64; i++) {
      final w15 = _w[i - 15];
      final w2 = _w[i - 2];
      final s0 = _rotr(w15, 7) ^ _rotr(w15, 18) ^ (w15 >>> 3);
      final s1 = _rotr(w2, 17) ^ _rotr(w2, 19) ^ (w2 >>> 10);
      _w[i] = (_w[i - 16] + s0 + _w[i - 7] + s1) & 0xffffffff;
    }

    var a = _state[0];
    var b = _state[1];
    var c = _state[2];
    var d = _state[3];
    var e = _state[4];
    var f = _state[5];
    var g = _state[6];
    var h = _state[7];

    for (var i = 0; i < 64; i++) {
      final s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
      final ch = (e & f) ^ ((~e & 0xffffffff) & g);
      final temp1 = (h + s1 + ch + _k[i] + _w[i]) & 0xffffffff;
      final s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final temp2 = (s0 + maj) & 0xffffffff;

      h = g;
      g = f;
      f = e;
      e = (d + temp1) & 0xffffffff;
      d = c;
      c = b;
      b = a;
      a = (temp1 + temp2) & 0xffffffff;
    }

    _state[0] = (_state[0] + a) & 0xffffffff;
    _state[1] = (_state[1] + b) & 0xffffffff;
    _state[2] = (_state[2] + c) & 0xffffffff;
    _state[3] = (_state[3] + d) & 0xffffffff;
    _state[4] = (_state[4] + e) & 0xffffffff;
    _state[5] = (_state[5] + f) & 0xffffffff;
    _state[6] = (_state[6] + g) & 0xffffffff;
    _state[7] = (_state[7] + h) & 0xffffffff;
  }

  String closeAndHex() {
    if (!_closed) {
      final bitLengthHi = (_totalBytes >>> 29) & 0xffffffff;
      final bitLengthLo = (_totalBytes << 3) & 0xffffffff;
      _buffer[_bufferLength++] = 0x80;
      if (_bufferLength > 56) {
        while (_bufferLength < 64) {
          _buffer[_bufferLength++] = 0;
        }
        _transform(_buffer, 0);
        _bufferLength = 0;
      }
      while (_bufferLength < 56) {
        _buffer[_bufferLength++] = 0;
      }
      _buffer[56] = (bitLengthHi >>> 24) & 0xff;
      _buffer[57] = (bitLengthHi >>> 16) & 0xff;
      _buffer[58] = (bitLengthHi >>> 8) & 0xff;
      _buffer[59] = bitLengthHi & 0xff;
      _buffer[60] = (bitLengthLo >>> 24) & 0xff;
      _buffer[61] = (bitLengthLo >>> 16) & 0xff;
      _buffer[62] = (bitLengthLo >>> 8) & 0xff;
      _buffer[63] = bitLengthLo & 0xff;
      _transform(_buffer, 0);
      _closed = true;
    }
    final out = StringBuffer();
    for (var i = 0; i < 8; i++) {
      out.write(_state[i].toRadixString(16).padLeft(8, '0'));
    }
    return out.toString();
  }
}

String sha256Hex(List<int> bytes) {
  final sink = Sha256Sink()..add(bytes);
  return sink.closeAndHex();
}

/// Semantic version parser and comparator supporting optional `v` prefix,
/// pre-release suffix, and `+build` metadata.
class AppVersion implements Comparable<AppVersion> {
  const AppVersion(
    this.major,
    this.minor,
    this.patch, {
    this.preRelease = '',
    this.build = '',
  });

  final int major;
  final int minor;
  final int patch;
  final String preRelease;
  final String build;

  static final RegExp _pattern = RegExp(
    r'^v?(\d+)\.(\d+)(?:\.(\d+))?(?:-([0-9A-Za-z.-]+))?(?:\+([0-9A-Za-z.-]+))?$',
  );

  static AppVersion? tryParse(String raw) {
    final trimmed = raw.trim();
    final match = _pattern.firstMatch(trimmed);
    if (match == null) return null;
    final major = int.tryParse(match.group(1)!);
    final minor = int.tryParse(match.group(2)!);
    final patch = match.group(3) == null ? 0 : int.tryParse(match.group(3)!);
    if (major == null || minor == null || patch == null) return null;
    return AppVersion(
      major,
      minor,
      patch,
      preRelease: match.group(4) ?? '',
      build: match.group(5) ?? '',
    );
  }

  String get normalized => preRelease.isEmpty
      ? '$major.$minor.$patch'
      : '$major.$minor.$patch-$preRelease';

  bool isNewerThan(AppVersion other) => compareTo(other) > 0;

  @override
  int compareTo(AppVersion other) {
    if (major != other.major) return major.compareTo(other.major);
    if (minor != other.minor) return minor.compareTo(other.minor);
    if (patch != other.patch) return patch.compareTo(other.patch);
    if (preRelease == other.preRelease) return 0;
    if (preRelease.isEmpty) return 1;
    if (other.preRelease.isEmpty) return -1;

    final left = preRelease.split('.');
    final right = other.preRelease.split('.');
    final len = left.length < right.length ? left.length : right.length;
    for (var i = 0; i < len; i++) {
      final a = left[i];
      final b = right[i];
      final ai = int.tryParse(a);
      final bi = int.tryParse(b);
      if (ai != null && bi != null) {
        if (ai != bi) return ai.compareTo(bi);
      } else if (ai != null) {
        return -1;
      } else if (bi != null) {
        return 1;
      } else {
        final cmp = a.compareTo(b);
        if (cmp != 0) return cmp;
      }
    }
    return left.length.compareTo(right.length);
  }

  @override
  bool operator ==(Object other) =>
      other is AppVersion &&
      major == other.major &&
      minor == other.minor &&
      patch == other.patch &&
      preRelease == other.preRelease &&
      build == other.build;

  @override
  int get hashCode => Object.hash(major, minor, patch, preRelease, build);
}

/// Parses `SHA256SUMS.txt` content (`<64-hex>  <filename>`) into basename -> hex.
Map<String, String> parseSha256Sums(String content) {
  final linePattern = RegExp(r'^\s*([0-9a-fA-F]{64})\s+\*?([^\r\n]+?)\s*$');
  final hashes = <String, String>{};
  for (final line in const LineSplitter().convert(content)) {
    final match = linePattern.firstMatch(line);
    if (match == null) continue;
    final hash = match.group(1)!.toLowerCase();
    final rawPath = match.group(2)!.trim();
    final fileName = rawPath.split('/').last.split(r'\').last;
    if (fileName.isNotEmpty) {
      hashes[fileName] = hash;
    }
  }
  return hashes;
}

/// Restricts update API/download requests strictly to GitHub HTTPS origins.
bool isTrustedGitHubUrl(Uri uri) {
  if (uri.scheme.toLowerCase() != 'https') return false;
  if (uri.userInfo.isNotEmpty) return false;
  final host = uri.host.toLowerCase();
  return host == 'github.com' ||
      host == 'api.github.com' ||
      host.endsWith('.githubusercontent.com');
}

class ReleaseAssetSelection {
  const ReleaseAssetSelection({
    this.assetName,
    this.downloadUrl,
    this.sizeBytes,
    this.canInstallAsset = false,
    this.sha256AssetUrl,
  });

  final String? assetName;
  final String? downloadUrl;
  final int? sizeBytes;
  final bool canInstallAsset;
  final String? sha256AssetUrl;
}

ReleaseAssetSelection selectReleaseAsset(
  List<Map<String, dynamic>> assets,
  UpdatePlatform platform,
) {
  String? sha256Url;
  Map<String, dynamic>? findBySuffix(String suffix) {
    for (final asset in assets) {
      final name = (asset['name'] as String? ?? '').toLowerCase();
      if (name.endsWith(suffix)) return asset;
    }
    return null;
  }

  for (final asset in assets) {
    final name = asset['name'] as String? ?? '';
    if (name.toUpperCase() == 'SHA256SUMS.TXT') {
      sha256Url = asset['browser_download_url'] as String?;
      break;
    }
  }

  Map<String, dynamic>? chosen;
  var installable = false;
  switch (platform) {
    case UpdatePlatform.macos:
      chosen = findBySuffix('-macos-arm64.dmg') ?? findBySuffix('-macos-arm64.zip');
      installable = chosen != null;
      break;
    case UpdatePlatform.windows:
      chosen = findBySuffix('-windows-x64.zip');
      installable = chosen != null;
      break;
    case UpdatePlatform.android:
      chosen = findBySuffix('-android-arm64.apk');
      installable = false;
      break;
    case UpdatePlatform.other:
      chosen = null;
      installable = false;
      break;
  }

  return ReleaseAssetSelection(
    assetName: chosen?['name'] as String?,
    downloadUrl: chosen?['browser_download_url'] as String?,
    sizeBytes: (chosen?['size'] as num?)?.toInt(),
    canInstallAsset: installable,
    sha256AssetUrl: sha256Url,
  );
}

class UpdateReleaseInfo {
  const UpdateReleaseInfo({
    required this.version,
    required this.tagName,
    required this.releaseUrl,
    required this.notes,
    this.publishedAt,
    this.assetName,
    this.downloadUrl,
    this.assetSizeBytes,
    this.sha256AssetUrl,
    this.canInstallAsset = false,
  });

  final AppVersion version;
  final String tagName;
  final String releaseUrl;
  final String notes;
  final DateTime? publishedAt;
  final String? assetName;
  final String? downloadUrl;
  final int? assetSizeBytes;
  final String? sha256AssetUrl;
  final bool canInstallAsset;
}

class AppRuntimeInfo {
  const AppRuntimeInfo({
    this.version = kDefaultAppVersion,
    this.buildNumber = '1',
    this.installPath = '',
    this.canAutoInstall = false,
    this.isSandboxed = false,
  });

  final String version;
  final String buildNumber;
  final String installPath;
  final bool canAutoInstall;
  final bool isSandboxed;
}

class UpdatePreferences {
  const UpdatePreferences({this.autoCheckEnabled = true});

  final bool autoCheckEnabled;

  static File _prefsFile(Directory appDataDir) =>
      File('${appDataDir.path}/app-update-prefs.json');

  static Future<UpdatePreferences> load(Directory appDataDir) async {
    try {
      final file = _prefsFile(appDataDir);
      if (!await file.exists()) return const UpdatePreferences();
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map<String, dynamic>) {
        final auto = decoded['autoCheckEnabled'];
        return UpdatePreferences(
          autoCheckEnabled: auto is bool ? auto : true,
        );
      }
    } catch (_) {
      // Fall back to defaults on corrupted/unreadable preferences.
    }
    return const UpdatePreferences();
  }

  Future<void> save(Directory appDataDir) async {
    await appDataDir.create(recursive: true);
    final file = _prefsFile(appDataDir);
    final temp = File('${file.path}.$pid.tmp');
    await temp.writeAsString(
      jsonEncode({'autoCheckEnabled': autoCheckEnabled}),
      flush: true,
    );
    await temp.rename(file.path);
  }
}

abstract class AppUpdaterBridge {
  Future<AppRuntimeInfo> getAppInfo();
  Future<bool> openDirectory(String path);
  Future<bool> openUrl(String url);
  Future<bool> installAndRestart({
    required String archivePath,
    required String expectedSha256,
  });
}

class MethodChannelAppUpdaterBridge implements AppUpdaterBridge {
  const MethodChannelAppUpdaterBridge([
    this.channel = const MethodChannel('org.wencrypt.updater'),
  ]);

  final MethodChannel channel;

  @override
  Future<AppRuntimeInfo> getAppInfo() async {
    try {
      final raw = await channel.invokeMapMethod<String, dynamic>('getAppInfo');
      if (raw == null) return const AppRuntimeInfo();
      return AppRuntimeInfo(
        version: (raw['version'] as String?)?.trim().isNotEmpty == true
            ? (raw['version'] as String).trim()
            : kDefaultAppVersion,
        buildNumber: (raw['buildNumber'] as String?) ?? '1',
        installPath: (raw['installPath'] as String?) ?? '',
        canAutoInstall: raw['canAutoInstall'] == true,
        isSandboxed: raw['isSandboxed'] == true,
      );
    } on MissingPluginException {
      return const AppRuntimeInfo();
    }
  }

  @override
  Future<bool> openDirectory(String path) async {
    if (path.trim().isEmpty) return false;
    try {
      return (await channel.invokeMethod<bool>('openDirectory', path)) ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<bool> openUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme.toLowerCase() != 'https') return false;
    try {
      return (await channel.invokeMethod<bool>('openUrl', url)) ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<bool> installAndRestart({
    required String archivePath,
    required String expectedSha256,
  }) async {
    final result = await channel.invokeMethod<bool>('installAndRestart', {
      'archivePath': archivePath,
      'sha256': expectedSha256,
    });
    return result ?? false;
  }
}

class _NoopUpdaterBridge implements AppUpdaterBridge {
  const _NoopUpdaterBridge(this.runtimeInfo);
  final AppRuntimeInfo runtimeInfo;

  @override
  Future<AppRuntimeInfo> getAppInfo() async => runtimeInfo;

  @override
  Future<bool> openDirectory(String path) async => false;

  @override
  Future<bool> openUrl(String url) async => false;

  @override
  Future<bool> installAndRestart({
    required String archivePath,
    required String expectedSha256,
  }) async =>
      false;
}

class _ValidatedHttpResult {
  const _ValidatedHttpResult({
    required this.statusCode,
    required this.bytes,
  });

  final int statusCode;
  final Uint8List bytes;
}

class AppUpdateController extends ChangeNotifier {
  AppUpdateController({
    AppUpdaterBridge? bridge,
    HttpClient Function()? httpClientFactory,
    UpdatePlatform? platformOverride,
    Future<Directory> Function()? tempDirProvider,
    Uri? latestReleaseApiUri,
    this.allowUntrustedHostsForTest = false,
  })  : _bridge = bridge ?? const MethodChannelAppUpdaterBridge(),
        _httpClientFactory = httpClientFactory ?? _defaultHttpClient,
        platform = platformOverride ?? currentUpdatePlatform(),
        _tempDirProvider = tempDirProvider ?? (() async => Directory.systemTemp),
        latestReleaseApiUri =
            latestReleaseApiUri ?? Uri.parse(kGitHubLatestReleaseApiUrl);

  factory AppUpdateController.preview({
    UpdatePlatform? platformOverride,
    String currentVersion = kDefaultAppVersion,
    UpdateStatus status = UpdateStatus.upToDate,
    bool autoCheckEnabled = true,
    String dataDirectoryPath = '/preview/org.wencrypt.wencrypt',
    String installPath = '/Applications/Wencrypt.app',
    bool canAutoInstall = true,
    bool isSandboxed = false,
    UpdateReleaseInfo? latestRelease,
    int downloadedBytes = 0,
    int? totalBytes,
    String? errorMessage,
    DateTime? lastCheckedAt,
    AppUpdaterBridge? bridge,
  }) =>
      AppUpdateController._preview(
        bridge ??
            _NoopUpdaterBridge(
              AppRuntimeInfo(
                version: currentVersion,
                installPath: installPath,
                canAutoInstall: canAutoInstall,
                isSandboxed: isSandboxed,
              ),
            ),
        platformOverride ?? UpdatePlatform.macos,
        AppRuntimeInfo(
          version: currentVersion,
          installPath: installPath,
          canAutoInstall: canAutoInstall,
          isSandboxed: isSandboxed,
        ),
        status,
        autoCheckEnabled,
        dataDirectoryPath,
        latestRelease,
        downloadedBytes,
        totalBytes,
        errorMessage,
        lastCheckedAt,
      );

  AppUpdateController._preview(
    this._bridge,
    this.platform,
    this._runtimeInfo,
    this._status,
    this._autoCheckEnabled,
    this._dataDirectoryPath,
    this._latestRelease,
    this._downloadedBytes,
    this._totalBytes,
    this._errorMessage,
    this._lastCheckedAt,
  ) : _httpClientFactory = _defaultHttpClient,
      _tempDirProvider = (() async => Directory.systemTemp),
      latestReleaseApiUri = Uri.parse(kGitHubLatestReleaseApiUrl),
      allowUntrustedHostsForTest = false;

  static HttpClient _defaultHttpClient() =>
      HttpClient()..connectionTimeout = const Duration(seconds: 15);

  final AppUpdaterBridge _bridge;
  final HttpClient Function() _httpClientFactory;
  final UpdatePlatform platform;
  final Future<Directory> Function() _tempDirProvider;
  final Uri latestReleaseApiUri;
  final bool allowUntrustedHostsForTest;

  Directory? _appDataDir;
  AppRuntimeInfo _runtimeInfo = const AppRuntimeInfo();
  UpdateStatus _status = UpdateStatus.idle;
  UpdateReleaseInfo? _latestRelease;
  bool _autoCheckEnabled = true;
  String _dataDirectoryPath = '';
  int _downloadedBytes = 0;
  int? _totalBytes;
  String? _errorMessage;
  DateTime? _lastCheckedAt;
  bool _disposed = false;

  AppRuntimeInfo get runtimeInfo => _runtimeInfo;
  String get currentVersion => _runtimeInfo.version;
  UpdateStatus get status => _status;
  UpdateReleaseInfo? get latestRelease => _latestRelease;
  bool get autoCheckEnabled => _autoCheckEnabled;
  String get dataDirectoryPath => _dataDirectoryPath;
  int get downloadedBytes => _downloadedBytes;
  int? get totalBytes => _totalBytes;
  String? get errorMessage => _errorMessage;
  DateTime? get lastCheckedAt => _lastCheckedAt;

  bool get isBusy =>
      _status == UpdateStatus.checking ||
      _status == UpdateStatus.downloading ||
      _status == UpdateStatus.verifying ||
      _status == UpdateStatus.installing;

  bool get hasUpdate {
    final release = _latestRelease;
    if (release == null) return false;
    final current = AppVersion.tryParse(_runtimeInfo.version);
    if (current == null) return false;
    return release.version.isNewerThan(current);
  }

  bool get canInstallInApp {
    final release = _latestRelease;
    return hasUpdate &&
        release != null &&
        _runtimeInfo.canAutoInstall &&
        release.canInstallAsset &&
        release.downloadUrl != null &&
        release.sha256AssetUrl != null;
  }

  double? get downloadProgress {
    final total = _totalBytes;
    if (total == null || total <= 0) return null;
    return (_downloadedBytes / total).clamp(0.0, 1.0);
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  Future<void> initialize(Directory? appDataDir) async {
    _appDataDir = appDataDir;
    if (appDataDir != null) {
      _dataDirectoryPath = appDataDir.path;
      final prefs = await UpdatePreferences.load(appDataDir);
      _autoCheckEnabled = prefs.autoCheckEnabled;
    }
    _runtimeInfo = await _bridge.getAppInfo();
    _notify();
    if (_autoCheckEnabled && !_disposed) {
      unawaited(checkForUpdates(silent: true));
    }
  }

  Future<void> setAutoCheckEnabled(bool enabled) async {
    _autoCheckEnabled = enabled;
    _notify();
    final dir = _appDataDir;
    if (dir != null) {
      try {
        await UpdatePreferences(autoCheckEnabled: enabled).save(dir);
      } catch (_) {
        // Ignore disk preference write failures.
      }
    }
  }

  Future<void> checkForUpdates({bool silent = false}) async {
    if (isBusy || _disposed) return;
    final previousStatus = _status;
    _status = UpdateStatus.checking;
    if (!silent) {
      _errorMessage = null;
    }
    _notify();

    try {
      final response = await _fetchBytes(
        latestReleaseApiUri,
        headers: {
          'Accept': 'application/vnd.github+json',
          'User-Agent': 'Wencrypt/${_runtimeInfo.version}',
        },
        maxBytes: _kMaxCheckBytes,
      );

      if (response.statusCode == 403 || response.statusCode == 429) {
        if (silent) {
          _status = previousStatus == UpdateStatus.checking
              ? UpdateStatus.idle
              : previousStatus;
          _notify();
          return;
        }
        _status = UpdateStatus.error;
        _errorMessage = 'GitHub 请求暂时受限，请稍后再试或前往 Releases 页面查看。';
        _notify();
        return;
      }

      if (response.statusCode != 200) {
        if (silent) {
          _status = previousStatus == UpdateStatus.checking
              ? UpdateStatus.idle
              : previousStatus;
          _notify();
          return;
        }
        _status = UpdateStatus.error;
        _errorMessage = '检查更新失败（HTTP ${response.statusCode}）。';
        _notify();
        return;
      }

      final decoded = jsonDecode(utf8.decode(response.bytes));
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Unexpected GitHub release payload');
      }

      final tagName = (decoded['tag_name'] as String? ?? '').trim();
      final parsedVersion = AppVersion.tryParse(tagName);
      if (parsedVersion == null) {
        throw const FormatException('Invalid release version tag');
      }

      final rawAssets = decoded['assets'];
      final assets = rawAssets is List
          ? rawAssets.whereType<Map<String, dynamic>>().toList()
          : const <Map<String, dynamic>>[];
      final selected = selectReleaseAsset(assets, platform);

      _latestRelease = UpdateReleaseInfo(
        version: parsedVersion,
        tagName: tagName,
        releaseUrl: (decoded['html_url'] as String?) ?? kGitHubReleasesUrl,
        notes: (decoded['body'] as String? ?? '').trim(),
        publishedAt: DateTime.tryParse(
          decoded['published_at'] as String? ?? '',
        ),
        assetName: selected.assetName,
        downloadUrl: selected.downloadUrl,
        assetSizeBytes: selected.sizeBytes,
        sha256AssetUrl: selected.sha256AssetUrl,
        canInstallAsset: selected.canInstallAsset,
      );
      _lastCheckedAt = DateTime.now();
      _errorMessage = null;

      final current =
          AppVersion.tryParse(_runtimeInfo.version) ??
          AppVersion.tryParse(kDefaultAppVersion)!;
      _status = parsedVersion.isNewerThan(current)
          ? UpdateStatus.available
          : UpdateStatus.upToDate;
      _notify();
    } catch (_) {
      if (_disposed) return;
      if (silent) {
        _status = previousStatus == UpdateStatus.checking
            ? UpdateStatus.idle
            : previousStatus;
      } else {
        _status = UpdateStatus.error;
        _errorMessage = '检查更新失败：无法连接 GitHub，请检查网络后重试。';
      }
      _notify();
    }
  }

  Future<bool> downloadAndInstallUpdate({
    Future<void> Function()? beforeRestart,
  }) async {
    final release = _latestRelease;
    if (isBusy || _disposed || release == null || !hasUpdate) return false;

    if (!_runtimeInfo.canAutoInstall) {
      _status = UpdateStatus.error;
      _errorMessage = _runtimeInfo.isSandboxed
          ? '当前运行于受限沙盒构建，请前往 GitHub Releases 下载并安装支持应用内更新的新版。'
          : '当前安装目录没有写入权限，请点击「前往下载」手动更新。';
      _notify();
      return false;
    }

    if (!release.canInstallAsset ||
        release.downloadUrl == null ||
        release.assetName == null ||
        release.sha256AssetUrl == null) {
      _status = UpdateStatus.error;
      _errorMessage = '该版本未提供可用于自动更新的校验包，请前往 GitHub Releases 手动下载。';
      _notify();
      return false;
    }

    File? archiveFile;
    try {
      _status = UpdateStatus.verifying;
      _downloadedBytes = 0;
      _totalBytes = release.assetSizeBytes;
      _errorMessage = null;
      _notify();

      final sumsResponse = await _fetchBytes(
        Uri.parse(release.sha256AssetUrl!),
        headers: {'User-Agent': 'Wencrypt/${_runtimeInfo.version}'},
        maxBytes: _kMaxSumsBytes,
      );
      if (sumsResponse.statusCode != 200) {
        throw const HttpException('Failed to fetch SHA256SUMS.txt');
      }

      final sums = parseSha256Sums(utf8.decode(sumsResponse.bytes));
      final expectedSha = sums[release.assetName!];
      if (expectedSha == null || expectedSha.length != 64) {
        throw const FormatException('Missing SHA-256 entry for release asset');
      }

      _status = UpdateStatus.downloading;
      _notify();

      final tempDir = await _tempDirProvider();
      await tempDir.create(recursive: true);
      final safeName = release.assetName!.replaceAll(
        RegExp(r'[^A-Za-z0-9._-]'),
        '_',
      );
      archiveFile = File(
        '${tempDir.path}${Platform.pathSeparator}wencrypt-upd-${DateTime.now().millisecondsSinceEpoch}-$safeName',
      );

      final actualSha = await _downloadVerifiedArchive(
        Uri.parse(release.downloadUrl!),
        archiveFile,
        fallbackTotalBytes: release.assetSizeBytes,
      );

      _status = UpdateStatus.verifying;
      _notify();

      if (actualSha.toLowerCase() != expectedSha.toLowerCase()) {
        await _deleteQuietly(archiveFile);
        _status = UpdateStatus.error;
        _errorMessage = '校验失败：安装包 SHA-256 摘要不匹配，已取消安装。';
        _notify();
        return false;
      }

      _status = UpdateStatus.installing;
      _notify();

      await beforeRestart?.call();

      final launched = await _bridge.installAndRestart(
        archivePath: archiveFile.path,
        expectedSha256: expectedSha,
      );
      if (!launched) {
        await _deleteQuietly(archiveFile);
        _status = UpdateStatus.error;
        _errorMessage = '无法启动更新安装程序，请尝试前往 GitHub Releases 手动下载。';
        _notify();
        return false;
      }
      return true;
    } on PlatformException catch (error) {
      await _deleteQuietly(archiveFile);
      if (!_disposed) {
        _status = UpdateStatus.error;
        _errorMessage = _describeNativeError(error.code);
        _notify();
      }
      return false;
    } on FormatException {
      await _deleteQuietly(archiveFile);
      if (!_disposed) {
        _status = UpdateStatus.error;
        _errorMessage = '校验文件不包含当前安装包摘要，已取消自动安装。';
        _notify();
      }
      return false;
    } catch (_) {
      await _deleteQuietly(archiveFile);
      if (!_disposed) {
        _status = UpdateStatus.error;
        _errorMessage = '下载或校验更新包失败，请检查网络后重试。';
        _notify();
      }
      return false;
    }
  }

  String _describeNativeError(String code) => switch (code) {
    'install_location_readonly' =>
      '当前安装目录没有写入权限，请先将应用移到可写目录或手动下载覆盖。',
    'checksum_mismatch' => '本地二次校验未通过，安装包哈希不匹配。',
    'invalid_archive' => '安装包解压失败，文件可能已损坏。',
    'bundle_validation_failed' => '更新包完整性校验未通过（签名或应用标识不匹配）。',
    _ => '应用内安装失败，请点击「前往下载」手动替换。',
  };

  Future<void> openDataDirectory() async {
    if (_dataDirectoryPath.isEmpty) return;
    await _bridge.openDirectory(_dataDirectoryPath);
  }

  Future<void> openReleasesPage() => _bridge.openUrl(kGitHubReleasesUrl);

  Future<void> openLatestReleasePage() {
    final target = _latestRelease?.releaseUrl ?? kGitHubReleasesUrl;
    return _bridge.openUrl(target);
  }

  void _validateUri(Uri uri) {
    if (allowUntrustedHostsForTest) {
      final host = uri.host.toLowerCase();
      if (host == '127.0.0.1' || host == 'localhost' || host == '::1') {
        return;
      }
    }
    if (!isTrustedGitHubUrl(uri)) {
      throw const HttpException('Untrusted update host');
    }
  }

  Future<HttpClientResponse> _openValidatedStream(
    HttpClient client,
    Uri initialUri,
    Map<String, String> headers,
  ) async {
    var current = initialUri;
    for (var hop = 0; hop <= _kMaxRedirects; hop++) {
      _validateUri(current);
      final request = await client.getUrl(current);
      request.followRedirects = false;
      for (final entry in headers.entries) {
        request.headers.set(entry.key, entry.value);
      }
      final response = await request.close();
      final status = response.statusCode;
      if (status == 301 ||
          status == 302 ||
          status == 303 ||
          status == 307 ||
          status == 308) {
        await response.drain<void>();
        final location = response.headers.value(HttpHeaders.locationHeader);
        if (location == null || location.isEmpty) {
          throw const HttpException('Redirect missing Location header');
        }
        current = current.resolve(location);
        continue;
      }
      return response;
    }
    throw const HttpException('Too many redirects');
  }

  Future<_ValidatedHttpResult> _fetchBytes(
    Uri uri, {
    required Map<String, String> headers,
    required int maxBytes,
  }) async {
    final client = _httpClientFactory();
    try {
      final response = await _openValidatedStream(client, uri, headers);
      if (response.contentLength > maxBytes) {
        await response.drain<void>();
        throw const HttpException('Response exceeded size limit');
      }
      final builder = BytesBuilder(copy: false);
      await for (final chunk in response) {
        if (builder.length + chunk.length > maxBytes) {
          throw const HttpException('Response exceeded size limit');
        }
        builder.add(chunk);
      }
      return _ValidatedHttpResult(
        statusCode: response.statusCode,
        bytes: builder.takeBytes(),
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<String> _downloadVerifiedArchive(
    Uri uri,
    File targetFile, {
    int? fallbackTotalBytes,
  }) async {
    final client = _httpClientFactory();
    IOSink? sink;
    try {
      final response = await _openValidatedStream(client, uri, {
        'User-Agent': 'Wencrypt/${_runtimeInfo.version}',
      });
      if (response.statusCode != 200) {
        await response.drain<void>();
        throw HttpException('Download failed with HTTP ${response.statusCode}');
      }
      final headerLength = response.contentLength;
      if (headerLength > kMaxUpdateArchiveBytes) {
        await response.drain<void>();
        throw const HttpException('Archive exceeded max allowed size');
      }
      _totalBytes = headerLength > 0 ? headerLength : fallbackTotalBytes;
      _downloadedBytes = 0;
      _notify();

      sink = targetFile.openWrite();
      final sha = Sha256Sink();
      var received = 0;
      var lastNotifiedBytes = 0;

      await for (final chunk in response) {
        received += chunk.length;
        if (received > kMaxUpdateArchiveBytes) {
          throw const HttpException('Archive exceeded max allowed size');
        }
        sha.add(chunk);
        sink.add(chunk);
        _downloadedBytes = received;
        if (received - lastNotifiedBytes >= 65536 ||
            (_totalBytes != null && received >= _totalBytes!)) {
          lastNotifiedBytes = received;
          _notify();
        }
      }
      await sink.flush();
      await sink.close();
      sink = null;
      return sha.closeAndHex();
    } finally {
      await sink?.close();
      client.close(force: true);
    }
  }

  Future<void> _deleteQuietly(File? file) async {
    if (file == null) return;
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {
      // Best-effort cleanup.
    }
  }
}
