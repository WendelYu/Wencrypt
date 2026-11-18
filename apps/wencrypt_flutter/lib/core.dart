import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

String _request(String request) {
  final exe = File(Platform.resolvedExecutable);
  final path = switch (Platform.operatingSystem) {
    'macos' => '${exe.parent.parent.path}/Frameworks/libwencrypt_core.dylib',
    'windows' => '${exe.parent.path}\\wencrypt_core.dll',
    'android' => 'libwencrypt_core.so',
    _ => throw UnsupportedError('Unsupported platform'),
  };
  final lib = DynamicLibrary.open(path);
  final alloc = lib
      .lookupFunction<
        Pointer<Uint8> Function(UintPtr),
        Pointer<Uint8> Function(int)
      >('wencrypt_alloc');
  final free = lib
      .lookupFunction<
        Void Function(Pointer<Uint8>, UintPtr),
        void Function(Pointer<Uint8>, int)
      >('wencrypt_free');
  final run = lib
      .lookupFunction<
        Pointer<Utf8> Function(Pointer<Uint8>, UintPtr),
        Pointer<Utf8> Function(Pointer<Uint8>, int)
      >('wencrypt_command');
  final release = lib
      .lookupFunction<
        Void Function(Pointer<Utf8>),
        void Function(Pointer<Utf8>)
      >('wencrypt_result_free');
  final bytes = utf8.encode(request);
  final p = alloc(bytes.length);
  if (p == nullptr) throw StateError('request_limit');
  try {
    p.asTypedList(bytes.length).setAll(0, bytes);
    final result = run(p, bytes.length);
    try {
      return result.toDartString();
    } finally {
      release(result);
    }
  } finally {
    bytes.fillRange(0, bytes.length, 0);
    free(p, bytes.length);
  }
}

int _epoch = 0;
int get nativeEpoch => _epoch;
// Synchronous invalidation serializes with the Rust mutex before the app backgrounds.
// Queued requests carry an older epoch and cannot reopen a locked vault.
void lockCore() {
  _epoch++;
  _request(jsonEncode({'op': 'lock', 'epoch': _epoch}));
}

Future<Map<String, dynamic>> core(Map<String, dynamic> request) async {
  final input = jsonEncode({...request, 'epoch': _epoch});
  final result = jsonDecode(
    await Isolate.run(() => _request(input)),
  ) as Map<String, dynamic>;
  if (result['ok'] != true) throw StateError(result['error'] as String);
  return result['result'] as Map<String, dynamic>;
}
