import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'sync.dart';
import 'vault_invite.dart';

typedef CoreInvoker =
    Future<Map<String, dynamic>> Function(Map<String, dynamic> request);

const int _maxFrameBytes = 2 * 1024 * 1024;
const int _maxLanPackBytes = 250 * 1024;
const int _maxLanPackObjects = 64;

class LanPeerRequest {
  const LanPeerRequest({
    required this.remoteAddress,
    required this.deviceLabel,
    required this.sas,
  });

  final String remoteAddress;
  final String deviceLabel;
  final String sas;
}

class LanTransferProgress {
  const LanTransferProgress({required this.transferred, required this.total});

  final int transferred;
  final int total;

  double? get fraction => total <= 0 ? null : (transferred / total).clamp(0, 1);
}

class LanJoinResult {
  const LanJoinResult({
    required this.session,
    required this.vaultId,
    required this.objectCount,
    required this.hasSync,
  });

  final String session;
  final String vaultId;
  final int objectCount;
  final bool hasSync;
}

Future<List<String>> localLanAddresses() async {
  final interfaces = await NetworkInterface.list(
    type: InternetAddressType.IPv4,
  );
  int rank(String ip) {
    if (ip.startsWith('192.168.')) return 0;
    if (ip.startsWith('10.')) return 1;
    final parts = ip.split('.');
    if (parts.length == 4) {
      final second = int.tryParse(parts[1]) ?? -1;
      if (parts[0] == '172' && second >= 16 && second <= 31) return 2;
    }
    return 3;
  }

  final candidates = <String>[];
  final seen = <String>{};
  for (final iface in interfaces) {
    for (final addr in iface.addresses) {
      final ip = addr.address;
      if (addr.isLoopback ||
          addr.isMulticast ||
          ip == '0.0.0.0' ||
          ip.startsWith('127.') ||
          ip.startsWith('169.254.')) {
        continue;
      }
      if (seen.add(ip)) candidates.add(ip);
    }
  }
  candidates.sort((a, b) => rank(a).compareTo(rank(b)));
  if (candidates.length > 4) return candidates.sublist(0, 4);
  return candidates;
}

class LanTransferSender {
  LanTransferSender._(
    this._server,
    this.ticket,
    this.expiresAt,
    this._keyBytes,
    this._tokenBytes,
    this._sessionToken,
    this._invoke,
    this._onPeerRequest,
    this._includeSyncSettings, {
    this.onProgress,
    this.onComplete,
    this.onExpired,
    this.onError,
  });

  final ServerSocket _server;
  final LanTransferTicket ticket;
  final DateTime expiresAt;
  final Uint8List _keyBytes;
  final Uint8List _tokenBytes;
  final String _sessionToken;
  final CoreInvoker _invoke;
  final Future<bool> Function(LanPeerRequest peer) _onPeerRequest;
  final bool _includeSyncSettings;
  final void Function(LanTransferProgress progress)? onProgress;
  final void Function()? onComplete;
  final void Function()? onExpired;
  final void Function(Object error)? onError;

  Timer? _ttlTimer;
  StreamSubscription<Socket>? _sub;
  bool _disposed = false;
  bool _busyClient = false;
  bool _completed = false;
  int _failures = 0;

  static Future<LanTransferSender> start({
    required String vaultId,
    required String sessionToken,
    required CoreInvoker invoke,
    required Future<bool> Function(LanPeerRequest peer) onPeerRequest,
    void Function(LanTransferProgress progress)? onProgress,
    void Function()? onComplete,
    void Function()? onExpired,
    void Function(Object error)? onError,
    bool includeSyncSettings = true,
    Duration ttl = const Duration(seconds: 120),
    List<String>? overrideIps,
  }) async {
    final ips = overrideIps ?? await localLanAddresses();
    if (ips.isEmpty) {
      throw StateError('lan_no_network');
    }
    final rng = Random.secure();
    final keyBytes = Uint8List.fromList(
      List<int>.generate(32, (_) => rng.nextInt(256)),
    );
    final tokenBytes = Uint8List.fromList(
      List<int>.generate(16, (_) => rng.nextInt(256)),
    );
    final keyHex = _encodeHex(keyBytes);
    final tokenHex = _encodeHex(tokenBytes);
    final server = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    final ticket = LanTransferTicket(
      ips: ips,
      port: server.port,
      keyHex: keyHex,
      tokenHex: tokenHex,
      vaultId: vaultId,
    );
    final sender = LanTransferSender._(
      server,
      ticket,
      DateTime.now().add(ttl),
      keyBytes,
      tokenBytes,
      sessionToken,
      invoke,
      onPeerRequest,
      includeSyncSettings,
      onProgress: onProgress,
      onComplete: onComplete,
      onExpired: onExpired,
      onError: onError,
    );
    sender._listen(ttl);
    return sender;
  }

  void _listen(Duration ttl) {
    _ttlTimer = Timer(ttl, () {
      if (_disposed || _completed) return;
      dispose();
      onExpired?.call();
    });
    _sub = _server.listen(
      (socket) {
        if (_disposed || _completed || _busyClient) {
          socket.destroy();
          return;
        }
        _busyClient = true;
        unawaited(_handleClient(socket));
      },
      onError: (Object error) {
        if (!_disposed && !_completed) {
          onError?.call(error);
        }
      },
    );
  }

  Future<void> _handleClient(Socket socket) async {
    final reader = _FrameReader(socket);
    try {
      final helloFrame = await reader.readFrame(const Duration(seconds: 10));
      if (helloFrame['t'] != 'hello' ||
          helloFrame['n'] is! String ||
          helloFrame['c'] is! String) {
        throw StateError('lan_frame_invalid');
      }
      final nonceHex = helloFrame['n'] as String;
      if (!_isHexOfBytes(nonceHex, 16)) {
        throw StateError('lan_frame_invalid');
      }

      final opened = await _invoke({
        'op': 'lan_open',
        'key': ticket.keyHex,
        'purpose': 'hello',
        'aad': 'hello:$nonceHex',
        'cipher': helloFrame['c'],
      });
      final plainBytes = _decodeHex(opened['plain'] as String);
      final helloPayload = jsonDecode(utf8.decode(plainBytes));
      if (helloPayload is! Map ||
          helloPayload['token'] != ticket.tokenHex ||
          helloPayload['nonce'] != nonceHex) {
        throw StateError('lan_auth_failed');
      }
      final deviceLabel = (helloPayload['device'] as String? ?? '').trim();

      final sasRes = await _invoke({
        'op': 'lan_sas',
        'key': ticket.keyHex,
        'token': ticket.tokenHex,
        'nonce': nonceHex,
      });
      final sas = sasRes['sas'] as String;
      if (_disposed) return;

      final approved = await _onPeerRequest(
        LanPeerRequest(
          remoteAddress: socket.remoteAddress.address,
          deviceLabel: deviceLabel.isEmpty ? '新设备' : deviceLabel,
          sas: sas,
        ),
      );
      if (_disposed) return;

      if (!approved) {
        _failures++;
        final rejectPlain = utf8.encode(jsonEncode({'reason': 'rejected'}));
        final rejectSealed = await _invoke({
          'op': 'lan_seal',
          'key': ticket.keyHex,
          'purpose': 'reject',
          'aad': 'reject:$nonceHex',
          'plain': _encodeHex(rejectPlain),
        });
        await _writeFrame(socket, {'t': 'reject', 'c': rejectSealed['cipher']});
        if (_failures >= 3) {
          dispose();
          onError?.call(StateError('lan_too_many_failures'));
        }
        return;
      }

      // Stop idle expiry while actively streaming objects.
      _ttlTimer?.cancel();
      final seedRes = await _invoke({
        'op': 'export_lan_seed',
        'session': _sessionToken,
        'key': ticket.keyHex,
        'aad': 'seed:$nonceHex',
        'include_sync_settings': _includeSyncSettings,
      });
      if (_disposed) return;

      final objects = Map<String, int>.from(seedRes['objects'] as Map);
      final groups = _packGroups(objects);
      final totalObjects = seedRes['object_count'] as int;

      await _writeFrame(socket, {
        't': 'seed',
        'c': seedRes['cipher'],
        'packs': groups.length,
        'objects': totalObjects,
      });
      onProgress?.call(LanTransferProgress(transferred: 0, total: totalObjects));

      var sent = 0;
      for (var i = 0; i < groups.length; i++) {
        if (_disposed) return;
        final packRes = await _invoke({
          'op': 'lan_build_pack',
          'session': _sessionToken,
          'hashes': groups[i],
          'key': ticket.keyHex,
          'aad': 'pack:$nonceHex:$i',
        });
        await _writeFrame(socket, {
          't': 'pack',
          'i': i,
          'c': packRes['cipher'],
        });
        sent += groups[i].length;
        onProgress?.call(
          LanTransferProgress(transferred: sent, total: totalObjects),
        );
      }

      final ackFrame = await reader.readFrame(const Duration(seconds: 30));
      if (ackFrame['t'] != 'ack' || ackFrame['c'] is! String) {
        throw StateError('lan_frame_invalid');
      }
      final ackOpened = await _invoke({
        'op': 'lan_open',
        'key': ticket.keyHex,
        'purpose': 'ack',
        'aad': 'ack:$nonceHex',
        'cipher': ackFrame['c'],
      });
      final ackPayload = jsonDecode(
        utf8.decode(_decodeHex(ackOpened['plain'] as String)),
      );
      if (ackPayload is! Map ||
          ackPayload['ok'] != true ||
          ackPayload['vault'] != ticket.vaultId) {
        throw StateError('lan_auth_failed');
      }

      _completed = true;
      dispose();
      onComplete?.call();
    } catch (error) {
      _failures++;
      if (!_disposed && !_completed) {
        if (_failures >= 3) {
          dispose();
          onError?.call(error);
        } else if (error is StateError &&
            (error.message == 'lan_auth_failed' ||
                error.message == 'lan_frame_invalid')) {
          // Wait for a legitimate client unless limit reached.
        } else {
          onError?.call(error);
        }
      }
    } finally {
      _busyClient = false;
      await reader.cancel();
      try {
        await socket.close();
      } catch (_) {
        socket.destroy();
      }
    }
  }

  List<List<String>> _packGroups(Map<String, int> objects) {
    final groups = <List<String>>[];
    var current = <String>[];
    var currentBytes = 4; // WPK1 magic
    for (final entry in objects.entries) {
      final needed = 4 + entry.value;
      if (current.isNotEmpty &&
          (current.length >= _maxLanPackObjects ||
              currentBytes + needed > _maxLanPackBytes)) {
        groups.add(current);
        current = <String>[];
        currentBytes = 4;
      }
      current.add(entry.key);
      currentBytes += needed;
    }
    if (current.isNotEmpty) groups.add(current);
    return groups;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _ttlTimer?.cancel();
    _ttlTimer = null;
    _keyBytes.fillRange(0, _keyBytes.length, 0);
    _tokenBytes.fillRange(0, _tokenBytes.length, 0);
    unawaited(_sub?.cancel() ?? Future<void>.value());
    unawaited(_server.close().catchError((_) => _server));
  }
}

class LanTransferReceiver {
  static Future<LanJoinResult> join({
    required LanTransferTicket ticket,
    required String vaultPath,
    required String deviceLabel,
    required CoreInvoker invoke,
    SyncMode syncMode = SyncMode.notify,
    void Function(String sas)? onSasReady,
    void Function(LanTransferProgress progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    Socket? socket;
    for (final ip in ticket.ips) {
      if (isCancelled?.call() == true) throw StateError('lan_cancelled');
      try {
        socket = await Socket.connect(
          ip,
          ticket.port,
          timeout: const Duration(seconds: 3),
        );
        break;
      } catch (_) {
        socket = null;
      }
    }
    if (socket == null) {
      throw StateError('lan_connect_failed');
    }

    final reader = _FrameReader(socket);
    var committed = false;
    try {
      final rng = Random.secure();
      final nonceBytes = Uint8List.fromList(
        List<int>.generate(16, (_) => rng.nextInt(256)),
      );
      final nonceHex = _encodeHex(nonceBytes);

      final sasRes = await invoke({
        'op': 'lan_sas',
        'key': ticket.keyHex,
        'token': ticket.tokenHex,
        'nonce': nonceHex,
      });
      final sas = sasRes['sas'] as String;
      onSasReady?.call(sas);
      if (isCancelled?.call() == true) throw StateError('lan_cancelled');

      final helloPlain = utf8.encode(
        jsonEncode({
          'token': ticket.tokenHex,
          'nonce': nonceHex,
          'device': deviceLabel,
        }),
      );
      final helloSealed = await invoke({
        'op': 'lan_seal',
        'key': ticket.keyHex,
        'purpose': 'hello',
        'aad': 'hello:$nonceHex',
        'plain': _encodeHex(helloPlain),
      });
      await _writeFrame(socket, {
        't': 'hello',
        'n': nonceHex,
        'c': helloSealed['cipher'],
      });

      final response = await reader.readFrame(const Duration(seconds: 125));
      if (response['t'] == 'reject') {
        if (response['c'] is String) {
          await invoke({
            'op': 'lan_open',
            'key': ticket.keyHex,
            'purpose': 'reject',
            'aad': 'reject:$nonceHex',
            'cipher': response['c'],
          });
        }
        throw StateError('lan_rejected');
      }
      if (response['t'] != 'seed' ||
          response['c'] is! String ||
          response['packs'] is! int ||
          response['objects'] is! int) {
        throw StateError('lan_frame_invalid');
      }
      final packCount = response['packs'] as int;
      final objectCount = response['objects'] as int;
      if (packCount < 0 || objectCount < 0 || objectCount > 10000) {
        throw StateError('lan_frame_invalid');
      }

      final seedRes = await invoke({
        'op': 'join_lan_seed',
        'path': vaultPath,
        'key': ticket.keyHex,
        'aad': 'seed:$nonceHex',
        'cipher': response['c'],
        'expected_vault': ticket.vaultId,
        'sync_mode': syncMode.name,
      });
      final session = seedRes['session'] as String;
      final hasSync = seedRes['has_sync'] == true;
      onProgress?.call(
        LanTransferProgress(transferred: 0, total: objectCount),
      );

      var received = 0;
      for (var i = 0; i < packCount; i++) {
        if (isCancelled?.call() == true) throw StateError('lan_cancelled');
        final packFrame = await reader.readFrame(const Duration(seconds: 30));
        if (packFrame['t'] != 'pack' ||
            packFrame['i'] != i ||
            packFrame['c'] is! String) {
          throw StateError('lan_frame_invalid');
        }
        final ingested = await invoke({
          'op': 'lan_ingest_pack',
          'session': session,
          'key': ticket.keyHex,
          'aad': 'pack:$nonceHex:$i',
          'cipher': packFrame['c'],
        });
        received += ingested['count'] as int;
        onProgress?.call(
          LanTransferProgress(transferred: received, total: objectCount),
        );
      }

      if (isCancelled?.call() == true) throw StateError('lan_cancelled');
      await invoke({'op': 'lan_finish_join', 'session': session});
      committed = true;

      final ackPlain = utf8.encode(
        jsonEncode({'ok': true, 'vault': ticket.vaultId}),
      );
      final ackSealed = await invoke({
        'op': 'lan_seal',
        'key': ticket.keyHex,
        'purpose': 'ack',
        'aad': 'ack:$nonceHex',
        'plain': _encodeHex(ackPlain),
      });
      await _writeFrame(socket, {'t': 'ack', 'c': ackSealed['cipher']});

      return LanJoinResult(
        session: session,
        vaultId: seedRes['vault'] as String,
        objectCount: objectCount,
        hasSync: hasSync,
      );
    } finally {
      if (!committed) {
        try {
          await invoke({'op': 'lock'});
        } catch (_) {
          // Best-effort cleanup of any staged database.
        }
      }
      await reader.cancel();
      try {
        await socket.close();
      } catch (_) {
        socket.destroy();
      }
    }
  }
}

class _FrameReader {
  _FrameReader(Socket socket) : _iterator = StreamIterator<Uint8List>(socket);

  final StreamIterator<Uint8List> _iterator;
  final List<int> _buffer = [];
  bool _eof = false;

  Future<Map<String, dynamic>> readFrame(Duration timeout) async {
    Future<void> ensure(int needed) async {
      while (_buffer.length < needed) {
        if (_eof) throw StateError('lan_connection_closed');
        final hasNext = await _iterator.moveNext().timeout(
          timeout,
          onTimeout: () => throw TimeoutException('lan_timeout'),
        );
        if (!hasNext) {
          _eof = true;
          throw StateError('lan_connection_closed');
        }
        _buffer.addAll(_iterator.current);
      }
    }

    await ensure(4);
    final length =
        (_buffer[0] << 24) |
        (_buffer[1] << 16) |
        (_buffer[2] << 8) |
        _buffer[3];
    if (length <= 0 || length > _maxFrameBytes) {
      throw StateError('lan_frame_invalid');
    }
    await ensure(4 + length);
    final payloadBytes = _buffer.sublist(4, 4 + length);
    _buffer.removeRange(0, 4 + length);
    final decoded = jsonDecode(utf8.decode(payloadBytes));
    if (decoded is! Map) throw StateError('lan_frame_invalid');
    return decoded.cast<String, dynamic>();
  }

  Future<void> cancel() async {
    try {
      await _iterator.cancel();
    } catch (_) {
      // Socket may already be closed.
    }
  }
}

Future<void> _writeFrame(Socket socket, Map<String, dynamic> payload) async {
  final body = utf8.encode(jsonEncode(payload));
  if (body.length > _maxFrameBytes) {
    throw StateError('lan_frame_invalid');
  }
  final frame = Uint8List(4 + body.length);
  final header = ByteData.sublistView(frame, 0, 4);
  header.setUint32(0, body.length, Endian.big);
  frame.setRange(4, frame.length, body);
  socket.add(frame);
  await socket.flush();
}

bool _isHexOfBytes(String value, int bytes) =>
    value.length == bytes * 2 && RegExp(r'^[0-9a-fA-F]+$').hasMatch(value);

String _encodeHex(List<int> bytes) {
  final sb = StringBuffer();
  for (final b in bytes) {
    sb.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

Uint8List _decodeHex(String hex) {
  if (hex.length.isOdd) throw StateError('lan_frame_invalid');
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}
