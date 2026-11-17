import 'dart:convert';
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

class NutstoreSync {
  NutstoreSync(this.directory, this.request);
  final Directory directory;
  final VaultRequest request;
  final HttpClient client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 20);
  late String auth;
  late SyncBudget budget;
  final Uri root = Uri.parse('https://dav.jianguoyun.com/dav/');
  Future<(int, Uint8List)> send(
    String method,
    Uri uri, {
    List<int> body = const [],
    int limit = 1024 * 1024,
  }) async {
    if (uri.scheme != 'https' ||
        uri.host != root.host ||
        uri.port != root.port ||
        !uri.path.startsWith(root.path)) {
      throw StateError('unsafe_url');
    }
    await budget.reserve(body.length + 2048, limit + 8192);
    final req = await client
        .openUrl(method, uri)
        .timeout(const Duration(seconds: 20));
    req.followRedirects = false;
    req.headers.set(HttpHeaders.authorizationHeader, auth);
    req.contentLength = body.length;
    if (method == 'PROPFIND') {
      req.headers.set('Depth', '1');
      req.headers.contentType = ContentType(
        'application',
        'xml',
        charset: 'utf-8',
      );
    }
    if (body.isNotEmpty) req.add(body);
    final response = await req.close().timeout(const Duration(seconds: 30));
    if (response.contentLength > limit) {
      client.close(force: true);
      throw StateError('response_limit');
    }
    final result = BytesBuilder();
    await for (final part in response.timeout(const Duration(seconds: 30))) {
      if (result.length + part.length > limit) {
        client.close(force: true);
        throw StateError('response_limit');
      }
      result.add(part);
    }
    return (response.statusCode, result.takeBytes());
  }

  List<int> unhex(String s) {
    if (s.length.isOdd) throw StateError('invalid_hex');
    return [
      for (int i = 0; i < s.length; i += 2)
        int.parse(s.substring(i, i + 2), radix: 16),
    ];
  }

  String hex(List<int> b) =>
      b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
  Future<String> sync(String username, String password) async {
    auth = 'Basic ${base64Encode(utf8.encode('$username:$password'))}';
    budget = SyncBudget(File('${directory.path}/sync-budget.json'));
    try {
      final snapshot = await request('sync_objects');
      final vault = snapshot['vault'] as String;
      final folder = root.resolve('wc-${vault.substring(0, 16)}/');
      final remembered = File('${directory.path}/sync-$vault.bound');
      final bootstrap = unhex(snapshot['bootstrap'] as String);
      final (status, remote) = await send(
        'GET',
        folder.resolve('bootstrap.wenc'),
        limit: 1024,
      );
      if (status == 404) {
        if (await remembered.exists()) throw StateError('remote_missing');
        final (made, _) = await send('MKCOL', folder, limit: 8192);
        if (made != 201) throw StateError('remote_folder_not_created');
        final (put, _) = await send(
          'PUT',
          folder.resolve('bootstrap.wenc'),
          body: bootstrap,
          limit: 8192,
        );
        if (put != 201 && put != 204) throw StateError('upload_failed');
      } else if (status != 200 || hex(remote) != hex(bootstrap)) {
        throw StateError('remote_identity_or_auth_failed');
      }
      await remembered.writeAsString('bound', flush: true);
      final (listingCode, listing) = await send(
        'PROPFIND',
        folder,
        body: utf8.encode(
          '<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/></d:prop></d:propfind>',
        ),
      );
      if (listingCode != 207) throw StateError('listing_failed');
      final xml = XmlDocument.parse(utf8.decode(listing));
      if (xml.descendants.any((n) => n is XmlDoctype)) {
        throw StateError('invalid_xml');
      }
      final responses = xml.descendants
          .whereType<XmlElement>()
          .where((e) => e.name.local == 'response')
          .toList();
      // Stop well before the provider's 750-item truncation threshold.
      if (responses.length >= 600) throw StateError('directory_limit');
      final remoteHashes = <String>{};
      for (final response in responses) {
        final hrefs = response.descendants
            .whereType<XmlElement>()
            .where((e) => e.name.local == 'href')
            .toList();
        if (hrefs.length != 1) throw StateError('invalid_listing');
        final uri = folder.resolve(hrefs.single.innerText);
        if (uri.origin != folder.origin ||
            !uri.path.startsWith(folder.path) ||
            uri.hasQuery ||
            uri.hasFragment) {
          throw StateError('unsafe_listing');
        }
        final name = uri.path.substring(folder.path.length);
        if (name.isEmpty || name == 'bootstrap.wenc') continue;
        if (!RegExp(r'^[0-9a-f]{64}\.wenc$').hasMatch(name)) {
          throw StateError('unexpected_remote_file');
        }
        remoteHashes.add(name.substring(0, 64));
      }
      final objects = (snapshot['objects'] as List)
          .cast<Map<String, dynamic>>();
      final localHashes = objects.map((o) => o['hash'] as String).toSet();
      if (remoteHashes.union(localHashes).length >= 598) {
        throw StateError('directory_limit');
      }
      int downloaded = 0, uploaded = 0;
      for (final hash in remoteHashes.difference(localHashes)) {
        final (code, bytes) = await send('GET', folder.resolve('$hash.wenc'));
        if (code != 200) throw StateError('download_failed');
        await request('ingest', {'hash': hash, 'body': hex(bytes)});
        downloaded++;
      }
      for (final object in objects.where(
        (o) => !remoteHashes.contains(o['hash']),
      )) {
        // Filename is a SHA-256 of ciphertext; equal names represent equal immutable objects.
        final (code, _) = await send(
          'PUT',
          folder.resolve('${object['hash']}.wenc'),
          body: unhex(object['body'] as String),
          limit: 8192,
        );
        if (code != 201 && code != 204) throw StateError('upload_failed');
        uploaded++;
      }
      return '本轮上传 $uploaded、下载 $downloaded。其他设备新增内容将在下次同步发现。';
    } finally {
      auth = '';
      client.close(force: true);
    }
  }
}
