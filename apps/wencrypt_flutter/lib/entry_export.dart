import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'design/wencrypt_theme.dart';
import 'design/wencrypt_widgets.dart';

enum EntryExportFormat { image, text }

class EntryExportDialog extends StatefulWidget {
  const EntryExportDialog({
    super.key,
    required this.entry,
    required this.toAlbum,
    required this.onExportImage,
    required this.onCopyText,
  });

  final Map<String, dynamic> entry;
  final bool toAlbum;
  final Future<void> Function(Uint8List png) onExportImage;
  final Future<void> Function(String text) onCopyText;

  @override
  State<EntryExportDialog> createState() => _EntryExportDialogState();
}

class _EntryExportDialogState extends State<EntryExportDialog> {
  final _card = GlobalKey();
  var _format = EntryExportFormat.image;
  bool _includePassword = false;
  bool _exporting = false;
  String? _error;

  String _value(String key) => widget.entry[key] as String? ?? '';

  Map<String, String> get _fields => {
    if (_value('username').isNotEmpty) '用户名': _value('username'),
    if (_value('url').isNotEmpty) '网址': _value('url'),
    if (_includePassword && _value('password').isNotEmpty)
      '密码': _value('password'),
  };

  String get _text => [
    if (_value('title').isNotEmpty) '账号名称：${_value('title')}',
    for (final field in _fields.entries) '${field.key}：${field.value}',
  ].join('\n');

  Future<void> _export() async {
    if (_exporting) return;
    setState(() {
      _exporting = true;
      _error = null;
    });
    Uint8List? bytes;
    try {
      if (_format == EntryExportFormat.text) {
        await widget.onCopyText(_text);
      } else {
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
          bytes = png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes);
        } finally {
          image.dispose();
        }
        if (!mounted) return;
        await widget.onExportImage(bytes);
      }
      if (mounted) Navigator.pop(context, _format);
    } on PlatformException catch (error) {
      if (mounted) {
        setState(() {
          _error = switch (error.code) {
            'clipboard_busy' => '剪贴板正被其他应用占用，请稍后重试。',
            _ when _format == EntryExportFormat.text => '无法复制文字到剪贴板，请重试。',
            _ when widget.toAlbum => '无法保存图片到相册，请重试。',
            _ => '无法复制图片到剪贴板，请重试。',
          };
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = _format == EntryExportFormat.text
              ? '无法复制文字到剪贴板，请重试。'
              : bytes == null
              ? '无法生成图片，请重试。'
              : '无法导出图片，请重试。';
        });
      }
    } finally {
      bytes?.fillRange(0, bytes.length, 0);
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = WColors.of(context);
    final isImage = _format == EntryExportFormat.image;
    return PopScope(
      canPop: !_exporting,
      child: WDialog(
        width: 420,
        icon: Icons.ios_share_rounded,
        title: '导出账号',
        bodyPadding: const EdgeInsets.fromLTRB(20, 12, 20, 14),
        footer: WDialogFooter(
          actions: [
            TextButton(
              style: TextButton.styleFrom(foregroundColor: c.textSecondary),
              onPressed: _exporting ? null : () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: _exporting ? null : _export,
              child: Text(
                !isImage
                    ? '复制文字'
                    : widget.toAlbum
                    ? '保存到相册'
                    : '复制图片',
              ),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Center(
              child: WSegmented<EntryExportFormat>(
                value: _format,
                onChanged: (next) {
                  if (_exporting) return;
                  setState(() {
                    _format = next;
                    _includePassword = false;
                    _error = null;
                  });
                },
                segments: const [
                  (EntryExportFormat.image, '图片', Icons.image_outlined),
                  (EntryExportFormat.text, '文字', Icons.notes),
                ],
              ),
            ),
            const SizedBox(height: 12),
            if (isImage)
              RepaintBoundary(
                key: _card,
                child: ColoredBox(
                  color: const Color(0xfff1f5f9),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      padding: const EdgeInsets.all(18),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _value('title'),
                            style: const TextStyle(
                              color: Color(0xff10213a),
                              fontSize: 20,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          for (final field in _fields.entries) ...[
                            const SizedBox(height: 14),
                            Text(
                              field.key,
                              style: const TextStyle(
                                color: Color(0xff475569),
                                fontSize: 11.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Text(
                              field.value,
                              style: const TextStyle(
                                color: Color(0xff10213a),
                                fontSize: 15,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              )
            else
              DecoratedBox(
                decoration: BoxDecoration(
                  color: c.surfaceMuted,
                  borderRadius: BorderRadius.circular(WRadius.sm),
                  border: Border.all(color: c.border),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    _text,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: c.textPrimary,
                    ),
                  ),
                ),
              ),
            if (_value('password').isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _includePassword,
                  title: const Text('包含密码'),
                  onChanged: _exporting
                      ? null
                      : (value) =>
                            setState(() => _includePassword = value == true),
                ),
              ),
            if (_includePassword)
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: WNote(
                  tone: WTone.warning,
                  child: Text('包含密码，请仅发送给受信任的接收方'),
                ),
              ),
            if (_error case final error?)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: WNote(tone: WTone.danger, child: Text(error)),
              ),
          ],
        ),
      ),
    );
  }
}
