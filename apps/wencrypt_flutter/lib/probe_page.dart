import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import 'design/wencrypt_theme.dart';

const deviceProbe = MethodChannel('org.wencrypt.p0/device');

void main() => runApp(const WencryptProbeApp());

String runRustProbe() {
  final executable = File(Platform.resolvedExecutable);
  final library = switch (Platform.operatingSystem) {
    'android' => 'libwencrypt_core.so',
    'macos' =>
      '${executable.parent.parent.path}/Frameworks/libwencrypt_core.dylib',
    'windows' => '${executable.parent.path}\\wencrypt_core.dll',
    _ => throw UnsupportedError('Platform not supported'),
  };
  final core = DynamicLibrary.open(library);
  final version = core.lookupFunction<Uint32 Function(), int Function()>(
    'wencrypt_format_version',
  )();
  final elapsed = core.lookupFunction<Int64 Function(), int Function()>(
    'wencrypt_probe_unlock_ms',
  )();
  if (version != 1 || elapsed < 0) throw StateError('Rust probe failed');
  return 'WENC v$version 验证通过，Argon2id 解锁 ${elapsed}ms';
}

class WencryptProbeApp extends StatefulWidget {
  const WencryptProbeApp({super.key});

  @override
  State<WencryptProbeApp> createState() => _WencryptProbeAppState();
}

class _WencryptProbeAppState extends State<WencryptProbeApp> {
  String result = '验证仅使用公开测试数据';
  bool busy = false;

  Future<void> run(Future<String> Function() operation) async {
    setState(() => busy = true);
    String next;
    try {
      next = await operation();
    } catch (_) {
      next = '验证未通过，请检查运行环境和打包产物。';
    }
    if (!mounted) return;
    setState(() {
      result = next;
      busy = false;
    });
  }

  Future<String> native(String method) async {
    final output = await deviceProbe.invokeMapMethod<String, Object?>(method);
    return output!.entries
        .map((entry) => '${entry.key} = ${entry.value}')
        .join('\n');
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: wencryptTheme(Brightness.light),
    darkTheme: wencryptTheme(Brightness.dark),
    home: Scaffold(
      appBar: AppBar(title: const Text('Wencrypt P0')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Center(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: Image.asset(
                'assets/brand/wencrypt-logo.png',
                width: 152,
                height: 152,
                semanticLabel: 'Wencrypt 标志',
              ),
            ),
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: busy ? null : () => run(() => Isolate.run(runRustProbe)),
            child: const Text('验证 Rust 加密与解锁耗时'),
          ),
          for (final (method, label) in [
            ('capabilities', '检查设备安全能力'),
            ('createProbe', '生成测试密钥'),
            if (!Platform.isWindows) ('unlockProbe', '认证并解包测试数据'),
            if (!Platform.isWindows) ('resetProbe', '清除测试密钥'),
          ])
            OutlinedButton(
              onPressed: busy ? null : () => run(() => native(method)),
              child: Text(label),
            ),
          const SizedBox(height: 16),
          // This output is read-only. Avoid an editable text client on macOS.
          Semantics(liveRegion: true, child: Text(busy ? '正在验证…' : result)),
        ],
      ),
    ),
  );
}
