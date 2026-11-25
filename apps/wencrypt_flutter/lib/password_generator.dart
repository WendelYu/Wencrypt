import 'dart:async';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'design/wencrypt_theme.dart';
import 'design/wencrypt_widgets.dart';

const _upperFull = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
const _upperClear = 'ABCDEFGHJKLMNPQRSTUVWXYZ';
const _lowerFull = 'abcdefghijklmnopqrstuvwxyz';
const _lowerClear = 'abcdefghijkmnpqrstuvwxyz';
const _digitsFull = '0123456789';
const _digitsClear = '23456789';
const _symbolsPool = '!@#%&*+-_=?';

/// Configuration options for random password generation.
@immutable
class PasswordGeneratorOptions {
  const PasswordGeneratorOptions({
    this.length = 20,
    this.uppercase = true,
    this.lowercase = true,
    this.digits = true,
    this.symbols = true,
    this.excludeAmbiguous = true,
  });

  final int length;
  final bool uppercase;
  final bool lowercase;
  final bool digits;
  final bool symbols;
  final bool excludeAmbiguous;

  int get clampedLength => length.clamp(8, 64);

  List<String> get activePools => [
    if (uppercase) excludeAmbiguous ? _upperClear : _upperFull,
    if (lowercase) excludeAmbiguous ? _lowerClear : _lowerFull,
    if (digits) excludeAmbiguous ? _digitsClear : _digitsFull,
    if (symbols) _symbolsPool,
  ];

  int get activeClassCount => activePools.length;

  String get pool => activePools.join();

  double get entropyBits {
    final chars = pool;
    if (chars.isEmpty) return 0;
    return clampedLength * (log(chars.length) / ln2);
  }

  PasswordGeneratorOptions copyWith({
    int? length,
    bool? uppercase,
    bool? lowercase,
    bool? digits,
    bool? symbols,
    bool? excludeAmbiguous,
  }) => PasswordGeneratorOptions(
    length: length ?? this.length,
    uppercase: uppercase ?? this.uppercase,
    lowercase: lowercase ?? this.lowercase,
    digits: digits ?? this.digits,
    symbols: symbols ?? this.symbols,
    excludeAmbiguous: excludeAmbiguous ?? this.excludeAmbiguous,
  );

  @override
  bool operator ==(Object other) =>
      other is PasswordGeneratorOptions &&
      other.length == length &&
      other.uppercase == uppercase &&
      other.lowercase == lowercase &&
      other.digits == digits &&
      other.symbols == symbols &&
      other.excludeAmbiguous == excludeAmbiguous;

  @override
  int get hashCode => Object.hash(
    length,
    uppercase,
    lowercase,
    digits,
    symbols,
    excludeAmbiguous,
  );
}

/// Generates a cryptographically random password containing at least one
/// character from each enabled character class, shuffled via Fisher-Yates.
String generateSecurePassword(
  PasswordGeneratorOptions options, {
  Random? random,
}) {
  final pools = options.activePools;
  if (pools.isEmpty) {
    throw ArgumentError('At least one character class must be enabled.');
  }
  final targetLength = options.clampedLength;
  final rng = random ?? Random.secure();
  final combined = options.pool;
  final chars = <String>[
    for (final p in pools) p[rng.nextInt(p.length)],
    for (var i = pools.length; i < targetLength; i++)
      combined[rng.nextInt(combined.length)],
  ];
  for (var i = chars.length - 1; i > 0; i--) {
    final j = rng.nextInt(i + 1);
    final tmp = chars[i];
    chars[i] = chars[j];
    chars[j] = tmp;
  }
  return chars.join();
}

enum _CharKind { letter, digit, symbol }

_CharKind _classifyRune(int rune) {
  if ((rune >= 0x41 && rune <= 0x5A) || (rune >= 0x61 && rune <= 0x7A)) {
    return _CharKind.letter;
  }
  if (rune >= 0x30 && rune <= 0x39) {
    return _CharKind.digit;
  }
  return _CharKind.symbol;
}

/// Builds a color-coded monospace [TextSpan] for password readability:
/// letters in primary text, digits in brand accent, and symbols in warning amber.
TextSpan buildStyledPasswordSpan(
  String password, {
  required WColors colors,
  required TextStyle baseStyle,
}) {
  final mono = baseStyle.copyWith(fontFamily: wMonoFamily);
  if (password.isEmpty) {
    return TextSpan(text: '', style: mono);
  }
  final spans = <InlineSpan>[];
  var currentKind = _classifyRune(password.runes.first);
  final buffer = StringBuffer();

  void flush() {
    if (buffer.isEmpty) return;
    final color = switch (currentKind) {
      _CharKind.letter => colors.textPrimary,
      _CharKind.digit => colors.brand,
      _CharKind.symbol => colors.warning,
    };
    spans.add(
      TextSpan(
        text: buffer.toString(),
        style: mono.copyWith(color: color),
      ),
    );
    buffer.clear();
  }

  for (final rune in password.runes) {
    final kind = _classifyRune(rune);
    if (kind != currentKind) {
      flush();
      currentKind = kind;
    }
    buffer.writeCharCode(rune);
  }
  flush();
  return TextSpan(children: spans, style: mono);
}

enum PasswordGeneratorAction { copy, createAccount, apply }

class PasswordGeneratorResult {
  const PasswordGeneratorResult({
    required this.action,
    required this.password,
    required this.options,
  });

  final PasswordGeneratorAction action;
  final String password;
  final PasswordGeneratorOptions options;
}

/// Opens the customizable random password generator dialog (desktop) or
/// full-screen page (mobile).
Future<PasswordGeneratorResult?> showPasswordGeneratorDialog(
  BuildContext context, {
  required PasswordGeneratorOptions initialOptions,
  required bool mobile,
  bool pickerMode = false,
  Future<void> Function(String password)? onCopy,
}) {
  final route = mobile
      ? MaterialPageRoute<PasswordGeneratorResult>(
          fullscreenDialog: true,
          builder: (_) => _PasswordGeneratorView(
            initialOptions: initialOptions,
            mobile: true,
            pickerMode: pickerMode,
            onCopy: onCopy,
          ),
        )
      : DialogRoute<PasswordGeneratorResult>(
          context: context,
          builder: (_) => _PasswordGeneratorView(
            initialOptions: initialOptions,
            mobile: false,
            pickerMode: pickerMode,
            onCopy: onCopy,
          ),
        );
  return Navigator.of(context).push(route);
}

class _PasswordGeneratorView extends StatefulWidget {
  const _PasswordGeneratorView({
    required this.initialOptions,
    required this.mobile,
    required this.pickerMode,
    this.onCopy,
  });

  final PasswordGeneratorOptions initialOptions;
  final bool mobile;
  final bool pickerMode;
  final Future<void> Function(String password)? onCopy;

  @override
  State<_PasswordGeneratorView> createState() => _PasswordGeneratorViewState();
}

class _PasswordGeneratorViewState extends State<_PasswordGeneratorView> {
  static const _lengthPresets = [12, 16, 20, 32];

  late PasswordGeneratorOptions _options;
  late String _password;
  bool _copied = false;
  Timer? _copiedTimer;

  @override
  void initState() {
    super.initState();
    _options = widget.initialOptions.activeClassCount == 0
        ? const PasswordGeneratorOptions()
        : widget.initialOptions;
    _password = generateSecurePassword(_options);
  }

  @override
  void dispose() {
    _copiedTimer?.cancel();
    super.dispose();
  }

  void _regenerate([PasswordGeneratorOptions? nextOptions]) {
    final target = nextOptions ?? _options;
    if (target.activeClassCount == 0) return;
    _copiedTimer?.cancel();
    setState(() {
      _options = target;
      _password = generateSecurePassword(target);
      _copied = false;
    });
  }

  Future<void> _handleInlineCopy() async {
    if (widget.onCopy != null) {
      await widget.onCopy!(_password);
    } else {
      await Clipboard.setData(ClipboardData(text: _password));
    }
    if (!mounted) return;
    _copiedTimer?.cancel();
    setState(() => _copied = true);
    _copiedTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  Future<void> _handleFooterCopy() async {
    if (widget.onCopy != null) {
      await _handleInlineCopy();
      return;
    }
    await Clipboard.setData(ClipboardData(text: _password));
    if (!mounted) return;
    Navigator.pop(
      context,
      PasswordGeneratorResult(
        action: PasswordGeneratorAction.copy,
        password: _password,
        options: _options,
      ),
    );
  }

  void _finish(PasswordGeneratorAction action) {
    Navigator.pop(
      context,
      PasswordGeneratorResult(
        action: action,
        password: _password,
        options: _options,
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final c = WColors.of(context);
    final mobile = widget.mobile;
    final entropy = _options.entropyBits.round();
    final canDisable = _options.activeClassCount > 1;

    Widget classChip({
      required String label,
      required bool selected,
      required ValueChanged<bool> onToggle,
    }) => FilterChip(
      label: Text(label),
      selected: selected,
      visualDensity: mobile ? VisualDensity.standard : VisualDensity.compact,
      labelStyle: TextStyle(fontSize: mobile ? 13 : 12),
      materialTapTargetSize: mobile
          ? MaterialTapTargetSize.padded
          : MaterialTapTargetSize.shrinkWrap,
      onSelected: (next) {
        if (!next && !canDisable) return;
        onToggle(next);
      },
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: EdgeInsets.fromLTRB(
            mobile ? 16 : 14,
            mobile ? 14 : 12,
            mobile ? 10 : 8,
            mobile ? 12 : 10,
          ),
          decoration: BoxDecoration(
            color: c.surfaceMuted,
            borderRadius: BorderRadius.circular(WRadius.md),
            border: Border.all(color: c.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 4, right: 8),
                      child: SelectableText.rich(
                        buildStyledPasswordSpan(
                          _password,
                          colors: c,
                          baseStyle: TextStyle(
                            fontSize: mobile ? 18 : 16.5,
                            fontWeight: FontWeight.w600,
                            height: 1.45,
                            letterSpacing: 0.4,
                          ),
                        ),
                      ),
                    ),
                  ),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          WIconButton(
                            icon: Icons.refresh_rounded,
                            tooltip: '重新生成',
                            size: mobile ? 38 : 30,
                            iconSize: mobile ? 20 : 17,
                            onPressed: () => _regenerate(),
                          ),
                          WIconButton(
                            icon: _copied
                                ? Icons.check_rounded
                                : Icons.copy_rounded,
                            tooltip: '复制密码',
                            size: mobile ? 38 : 30,
                            iconSize: mobile ? 19 : 16,
                            color: _copied ? c.success : null,
                            onPressed: _handleInlineCopy,
                          ),
                        ],
                      ),
                      if (_copied)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            '已复制',
                            style: TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w600,
                              color: c.success,
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(child: WPasswordStrength(password: _password)),
                  const SizedBox(width: 10),
                  WStatusPill(
                    label: '约 $entropy bits',
                    tone: entropy >= 80
                        ? WTone.success
                        : entropy >= 56
                        ? WTone.info
                        : WTone.warning,
                  ),
                ],
              ),
            ],
          ),
        ),
        SizedBox(height: mobile ? 18 : 14),
        Row(
          children: [
            Text(
              '密码长度',
              style: TextStyle(
                fontSize: mobile ? 13.5 : 12,
                fontWeight: FontWeight.w600,
                color: c.textSecondary,
              ),
            ),
            const Spacer(),
            Text(
              '${_options.clampedLength} 位',
              style: TextStyle(
                fontSize: mobile ? 14 : 12.5,
                fontWeight: FontWeight.w700,
                fontFamily: wMonoFamily,
                color: c.brand,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            for (final preset in _lengthPresets)
              ChoiceChip(
                label: Text('$preset 位'),
                selected: _options.clampedLength == preset,
                visualDensity: mobile
                    ? VisualDensity.standard
                    : VisualDensity.compact,
                labelStyle: TextStyle(fontSize: mobile ? 13 : 11.5),
                materialTapTargetSize: mobile
                    ? MaterialTapTargetSize.padded
                    : MaterialTapTargetSize.shrinkWrap,
                onSelected: (_) =>
                    _regenerate(_options.copyWith(length: preset)),
              ),
          ],
        ),
        Slider(
          value: _options.clampedLength.toDouble(),
          min: 8,
          max: 64,
          divisions: 56,
          label: '${_options.clampedLength} 位',
          onChanged: (value) =>
              _regenerate(_options.copyWith(length: value.round())),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Text(
              '字符组成',
              style: TextStyle(
                fontSize: mobile ? 13.5 : 12,
                fontWeight: FontWeight.w600,
                color: c.textSecondary,
              ),
            ),
            if (!canDisable) ...[
              const SizedBox(width: 8),
              Text(
                '至少保留一种字符类型',
                style: TextStyle(fontSize: 11, color: c.textTertiary),
              ),
            ],
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            classChip(
              label: '大写字母 (A-Z)',
              selected: _options.uppercase,
              onToggle: (v) => _regenerate(_options.copyWith(uppercase: v)),
            ),
            classChip(
              label: '小写字母 (a-z)',
              selected: _options.lowercase,
              onToggle: (v) => _regenerate(_options.copyWith(lowercase: v)),
            ),
            classChip(
              label: '数字 (0-9)',
              selected: _options.digits,
              onToggle: (v) => _regenerate(_options.copyWith(digits: v)),
            ),
            classChip(
              label: '特殊符号 (!@#…)',
              selected: _options.symbols,
              onToggle: (v) => _regenerate(_options.copyWith(symbols: v)),
            ),
          ],
        ),
        SizedBox(height: mobile ? 16 : 12),
        Container(
          padding: EdgeInsets.fromLTRB(
            mobile ? 14 : 10,
            mobile ? 8 : 5,
            mobile ? 10 : 6,
            mobile ? 8 : 5,
          ),
          decoration: BoxDecoration(
            color: c.surfaceMuted,
            borderRadius: BorderRadius.circular(WRadius.sm),
          ),
          child: Row(
            children: [
              Icon(
                Icons.visibility_outlined,
                size: mobile ? 18 : 15,
                color: c.textSecondary,
              ),
              SizedBox(width: mobile ? 10 : 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '排除易混淆字符',
                      style: TextStyle(
                        fontSize: mobile ? 14 : 12.2,
                        fontWeight: FontWeight.w600,
                        color: c.textPrimary,
                      ),
                    ),
                    Text(
                      '避开 0 / O / o / 1 / l / I，手工录入更不易看错',
                      style: TextStyle(
                        fontSize: mobile ? 11.8 : 10.8,
                        color: c.textTertiary,
                      ),
                    ),
                  ],
                ),
              ),
              Switch.adaptive(
                value: _options.excludeAmbiguous,
                onChanged: (v) =>
                    _regenerate(_options.copyWith(excludeAmbiguous: v)),
              ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = WColors.of(context);
    if (!widget.mobile) {
      return WDialog(
        width: 480,
        icon: Icons.auto_fix_high_rounded,
        title: '随机密码生成器',
        subtitle: '本地安全随机生成 · 支持长度与字符集定制',
        footer: WDialogFooter(
          actions: widget.pickerMode
              ? [
                  TextButton(
                    style: TextButton.styleFrom(
                      foregroundColor: c.textSecondary,
                    ),
                    onPressed: () => Navigator.pop(context),
                    child: const Text('取消'),
                  ),
                  FilledButton(
                    onPressed: () => _finish(PasswordGeneratorAction.apply),
                    child: const Text('使用此密码'),
                  ),
                ]
              : [
                  TextButton(
                    style: TextButton.styleFrom(
                      foregroundColor: c.textSecondary,
                    ),
                    onPressed: () => Navigator.pop(context),
                    child: const Text('关闭'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _handleFooterCopy,
                    icon: const Icon(Icons.copy_rounded, size: 15),
                    label: const Text('复制密码'),
                  ),
                  FilledButton.icon(
                    onPressed: () =>
                        _finish(PasswordGeneratorAction.createAccount),
                    icon: const Icon(Icons.add_rounded, size: 16),
                    label: const Text('用此密码新增账号'),
                  ),
                ],
        ),
        child: _buildBody(context),
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
        title: const Text('随机密码生成器'),
        titleTextStyle: Theme.of(context).textTheme.titleLarge?.copyWith(
          fontSize: 17,
          fontWeight: FontWeight.w600,
        ),
        backgroundColor: c.surface,
        elevation: 0,
        scrolledUnderElevation: 0,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Divider(height: 1, color: c.border),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          child: _buildBody(context),
        ),
      ),
      bottomNavigationBar: DecoratedBox(
        decoration: BoxDecoration(
          color: c.surface,
          border: Border(top: BorderSide(color: c.border)),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            child: widget.pickerMode
                ? SizedBox(
                    height: 46,
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: () => _finish(PasswordGeneratorAction.apply),
                      child: const Text('使用此密码'),
                    ),
                  )
                : Row(
                    children: [
                      Expanded(
                        child: SizedBox(
                          height: 46,
                          child: OutlinedButton.icon(
                            onPressed: _handleFooterCopy,
                            icon: const Icon(Icons.copy_rounded, size: 17),
                            label: const Text('复制密码'),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        flex: 2,
                        child: SizedBox(
                          height: 46,
                          child: FilledButton.icon(
                            onPressed: () =>
                                _finish(PasswordGeneratorAction.createAccount),
                            icon: const Icon(Icons.add_rounded, size: 18),
                            label: const Text('用此密码新增账号'),
                          ),
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}
