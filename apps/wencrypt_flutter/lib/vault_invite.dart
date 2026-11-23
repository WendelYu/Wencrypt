import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

class VaultInvite {
  const VaultInvite({required this.folder, required this.vault});

  static final _vaultId = RegExp(r'^[0-9a-f]{32}$');
  final String folder;
  final String vault;

  static VaultInvite? parse(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null ||
        uri.scheme != 'wencrypt' ||
        uri.host != 'join' ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/')) {
      return null;
    }
    final Map<String, List<String>> parameters;
    try {
      parameters = uri.queryParametersAll;
    } on FormatException {
      return null;
    }
    final folder = parameters['folder'];
    final vault = parameters['vault'];
    if (parameters.length != 2 ||
        folder?.length != 1 ||
        vault?.length != 1 ||
        !_vaultId.hasMatch(vault!.single)) {
      return null;
    }
    final name = folder!.single;
    if (name.trim().isEmpty ||
        name.length > 32 ||
        name == '.' ||
        name.contains('..') ||
        name.contains('/') ||
        name.contains('\\') ||
        name.codeUnits.any((code) => code < 32 || code == 127)) {
      return null;
    }
    return VaultInvite(folder: name, vault: vault.single);
  }

  Uri toUri() => Uri(
    scheme: 'wencrypt',
    host: 'join',
    queryParameters: {'folder': folder, 'vault': vault},
  );
}

sealed class JoinInvite {
  const JoinInvite();

  String get vaultId;
  Uri toUri();
}

final class LegacyVaultInvite extends JoinInvite {
  const LegacyVaultInvite(this.invite);

  final VaultInvite invite;

  @override
  String get vaultId => invite.vault;

  @override
  Uri toUri() => invite.toUri();
}

final class EncryptedVaultInvite extends JoinInvite {
  const EncryptedVaultInvite({required this.payloadHex, required this.vaultId});

  final String payloadHex;
  @override
  final String vaultId;

  static EncryptedVaultInvite? fromPayloadHex(String hex) {
    final bytes = _decodeHex(hex);
    if (bytes == null) return null;
    return _fromBytes(bytes, hex.toLowerCase());
  }

  static EncryptedVaultInvite? _fromBase64Url(String encoded) {
    final bytes = _decodeBase64Url(encoded);
    if (bytes == null) return null;
    return _fromBytes(bytes, _encodeHex(bytes));
  }

  static EncryptedVaultInvite? _fromBytes(Uint8List bytes, String hex) {
    // 8B WENCINV2 + 135B bootstrap + >=91B backup object
    if (bytes.length < 234 || bytes.length > 4096) return null;
    const invMagic = [0x57, 0x45, 0x4e, 0x43, 0x49, 0x4e, 0x56, 0x32]; // WENCINV2
    for (var i = 0; i < 8; i++) {
      if (bytes[i] != invMagic[i]) return null;
    }
    const bootMagic = [0x57, 0x45, 0x4e, 0x43, 0x52, 0x59, 0x50, 0x54]; // WENCRYPT
    for (var i = 0; i < 8; i++) {
      if (bytes[8 + i] != bootMagic[i]) return null;
    }
    // Version [1, 0] + Kind::Bootstrap (1)
    if (bytes[16] != 1 || bytes[17] != 0 || bytes[18] != 1) return null;
    final id = _encodeHex(Uint8List.sublistView(bytes, 19, 35));
    return EncryptedVaultInvite(payloadHex: hex, vaultId: id);
  }

  @override
  Uri toUri() {
    final bytes = _decodeHex(payloadHex)!;
    return Uri(
      scheme: 'wencrypt',
      host: 'join',
      queryParameters: {'v': '2', 'p': _encodeBase64UrlNoPad(bytes)},
    );
  }
}

final class LanTransferTicket extends JoinInvite {
  const LanTransferTicket({
    required this.ips,
    required this.port,
    required this.keyHex,
    required this.tokenHex,
    required this.vaultId,
  });

  final List<String> ips;
  final int port;
  final String keyHex;
  final String tokenHex;
  @override
  final String vaultId;

  static LanTransferTicket? _fromBase64Url(String encoded) {
    final bytes = _decodeBase64Url(encoded);
    if (bytes == null || bytes.length > 1024) return null;
    final dynamic decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes));
    } catch (_) {
      return null;
    }
    if (decoded is! Map) return null;
    final rawIps = decoded['i'];
    final port = decoded['p'];
    final rawKey = decoded['k'];
    final rawToken = decoded['t'];
    final vault = decoded['v'];
    if (rawIps is! List ||
        rawIps.isEmpty ||
        rawIps.length > 4 ||
        port is! int ||
        port < 1024 ||
        port > 65535 ||
        rawKey is! String ||
        rawToken is! String ||
        vault is! String ||
        !VaultInvite._vaultId.hasMatch(vault)) {
      return null;
    }
    final ips = <String>[];
    for (final item in rawIps) {
      if (item is! String) return null;
      final addr = InternetAddress.tryParse(item);
      if (addr == null ||
          addr.type != InternetAddressType.IPv4 ||
          addr.isLoopback ||
          addr.isMulticast ||
          item == '0.0.0.0' ||
          item.startsWith('169.254.')) {
        return null;
      }
      ips.add(addr.address);
    }
    final keyBytes = _decodeBase64Url(rawKey);
    final tokenBytes = _decodeBase64Url(rawToken);
    if (keyBytes == null ||
        keyBytes.length != 32 ||
        tokenBytes == null ||
        tokenBytes.length != 16) {
      return null;
    }
    return LanTransferTicket(
      ips: ips,
      port: port,
      keyHex: _encodeHex(keyBytes),
      tokenHex: _encodeHex(tokenBytes),
      vaultId: vault,
    );
  }

  @override
  Uri toUri() {
    final keyBytes = _decodeHex(keyHex)!;
    final tokenBytes = _decodeHex(tokenHex)!;
    final jsonBytes = utf8.encode(
      jsonEncode({
        'i': ips,
        'p': port,
        'k': _encodeBase64UrlNoPad(keyBytes),
        't': _encodeBase64UrlNoPad(tokenBytes),
        'v': vaultId,
      }),
    );
    return Uri(
      scheme: 'wencrypt',
      host: 'join',
      queryParameters: {
        'v': '2',
        'lan': _encodeBase64UrlNoPad(Uint8List.fromList(jsonBytes)),
      },
    );
  }
}

JoinInvite? parseJoinInvite(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;

  if (trimmed.startsWith('wencrypt-invite:v2:')) {
    final encoded = trimmed.substring('wencrypt-invite:v2:'.length).trim();
    return EncryptedVaultInvite._fromBase64Url(encoded);
  }

  final legacy = VaultInvite.parse(trimmed);
  if (legacy != null) return LegacyVaultInvite(legacy);

  final uri = Uri.tryParse(trimmed);
  if (uri != null &&
      uri.scheme == 'wencrypt' &&
      uri.host == 'join' &&
      uri.userInfo.isEmpty &&
      !uri.hasPort &&
      !uri.hasFragment &&
      (uri.path.isEmpty || uri.path == '/')) {
    final Map<String, List<String>> params;
    try {
      params = uri.queryParametersAll;
    } on FormatException {
      return null;
    }
    final version = params['v'];
    if (version?.length == 1 && version!.single == '2' && params.length == 2) {
      final p = params['p'];
      if (p?.length == 1) {
        return EncryptedVaultInvite._fromBase64Url(p!.single);
      }
      final lan = params['lan'];
      if (lan?.length == 1) {
        return LanTransferTicket._fromBase64Url(lan!.single);
      }
    }
    return null;
  }

  // Fallback: direct paste of base64url encrypted invite payload
  return EncryptedVaultInvite._fromBase64Url(trimmed);
}

final RegExp _b64uPattern = RegExp(r'^[A-Za-z0-9_-]+={0,2}$');

Uint8List? _decodeBase64Url(String input) {
  if (input.isEmpty || !_b64uPattern.hasMatch(input)) return null;
  final mod = input.length % 4;
  if (mod == 1) return null;
  final padded = mod == 0 ? input : '$input${'=' * (4 - mod)}';
  try {
    return base64Url.decode(padded);
  } catch (_) {
    return null;
  }
}

String _encodeBase64UrlNoPad(Uint8List bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

Uint8List? _decodeHex(String hex) {
  if (hex.length.isOdd) return null;
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    final byte = int.tryParse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    if (byte == null) return null;
    out[i] = byte;
  }
  return out;
}

String _encodeHex(Uint8List bytes) {
  final sb = StringBuffer();
  for (final b in bytes) {
    sb.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}
