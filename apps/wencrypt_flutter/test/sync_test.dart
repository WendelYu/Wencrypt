import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wencrypt/sync.dart';

String listing(String folder, List<String> names, {bool slash = true}) =>
    '<d:multistatus xmlns:d="DAV:">${[slash ? folder : folder.substring(0, folder.length - 1), ...names.map((n) => '$folder$n')].map((h) => '<d:response><d:href>$h</d:href><d:propstat><d:prop><d:resourcetype/></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>').join()}</d:multistatus>';

class _MemoryDav {
  final directories = <String>{'/dav/', '/dav/shared/'};
  final files = <String, List<int>>{
    '/dav/shared/bootstrap.wenc': [1, 2, 3],
  };
  final calls = <(String, String)>[];

  Future<DavReply> wire(
    String method,
    Uri uri,
    List<int> body,
    String depth,
    int limit,
  ) async {
    final path = uri.path;
    calls.add((method, path));
    switch (method) {
      case 'GET':
        final bytes = files[path];
        return bytes == null ? DavReply(404, []) : DavReply(200, bytes);
      case 'PUT':
        if (files.containsKey(path)) return DavReply(412, []);
        files[path] = body.toList();
        return DavReply(201, []);
      case 'MKCOL':
        return DavReply(directories.add(path) ? 201 : 405, []);
      case 'PROPFIND':
        if (!directories.contains(path)) return DavReply(404, []);
        final children = [...directories, ...files.keys]
            .where((item) => item.startsWith(path) && item != path)
            .map((item) => item.substring(path.length))
            .where(
              (item) => !item.replaceFirst(RegExp(r'/$'), '').contains('/'),
            )
            .toList();
        return DavReply(
          207,
          utf8.encode(listing(path, depth == '0' ? [] : children)),
        );
      default:
        throw StateError('Unexpected WebDAV verb');
    }
  }
}

class _FakeVault {
  _FakeVault({this.objectSize = 128});

  final int objectSize;
  final objects = <String>{};
  final receipts = <String, List<String>>{};

  Future<Map<String, dynamic>> request(
    String op, [
    Map<String, dynamic> fields = const {},
  ]) async {
    switch (op) {
      case 'sync_inventory':
        return {
          'vault': '0123456789abcdef0123456789abcdef',
          'bootstrap': '010203',
          'objects': {for (final hash in objects) hash: objectSize},
        };
      case 'sync_receipts':
        return {
          'packs': {
            for (final pack in (fields['packs'] as List).cast<String>())
              if (receipts.containsKey(pack)) pack: receipts[pack],
          },
        };
      case 'sync_build_pack':
        final hashes = (fields['hashes'] as List).cast<String>().toList();
        final suffix = hashes.first;
        final hash = '${suffix.substring(62)}${suffix.substring(2)}';
        receipts[hash] = hashes;
        return {'hash': hash, 'body': _hex(utf8.encode(jsonEncode(hashes)))};
      case 'sync_ingest_pack':
        final hash = fields['hash'] as String;
        final body = fields['body'] as String;
        final hashes = (jsonDecode(
          utf8.decode([
            for (var i = 0; i < body.length; i += 2)
              int.parse(body.substring(i, i + 2), radix: 16),
          ]),
        ) as List).cast<String>();
        receipts[hash] = hashes;
        objects.addAll(hashes);
        return {'hashes': hashes};
      case 'ingest':
        objects.add(fields['hash'] as String);
        return {};
      default:
        throw StateError('Unexpected vault operation');
    }
  }

  String _hex(List<int> bytes) =>
      bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}

String _hash(int value) => value.toRadixString(16).padLeft(64, '0');

void main() {
  test('sync mode keeps existing settings and backs off when idle', () {
    expect(SyncMode.fromSettings(null), SyncMode.manual);
    expect(SyncMode.fromSettings({'auto': false}), SyncMode.manual);
    expect(SyncMode.fromSettings({'auto': true}), SyncMode.automatic);
    expect(
      SyncMode.fromSettings({'auto': true, 'syncMode': 'notify'}),
      SyncMode.notify,
    );
    expect(
      [
        for (final rounds in [0, 1, 2, 3])
          syncPollInterval(failures: 0, idleRounds: rounds).inMinutes,
      ],
      [15, 30, 60, 60],
    );
    expect(syncPollInterval(failures: 4, idleRounds: 0).inMinutes, 240);
  });

  test('read-only checks detect new packs inside an existing bucket', () async {
    final fixture = await Directory.systemTemp.createTemp('wencrypt-dav-check');
    addTearDown(() => fixture.delete(recursive: true));
    final dav = _MemoryDav();
    final source = _FakeVault()..objects.add(_hash(1));
    final peer = _FakeVault();
    final first = await fixture.createTemp('source');
    final second = await fixture.createTemp('peer');
    final bucket = '/dav/shared/packs-v1/01/';

    Future<SyncReport> run(
      Directory directory,
      _FakeVault vault, {
      bool checkOnly = false,
      String folder = 'shared',
    }) => NutstoreSync(
      directory,
      vault.request,
      wire: dav.wire,
      pace: Duration.zero,
    ).sync('fixture', 'fixture', remoteFolder: folder, checkOnly: checkOnly);

    expect((await run(first, source)).uploaded, 1);
    expect((await run(second, peer)).downloaded, 1);
    dav.calls.clear();
    expect((await run(second, peer, checkOnly: true)).hasChanges, isFalse);
    expect(dav.calls, [
      ('PROPFIND', '/dav/'),
      ('GET', '/dav/shared/bootstrap.wenc'),
      ('PROPFIND', '/dav/shared/'),
      ('PROPFIND', '/dav/shared/packs-v1/'),
      ('PROPFIND', bucket),
    ]);

    // A peer using the current pack format adds a file to the same bucket.
    source.objects.add(_hash(33));
    expect((await run(first, source)).uploaded, 1);
    peer.objects.add(_hash(2));
    dav.calls.clear();
    final noticed = await run(second, peer, checkOnly: true);
    expect(noticed.remoteChanges, isTrue);
    expect(noticed.localChanges, isTrue);
    expect(noticed.uploaded + noticed.downloaded, 0);
    expect(peer.objects, {_hash(1), _hash(2)});
    expect(dav.calls.where((call) => call.$1 != 'PROPFIND'), [
      ('GET', '/dav/shared/bootstrap.wenc'),
    ]);

    final applied = await run(second, peer);
    expect(applied.downloaded, 1);
    expect(applied.uploaded, 1);
    expect((await run(first, source)).downloaded, 1);
    expect(source.objects, {_hash(1), _hash(2), _hash(33)});
    expect(peer.objects, source.objects);

    final legacy = '/dav/shared/${_hash(4)}.wenc';
    dav.files[legacy] = [42];
    dav.calls.clear();
    expect((await run(second, peer, checkOnly: true)).remoteChanges, isTrue);
    expect(dav.calls, isNot(contains(('GET', legacy))));

    dav.calls.clear();
    expect(
      (await run(
        second,
        peer,
        checkOnly: true,
        folder: 'uninitialized',
      )).localChanges,
      isTrue,
    );
    expect(dav.calls.map((call) => call.$1), ['PROPFIND', 'GET']);
    expect(dav.directories, isNot(contains('/dav/uninitialized/')));
  });

  test(
    'password rotation with no strong ETag locks and verifies the cloud update',
    () async {
      final dir = await Directory.systemTemp.createTemp('wencrypt-rewrap-test');
      addTearDown(() => dir.delete(recursive: true));
      final calls = <String>[];
      String? version;
      var changeBeforeReread = false;
      var conflictDuringPut = false;
      var uncertainWrite = false;
      var lockHeld = false;
      var remote = <int>[1, 2];
      NutstoreSync client() => NutstoreSync(
        dir,
        (op, [args = const {}]) async {
          if (op == 'sync_bootstrap_relation') {
            final candidate = args['bootstrap'];
            return {
              'same_vault': ['0102', '0506'].contains(candidate),
              'previous': candidate == '0102',
            };
          }
          return {
            'vault': '0123456789abcdef0123456789abcdef',
            'bootstrap': '0304',
            'objects': <String, int>{},
          };
        },
        pace: Duration.zero,
        wire: (method, uri, body, depth, limit) async {
          calls.add(method);
          if (method == 'GET') return DavReply(200, remote, etag: version);
          if (method == 'MKCOL' || method == 'DELETE') {
            expect(uri.path, endsWith('/bootstrap-update-lock/'));
            if (method == 'DELETE') {
              expect(lockHeld, isTrue);
              lockHeld = false;
              return DavReply(204, []);
            }
            if (lockHeld) return DavReply(405, []);
            lockHeld = true;
            if (changeBeforeReread) remote = [5, 6];
            return DavReply(201, []);
          }
          if (method == 'PUT') {
            expect(lockHeld, isTrue);
            expect(body, [3, 4]);
            if (uncertainWrite) {
              throw const SocketException('fixture disconnect');
            }
            if (conflictDuringPut) {
              remote = [5, 6];
              return DavReply(412, []);
            }
            remote = body;
            return DavReply(204, []);
          }
          return DavReply(
            207,
            utf8.encode(listing(uri.path, ['bootstrap.wenc'])),
          );
        },
      );
      final pending = await client().sync(
        'fixture',
        'fixture',
        checkOnly: true,
      );
      expect(pending.localChanges, isTrue);
      expect(remote, [1, 2]);
      expect(calls, isNot(contains(anyOf('MKCOL', 'PUT', 'DELETE'))));
      calls.clear();
      expect((await client().sync('fixture', 'fixture')).complete, isTrue);
      expect(remote, [3, 4]);
      expect(lockHeld, isFalse);
      expect(
        calls,
        containsAllInOrder(['MKCOL', 'GET', 'PUT', 'GET', 'DELETE']),
      );

      calls.clear();
      remote = [1, 2];
      changeBeforeReread = true;
      await expectLater(
        client().sync('fixture', 'fixture', remoteFolder: 'shared'),
        throwsA(
          isA<CloudPasswordChanged>()
              .having((e) => e.bootstrap, 'bootstrap', '0506')
              .having((e) => e.folder, 'folder', 'shared'),
        ),
      );
      expect(lockHeld, isFalse);
      expect(calls, isNot(contains('PUT')));

      remote = [1, 2];
      changeBeforeReread = false;
      version = '"old-strong-etag"';
      conflictDuringPut = true;
      await expectLater(
        client().sync('fixture', 'fixture', remoteFolder: 'shared'),
        throwsA(
          isA<CloudPasswordChanged>()
              .having((e) => e.bootstrap, 'bootstrap', '0506')
              .having((e) => e.folder, 'folder', 'shared'),
        ),
      );
      expect(remote, [5, 6]);
      expect(lockHeld, isFalse);
      calls.clear();
      await expectLater(
        client().sync('fixture', 'fixture'),
        throwsA(isA<CloudPasswordChanged>()),
      );
      expect(calls, isNot(contains('PUT')));
      conflictDuringPut = false;
      remote = [7, 8];
      await expectLater(
        client().sync('fixture', 'fixture', recoveringPassword: true),
        throwsA(
          isA<DavFailure>().having(
            (failure) => failure.reason,
            'reason',
            'vault_identity_mismatch',
          ),
        ),
      );
      expect(calls, isNot(contains('PUT')));
      remote = [5, 6];
      version = 'W/"weak-etag"';
      expect(
        (await client().sync(
          'fixture',
          'fixture',
          recoveringPassword: true,
        )).complete,
        isTrue,
      );
      expect(remote, [3, 4]);

      calls.clear();
      remote = [1, 2];
      uncertainWrite = true;
      await expectLater(
        client().sync('fixture', 'fixture'),
        throwsA(
          isA<DavFailure>().having(
            (e) => e.reason,
            'reason',
            'bootstrap_write_uncertain',
          ),
        ),
      );
      expect(lockHeld, isTrue);
      expect(calls, isNot(contains('DELETE')));

      calls.clear();
      uncertainWrite = false;
      await expectLater(
        client().sync('fixture', 'fixture'),
        throwsA(
          isA<DavFailure>().having(
            (e) => e.reason,
            'reason',
            'bootstrap_update_busy',
          ),
        ),
      );
      expect(calls, isNot(contains('PUT')));
      expect(calls, isNot(contains('DELETE')));
    },
  );

  test(
    'DAV accepts collection without final slash and rejects partial responses',
    () {
      final uri = Uri.parse('https://dav.jianguoyun.com/dav/wc-123/');
      expect(
        parseDavListing(
          utf8.encode(
            listing(uri.path, [
              'bootstrap.wenc',
              recoveryFileName,
            ], slash: false),
          ),
          uri,
        ),
        {'bootstrap.wenc', recoveryFileName},
      );
      expect(
        () => parseDavListing(
          utf8.encode(
            listing(uri.path, [
              'bootstrap.wenc',
            ]).replaceFirst('200 OK', '404 Not Found'),
          ),
          uri,
        ),
        throwsA(isA<DavFailure>()),
      );
      expect(
        () => parseDavListing(utf8.encode('<foo/>'), uri),
        throwsA(isA<DavFailure>()),
      );
    },
  );
  test('resumes initialization after MKCOL succeeded and bootstrap upload was interrupted', () async {
    final dir = await Directory.systemTemp.createTemp('wencrypt-sync-test');
    final calls = <String>[];
    var gets = 0;
    var lists = 0;
    try {
      final sync = NutstoreSync(
        dir,
        (String op, [Map<String, dynamic> extra = const {}]) async => {
          'vault': '0123456789abcdef0123456789abcdef',
          'bootstrap': '010203',
          'objects': <String, int>{},
        },
        pace: Duration.zero,
        wire: (method, uri, body, depth, limit) async {
          calls.add(method);
          if (method == 'PROPFIND' && depth == '0') {
            return DavReply(207, utf8.encode('<root/>'));
          }
          if (method == 'GET') {
            return gets++ == 0
                ? DavReply(404, utf8.encode('x' * 2048))
                : DavReply(200, [1, 2, 3]);
          }
          if (method == 'MKCOL') return DavReply(405, []);
          if (method == 'PROPFIND') {
            return DavReply(
              207,
              utf8.encode(
                listing(uri.path, lists++ == 0 ? [] : ['bootstrap.wenc']),
              ),
            );
          }
          if (method == 'PUT') return DavReply(201, []);
          throw StateError('unexpected');
        },
      );
      expect((await sync.sync('test@example.com', 'test-only')).uploaded, 0);
      expect(calls, [
        'PROPFIND',
        'GET',
        'MKCOL',
        'PROPFIND',
        'PUT',
        'GET',
        'PROPFIND',
      ]);
      final budget = jsonDecode(
        await File('${dir.path}/sync-budget.json').readAsString(),
      ) as Map<String, dynamic>;
      expect(budget['down'] as int, lessThan(100 * 1024));
    } finally {
      await dir.delete(recursive: true);
    }
  });
  test(
    'auth failures expose safe stage and HTTP code without credentials',
    () async {
      final dir = await Directory.systemTemp.createTemp('wencrypt-sync-test');
      try {
        final sync = NutstoreSync(
          dir,
          (String op, [Map<String, dynamic> extra = const {}]) async => {
            'vault': '0123456789abcdef0123456789abcdef',
            'bootstrap': '0102',
            'objects': <String, int>{},
          },
          pace: Duration.zero,
          wire: (_, uri, body, depth, limit) async =>
              DavReply(401, utf8.encode('server body must not be logged')),
        );
        await expectLater(
          sync.sync('private@example.com', 'do-not-log-me'),
          throwsA(
            isA<DavFailure>()
                .having((e) => e.stage, 'stage', 'authenticate')
                .having((e) => e.status, 'status', 401),
          ),
        );
        final report = await File('${dir.path}/last-sync-diagnostic.json')
            .readAsString();
        expect(report, contains('401'));
        expect(report, isNot(contains('private')));
        expect(report, isNot(contains('do-not-log')));
        expect(report, isNot(contains('server body')));
      } finally {
        await dir.delete(recursive: true);
      }
    },
  );

  test(
    'migrates legacy objects and synchronizes 1,291 revisions to three devices',
    () async {
      final dir = await Directory.systemTemp.createTemp('wencrypt-packs-test');
      addTearDown(() => dir.delete(recursive: true));
      final dav = _MemoryDav();
      final legacy = '/dav/shared/${_hash(1290)}.wenc';
      dav.files[legacy] = [42];
      final source = _FakeVault()..objects.addAll(List.generate(1290, _hash));
      final second = _FakeVault();
      final third = _FakeVault();
      Future<SyncReport> sync(_FakeVault vault, String name) async {
        final device = await Directory('${dir.path}/$name').create();
        return NutstoreSync(
          device,
          vault.request,
          pace: Duration.zero,
          wire: dav.wire,
        ).sync(
          'test@example.com',
          'fixture-app-password',
          remoteFolder: 'shared',
        );
      }

      final initial = await sync(source, 'source');
      expect(initial.uploaded, 1291);
      expect(initial.downloaded, 1);
      expect(initial.complete, isTrue);
      expect(dav.files[legacy], [42]);
      expect(dav.files.keys.where((path) => path.endsWith('.pack')).length, 11);
      final intervalStart = dav.calls.length;
      expect((await sync(second, 'second')).downloaded, 1291);
      expect((await sync(third, 'third')).downloaded, 1291);
      expect(second.objects, source.objects);
      expect(third.objects, source.objects);
      expect(dav.calls.skip(intervalStart), isNot(contains(('GET', legacy))));

      final idlePass = await sync(second, 'second');
      expect(idlePass.downloaded, 0);
      expect(idlePass.uploaded, 0);

      second.objects.add(_hash(1291));
      expect((await sync(second, 'second')).uploaded, 1);
      expect((await sync(source, 'source')).downloaded, 1);
      expect((await sync(third, 'third')).downloaded, 1);
      expect(third.objects.length, 1292);
    },
  );

  test(
    'continues a quota-limited upload without rewriting committed packs',
    () async {
      final dir = await Directory.systemTemp.createTemp('wencrypt-packs-test');
      addTearDown(() => dir.delete(recursive: true));
      final dav = _MemoryDav();
      final source = _FakeVault(objectSize: 260 * 1024)
        ..objects.addAll(List.generate(95, _hash));
      Future<SyncReport> sync() =>
          NutstoreSync(
            dir,
            source.request,
            pace: Duration.zero,
            wire: dav.wire,
          ).sync(
            'test@example.com',
            'fixture-app-password',
            remoteFolder: 'shared',
          );
      final first = await sync();
      expect(first.complete, isFalse);
      expect(first.uploaded, greaterThan(0));
      expect(first.uploaded, lessThan(95));
      var uploaded = first.uploaded;
      final ledger = File('${dir.path}/sync-budget.json');
      for (var window = 0; window < 4 && uploaded < 95; window++) {
        final state = jsonDecode(await ledger.readAsString()) as Map;
        state['requests'] = [];
        await ledger.writeAsString(jsonEncode(state));
        uploaded += (await sync()).uploaded;
      }
      expect(uploaded, 95);
      expect(dav.calls.where((c) => c.$1 == 'PUT').length, 95);
    },
  );

  test('joining a missing cloud vault performs no writes', () async {
    final dir = await Directory.systemTemp.createTemp('wencrypt-join-test');
    addTearDown(() => dir.delete(recursive: true));
    final dav = _MemoryDav();
    final vault = _FakeVault();
    NutstoreSync client() =>
        NutstoreSync(dir, vault.request, pace: Duration.zero, wire: dav.wire);
    expect(
      await client().readExistingBootstrap(
        'test@example.com',
        'fixture',
        'shared',
      ),
      '010203',
    );
    await expectLater(
      client().readExistingBootstrap('test@example.com', 'fixture', 'missing'),
      throwsA(
        isA<DavFailure>().having((e) => e.reason, 'reason', 'remote_missing'),
      ),
    );
    await expectLater(
      client().sync(
        'test@example.com',
        'fixture',
        remoteFolder: 'missing',
        existingOnly: true,
      ),
      throwsA(
        isA<DavFailure>().having((e) => e.reason, 'reason', 'remote_missing'),
      ),
    );
    expect(dav.calls.map((call) => call.$1).toSet(), {'GET', 'PROPFIND'});
  });

  group('Nutstore bootstrap GET returns 409', () {
    const vault = '0123456789abcdef0123456789abcdef';
    Future<Map<String, dynamic>> snapshot(
      String op, [
      Map<String, dynamic> args = const {},
    ]) async => {
      'vault': vault,
      'bootstrap': '010203',
      'objects': <String, int>{},
    };

    test('creates the missing directory and verifies the bootstrap', () async {
      final dir = await Directory.systemTemp.createTemp('wencrypt-sync-test');
      addTearDown(() => dir.delete(recursive: true));
      final calls = <String>[];
      var created = false;
      var written = false;
      final sync = NutstoreSync(
        dir,
        snapshot,
        pace: Duration.zero,
        wire: (method, uri, body, depth, limit) async {
          calls.add(method);
          switch (method) {
            case 'PROPFIND':
              return DavReply(
                207,
                depth == '0'
                    ? []
                    : utf8.encode(listing(uri.path, ['bootstrap.wenc'])),
              );
            case 'GET':
              return written ? DavReply(200, [1, 2, 3]) : DavReply(409, []);
            case 'MKCOL':
              created = true;
              return DavReply(201, []);
            case 'PUT':
              expect(created, isTrue);
              expect(body, [1, 2, 3]);
              written = true;
              return DavReply(201, []);
            default:
              throw StateError('Unexpected $method');
          }
        },
      );
      expect((await sync.sync('test@example.com', 'test-only')).uploaded, 0);
      expect(calls, ['PROPFIND', 'GET', 'MKCOL', 'PUT', 'GET', 'PROPFIND']);
      expect(await File('${dir.path}/sync-$vault.bound').exists(), isTrue);
    });

    test('leaves an already-bound directory untouched', () async {
      final dir = await Directory.systemTemp.createTemp('wencrypt-sync-test');
      addTearDown(() => dir.delete(recursive: true));
      await File('${dir.path}/sync-$vault.bound').writeAsString('bound');
      final calls = <String>[];
      final sync = NutstoreSync(
        dir,
        snapshot,
        pace: Duration.zero,
        wire: (method, uri, body, depth, limit) async {
          calls.add(method);
          return DavReply(method == 'GET' ? 409 : 207, []);
        },
      );
      await expectLater(
        sync.sync('test@example.com', 'test-only'),
        throwsA(
          isA<DavFailure>()
              .having((e) => e.stage, 'stage', 'read_bootstrap')
              .having((e) => e.reason, 'reason', 'remote_missing')
              .having((e) => e.status, 'status', 409),
        ),
      );
      expect(calls, ['PROPFIND', 'GET']);
    });
  });
}
