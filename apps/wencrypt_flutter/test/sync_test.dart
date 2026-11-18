import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wencrypt/sync.dart';

String listing(String folder, List<String> names, {bool slash = true}) =>
    '<d:multistatus xmlns:d="DAV:">${[slash ? folder : folder.substring(0, folder.length - 1), ...names.map((n) => '$folder$n')].map((h) => '<d:response><d:href>$h</d:href><d:propstat><d:prop><d:resourcetype/></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>').join()}</d:multistatus>';
void main() {
  test(
    'DAV accepts collection without final slash and rejects partial responses',
    () {
      final uri = Uri.parse('https://dav.jianguoyun.com/dav/wc-123/');
      expect(
        parseDavListing(
          utf8.encode(listing(uri.path, ['bootstrap.wenc'], slash: false)),
          uri,
        ),
        {'bootstrap.wenc'},
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
          'objects': <dynamic>[],
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
      expect(
        await sync.sync('test@example.com', 'test-only'),
        contains('上传 0'),
      );
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
            'objects': [],
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
}
