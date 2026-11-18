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
