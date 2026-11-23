import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wencrypt/lan_transfer.dart';
import 'package:wencrypt/sync.dart';
import 'package:wencrypt/vault_invite.dart';

class _MockVaultCore {
  _MockVaultCore({this.objects = const {}});

  final Map<String, String> objects;
  final bool hasSync = true;
  final List<String> ops = [];
  bool committed = false;
  bool lockCalled = false;
  final ingestedHashes = <String>[];

  // Deterministic XOR cipher keyed on (key, purpose, aad) for wire framing tests.
  String _seal(String key, String purpose, String aad, String plainHex) {
    final tag = base64Encode(utf8.encode('$key|$purpose|$aad'));
    return jsonEncode({'tag': tag, 'data': plainHex});
  }

  String _open(String key, String purpose, String aad, String cipher) {
    final map = jsonDecode(cipher) as Map<String, dynamic>;
    final expectedTag = base64Encode(utf8.encode('$key|$purpose|$aad'));
    if (map['tag'] != expectedTag) {
      throw StateError('lan_auth_failed');
    }
    return map['data'] as String;
  }

  Future<Map<String, dynamic>> invoke(Map<String, dynamic> req) async {
    final op = req['op'] as String;
    ops.add(op);
    switch (op) {
      case 'lock':
        lockCalled = true;
        return {'locked': true};
      case 'lan_sas':
        final combined = '${req['key']}:${req['token']}:${req['nonce']}';
        final code = combined.codeUnits.fold<int>(0, (a, b) => (a * 31 + b) % 1000000);
        final hi = (code ~/ 1000).toString().padLeft(3, '0');
        final lo = (code % 1000).toString().padLeft(3, '0');
        return {'sas': '$hi-$lo'};
      case 'lan_seal':
        return {
          'cipher': _seal(
            req['key'] as String,
            req['purpose'] as String,
            req['aad'] as String,
            req['plain'] as String,
          ),
        };
      case 'lan_open':
        return {
          'plain': _open(
            req['key'] as String,
            req['purpose'] as String,
            req['aad'] as String,
            req['cipher'] as String,
          ),
        };
      case 'export_lan_seed':
        final plainHex = _hex(
          utf8.encode(
            jsonEncode({
              'vault': '0123456789abcdef0123456789abcdef',
              'has_sync': hasSync,
              'count': objects.length,
            }),
          ),
        );
        return {
          'cipher': _seal(
            req['key'] as String,
            'seed',
            req['aad'] as String,
            plainHex,
          ),
          'objects': {
            for (final e in objects.entries) e.key: e.value.length,
          },
          'object_count': objects.length,
          'has_sync': hasSync,
        };
      case 'lan_build_pack':
        final hashes = (req['hashes'] as List).cast<String>();
        final packData = {for (final h in hashes) h: objects[h]!};
        return {
          'cipher': _seal(
            req['key'] as String,
            'pack',
            req['aad'] as String,
            _hex(utf8.encode(jsonEncode(packData))),
          ),
        };
      case 'join_lan_seed':
        final plain = utf8.decode(
          _unhex(
            _open(
              req['key'] as String,
              'seed',
              req['aad'] as String,
              req['cipher'] as String,
            ),
          ),
        );
        final meta = jsonDecode(plain) as Map<String, dynamic>;
        return {
          'session': 'mock-session-1',
          'vault': meta['vault'],
          'staged': (meta['count'] as int) > 0,
          'has_sync': meta['has_sync'],
        };
      case 'lan_ingest_pack':
        final plain = utf8.decode(
          _unhex(
            _open(
              req['key'] as String,
              'pack',
              req['aad'] as String,
              req['cipher'] as String,
            ),
          ),
        );
        final packData = (jsonDecode(plain) as Map).cast<String, String>();
        ingestedHashes.addAll(packData.keys);
        return {'count': packData.length};
      case 'lan_finish_join':
        committed = true;
        return {'committed': true, 'entries': ingestedHashes.length};
      default:
        throw StateError('unexpected_op:$op');
    }
  }
}

String _hex(List<int> bytes) {
  final sb = StringBuffer();
  for (final b in bytes) {
    sb.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

Uint8List _unhex(String hex) {
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

void main() {
  test('completes multi-pack LAN transfer with matching SAS', () async {
    final objects = {
      for (var i = 0; i < 70; i++)
        i.toRadixString(16).padLeft(64, '0'): 'ciphertext-body-$i',
    };
    final senderCore = _MockVaultCore(objects: objects);
    final receiverCore = _MockVaultCore();
    String? senderSas;
    String? receiverSas;
    final done = Completer<void>();
    final progressEvents = <int>[];

    final sender = await LanTransferSender.start(
      vaultId: '0123456789abcdef0123456789abcdef',
      sessionToken: 'src-session',
      invoke: senderCore.invoke,
      overrideIps: const ['127.0.0.1'],
      onPeerRequest: (peer) async {
        senderSas = peer.sas;
        expect(peer.deviceLabel, 'Pixel Fixture');
        return true;
      },
      onComplete: () {
        if (!done.isCompleted) done.complete();
      },
      onError: (e) {
        if (!done.isCompleted) done.completeError(e);
      },
    );
    addTearDown(sender.dispose);

    final result = await LanTransferReceiver.join(
      ticket: sender.ticket,
      vaultPath: '/tmp/unused.db',
      deviceLabel: 'Pixel Fixture',
      invoke: receiverCore.invoke,
      syncMode: SyncMode.automatic,
      onSasReady: (sas) => receiverSas = sas,
      onProgress: (p) => progressEvents.add(p.transferred),
    );
    await done.future.timeout(const Duration(seconds: 5));

    expect(senderSas, isNotNull);
    expect(receiverSas, senderSas);
    expect(result.session, 'mock-session-1');
    expect(result.objectCount, 70);
    expect(result.hasSync, isTrue);
    expect(receiverCore.committed, isTrue);
    expect(receiverCore.lockCalled, isFalse);
    expect(receiverCore.ingestedHashes.toSet(), objects.keys.toSet());
    expect(progressEvents.last, 70);
    expect(
      senderCore.ops.where((op) => op == 'lan_build_pack').length,
      2, // 64 + 6 across 2 packs
    );
  });

  test('sender rejection aborts receiver cleanly', () async {
    final senderCore = _MockVaultCore();
    final receiverCore = _MockVaultCore();
    final sender = await LanTransferSender.start(
      vaultId: '0123456789abcdef0123456789abcdef',
      sessionToken: 'src-session',
      invoke: senderCore.invoke,
      overrideIps: const ['127.0.0.1'],
      onPeerRequest: (_) async => false,
    );
    addTearDown(sender.dispose);

    await expectLater(
      LanTransferReceiver.join(
        ticket: sender.ticket,
        vaultPath: '/tmp/unused.db',
        deviceLabel: 'Rejected Device',
        invoke: receiverCore.invoke,
      ),
      throwsA(
        isA<StateError>().having((e) => e.message, 'message', 'lan_rejected'),
      ),
    );
    expect(receiverCore.committed, isFalse);
    expect(receiverCore.lockCalled, isTrue);
  });

  test('tampered frame triggers auth failure and lock cleanup', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    final receiverCore = _MockVaultCore();

    server.listen((client) async {
      // Read client hello length + payload, then send a tampered seed frame.
      await client.first;
      final body = utf8.encode(
        jsonEncode({
          't': 'seed',
          'c': jsonEncode({'tag': 'bad-tag', 'data': '00'}),
          'packs': 1,
          'objects': 1,
        }),
      );
      final frame = Uint8List(4 + body.length);
      ByteData.sublistView(frame, 0, 4).setUint32(0, body.length, Endian.big);
      frame.setRange(4, frame.length, body);
      client.add(frame);
      await client.flush();
      await client.close();
    });

    final ticket = await LanTransferSender.start(
      vaultId: '0123456789abcdef0123456789abcdef',
      sessionToken: 'unused',
      invoke: _MockVaultCore().invoke,
      overrideIps: const ['127.0.0.1'],
      onPeerRequest: (_) async => false,
    ).then((s) {
      final t = s.ticket;
      s.dispose();
      return t;
    });

    await expectLater(
      LanTransferReceiver.join(
        ticket: LanTransferTicket(
          ips: const ['127.0.0.1'],
          port: server.port,
          keyHex: ticket.keyHex,
          tokenHex: ticket.tokenHex,
          vaultId: ticket.vaultId,
        ),
        vaultPath: '/tmp/unused.db',
        deviceLabel: 'Target',
        invoke: receiverCore.invoke,
      ),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          'lan_auth_failed',
        ),
      ),
    );
    expect(receiverCore.committed, isFalse);
    expect(receiverCore.lockCalled, isTrue);
  });

  test('receiver cancellation before finish cleans up via lock', () async {
    final objects = {
      for (var i = 0; i < 65; i++)
        i.toRadixString(16).padLeft(64, '0'): 'body-$i',
    };
    final senderCore = _MockVaultCore(objects: objects);
    final receiverCore = _MockVaultCore();
    var cancelled = false;

    final sender = await LanTransferSender.start(
      vaultId: '0123456789abcdef0123456789abcdef',
      sessionToken: 'src-session',
      invoke: senderCore.invoke,
      overrideIps: const ['127.0.0.1'],
      onPeerRequest: (_) async => true,
    );
    addTearDown(sender.dispose);

    await expectLater(
      LanTransferReceiver.join(
        ticket: sender.ticket,
        vaultPath: '/tmp/unused.db',
        deviceLabel: 'Cancelling Device',
        invoke: receiverCore.invoke,
        onProgress: (p) {
          if (p.transferred > 0) cancelled = true;
        },
        isCancelled: () => cancelled,
      ),
      throwsA(
        isA<StateError>().having((e) => e.message, 'message', 'lan_cancelled'),
      ),
    );
    expect(receiverCore.committed, isFalse);
    expect(receiverCore.lockCalled, isTrue);
  });
}
