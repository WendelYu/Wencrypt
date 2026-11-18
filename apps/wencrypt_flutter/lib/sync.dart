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

Set<String> parseDavListing(List<int> bytes, Uri folder) {
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
  if (responses.length >= 600) {
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
    final name = uri.path.substring(folder.path.length);
    if (name != 'bootstrap.wenc' &&
        !RegExp(r'^[0-9a-f]{64}\.wenc$').hasMatch(name)) {
      throw const DavFailure('list', 'unexpected_file');
    }
    if (!names.add(name)) throw const DavFailure('list', 'duplicate_href');
  }
  if (!self) throw const DavFailure('list', 'missing_collection');
  return names;
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

  List<int> unhex(String s) => [
    for (int i = 0; i < s.length; i += 2)
      int.parse(s.substring(i, i + 2), radix: 16),
  ];
  String hex(List<int> b) =>
      b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
  String _normalizeFolder(String? remoteFolder, String vault) {
    final raw = (remoteFolder ?? '').trim();
    if (raw.isEmpty) return 'wc-${vault.substring(0, 16)}/';
    final cleaned = raw.replaceAll('\\', '/').replaceAll(RegExp(r'^/+|/+$'), '');
    if (cleaned.isEmpty ||
        cleaned.contains('..') ||
        cleaned.contains('/') ||
        cleaned.length > 32) {
      throw const DavFailure('configure', 'invalid_remote_folder');
    }
    return '$cleaned/';
  }

  Future<String> sync(
    String username,
    String password, {
    String? remoteFolder,
  }) async {
    if (username.trim().isEmpty || username.contains(':') || password.isEmpty) {
      throw const DavFailure('configure', 'missing_credentials');
    }
    auth = 'Basic ${base64Encode(utf8.encode('${username.trim()}:$password'))}';
    budget = SyncBudget(File('${directory.path}/sync-budget.json'));
    try {
      final snapshot = await request('sync_objects');
      final vault = snapshot['vault'] as String;
      final folderName = _normalizeFolder(remoteFolder, vault);
      final isDefaultFolder = folderName == 'wc-${vault.substring(0, 16)}/';
      final folder = root.resolve(folderName);
      final boundKey = isDefaultFolder
          ? vault
          : '$vault-${base64Url.encode(utf8.encode(folderName))}';
      final remembered = File('${directory.path}/sync-$boundKey.bound');
      final bootstrap = unhex(snapshot['bootstrap'] as String);
      // Authentication is diagnosed separately from missing collections.
      await send(
        'authenticate',
        'PROPFIND',
        root,
        body: prop,
        depth: '0',
        limit: 64 * 1024,
        accepted: {207},
      );
      var remote = await send(
        'read_bootstrap',
        'GET',
        folder.resolve('bootstrap.wenc'),
        limit: 8192,
        accepted: {200, 404, 409},
      );
      if (remote.status != 200) {
        if (await remembered.exists()) {
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
      final listing = await send(
        'list',
        'PROPFIND',
        folder,
        body: prop,
        accepted: {207},
      );
      final names = parseDavListing(listing.body, folder);
      if (!names.contains('bootstrap.wenc')) {
        throw const DavFailure('list', 'bootstrap_missing');
      }
      final remoteHashes = names
          .where((n) => n != 'bootstrap.wenc')
          .map((n) => n.substring(0, 64))
          .toSet();
      final objects = (snapshot['objects'] as List)
          .cast<Map<String, dynamic>>();
      final local = objects.map((o) => o['hash'] as String).toSet();
      if (remoteHashes.union(local).length >= 598) {
        throw const DavFailure('list', 'directory_limit');
      }
      int downloaded = 0, uploaded = 0;
      for (final hash in remoteHashes.difference(local)) {
        final response = await send(
          'download',
          'GET',
          folder.resolve('$hash.wenc'),
        );
        await request('ingest', {'hash': hash, 'body': hex(response.body)});
        downloaded++;
      }
      for (final object in objects.where(
        (o) => !remoteHashes.contains(o['hash']),
      )) {
        await send(
          'upload',
          'PUT',
          folder.resolve('${object['hash']}.wenc'),
          body: unhex(object['body'] as String),
          limit: 8192,
          accepted: {201, 204},
        );
        uploaded++;
      }
      return '本轮上传 $uploaded、下载 $downloaded；其他设备的新内容会在后续同步发现。';
    } catch (e) {
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
