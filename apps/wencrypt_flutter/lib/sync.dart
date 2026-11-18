import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:xml/xml.dart';

typedef VaultRequest = Future<Map<String, dynamic>> Function(
  String, [
  Map<String, dynamic>,
]);

/// Conservative per-installation limits. Three installations reserve <=300/900 MiB monthly.
/// Other clients and account activity still consume the provider's separate account quota.
class SyncBudget {
  SyncBudget(this.file);
  final File file;
  Future<void> reserve(int upload, int download) async {
    final guard = await File('${file.path}.lock').open(mode: FileMode.append);
    try {
      await guard.lock(FileLock.exclusive);
      await _reserve(upload, download);
    } finally {
      await guard.unlock();
      await guard.close();
    }
  }

  Future<void> settleDownload(int unused, String reservedMonth) async {
    if (unused <= 0) return;
    final guard = await File('${file.path}.lock').open(mode: FileMode.append);
    try {
      await guard.lock(FileLock.exclusive);
      if (!await file.exists()) return;
      final data =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      if (data['month'] != reservedMonth) return;
      data['down'] = ((data['down'] as int) - unused).clamp(
        0,
        300 * 1024 * 1024,
      );
      final temp = File('${file.path}.tmp');
      await temp.writeAsString(jsonEncode(data), flush: true);
      await temp.rename(file.path);
    } finally {
      await guard.unlock();
      await guard.close();
    }
  }

  Future<void> _reserve(int upload, int download) async {
    final now = DateTime.now().toUtc();
    final month = '${now.year}-${now.month.toString().padLeft(2, '0')}';
    Map<String, dynamic> data = await file.exists()
        ? jsonDecode(await file.readAsString()) as Map<String, dynamic>
        : {};
    if (data['month'] != null &&
        (data['month'] as String).compareTo(month) > 0) {
      throw StateError('clock_rollback');
    }
    if (data['month'] != month) {
      data = {'month': month, 'up': 0, 'down': 0, 'requests': <int>[]};
    }
    final recent = (data['requests'] as List)
        .cast<int>()
        .where((t) => t > now.millisecondsSinceEpoch - 30 * 60 * 1000)
        .toList();
    if (recent.any((t) => t > now.millisecondsSinceEpoch)) {
      throw StateError('clock_rollback');
    }
    if (recent.length >= 80 ||
        (data['up'] as int) + upload > 100 * 1024 * 1024 ||
        (data['down'] as int) + download > 300 * 1024 * 1024) {
      throw StateError('free_budget_reached');
    }
    data['up'] = (data['up'] as int) + upload;
    data['down'] = (data['down'] as int) + download;
    recent.add(now.millisecondsSinceEpoch);
    data['requests'] = recent;
    // Reserve before issuing the request. Interrupted requests are not refunded.
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(jsonEncode(data), flush: true);
    await temporary.rename(file.path);
  }
}

class DavFailure implements Exception {
  const DavFailure(this.stage, this.reason, [this.status]);
  final String stage, reason;
  final int? status;
  Map<String, dynamic> get diagnostic => {
    'stage': stage,
    'reason': reason,
    if (status != null) 'http_status': status,
  };
  @override
  String toString() =>
      '同步失败 [$stage / $reason${status == null ? '' : ' / HTTP $status'}]';
}

class DavReply {
  DavReply(this.status, List<int> body) : body = Uint8List.fromList(body);
  final int status;
  final Uint8List body;
}

typedef DavWire = Future<DavReply> Function(
  String method,
  Uri uri,
  List<int> body,
  String depth,
  int limit,
);

enum DavContents { vault, packBuckets, packs }

final _revisionFile = RegExp(r'^[0-9a-f]{64}\.wenc$');
final _packFile = RegExp(r'^[0-9a-f]{64}\.pack$');
final _bucketName = RegExp(r'^[01][0-9a-f]$');

Set<String> parseDavListing(
  List<int> bytes,
  Uri folder, {
  DavContents contents = DavContents.vault,
}) {
  final text = utf8.decode(bytes);
  if (text.toUpperCase().contains('<!DOCTYPE') ||
      text.toUpperCase().contains('<!ENTITY')) {
    throw const DavFailure('list', 'unsafe_xml');
  }
  final document = XmlDocument.parse(text);
  final root = document.rootElement;
  if (root.name.local != 'multistatus' || root.namespaceUri != 'DAV:') {
    throw const DavFailure('list', 'invalid_multistatus');
  }
  final responses = root
      .findElements('response', namespaceUri: 'DAV:')
      .toList();
  if (responses.length >= 750) {
    throw const DavFailure('list', 'directory_limit');
  }
  final names = <String>{};
  bool self = false;
  for (final response in responses) {
    final href = response.getElement('href', namespaceUri: 'DAV:')?.innerText;
    if (href == null) throw const DavFailure('list', 'missing_href');
    final uri = folder.resolve(href);
    final path = uri.path.endsWith('/')
        ? uri.path.substring(0, uri.path.length - 1)
        : uri.path;
    final parent = folder.path.substring(0, folder.path.length - 1);
    if (uri.origin != folder.origin ||
        uri.hasQuery ||
        uri.hasFragment ||
        (path != parent && !uri.path.startsWith(folder.path))) {
      throw const DavFailure('list', 'unsafe_href');
    }
    final stats = response.findElements('propstat', namespaceUri: 'DAV:');
    if (!stats.any(
      (p) => RegExp(r'^HTTP/\S+ 200(?: |$)').hasMatch(
        p.getElement('status', namespaceUri: 'DAV:')?.innerText.trim() ?? '',
      ),
    )) {
      throw const DavFailure('list', 'partial_response');
    }
    if (path == parent) {
      self = true;
      continue;
    }
    final name = path.substring(folder.path.length);
    final allowed = switch (contents) {
      DavContents.vault =>
        name == 'bootstrap.wenc' ||
            name == 'packs-v1' ||
            _revisionFile.hasMatch(name),
      DavContents.packBuckets => _bucketName.hasMatch(name),
      DavContents.packs => _packFile.hasMatch(name),
    };
    if (!allowed) throw const DavFailure('list', 'unexpected_file');
    if (!names.add(name)) throw const DavFailure('list', 'duplicate_href');
  }
  if (!self) throw const DavFailure('list', 'missing_collection');
  return names;
}

class SyncReport {
  const SyncReport(this.uploaded, this.downloaded, {this.complete = true});

  final int uploaded, downloaded;
  final bool complete;

  String get message =>
      '本轮上传 $uploaded、下载 $downloaded。'
      '${complete ? '' : '已达到同步额度，下轮继续。'}';
}

class NutstoreSync {
  NutstoreSync(
    this.directory,
    this.request, {
    this.wire,
    this.pace = const Duration(seconds: 4),
  });
  final Directory directory;
  final VaultRequest request;
  final DavWire? wire;
  final Duration pace;
  static const _packSize = 512 * 1024;
  static const _packCount = 128;
  final HttpClient client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 20);
  String auth = '';
  late SyncBudget budget;
  DateTime? last;
  bool cancelled = false;
  static final root = Uri.parse('https://dav.jianguoyun.com/dav/');
  static final prop = utf8.encode(
    '<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/></d:prop></d:propfind>',
  );
  void cancel() {
    cancelled = true;
    client.close(force: true);
  }

  Future<DavReply> _http(
    String method,
    Uri uri,
    List<int> body,
    String depth,
    int limit, {
    required bool createOnly,
  }) async {
    final req = await client
        .openUrl(method, uri)
        .timeout(const Duration(seconds: 20));
    req.followRedirects = false;
    req.headers.set(HttpHeaders.authorizationHeader, auth);
    req.headers.set(HttpHeaders.userAgentHeader, 'Wencrypt/0.2');
    if (createOnly) req.headers.set(HttpHeaders.ifNoneMatchHeader, '*');
    if (method != 'GET' && method != 'HEAD') req.contentLength = body.length;
    if (method == 'PUT') req.headers.contentType = ContentType.binary;
    if (method == 'PROPFIND') {
      req.headers.set('Depth', depth);
      req.headers.contentType = ContentType(
        'application',
        'xml',
        charset: 'utf-8',
      );
    }
    if (body.isNotEmpty) req.add(body);
    final res = await req.close().timeout(const Duration(seconds: 30));
    if (res.contentLength > limit) {
      throw const DavFailure('response', 'size_limit');
    }
    final bytes = BytesBuilder();
    await for (final chunk in res.timeout(const Duration(seconds: 30))) {
      if (bytes.length + chunk.length > limit) {
        throw const DavFailure('response', 'size_limit');
      }
      bytes.add(chunk);
    }
    return DavReply(res.statusCode, bytes.takeBytes());
  }

  Future<DavReply> send(
    String stage,
    String method,
    Uri uri, {
    List<int> body = const [],
    String depth = '1',
    int limit = 1024 * 1024,
    Set<int> accepted = const {200},
    bool createOnly = false,
  }) async {
    try {
      if (uri.scheme != 'https' ||
          uri.origin != root.origin ||
          !uri.path.startsWith(root.path)) {
        throw DavFailure(stage, 'unsafe_url');
      }
      if (last != null) {
        final remaining = pace - DateTime.now().difference(last!);
        if (remaining > Duration.zero) await Future<void>.delayed(remaining);
      }
      if (cancelled) throw DavFailure(stage, 'cancelled');
      final now = DateTime.now().toUtc();
      final month = '${now.year}-${now.month.toString().padLeft(2, '0')}';
      await budget.reserve(body.length + 2048, limit + 8192);
      last = DateTime.now();
      final response =
          await (wire?.call(method, uri, body, depth, limit) ??
              _http(method, uri, body, depth, limit, createOnly: createOnly));
      if (response.body.length > limit) {
        throw DavFailure(stage, 'response_limit', response.status);
      }
      await budget.settleDownload(limit - response.body.length, month);
      if (!accepted.contains(response.status)) {
        throw DavFailure(
          stage,
          response.status == 401 || response.status == 403
              ? 'authentication_or_permission'
              : response.status == 429
              ? 'rate_limited'
              : 'http_error',
          response.status,
        );
      }
      return response;
    } on DavFailure catch (e) {
      throw DavFailure(stage, e.reason, e.status);
    } on HandshakeException {
      throw DavFailure(stage, 'tls_failed');
    } on SocketException {
      throw DavFailure(stage, 'network_failed');
    } on HttpException {
      throw DavFailure(stage, 'network_failed');
    } on TimeoutException {
      throw DavFailure(stage, 'timeout');
    } on FileSystemException {
      throw DavFailure(stage, 'local_budget_storage_failed');
    } on StateError catch (e) {
      throw DavFailure(
        stage,
        e.message == 'free_budget_reached'
            ? 'free_budget_reached'
            : 'local_state_failed',
      );
    }
  }

  List<int> unhex(String value) {
    final bytes = Uint8List(value.length ~/ 2);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = int.parse(value.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return bytes;
  }

  String hex(List<int> bytes) {
    final buffer = StringBuffer();
    for (final byte in bytes) {
      buffer.write(byte.toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }

  String _folderName(String raw) {
    final name = raw.trim().replaceAll(RegExp(r'^/+|/+$'), '');
    if (name.isEmpty ||
        name == '.' ||
        name.contains('..') ||
        name.contains('/') ||
        name.contains('\\') ||
        name.length > 32) {
      throw const DavFailure('configure', 'invalid_remote_folder');
    }
    return name;
  }

  Uri _folderUri(String name) => root.replace(pathSegments: ['dav', name, '']);

  String _packBucket(String pack) =>
      (int.parse(pack.substring(0, 2), radix: 16) & 31)
          .toRadixString(16)
          .padLeft(2, '0');

  void _configure(String username, String password) {
    if (username.trim().isEmpty || username.contains(':') || password.isEmpty) {
      throw const DavFailure('configure', 'missing_credentials');
    }
    auth = 'Basic ${base64Encode(utf8.encode('${username.trim()}:$password'))}';
    budget = SyncBudget(File('${directory.path}/sync-budget.json'));
  }

  Future<void> _authenticate() async {
    await send(
      'authenticate',
      'PROPFIND',
      root,
      body: prop,
      depth: '0',
      limit: 64 * 1024,
      accepted: {207},
    );
  }

  Future<String> readExistingBootstrap(
    String username,
    String password,
    String folderName,
  ) async {
    try {
      final folder = _folderUri(_folderName(folderName));
      _configure(username, password);
      await _authenticate();
      final reply = await send(
        'read_bootstrap',
        'GET',
        folder.resolve('bootstrap.wenc'),
        limit: 8192,
        accepted: {200, 404, 409},
      );
      if (reply.status != 200) {
        throw DavFailure('read_bootstrap', 'remote_missing', reply.status);
      }
      return hex(reply.body);
    } finally {
      auth = '';
      client.close(force: true);
    }
  }

  Future<Set<String>> _list(Uri folder, DavContents contents) async {
    final reply = await send(
      'list',
      'PROPFIND',
      folder,
      body: prop,
      accepted: {207},
    );
    return parseDavListing(reply.body, folder, contents: contents);
  }

  Future<void> _makeFolder(Uri folder) async {
    await send(
      'create_pack_directory',
      'MKCOL',
      folder,
      limit: 8192,
      accepted: {201, 405},
    );
  }

  Iterable<List<String>> _packGroups(Map<String, int> objects) sync* {
    var size = 4;
    var group = <String>[];
    for (final object in objects.entries) {
      final record = 4 + object.value;
      if (record + 4 > _packSize) {
        throw const DavFailure('upload', 'revision_size_limit');
      }
      if (group.length == _packCount || size + record > _packSize) {
        yield group;
        group = [];
        size = 4;
      }
      group.add(object.key);
      size += record;
    }
    if (group.isNotEmpty) yield group;
  }

  Future<SyncReport> sync(
    String username,
    String password, {
    String? remoteFolder,
    bool existingOnly = false,
    void Function(String message)? onProgress,
  }) async {
    _configure(username, password);
    var downloaded = 0;
    var uploaded = 0;
    void progress() => onProgress?.call('已上传 $uploaded 条，已下载 $downloaded 条');
    try {
      final snapshot = await request('sync_inventory');
      final vault = snapshot['vault'] as String;
      final defaultName = 'wc-${vault.substring(0, 16)}';
      final folderName = (remoteFolder ?? '').trim().isEmpty
          ? defaultName
          : _folderName(remoteFolder!);
      final folder = _folderUri(folderName);
      final boundKey = folderName == defaultName
          ? vault
          : '$vault-${base64Url.encode(utf8.encode('$folderName/'))}';
      final remembered = File('${directory.path}/sync-$boundKey.bound');
      final bootstrap = unhex(snapshot['bootstrap'] as String);
      await _authenticate();
      var remote = await send(
        'read_bootstrap',
        'GET',
        folder.resolve('bootstrap.wenc'),
        limit: 8192,
        accepted: {200, 404, 409},
      );
      if (remote.status != 200) {
        if (existingOnly || await remembered.exists()) {
          throw DavFailure('read_bootstrap', 'remote_missing', remote.status);
        }
        // Nutstore can return 409 for a file inside a missing collection.
        // Confirm the directory is new or empty before writing the bootstrap.
        final made = await send(
          'create_directory',
          'MKCOL',
          folder,
          limit: 8192,
          accepted: {201, 405},
        );
        if (made.status == 405) {
          final listed = await send(
            'inspect_existing_directory',
            'PROPFIND',
            folder,
            body: prop,
            accepted: {207},
          );
          final names = parseDavListing(listed.body, folder);
          if (names.contains('bootstrap.wenc')) {
            remote = await send(
              'reread_bootstrap',
              'GET',
              folder.resolve('bootstrap.wenc'),
              limit: 8192,
            );
          } else if (names.isNotEmpty) {
            throw const DavFailure('initialize', 'nonempty_unbound_directory');
          }
        }
        if (remote.status != 200) {
          await send(
            'write_bootstrap',
            'PUT',
            folder.resolve('bootstrap.wenc'),
            body: bootstrap,
            limit: 8192,
            createOnly: true,
            accepted: {201, 204, 412},
          );
          remote = await send(
            'verify_bootstrap',
            'GET',
            folder.resolve('bootstrap.wenc'),
            limit: 8192,
          );
        }
      }
      if (hex(remote.body) != hex(bootstrap)) {
        throw const DavFailure('verify_bootstrap', 'vault_identity_mismatch');
      }
      await remembered.writeAsString('bound', flush: true);
      final names = await _list(folder, DavContents.vault);
      if (!names.contains('bootstrap.wenc')) {
        throw const DavFailure('list', 'bootstrap_missing');
      }
      final local = Map<String, int>.from(snapshot['objects'] as Map);
      final known = local.keys.toSet();
      final packed = <String>{};
      final packsFolder = folder.resolve('packs-v1/');
      final packsExist = names.contains('packs-v1');
      final buckets = <String>{};
      final remotePacks = <String, Uri>{};

      if (packsExist) {
        buckets.addAll(await _list(packsFolder, DavContents.packBuckets));
        for (final bucket in buckets) {
          final bucketUri = packsFolder.resolve('$bucket/');
          for (final file in await _list(bucketUri, DavContents.packs)) {
            final pack = file.substring(0, 64);
            if (bucket != _packBucket(pack)) {
              throw const DavFailure('list', 'pack_in_wrong_bucket');
            }
            remotePacks[pack] = bucketUri.resolve(file);
          }
        }
      }

      if (remotePacks.isNotEmpty) {
        final receipts =
            (await request('sync_receipts', {
                  'packs': remotePacks.keys.toList(),
                }))['packs']
                as Map;
        for (final pack in remotePacks.entries) {
          final receipt = receipts[pack.key];
          if (receipt is List && receipt.every(known.contains)) {
            packed.addAll(receipt.cast<String>());
            continue;
          }
          final response = await send(
            'download_pack',
            'GET',
            pack.value,
            limit: _packSize,
          );
          final result = await request('sync_ingest_pack', {
            'hash': pack.key,
            'body': hex(response.body),
          });
          final hashes = (result['hashes'] as List).cast<String>();
          for (final hash in hashes) {
            if (known.add(hash)) downloaded++;
          }
          packed.addAll(hashes);
          progress();
        }
      }

      // Existing flat objects remain readable. Publish them in packs too so
      // another newly joined device can fetch the complete history efficiently.
      var readLegacy = false;
      for (final file in names.where(_revisionFile.hasMatch)) {
        final hash = file.substring(0, 64);
        if (known.contains(hash)) continue;
        final response = await send(
          'download_legacy',
          'GET',
          folder.resolve(file),
        );
        await request('ingest', {'hash': hash, 'body': hex(response.body)});
        known.add(hash);
        readLegacy = true;
        downloaded++;
        progress();
      }
      final remaining = readLegacy
          ? Map<String, int>.from(
              (await request('sync_inventory'))['objects'] as Map,
            )
          : local;
      remaining.removeWhere((hash, _) => packed.contains(hash));
      if (remaining.isNotEmpty && !packsExist) await _makeFolder(packsFolder);
      for (final group in _packGroups(remaining)) {
        final result = await request('sync_build_pack', {'hashes': group});
        final pack = result['hash'] as String;
        final body = unhex(result['body'] as String);
        final bucket = _packBucket(pack);
        final bucketUri = packsFolder.resolve('$bucket/');
        if (buckets.add(bucket)) await _makeFolder(bucketUri);
        final uri = bucketUri.resolve('$pack.pack');
        final reply = await send(
          'upload_pack',
          'PUT',
          uri,
          body: body,
          limit: 8192,
          createOnly: true,
          accepted: {201, 204, 412},
        );
        if (reply.status == 412) {
          final existing = await send(
            'verify_pack',
            'GET',
            uri,
            limit: _packSize,
          );
          if (hex(existing.body) != result['body']) {
            throw const DavFailure('verify_pack', 'pack_content_mismatch');
          }
        }
        uploaded += group.length;
        progress();
      }
      return SyncReport(uploaded, downloaded);
    } catch (e) {
      if (e is DavFailure &&
          e.reason == 'free_budget_reached' &&
          (downloaded > 0 || uploaded > 0)) {
        return SyncReport(uploaded, downloaded, complete: false);
      }
      final safe = e is DavFailure
          ? e
          : const DavFailure('merge_or_parse', 'validation_failed');
      await File('${directory.path}/last-sync-diagnostic.json').writeAsString(
        jsonEncode({
          ...safe.diagnostic,
          'time': DateTime.now().toUtc().toIso8601String(),
        }),
        flush: true,
      );
      throw safe;
    } finally {
      auth = '';
      client.close(force: true);
    }
  }
}
