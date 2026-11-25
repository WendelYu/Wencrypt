import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'design/wencrypt_theme.dart';
import 'design/wencrypt_widgets.dart';
import 'password_generator.dart';
import 'screenshot_import.dart';

const _presetImportGroups = ['工作', '财务', '社交', '开发', '购物', '生活'];

List<String> _mergeGroupTags(Iterable<String> groups) {
  final seen = <String>{};
  final result = <String>[];
  for (final raw in groups) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) continue;
    final lower = trimmed.toLowerCase();
    if (seen.add(lower)) result.add(trimmed);
  }
  return result;
}

List<String> _splitGroupText(String text) =>
    _mergeGroupTags(text.split(RegExp(r'[,，]')))
        .where((tag) => tag != '置顶')
        .toList();

/// Opens the quick registration-screenshot import dialog (desktop) or
/// full-screen page (mobile). Returns the validated entry `data` map on save.
Future<Map<String, String>?> showScreenshotImportDialog(
  BuildContext context, {
  required bool mobile,
  required List<String> groupOptions,
  String? initialGroup,
  required PasswordGeneratorOptions generatorOptions,
  ValueChanged<PasswordGeneratorOptions>? onGeneratorOptionsChanged,
  Uint8List? initialImageBytes,
  ScreenshotOcrService? ocrService,
  Future<Uint8List?> Function()? onPickImageFile,
}) {
  final route = mobile
      ? MaterialPageRoute<Map<String, String>>(
          fullscreenDialog: true,
          builder: (_) => _ScreenshotImportView(
            mobile: true,
            groupOptions: groupOptions,
            initialGroup: initialGroup,
            generatorOptions: generatorOptions,
            onGeneratorOptionsChanged: onGeneratorOptionsChanged,
            initialImageBytes: initialImageBytes,
            ocrService: ocrService ?? const ScreenshotOcrService(),
            onPickImageFile: onPickImageFile,
          ),
        )
      : DialogRoute<Map<String, String>>(
          context: context,
          builder: (_) => _ScreenshotImportView(
            mobile: false,
            groupOptions: groupOptions,
            initialGroup: initialGroup,
            generatorOptions: generatorOptions,
            onGeneratorOptionsChanged: onGeneratorOptionsChanged,
            initialImageBytes: initialImageBytes,
            ocrService: ocrService ?? const ScreenshotOcrService(),
            onPickImageFile: onPickImageFile,
          ),
        );
  return Navigator.of(context).push(route);
}

class _ScreenshotImportView extends StatefulWidget {
  const _ScreenshotImportView({
    required this.mobile,
    required this.groupOptions,
    this.initialGroup,
    required this.generatorOptions,
    this.onGeneratorOptionsChanged,
    this.initialImageBytes,
    required this.ocrService,
    this.onPickImageFile,
  });

  final bool mobile;
  final List<String> groupOptions;
  final String? initialGroup;
  final PasswordGeneratorOptions generatorOptions;
  final ValueChanged<PasswordGeneratorOptions>? onGeneratorOptionsChanged;
  final Uint8List? initialImageBytes;
  final ScreenshotOcrService ocrService;
  final Future<Uint8List?> Function()? onPickImageFile;

  @override
  State<_ScreenshotImportView> createState() => _ScreenshotImportViewState();
}

class _ScreenshotImportViewState extends State<_ScreenshotImportView> {
  late final Map<String, TextEditingController> _controllers;
  late final ValueNotifier<String> _committedTags;
  late final List<String> _mergedGroups;
  final _titleFocus = FocusNode();
  final _usernameFocus = FocusNode();
  final _passwordFocus = FocusNode();
  final _urlFocus = FocusNode();
  final _tagsFocus = FocusNode();
  final _shortcutFocus = FocusNode();

  late PasswordGeneratorOptions _generatorOptions;
  Uint8List? _imageBytes;
  ParsedCredential? _parsed;
  bool _checkingClipboard = false;
  bool _recognizing = false;
  bool _revealPassword = true;
  bool _showReview = false;
  String? _error;
  String? _titleError;
  String? _passwordError;

  @override
  void initState() {
    super.initState();
    _generatorOptions = widget.generatorOptions;
    _mergedGroups = _mergeGroupTags([
      ...widget.groupOptions,
      ..._presetImportGroups,
    ]);
    _controllers = {
      'title': TextEditingController(),
      'username': TextEditingController(),
      'password': TextEditingController(),
      'url': TextEditingController(),
      'tags': TextEditingController(text: widget.initialGroup ?? ''),
    };
    _committedTags = ValueNotifier(_controllers['tags']!.text);
    _controllers['tags']!.addListener(() {
      final value = _controllers['tags']!.value;
      if (!value.composing.isValid || value.composing.isCollapsed) {
        _committedTags.value = value.text;
      }
    });
    unawaited(_bootstrap());
  }

  @override
  void dispose() {
    _wipeImageBytes();
    for (final c in _controllers.values) {
      c.dispose();
    }
    _committedTags.dispose();
    _titleFocus.dispose();
    _usernameFocus.dispose();
    _passwordFocus.dispose();
    _urlFocus.dispose();
    _tagsFocus.dispose();
    _shortcutFocus.dispose();
    super.dispose();
  }

  void _wipeImageBytes() {
    final current = _imageBytes;
    if (current != null) {
      current.fillRange(0, current.length, 0);
      _imageBytes = null;
    }
  }

  bool get _hasAnyFieldFocus =>
      _titleFocus.hasFocus ||
      _usernameFocus.hasFocus ||
      _passwordFocus.hasFocus ||
      _urlFocus.hasFocus ||
      _tagsFocus.hasFocus;

  Future<void> _bootstrap() async {
    final initial = widget.initialImageBytes;
    if (initial != null && initial.isNotEmpty) {
      await _processImageBytes(Uint8List.fromList(initial));
      return;
    }
    setState(() => _checkingClipboard = true);
    try {
      final result = await widget.ocrService.readAndRecognizeClipboardImage();
      if (!mounted) return;
      _checkingClipboard = false;
      if (result != null) {
        final parsed = parseCredentialFromOcr(result.recognition.blocks);
        _wipeImageBytes();
        setState(() {
          _imageBytes = result.imageBytes;
          _applyParsedCredential(parsed, replacePrevious: false);
        });
      } else {
        setState(() {});
      }
    } catch (_) {
      if (mounted) {
        setState(() => _checkingClipboard = false);
      }
    }
  }

  void _applyParsedCredential(
    ParsedCredential parsed, {
    bool replacePrevious = true,
  }) {
    if (replacePrevious) {
      _controllers['username']!.text = '';
      _controllers['password']!.text = '';
      _controllers['url']!.text = '';
    }
    final currentTitle = _controllers['title']!.text.trim();
    if (parsed.title.isNotEmpty) {
      _controllers['title']!.text = parsed.title;
    } else if (currentTitle.isEmpty) {
      _controllers['title']!.text = '';
    }
    if (parsed.username.isNotEmpty) {
      _controllers['username']!.text = parsed.username;
    }
    if (parsed.password.isNotEmpty) {
      _controllers['password']!.text = parsed.password;
    }
    if (parsed.url.isNotEmpty) {
      _controllers['url']!.text = parsed.url;
    }
    _parsed = parsed;
    _showReview = true;
    _titleError = null;
    _passwordError = null;
    if (_controllers['title']!.text.trim().isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _controllers['title']!.text.trim().isEmpty) {
          _titleFocus.requestFocus();
        }
      });
    }
  }

  Future<void> _processImageBytes(Uint8List bytes) async {
    if (_recognizing) {
      bytes.fillRange(0, bytes.length, 0);
      return;
    }
    final hadPrevious = _parsed != null;
    _wipeImageBytes();
    setState(() {
      _imageBytes = bytes;
      _recognizing = true;
      _showReview = true;
      _error = null;
    });
    try {
      final result = await widget.ocrService.recognizeImage(bytes);
      if (!mounted) return;
      final parsed = parseCredentialFromOcr(result.blocks);
      setState(() {
        _recognizing = false;
        _applyParsedCredential(parsed, replacePrevious: hadPrevious);
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _recognizing = false;
        _showReview = true;
        _error = ScreenshotOcrService.friendlyError(error);
      });
    }
  }

  Future<void> _pasteFromClipboard() async {
    if (_recognizing || _checkingClipboard) return;
    final hadPrevious = _parsed != null;
    setState(() {
      _error = null;
      _recognizing = true;
    });
    try {
      final result = await widget.ocrService.readAndRecognizeClipboardImage();
      if (!mounted) return;
      if (result != null) {
        final parsed = parseCredentialFromOcr(result.recognition.blocks);
        _wipeImageBytes();
        setState(() {
          _recognizing = false;
          _imageBytes = result.imageBytes;
          _applyParsedCredential(parsed, replacePrevious: hadPrevious);
        });
        return;
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _recognizing = false;
        _error = ScreenshotOcrService.friendlyError(error);
      });
      return;
    }

    final clipText =
        (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim() ?? '';
    if (!mounted) return;
    if (clipText.isNotEmpty) {
      final parsed = parseCredentialFromText(clipText);
      if (!parsed.isEmpty || parsed.rawLines.isNotEmpty) {
        _wipeImageBytes();
        setState(() {
          _recognizing = false;
          _applyParsedCredential(parsed, replacePrevious: hadPrevious);
        });
        return;
      }
    }

    setState(() {
      _recognizing = false;
      _error = '剪贴板中暂无截图或账号文本，请先截图或直接选择图片文件。';
    });
  }

  Future<void> _importClipboardText() async {
    if (_recognizing || _checkingClipboard) return;
    final hadPrevious = _parsed != null;
    final clipText =
        (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim() ?? '';
    if (!mounted) return;
    if (clipText.isEmpty) {
      setState(() => _error = '剪贴板中没有可识别的文本。');
      return;
    }
    _wipeImageBytes();
    setState(() {
      _error = null;
      _applyParsedCredential(
        parseCredentialFromText(clipText),
        replacePrevious: hadPrevious,
      );
    });
  }

  Future<void> _pickImageFile() async {
    if (_recognizing || _checkingClipboard || widget.onPickImageFile == null) {
      return;
    }
    setState(() => _error = null);
    try {
      final bytes = await widget.onPickImageFile!();
      if (!mounted || bytes == null || bytes.isEmpty) return;
      await _processImageBytes(bytes);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = ScreenshotOcrService.friendlyError(error));
    }
  }

  void _quickGeneratePassword() {
    setState(() {
      _controllers['password']!.text = generateSecurePassword(
        _generatorOptions,
      );
      _passwordError = null;
      _revealPassword = true;
    });
  }

  Future<void> _openCustomGenerator() async {
    final result = await showPasswordGeneratorDialog(
      context,
      initialOptions: _generatorOptions,
      mobile: widget.mobile,
      pickerMode: true,
    );
    if (!mounted || result == null) return;
    _generatorOptions = result.options;
    widget.onGeneratorOptionsChanged?.call(result.options);
    if (result.action == PasswordGeneratorAction.apply) {
      setState(() {
        _controllers['password']!.text = result.password;
        _passwordError = null;
        _revealPassword = true;
      });
    }
  }

  void _assignCandidate(String fieldKey, String value) {
    setState(() {
      _controllers[fieldKey]!.text = value;
      if (fieldKey == 'title') _titleError = null;
      if (fieldKey == 'password') {
        _passwordError = null;
        _revealPassword = true;
      }
    });
  }

  void _openImageZoomPreview() {
    final bytes = _imageBytes;
    if (bytes == null || bytes.isEmpty) return;
    showDialog<void>(
      context: context,
      builder: (ctx) {
        final c = WColors.of(ctx);
        return Dialog(
          backgroundColor: c.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(WRadius.xl),
            side: BorderSide(color: c.border),
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760, maxHeight: 620),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 8, 8),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text(
                          '核对截图原图（支持双指或滚轮缩放）',
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      WIconButton(
                        icon: Icons.close_rounded,
                        tooltip: '关闭',
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                ),
                Divider(height: 1, color: c.border),
                Flexible(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: InteractiveViewer(
                      minScale: 0.8,
                      maxScale: 4.0,
                      child: Image.memory(bytes, fit: BoxFit.contain),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _submit() {
    final title = _controllers['title']!.text.trim();
    final password = _controllers['password']!.text;
    setState(() {
      _titleError = title.isEmpty ? '请填写来源或名称' : null;
      _passwordError = password.isEmpty ? '请填写或生成密码' : null;
    });
    if (_titleError != null || _passwordError != null) return;
    final cleanedGroups = _splitGroupText(_controllers['tags']!.text);
    Navigator.pop(context, {
      'title': title,
      'username': _controllers['username']!.text.trim(),
      'password': password,
      'url': _controllers['url']!.text.trim(),
      'tags': cleanedGroups.join(', '),
      'notes': '',
    });
  }

  Widget _buildStatusNote() {
    if (_error != null) {
      return WNote(tone: WTone.warning, child: Text(_error!));
    }
    final parsed = _parsed;
    if (parsed == null) return const SizedBox.shrink();
    if (parsed.passwordMasked && _controllers['password']!.text.isEmpty) {
      return const WNote(
        tone: WTone.warning,
        child: Text('检测到截图中的密码已被星号或圆点遮盖，请手动补全密码或点击右侧按钮生成随机密码。'),
      );
    }
    if (_controllers['title']!.text.trim().isEmpty &&
        (_controllers['username']!.text.isNotEmpty ||
            _controllers['password']!.text.isNotEmpty)) {
      return const WNote(
        tone: WTone.info,
        child: Text('已识别注册信息，请填写「来源 / 名称」并核对无误后保存。'),
      );
    }
    if (!parsed.isEmpty) {
      return const WNote(
        tone: WTone.success,
        child: Text('已自动填入识别到的账号信息，保存前可对照截图核对或修改。'),
      );
    }
    return const WNote(
      tone: WTone.warning,
      child: Text('未能自动匹配具体字段，可点击下方识别到的文本片段快速填入，或直接手动输入。'),
    );
  }

  Widget _buildBody(BuildContext context) {
    final c = WColors.of(context);
    final mobile = widget.mobile;
    final gap = mobile ? 14.0 : 11.0;
    final pasteShortcut = Platform.isMacOS ? '⌘V' : 'Ctrl+V';

    InputDecoration decoration(
      IconData icon, {
      String? hint,
      Widget? suffix,
      String? error,
    }) => InputDecoration(
      hintText: hint,
      isDense: !mobile,
      contentPadding: mobile
          ? const EdgeInsets.symmetric(horizontal: 14, vertical: 14)
          : null,
      prefixIcon: Icon(icon, size: mobile ? 19 : 16),
      prefixIconConstraints: BoxConstraints(
        minWidth: mobile ? 44 : 36,
        minHeight: mobile ? 44 : 36,
      ),
      suffixIcon: suffix,
      suffixIconConstraints: BoxConstraints(
        minWidth: mobile ? 44 : 36,
        minHeight: mobile ? 44 : 0,
      ),
      errorText: error,
    );

    TextStyle fieldStyle({bool mono = false}) => TextStyle(
      fontSize: mobile ? 15 : 12.8,
      fontFamily: mono ? wMonoFamily : null,
      color: c.textPrimary,
    );

    if (!_showReview) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const WNote(
            tone: WTone.info,
            child: Text('所有识别均在本机离线完成，截图仅在内存中处理，不会上传网络或落盘保存。'),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            WNote(tone: WTone.warning, child: Text(_error!)),
          ],
          SizedBox(height: mobile ? 20 : 16),
          Container(
            padding: EdgeInsets.all(mobile ? 18 : 16),
            decoration: BoxDecoration(
              color: c.surfaceMuted,
              borderRadius: BorderRadius.circular(WRadius.lg),
              border: Border.all(color: c.border),
            ),
            child: Column(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: c.brandSoft,
                    borderRadius: BorderRadius.circular(WRadius.md),
                  ),
                  child: Icon(
                    Icons.document_scanner_outlined,
                    size: 24,
                    color: c.brand,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  '截取注册或账号页面后直接导入',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: mobile ? 15.5 : 14,
                    fontWeight: FontWeight.w600,
                    color: c.textPrimary,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  mobile
                      ? '可从相册/文件选择截图，或在系统截图中「分享到 Wencrypt」自动识别'
                      : '截图复制到剪贴板后可直接按 $pasteShortcut 粘贴识别，或选择本地图片文件',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: mobile ? 13 : 12,
                    color: c.textSecondary,
                    height: 1.45,
                  ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  height: mobile ? 46 : 38,
                  child: FilledButton.icon(
                    onPressed: (_recognizing || _checkingClipboard)
                        ? null
                        : _pasteFromClipboard,
                    icon: (_recognizing || _checkingClipboard)
                        ? const SizedBox(
                            width: 15,
                            height: 15,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.content_paste_rounded, size: 17),
                    label: Text(
                      _checkingClipboard
                          ? '正在检测剪贴板截图…'
                          : (mobile ? '粘贴剪贴板截图' : '粘贴剪贴板截图 ($pasteShortcut)'),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  alignment: WrapAlignment.center,
                  children: [
                    if (widget.onPickImageFile != null)
                      OutlinedButton.icon(
                        onPressed: _recognizing ? null : _pickImageFile,
                        icon: const Icon(Icons.photo_library_outlined, size: 16),
                        label: const Text('选择截图文件'),
                      ),
                    OutlinedButton.icon(
                      onPressed: _recognizing ? null : _importClipboardText,
                      icon: const Icon(Icons.text_snippet_outlined, size: 16),
                      label: const Text('识别剪贴板文字'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      );
    }

    final candidates = _parsed?.candidates ?? const <String>[];
    final imageBytes = _imageBytes;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (imageBytes != null) ...[
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: c.surfaceMuted,
              borderRadius: BorderRadius.circular(WRadius.md),
              border: Border.all(color: c.border),
            ),
            child: Row(
              children: [
                InkWell(
                  borderRadius: BorderRadius.circular(WRadius.sm),
                  onTap: _openImageZoomPreview,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(WRadius.sm),
                    child: Container(
                      width: mobile ? 84 : 96,
                      height: mobile ? 84 : 76,
                      color: c.surfaceSunken,
                      child: Image.memory(
                        imageBytes,
                        fit: BoxFit.cover,
                        cacheWidth: 256,
                        filterQuality: FilterQuality.medium,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '已加载内存截图（不落盘）',
                        style: TextStyle(
                          fontSize: mobile ? 13.5 : 12.2,
                          fontWeight: FontWeight.w600,
                          color: c.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '点击左侧缩略图可放大核对原图',
                        style: TextStyle(
                          fontSize: mobile ? 12 : 11,
                          color: c.textTertiary,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          TextButton.icon(
                            onPressed: _recognizing
                                ? null
                                : _pasteFromClipboard,
                            style: TextButton.styleFrom(
                              minimumSize: const Size(0, 28),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                              ),
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            icon: const Icon(
                              Icons.content_paste_rounded,
                              size: 14,
                            ),
                            label: const Text(
                              '重新粘贴',
                              style: TextStyle(fontSize: 12),
                            ),
                          ),
                          if (widget.onPickImageFile != null)
                            TextButton.icon(
                              onPressed: _recognizing ? null : _pickImageFile,
                              style: TextButton.styleFrom(
                                minimumSize: const Size(0, 28),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                ),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              icon: const Icon(
                                Icons.swap_horiz_rounded,
                                size: 15,
                              ),
                              label: const Text(
                                '换一张图',
                                style: TextStyle(fontSize: 12),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          SizedBox(height: gap),
        ],
        if (_recognizing) ...[
          Container(
            padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 14),
            decoration: BoxDecoration(
              color: c.surfaceMuted,
              borderRadius: BorderRadius.circular(WRadius.md),
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: c.brand,
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  '正在本机离线识别截图…',
                  style: TextStyle(
                    fontSize: mobile ? 14 : 12.8,
                    color: c.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(height: gap),
        ] else ...[
          _buildStatusNote(),
          SizedBox(height: gap),
        ],
        Padding(
          padding: EdgeInsets.only(bottom: gap),
          child: WLabeledField(
            label: '来源 / 名称（必填）',
            child: TextField(
              controller: _controllers['title'],
              focusNode: _titleFocus,
              textInputAction: TextInputAction.next,
              onChanged: (_) {
                if (_titleError != null) setState(() => _titleError = null);
              },
              style: fieldStyle(),
              decoration: decoration(
                Icons.label_outline_rounded,
                hint: '例如 GitHub、公司内网、某网站',
                error: _titleError,
              ),
            ),
          ),
        ),
        Padding(
          padding: EdgeInsets.only(bottom: gap),
          child: WLabeledField(
            label: '账号 / 用户名',
            child: TextField(
              controller: _controllers['username'],
              focusNode: _usernameFocus,
              autocorrect: false,
              textInputAction: TextInputAction.next,
              style: fieldStyle(),
              decoration: decoration(
                Icons.person_outline_rounded,
                hint: '邮箱、手机号或用户名',
              ),
            ),
          ),
        ),
        Padding(
          padding: EdgeInsets.only(bottom: gap),
          child: WLabeledField(
            label: '密码（必填）',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _controllers['password'],
                  focusNode: _passwordFocus,
                  obscureText: !_revealPassword,
                  autocorrect: false,
                  enableSuggestions: false,
                  textInputAction: TextInputAction.next,
                  onChanged: (_) => setState(() {
                    _passwordError = null;
                  }),
                  style: fieldStyle(mono: _revealPassword),
                  decoration: decoration(
                    Icons.key_outlined,
                    hint: '输入或随机生成密码',
                    error: _passwordError,
                    suffix: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: '生成随机密码',
                          iconSize: mobile ? 19 : 17,
                          visualDensity: mobile
                              ? VisualDensity.standard
                              : VisualDensity.compact,
                          icon: const Icon(Icons.auto_fix_high_rounded),
                          onPressed: _quickGeneratePassword,
                        ),
                        IconButton(
                          tooltip: '自定义随机密码',
                          iconSize: mobile ? 19 : 17,
                          visualDensity: mobile
                              ? VisualDensity.standard
                              : VisualDensity.compact,
                          icon: const Icon(Icons.tune_rounded),
                          onPressed: _openCustomGenerator,
                        ),
                        IconButton(
                          tooltip: _revealPassword ? '隐藏密码' : '显示密码',
                          iconSize: mobile ? 19 : 17,
                          visualDensity: mobile
                              ? VisualDensity.standard
                              : VisualDensity.compact,
                          icon: Icon(
                            _revealPassword
                                ? Icons.visibility_off_outlined
                                : Icons.visibility_outlined,
                          ),
                          onPressed: () =>
                              setState(() => _revealPassword = !_revealPassword),
                        ),
                      ],
                    ),
                  ),
                ),
                if (_controllers['password']!.text.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  WPasswordStrength(password: _controllers['password']!.text),
                ],
              ],
            ),
          ),
        ),
        Padding(
          padding: EdgeInsets.only(bottom: gap),
          child: WLabeledField(
            label: '网址',
            child: TextField(
              controller: _controllers['url'],
              focusNode: _urlFocus,
              autocorrect: false,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.next,
              style: fieldStyle(),
              decoration: decoration(Icons.link_rounded, hint: 'https://'),
            ),
          ),
        ),
        Padding(
          padding: EdgeInsets.only(bottom: gap),
          child: WLabeledField(
            label: '分组',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _controllers['tags'],
                  focusNode: _tagsFocus,
                  textInputAction: TextInputAction.done,
                  style: fieldStyle(),
                  decoration: decoration(
                    Icons.folder_outlined,
                    hint: '可输入新分组，多个用逗号分隔',
                  ),
                ),
                const SizedBox(height: 8),
                ValueListenableBuilder<String>(
                  valueListenable: _committedTags,
                  builder: (_, tags, _) {
                    final active = _splitGroupText(tags);
                    final keys = active.map((e) => e.toLowerCase()).toSet();
                    return Wrap(
                      spacing: mobile ? 8 : 6,
                      runSpacing: mobile ? 8 : 6,
                      children: [
                        for (final preset in _mergedGroups)
                          FilterChip(
                            label: Text(preset),
                            selected: keys.contains(preset.toLowerCase()),
                            visualDensity: mobile
                                ? VisualDensity.standard
                                : VisualDensity.compact,
                            labelStyle: TextStyle(fontSize: mobile ? 13 : 11),
                            materialTapTargetSize: mobile
                                ? MaterialTapTargetSize.padded
                                : MaterialTapTargetSize.shrinkWrap,
                            onSelected: (selected) {
                              if (selected) {
                                active.add(preset);
                              } else {
                                active.removeWhere(
                                  (name) =>
                                      name.toLowerCase() ==
                                      preset.toLowerCase(),
                                );
                              }
                              _controllers['tags']!.text = active.join(', ');
                            },
                          ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ),
        if (candidates.isNotEmpty) ...[
          WLabeledField(
            label: '识别到的文本片段（点击可快速填入指定字段）',
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final candidate in candidates)
                  PopupMenuButton<String>(
                    tooltip: '将该文本填入字段',
                    onSelected: (fieldKey) =>
                        _assignCandidate(fieldKey, candidate),
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'title', child: Text('填入来源 / 名称')),
                      PopupMenuItem(
                        value: 'username',
                        child: Text('填入账号 / 用户名'),
                      ),
                      PopupMenuItem(value: 'password', child: Text('填入密码')),
                      PopupMenuItem(value: 'url', child: Text('填入网址')),
                    ],
                    child: Chip(
                      label: Text(
                        candidate,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: mobile ? 12.5 : 11.5),
                      ),
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = WColors.of(context);
    final mac = Platform.isMacOS;

    final bodyWithPasteShortcut = CallbackShortcuts(
      bindings: {
        SingleActivator(LogicalKeyboardKey.keyV, meta: mac, control: !mac): () {
          if (!_hasAnyFieldFocus && !_recognizing && !_checkingClipboard) {
            unawaited(_pasteFromClipboard());
          }
        },
      },
      child: Focus(
        focusNode: _shortcutFocus,
        autofocus: !_showReview,
        child: _buildBody(context),
      ),
    );

    if (!widget.mobile) {
      return WDialog(
        width: 560,
        icon: Icons.document_scanner_outlined,
        title: '从截图快捷导入',
        subtitle: '自动识别账号密码 · 填写来源即可保存',
        footer: WDialogFooter(
          leading: _showReview && widget.onPickImageFile != null
              ? TextButton.icon(
                  onPressed: _recognizing ? null : _pickImageFile,
                  icon: const Icon(Icons.photo_library_outlined, size: 15),
                  label: const Text('选择截图'),
                )
              : null,
          actions: [
            TextButton(
              style: TextButton.styleFrom(foregroundColor: c.textSecondary),
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            if (_showReview)
              FilledButton(
                onPressed: _recognizing ? null : _submit,
                child: const Text('保存账号'),
              ),
          ],
        ),
        child: bodyWithPasteShortcut,
      );
    }

    return Scaffold(
      backgroundColor: c.canvas,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          tooltip: '关闭',
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text('从截图快捷导入'),
        titleTextStyle: Theme.of(context).textTheme.titleLarge?.copyWith(
          fontSize: 17,
          fontWeight: FontWeight.w600,
        ),
        backgroundColor: c.surface,
        elevation: 0,
        scrolledUnderElevation: 0,
        actionsPadding: const EdgeInsets.only(right: 12),
        actions: [
          if (_showReview)
            FilledButton(
              onPressed: _recognizing ? null : _submit,
              child: const Text('保存账号'),
            ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Divider(height: 1, color: c.border),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          child: bodyWithPasteShortcut,
        ),
      ),
    );
  }
}
