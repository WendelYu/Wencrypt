import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';
import 'package:file_selector/file_selector.dart';
import 'package:csv/csv.dart';

import 'core.dart';
import 'sync.dart';
import 'probe_page.dart' show WencryptProbeApp;

void main() => runApp(const WencryptApp());

class WencryptApp extends StatelessWidget {
  const WencryptApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Wencrypt',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff2458a6)),
      useMaterial3: true,
    ),
    home: const VaultPage(),
  );
}

class VaultPage extends StatefulWidget {
  const VaultPage({super.key});
  @override
  State<VaultPage> createState() => _VaultPageState();
}

class _VaultPageState extends State<VaultPage> with WidgetsBindingObserver {
  final master = TextEditingController();
  final confirm = TextEditingController();
  String? path, token;
  String message = '正在加载…', query = '';
  bool exists = false, busy = false, trash = false;
  int generation = 0;
  List<Map<String, dynamic>> entries = [];
  Timer? idle, clipboard;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    initialize();
  }

  Future<void> initialize() async {
    try {
      final dir = await getApplicationSupportDirectory();
      await dir.create(recursive: true);
      path = '${dir.path}/wencrypt-alpha.db';
      exists = await File(path!).exists();
      if (mounted) setState(() => message = '本地加密 · 离线可用');
    } catch (_) {
      if (mounted) setState(() => message = '无法打开应用数据目录');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    master.dispose();
    confirm.dispose();
    idle?.cancel();
    clipboard?.cancel();
    super.dispose();
  }

  void touch() {
    idle?.cancel();
    if (token != null) idle = Timer(const Duration(minutes: 5), lock);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) lock();
  }

  void lock() {
    generation++;
    token = null;
    entries = [];
    master.clear();
    confirm.clear();
    idle?.cancel();
    if (mounted) {
      Navigator.of(context).popUntil((r) => r.isFirst);
      setState(() => message = '密码库已锁定');
    }
    try {
      lockCore();
    } catch (_) {
      /* A missing core cannot hold an active vault. */
    }
  }

  Future<void> action(Future<void> Function() task) async {
    if (busy) return;
    setState(() {
      busy = true;
      message = '';
    });
    try {
      await task();
    } catch (e) {
      if (mounted) setState(() => message = friendly(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  String friendly(Object e) {
    final text = e.toString();
    if (text.contains('backup_limit')) return '超出 Alpha 的 2 MiB 备份上限，导出已停止。';
    if (text.contains('free_budget')) return '已达到本机免费流量或请求预算，请稍后再试。';
    if (text.contains('remote_missing')) return '云端副本缺失，已停止同步；本地数据仍保留。';
    if (text.contains('directory_limit')) return '达到 Alpha 云目录上限，请先导出加密备份。';
    if (text.contains('entry_changed')) return '条目已被修改，请重新打开后编辑。';
    if (text.contains('authentication')) return '主密码不正确或文件已损坏。';
    if (text.contains('password_length')) return '主密码至少需要 12 个字符。';
    if (text.contains('session') || text.contains('locked')) {
      return '密码库已锁定，请重新解锁。';
    }
    return '操作未完成，请检查文件、网络或输入后重试。';
  }

  Future<void> unlock() => action(() async {
    if (!exists && master.text != confirm.text) {
      setState(() => message = '两次主密码不一致');
      return;
    }
    final epoch = generation;
    final result = await core({
      'op': exists ? 'unlock' : 'create',
      'path': path,
      'password': master.text,
    });
    master.clear();
    confirm.clear();
    if (epoch != generation) {
      await core({'op': 'lock'});
      return;
    }
    token = result['session'] as String;
    exists = true;
    touch();
    await refresh();
  });
  Future<Map<String, dynamic>> request(
    String op, [
    Map<String, dynamic> extra = const {},
  ]) async {
    final current = token;
    final epoch = generation;
    if (current == null) throw StateError('locked');
    final result = await core({'op': op, 'session': current, ...extra});
    if (epoch != generation) throw StateError('locked');
    return result;
  }

  Future<void> refresh() async {
    final data = await request('list');
    if (mounted) {
      setState(() {
        entries = (data['entries'] as List).cast<Map<String, dynamic>>();
        message = data['pending'] == 0 ? '已保存在本机' : '存在缺失的历史版本，请完成同步';
      });
    }
  }

  Future<void> copy(String value) async {
    touch();
    if (Platform.isAndroid) {
      await const MethodChannel('org.wencrypt.files')
          .invokeMethod('copySensitive', {'text': value});
    } else {
      await Clipboard.setData(ClipboardData(text: value));
    }
    clipboard?.cancel();
    clipboard = Timer(const Duration(seconds: 20), () async {
      final current = await Clipboard.getData('text/plain');
      if (current?.text == value) {
        await Clipboard.setData(const ClipboardData(text: ''));
      }
    });
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已复制，20 秒后清除')));
    }
  }

  Future<void> edit(Map<String, dynamic>? revision) async {
    touch();
    final epoch = generation;
    final group = revision == null
        ? <Map<String, dynamic>>[]
        : entries.where((r) => r['entry'] == revision['entry']).toList();
    final controllers = <String, TextEditingController>{
      for (final key in [
        'title',
        'username',
        'password',
        'url',
        'tags',
        'notes',
      ])
        key: TextEditingController(
          text: revision?['data'][key] as String? ?? '',
        ),
    };
    bool reveal = false;
    final result = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: Text(
            revision == null
                ? '新增账号'
                : group.length > 1
                ? '解决冲突（${group.length} 个版本）'
                : '编辑账号',
          ),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (group.length > 1) ...[
                    const Text('选择一个版本作为基础，再编辑并保存。历史版本仍会保留。'),
                    for (final r in group)
                      TextButton(
                        onPressed: () {
                          for (final key in controllers.keys) {
                            controllers[key]!.text = r['data'][key] as String;
                          }
                          setLocal(() {});
                        },
                        child: Text(
                          '${r['data']['title']} · ${r['deleted'] == true ? '删除版本' : r['data']['username']} · ${r['id'].toString().substring(0, 8)}',
                        ),
                      ),
                  ],
                  for (final key in controllers.keys)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: TextField(
                        controller: controllers[key],
                        obscureText: key == 'password' && !reveal,
                        autocorrect: false,
                        enableSuggestions: false,
                        maxLines: key == 'notes' ? 3 : 1,
                        decoration: InputDecoration(
                          labelText: const {
                            'title': '名称',
                            'username': '用户名',
                            'password': '密码',
                            'url': '网址',
                            'tags': '标签',
                            'notes': '备注',
                          }[key],
                          border: const OutlineInputBorder(),
                          suffixIcon: key == 'password'
                              ? IconButton(
                                  icon: Icon(
                                    reveal
                                        ? Icons.visibility_off
                                        : Icons.visibility,
                                  ),
                                  onPressed: () =>
                                      setLocal(() => reveal = !reveal),
                                )
                              : null,
                        ),
                      ),
                    ),
                  TextButton.icon(
                    onPressed: () {
                      const chars =
                          'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!@#%&*+-_';
                      final rng = Random.secure();
                      controllers['password']!.text = List.generate(
                        24,
                        (_) => chars[rng.nextInt(chars.length)],
                      ).join();
                    },
                    icon: const Icon(Icons.password),
                    label: const Text('生成 24 位随机密码'),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            if (revision != null)
              TextButton(
                onPressed: () =>
                    Navigator.pop(context, trash ? 'restore' : 'delete'),
                child: Text(trash ? '恢复' : '移入回收站'),
              ),
            FilledButton(
              onPressed: () => Navigator.pop(context, 'save'),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (result != null && epoch == generation) {
      final data = {for (final e in controllers.entries) e.key: e.value.text};
      await action(() async {
        await request('save', {
          'data': data,
          if (revision != null) 'entry': revision['entry'],
          'parents': group.map((r) => r['id']).toList(),
          'deleted': result == 'delete',
        });
        await refresh();
      });
    }
    for (final c in controllers.values) {
      c.clear();
      c.dispose();
    }
  }

  Future<String?> passwordPrompt() async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认主密码'),
        content: TextField(
          controller: controller,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('确认'),
          ),
        ],
      ),
    );
    controller.clear();
    controller.dispose();
    return result;
  }

  Future<void> backup() async {
    final password = await passwordPrompt();
    if (password == null) return;
    await action(() async {
      final data = await request('export', {'password': password});
      final bytes = utf8.encode(jsonEncode(data));
      if (bytes.length > 2 * 1024 * 1024) {
        throw StateError('backup_limit');
      }
      if (Platform.isAndroid) {
        await const MethodChannel('org.wencrypt.files')
            .invokeMethod('saveBackup', {'bytes': Uint8List.fromList(bytes)});
      } else {
        final location = await getSaveLocation(
          suggestedName: 'wencrypt-backup.wenback',
        );
        if (location != null) {
          await XFile.fromData(Uint8List.fromList(bytes)).saveTo(location.path);
        }
      }
      if (mounted) setState(() => message = '备份导出操作已结束');
    });
  }

  Future<void> restore() async {
    final file = await openFile();
    if (file == null) return;
    if (await file.length() > 2 * 1024 * 1024) {
      setState(() => message = 'Alpha 备份文件上限 2 MiB');
      return;
    }
    final data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    if (!mounted) return;
    final password = await passwordPrompt();
    if (password == null) return;
    await action(() async {
      await core({
        'op': 'restore',
        'path': path,
        'password': password,
        'bootstrap': data['bootstrap'],
        'backup': data['backup'],
      });
      await initialize();
    });
  }

  Future<void> history(Map<String, dynamic> revision) async {
    await action(() async {
      final data = await request('history', {'entry': revision['entry']});
      if (!mounted) return;
      final revisions = (data['revisions'] as List).cast<Map<String, dynamic>>()
        ..sort(
          (a, b) => (b['updated_at'] as int).compareTo(a['updated_at'] as int),
        );
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('历史版本'),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final r in revisions)
                    ListTile(
                      title: Text(
                        '${r['data']['title']} · ${r['deleted'] == true ? '已删除' : '已保存'}',
                      ),
                      subtitle: Text(
                        DateTime.fromMillisecondsSinceEpoch(
                          (r['updated_at'] as int) * 1000,
                        ).toLocal().toString(),
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.copy),
                        tooltip: '复制此版本密码',
                        onPressed: () => copy(r['data']['password'] as String),
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
    });
  }

  Future<void> importCsv() async {
    // The system picker locks the vault. Reauthenticate after reading the selected file.
    try {
      final file = await openFile();
      if (file == null) return;
      if (await file.length() > 1024 * 1024) throw StateError('csv_limit');
      final rows = csv.decode(await file.readAsString());
      if (rows.isEmpty || rows.length > 501) throw StateError('csv_limit');
      final headers = rows.first
          .map((v) => v.toString().replaceFirst('\ufeff', '').toLowerCase())
          .toList();
      if (!headers.contains('password') || !headers.contains('username')) {
        throw StateError('csv_headers');
      }
      String value(List<dynamic> row, String name) {
        final i = headers.indexOf(name);
        return i < 0 || i >= row.length ? '' : row[i].toString();
      }

      final data = [
        for (final row in rows.skip(1))
          if (row.any((v) => v.toString().isNotEmpty))
            {
              'title': value(row, 'name').isNotEmpty
                  ? value(row, 'name')
                  : value(row, 'url').isNotEmpty
                  ? value(row, 'url')
                  : '导入账号',
              'username': value(row, 'username'),
              'password': value(row, 'password'),
              'url': value(row, 'url'),
              'notes': value(row, 'note'),
              'tags': '导入',
            },
      ];
      if (!mounted) return;
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('导入 ${data.length} 个账号'),
          content: const Text(
            '支持 Chrome/Edge CSV。所有行将作为新账号加入，不覆盖已有条目，重复导入会产生重复账号。原始 CSV 含明文密码，请自行妥善处理。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('继续'),
            ),
          ],
        ),
      );
      if (accepted != true) return;
      if (!mounted) return;
      final password = await passwordPrompt();
      if (password == null) return;
      await action(() async {
        final epoch = generation;
        final unlocked = await core({
          'op': 'unlock',
          'path': path,
          'password': password,
        });
        if (epoch != generation) {
          await core({'op': 'lock'});
          return;
        }
        token = unlocked['session'] as String;
        await request('import', {'entries': data});
        await refresh();
        touch();
      });
    } catch (e) {
      if (mounted) setState(() => message = friendly(e));
    }
  }

  Future<void> sync() async {
    final user = TextEditingController();
    final password = TextEditingController();
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('坚果云同步'),
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                '使用坚果云 WebDAV 应用密码。凭据仅在本次同步保留。新设备先恢复同一份加密备份。初版最多 598 个修订对象，达到上限会停止同步。',
              ),
              TextField(
                controller: user,
                decoration: const InputDecoration(labelText: '坚果云账号'),
              ),
              TextField(
                controller: password,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(labelText: 'WebDAV 应用密码'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('同步 / 首次创建云端副本'),
          ),
        ],
      ),
    );
    if (accepted == true && token != null) {
      await action(() async {
        final result = await NutstoreSync(
          File(path!).parent,
          request,
        ).sync(user.text, password.text);
        await refresh();
        if (mounted) setState(() => message = result);
      });
    }
    user.clear();
    password.clear();
    user.dispose();
    password.dispose();
  }

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: (_) => touch(),
    child: Scaffold(
      appBar: AppBar(
        title: const Text('Wencrypt'),
        actions: [
          if (token != null)
            IconButton(
              onPressed: busy ? null : sync,
              icon: const Icon(Icons.sync),
              tooltip: '坚果云同步',
            ),
          if (token != null)
            IconButton(
              onPressed: busy ? null : backup,
              icon: const Icon(Icons.save_alt),
              tooltip: '加密备份',
            ),
          if (token != null)
            IconButton(
              onPressed: lock,
              icon: const Icon(Icons.lock_outline),
              tooltip: '锁定',
            ),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'csv') {
                importCsv();
              }
              if (v == 'probe') {
                lock();
                Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => const WencryptProbeApp(),
                  ),
                );
              }
            },
            itemBuilder: (_) => [
              if (exists)
                const PopupMenuItem(value: 'csv', child: Text('导入浏览器 CSV')),
              const PopupMenuItem(value: 'probe', child: Text('设备诊断')),
            ],
          ),
        ],
      ),
      body: token == null
          ? Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.all(28),
                  children: [
                    Image.asset('assets/brand/wencrypt-logo.png', height: 140),
                    const SizedBox(height: 24),
                    Text(
                      exists ? '解锁密码库' : '创建你的密码库',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 12),
                    const Text('Alpha 测试版 · 请先使用测试数据\n主密码无法找回，请妥善保存独立加密备份。'),
                    const SizedBox(height: 24),
                    TextField(
                      controller: master,
                      obscureText: true,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: const InputDecoration(
                        labelText: '主密码（至少 12 个字符）',
                        border: OutlineInputBorder(),
                      ),
                      onSubmitted: (_) => busy ? null : unlock(),
                    ),
                    if (!exists) ...[
                      const SizedBox(height: 12),
                      TextField(
                        controller: confirm,
                        obscureText: true,
                        autocorrect: false,
                        enableSuggestions: false,
                        decoration: const InputDecoration(
                          labelText: '再次输入主密码',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ],
                    const SizedBox(height: 20),
                    FilledButton(
                      onPressed: busy || path == null ? null : unlock,
                      child: Text(
                        busy
                            ? '正在处理…'
                            : exists
                            ? '解锁'
                            : '创建密码库',
                      ),
                    ),
                    if (!exists)
                      TextButton(
                        onPressed: busy || path == null ? null : restore,
                        child: const Text('从加密备份恢复'),
                      ),
                    const SizedBox(height: 12),
                    Text(message),
                  ],
                ),
              ),
            )
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          onChanged: (v) {
                            touch();
                            setState(() => query = v);
                          },
                          decoration: const InputDecoration(
                            prefixIcon: Icon(Icons.search),
                            hintText: '搜索名称、用户名、网址或标签',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: () => setState(() => trash = !trash),
                        icon: Icon(
                          trash ? Icons.inventory_2 : Icons.delete_outline,
                        ),
                        tooltip: trash ? '返回账号' : '回收站',
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Row(
                    children: [
                      Expanded(child: Text(busy ? '正在处理…' : message)),
                      Text('${entries.length} 个版本'),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView(
                    children: [
                      for (final r in entries.where(
                        (r) =>
                            r['deleted'] == trash &&
                            ['title', 'username', 'url', 'tags'].any(
                              (k) => r['data'][k]
                                  .toString()
                                  .toLowerCase()
                                  .contains(query.toLowerCase()),
                            ),
                      ))
                        Card(
                          margin: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 5,
                          ),
                          child: ListTile(
                            leading: Icon(
                              entries
                                          .where(
                                            (v) => v['entry'] == r['entry'],
                                          )
                                          .length >
                                      1
                                  ? Icons.warning_amber
                                  : Icons.key,
                            ),
                            title: Text(r['data']['title'] as String),
                            subtitle: Text(r['data']['username'] as String),
                            onTap: busy ? null : () => edit(r),
                            trailing: PopupMenuButton<String>(
                              onSelected: (v) {
                                if (v == 'history') {
                                  history(r);
                                } else {
                                  copy(r['data'][v] as String);
                                }
                              },
                              itemBuilder: (_) => [
                                const PopupMenuItem(
                                  value: 'username',
                                  child: Text('复制用户名'),
                                ),
                                const PopupMenuItem(
                                  value: 'password',
                                  child: Text('复制密码'),
                                ),
                                const PopupMenuItem(
                                  value: 'history',
                                  child: Text('历史版本'),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
      floatingActionButton: token == null
          ? null
          : FloatingActionButton.extended(
              onPressed: busy ? null : () => edit(null),
              icon: const Icon(Icons.add),
              label: const Text('新增账号'),
            ),
    ),
  );
}
