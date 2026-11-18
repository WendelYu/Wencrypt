import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';

class EntryImageDialog extends StatefulWidget {
  const EntryImageDialog({
    super.key,
    required this.entry,
    required this.toAlbum,
  });

  final Map<String, dynamic> entry;
  final bool toAlbum;

  @override
  State<EntryImageDialog> createState() => _EntryImageDialogState();
}

class _EntryImageDialogState extends State<EntryImageDialog> {
  final _card = GlobalKey();
  bool _includePassword = false;
  bool _rendering = false;
  String? _error;

  Future<void> _capture() async {
    setState(() {
      _rendering = true;
      _error = null;
    });
    try {
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      final boundary =
          _card.currentContext!.findRenderObject() as RenderRepaintBoundary;
      if (boundary.size.height > 2048) {
        setState(() => _error = '账号内容太长，无法生成完整图片');
        return;
      }
      final image = await boundary.toImage(pixelRatio: 2);
      try {
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        if (png == null) throw StateError('image_export_failed');
        if (mounted) {
          Navigator.pop(
            context,
            png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
          );
        }
      } finally {
        image.dispose();
      }
    } catch (_) {
      if (mounted) setState(() => _error = '无法生成图片，请重试');
    } finally {
      if (mounted) setState(() => _rendering = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.entry['title'] as String? ?? '';
    final username = widget.entry['username'] as String? ?? '';
    final url = widget.entry['url'] as String? ?? '';
    final password = widget.entry['password'] as String? ?? '';
    final fields = {
      if (username.isNotEmpty) '用户名': username,
      if (url.isNotEmpty) '网址': url,
      if (_includePassword && password.isNotEmpty) '密码': password,
    };
    return AlertDialog(
      title: const Text('导出账号图片'),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              RepaintBoundary(
                key: _card,
                child: ColoredBox(
                  color: const Color(0xfff1f5f9),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            style: const TextStyle(
                              color: Color(0xff10213a),
                              fontSize: 22,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          for (final field in fields.entries) ...[
                            const SizedBox(height: 16),
                            Text(
                              field.key,
                              style: const TextStyle(
                                color: Color(0xff475569),
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Text(
                              field.value,
                              style: const TextStyle(
                                color: Color(0xff10213a),
                                fontSize: 16,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              if (password.isNotEmpty)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _includePassword,
                  title: const Text('在图片中包含密码'),
                  onChanged: _rendering
                      ? null
                      : (value) =>
                            setState(() => _includePassword = value == true),
                ),
              if (_includePassword) const Text('收到图片的人可以直接查看密码。'),
              if (_error case final error?)
                Text(
                  error,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _rendering ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _rendering ? null : _capture,
          child: Text(widget.toAlbum ? '保存到相册' : '复制图片'),
        ),
      ],
    );
  }
}
