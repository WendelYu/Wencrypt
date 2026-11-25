import 'dart:math' as math;

import 'package:flutter/services.dart';

/// A single line or block of text recognized by native offline OCR, with
/// normalized top-left coordinates in `[0.0, 1.0]`.
class OcrBlock {
  const OcrBlock({
    required this.text,
    this.x = 0.0,
    this.y = 0.0,
    this.w = 0.0,
    this.h = 0.0,
  });

  final String text;
  final double x;
  final double y;
  final double w;
  final double h;

  double get centerY => y + h / 2.0;
  double get right => x + w;
  double get bottom => y + h;
}

class OcrRecognitionResult {
  const OcrRecognitionResult({required this.text, required this.blocks});

  final String text;
  final List<OcrBlock> blocks;
}

class ParsedCredential {
  const ParsedCredential({
    this.title = '',
    this.username = '',
    this.password = '',
    this.url = '',
    this.passwordMasked = false,
    this.candidates = const [],
    this.rawLines = const [],
  });

  final String title;
  final String username;
  final String password;
  final String url;
  final bool passwordMasked;
  final List<String> candidates;
  final List<String> rawLines;

  bool get isEmpty =>
      title.isEmpty && username.isEmpty && password.isEmpty && url.isEmpty;
}

class ScreenshotOcrException implements Exception {
  const ScreenshotOcrException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => message;
}

/// Bridge to the native offline OCR & clipboard/share channels (`org.wencrypt.ocr`).
class ScreenshotOcrService {
  const ScreenshotOcrService({MethodChannel? channel})
    : _channel = channel ?? defaultChannel;

  static const defaultChannel = MethodChannel('org.wencrypt.ocr');

  final MethodChannel _channel;

  Future<Uint8List?> readClipboardImage() async {
    try {
      return await _channel.invokeMethod<Uint8List>('readClipboardImage');
    } on MissingPluginException {
      return null;
    } on PlatformException catch (error) {
      throw ScreenshotOcrException(error.code, friendlyError(error));
    }
  }

  Future<Uint8List?> takePendingImage() async {
    try {
      return await _channel.invokeMethod<Uint8List>('takePendingImage');
    } on MissingPluginException {
      return null;
    } on PlatformException catch (error) {
      throw ScreenshotOcrException(error.code, friendlyError(error));
    }
  }

  Future<OcrRecognitionResult> recognizeImage(Uint8List bytes) async {
    if (bytes.isEmpty) {
      throw const ScreenshotOcrException('invalid_image', '图片数据为空，请重新选择截图。');
    }
    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>(
        'recognizeImage',
        bytes,
      );
      if (raw == null) {
        return const OcrRecognitionResult(text: '', blocks: []);
      }
      final fullText = (raw['text'] as String? ?? '').trim();
      final rawBlocks = raw['blocks'] as List? ?? const [];
      final blocks = <OcrBlock>[];
      for (final item in rawBlocks) {
        if (item is! Map) continue;
        final text = (item['text'] as String? ?? '').trim();
        if (text.isEmpty) continue;
        double numVal(String k) {
          final v = item[k];
          if (v is num && v.isFinite) return v.toDouble().clamp(0.0, 1.0);
          return 0.0;
        }

        blocks.add(
          OcrBlock(
            text: text,
            x: numVal('x'),
            y: numVal('y'),
            w: numVal('w'),
            h: numVal('h'),
          ),
        );
      }
      if (blocks.isEmpty && fullText.isNotEmpty) {
        final fallback = _blocksFromPlainText(fullText);
        return OcrRecognitionResult(text: fullText, blocks: fallback);
      }
      return OcrRecognitionResult(text: fullText, blocks: blocks);
    } on MissingPluginException {
      throw const ScreenshotOcrException(
        'ocr_unavailable',
        '当前平台暂不支持离线截图识别，请手动填写。',
      );
    } on PlatformException catch (error) {
      throw ScreenshotOcrException(error.code, friendlyError(error));
    }
  }

  static String friendlyError(Object error) {
    if (error is ScreenshotOcrException) return error.message;
    if (error is PlatformException) {
      return switch (error.code) {
        'ocr_unavailable' => '当前系统未启用本机 OCR（Windows 请确认已安装中文或英文 OCR 语言包）。',
        'invalid_image' => '无法读取该截图文件，请使用 PNG 或 JPG 图片重试。',
        'clipboard_busy' => '剪贴板正被其他应用占用，请稍后重试。',
        _ => '未能识别图片中的文字，请更换清晰截图后重试。',
      };
    }
    return '截图识别未完成，请重试。';
  }
}

const _cjkPattern = r'[\u4E00-\u9FFF\u3400-\u4DBF\uF900-\uFAFF]';
final _cjkPairSpaceRe = RegExp('(?<=$_cjkPattern)[ \\t]+(?=$_cjkPattern)');
final _cjkBeforePunctSpaceRe = RegExp(
  '(?<=$_cjkPattern)[ \\t]+(?=[：:，,。.！？（）()【】])',
);
final _cjkAfterPunctSpaceRe = RegExp(
  '(?<=[：:（(【])[ \\t]+(?=$_cjkPattern)|(?<=$_cjkPattern'
  '：)[ \\t]+',
);

/// Collapses inter-character spaces inserted by some OCR engines (e.g. Windows
/// Media OCR turning "用户名" into "用 户 名") while preserving ASCII spacing.
String normalizeCjkSpacing(String input) {
  var out = input.trim();
  if (out.isEmpty) return '';
  for (var i = 0; i < 4; i++) {
    final next = out
        .replaceAll(_cjkPairSpaceRe, '')
        .replaceAll(_cjkBeforePunctSpaceRe, '')
        .replaceAll(_cjkAfterPunctSpaceRe, '');
    if (next == out) break;
    out = next;
  }
  return out;
}

List<OcrBlock> _blocksFromPlainText(String text) {
  final lines = text
      .split(RegExp(r'\r?\n'))
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .toList();
  return [
    for (var i = 0; i < lines.length; i++)
      OcrBlock(text: lines[i], x: 0.08, y: i * 0.05, w: 0.84, h: 0.03),
  ];
}

enum _FieldKind {
  username,
  password,
  confirmPassword,
  url,
  title,
  captcha,
  none,
}

final _maskedPasswordRe = RegExp(r'^[\s•●·\*○▪■✦∗◦⚫\-_]{4,}$');
final _repeatedSameMaskRe = RegExp(r'^([•●·\*○▪■✦∗◦⚫])\1{3,}$');

bool isMaskedPasswordText(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) return false;
  if (_repeatedSameMaskRe.hasMatch(trimmed)) return true;
  if (RegExp(r'^[\s\-_]+$').hasMatch(trimmed)) return false;
  return _maskedPasswordRe.hasMatch(trimmed);
}

final _statusTimeRe = RegExp(r'^\d{1,2}:\d{2}$');
final _percentRe = RegExp(r'^\d{1,3}%$');
final _signalRe = RegExp(r'^(5G|4G|3G|LTE|HD|Wi-?Fi)$', caseSensitive: false);

final _exactActionNoise = <String>{
  '注册',
  '立即注册',
  '免费注册',
  '注册账号',
  '注册账户',
  '创建账号',
  '创建账户',
  '完成注册',
  '登录',
  '立即登录',
  '登录账号',
  '下一步',
  '上一步',
  '完成',
  '提交',
  '确定',
  '确认',
  '取消',
  '保存',
  '继续',
  '发送验证码',
  '获取验证码',
  '重新发送',
  '忘记密码',
  '忘记密码?',
  '忘记密码？',
  '找回密码',
  '已有账号',
  '已有账号?',
  '已有账号？',
  '去登录',
  '立即体验',
  '看不清换一张',
  '换一张',
  'sign up',
  'signup',
  'sign in',
  'signin',
  'log in',
  'login',
  'register',
  'create account',
  'create an account',
  'continue',
  'next',
  'submit',
  'done',
  'confirm',
  'cancel',
  'get code',
  'send code',
  'resend',
  'forgot password',
  'forgot password?',
  'already have an account',
  'already have an account?',
  'or',
  '或者',
};

final _placeholderPrefixes = [
  '请输入',
  '请填写',
  '请设置',
  '请再次输入',
  '再次输入',
  '请确认',
  '请输',
  'enter ',
  'please enter ',
  'input ',
  'type ',
  'choose a ',
  'create a ',
  're-enter ',
  'reenter ',
  'confirm your ',
  'your ',
];

final _hintPatterns = [
  RegExp(r'^(至少|需包含|必须包含|密码长度|长度[为在]?)\s*\d+'),
  RegExp(r'\d+\s*[-~～至到]\s*\d+\s*位'),
  RegExp(r'(at least|minimum)\s+\d+\s+char', caseSensitive: false),
  RegExp(r'characters?\s+(long|minimum|or more)', caseSensitive: false),
  RegExp(r'(字母和数字|大小写字母|特殊字符|数字和字母)'),
  RegExp(r'(用户协议|隐私政策|服务条款|服务协议|隐私权政策)'),
  RegExp(
    r'(terms of service|privacy policy|by signing up|i agree to)',
    caseSensitive: false,
  ),
];

bool _isUiNoise(String raw) {
  final normalized = normalizeCjkSpacing(raw).trim();
  if (normalized.isEmpty) return true;
  if (_statusTimeRe.hasMatch(normalized) ||
      _percentRe.hasMatch(normalized) ||
      _signalRe.hasMatch(normalized)) {
    return true;
  }
  final lower = normalized.toLowerCase();
  if (_exactActionNoise.contains(lower)) return true;
  final stripped = lower.replaceAll(RegExp(r'^[•\-\*\s]+|[!！?？。.\s]+$'), '');
  if (_exactActionNoise.contains(stripped)) return true;
  for (final prefix in _placeholderPrefixes) {
    if (lower.startsWith(prefix)) return true;
  }
  for (final pattern in _hintPatterns) {
    if (pattern.hasMatch(normalized)) return true;
  }
  if ((normalized.contains('同意') || normalized.contains('阅读并同意')) &&
      (normalized.contains('协议') ||
          normalized.contains('政策') ||
          normalized.contains('条款'))) {
    return true;
  }
  return false;
}

String _stripLabelDecorations(String text) {
  var out = normalizeCjkSpacing(text).trim();
  out = out.replaceAll(RegExp(r'^[\*\s•·\-]+'), '');
  out = out.replaceAll(RegExp(r'[\*\s：:]+$'), '');
  return out.trim();
}

const _captchaLabels = [
  '图形验证码',
  '短信验证码',
  '邮箱验证码',
  '手机验证码',
  '动态验证码',
  '验证码',
  '校验码',
  '动态码',
  '安全码',
  '邀请码',
  '推荐码',
  'verification code',
  'verify code',
  'security code',
  'captcha',
  'otp',
  'sms code',
  'email code',
  'invite code',
  'invitation code',
  'referral code',
];

const _confirmPasswordLabels = [
  '确认密码',
  '重复密码',
  '再次输入密码',
  '确认登录密码',
  '确认新密码',
  '密码确认',
  'confirm password',
  'confirm new password',
  're-enter password',
  'reenter password',
  'repeat password',
  'verify password',
  'password again',
];

const _passwordLabels = [
  '登录密码',
  '初始密码',
  '默认密码',
  '设置密码',
  '新密码',
  '账户密码',
  '账号密码',
  '通行密码',
  '密码',
  '口令',
  'new password',
  'initial password',
  'default password',
  'password',
  'passwd',
  'pwd',
  'passcode',
  'passphrase',
];

const _usernameLabels = [
  '登录账号',
  '登录帐号',
  '登录名',
  '用户名',
  '账户名',
  '电子邮箱',
  '邮箱地址',
  '手机号码',
  '账号',
  '帐号',
  '账户',
  '邮箱',
  '手机号',
  '用户id',
  '用户名/邮箱',
  '手机号/邮箱',
  '账号/邮箱',
  'user name',
  'username',
  'user id',
  'userid',
  'account',
  'login id',
  'login name',
  'login',
  'e-mail',
  'email',
  'phone number',
  'phone',
  'mobile',
];

const _urlLabels = [
  '登录地址',
  '网站地址',
  '服务器地址',
  '网址',
  '网站',
  '地址',
  '官网',
  '服务器',
  '域名',
  'website',
  'web site',
  'login url',
  'site url',
  'server url',
  'url',
  'site',
  'host',
  'server',
  'domain',
  'endpoint',
];

const _titleLabels = [
  '网站名称',
  '平台名称',
  '系统名称',
  '应用名称',
  '服务名称',
  '来源',
  '平台',
  '名称',
  '应用',
  '服务',
  'service name',
  'app name',
  'platform',
  'source',
  'title',
  'name',
];

bool _matchesLabelList(String cleanedLower, List<String> candidates) {
  for (final label in candidates) {
    if (cleanedLower == label) return true;
  }
  return false;
}

_FieldKind _classifyLabel(String raw) {
  final cleaned = _stripLabelDecorations(raw);
  if (cleaned.isEmpty || cleaned.length > 26) return _FieldKind.none;
  if (_isUiNoise(cleaned)) return _FieldKind.none;
  final lower = cleaned.toLowerCase();
  if (_matchesLabelList(lower, _captchaLabels)) return _FieldKind.captcha;
  if (_matchesLabelList(lower, _confirmPasswordLabels)) {
    return _FieldKind.confirmPassword;
  }
  if (_matchesLabelList(lower, _passwordLabels)) return _FieldKind.password;
  if (_matchesLabelList(lower, _usernameLabels)) return _FieldKind.username;
  if (_matchesLabelList(lower, _urlLabels)) return _FieldKind.url;
  if (_matchesLabelList(lower, _titleLabels)) return _FieldKind.title;
  return _FieldKind.none;
}

({String label, String value})? _splitInlineLabelValue(String raw) {
  final normalized = normalizeCjkSpacing(raw).trim();
  if (normalized.isEmpty) return null;

  // Prefer explicit colon separators (ignoring URL scheme `://`).
  for (var i = 0; i < normalized.length; i++) {
    final ch = normalized[i];
    if (ch == '：' || ch == ':') {
      if (ch == ':' &&
          i + 2 < normalized.length &&
          normalized.substring(i + 1, i + 3) == '//') {
        continue;
      }
      final left = normalized.substring(0, i).trim();
      final right = normalized.substring(i + 1).trim();
      if (_classifyLabel(left) != _FieldKind.none) {
        return (label: left, value: right);
      }
    }
  }

  // Fallback for space-separated inline pairs like "账号 alice@example.com"
  // or "Password MySecret99!".
  final allLabels = [
    ..._captchaLabels,
    ..._confirmPasswordLabels,
    ..._passwordLabels,
    ..._usernameLabels,
    ..._urlLabels,
    ..._titleLabels,
  ];
  final lower = normalized.toLowerCase();
  for (final candidate in allLabels) {
    if (!lower.startsWith(candidate)) continue;
    final rest = normalized.substring(candidate.length);
    if (rest.isEmpty) continue;
    final startsWithGap = rest.startsWith(' ') || rest.startsWith('\t');
    final isCjkLabelToAsciiValue =
        candidate.runes.any((r) => r >= 0x4E00) &&
        RegExp(r'^[A-Za-z0-9@._+!\-#]').hasMatch(rest);
    if (startsWithGap || isCjkLabelToAsciiValue) {
      final value = rest.trim();
      if (value.isNotEmpty) {
        return (label: normalized.substring(0, candidate.length), value: value);
      }
    }
  }
  return null;
}

final _emailRe = RegExp(
  r'\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\b',
);
final _urlWithSchemeRe = RegExp(
  r'https?://[^\s<>\]\)"\x27]+',
  caseSensitive: false,
);
final _domainRe = RegExp(
  r'(?<![@\w.\-])([a-zA-Z0-9\-]+(?:\.[a-zA-Z0-9\-]+)*\.(?:com|cn|com\.cn|net|org|io|app|dev|co|ai|me|cc|tv|jp|uk|edu|gov|cloud|tech|xyz)(?:/[^\s<>\]\)"\x27]*)?)\b',
  caseSensitive: false,
);
final _cnPhoneRe = RegExp(r'(?<!\d)(?:\+?86[-\s]?)?(1[3-9]\d{9})(?!\d)');
final _intlPhoneRe = RegExp(r'(?<!\w)(\+\d{1,3}[\s\-]?\d{6,12})(?!\d)');

String? _extractUrlCandidate(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  final withScheme = _urlWithSchemeRe.firstMatch(trimmed);
  if (withScheme != null) {
    return _cleanTrailingUrlPunct(withScheme.group(0)!);
  }
  final domain = _domainRe.firstMatch(trimmed);
  if (domain != null) {
    final matched = _cleanTrailingUrlPunct(domain.group(1)!);
    return 'https://$matched';
  }
  return null;
}

String _cleanTrailingUrlPunct(String url) =>
    url.replaceAll(RegExp(r'[,.;:!?，。；：！？\)]+$'), '');

String? _extractEmailCandidate(String raw) => _emailRe.firstMatch(raw)?.group(0);

String? _extractPhoneCandidate(String raw) {
  final cn = _cnPhoneRe.firstMatch(raw);
  if (cn != null) return cn.group(1);
  final intl = _intlPhoneRe.firstMatch(raw);
  if (intl != null) {
    final value = intl.group(1)!.replaceAll(RegExp(r'\s+'), '');
    if (!value.startsWith('400') && !value.startsWith('800')) return value;
  }
  return null;
}

bool _isGenericServiceEmail(String email) {
  final lower = email.toLowerCase();
  return lower.startsWith('noreply@') ||
      lower.startsWith('no-reply@') ||
      lower.startsWith('support@') ||
      lower.startsWith('service@') ||
      lower.startsWith('help@') ||
      lower.startsWith('feedback@') ||
      lower.startsWith('kefu@') ||
      lower.startsWith('admin@');
}

bool _looksLikePasswordToken(String value) {
  final s = value.trim();
  if (s.length < 6 || s.length > 64) return false;
  if (s.contains(RegExp(r'\s'))) return false;
  if (s.runes.any((r) => r < 0x21 || r > 0x7E)) return false;
  if (_urlWithSchemeRe.hasMatch(s) || _emailRe.hasMatch(s)) return false;
  if (_isUiNoise(s) || isMaskedPasswordText(s)) return false;

  var classes = 0;
  if (RegExp(r'[a-z]').hasMatch(s)) classes++;
  if (RegExp(r'[A-Z]').hasMatch(s)) classes++;
  if (RegExp(r'[0-9]').hasMatch(s)) classes++;
  if (RegExp(r'[^a-zA-Z0-9]').hasMatch(s)) classes++;
  if (classes >= 2 && s.length >= 6) return true;
  if (classes == 1 && s.length >= 10 && RegExp(r'[a-zA-Z]').hasMatch(s)) {
    return true;
  }
  return false;
}

const _knownBrandDomains = <String, String>{
  'github.com': 'GitHub',
  'gitlab.com': 'GitLab',
  'bitbucket.org': 'Bitbucket',
  'google.com': 'Google',
  'accounts.google.com': 'Google',
  'apple.com': 'Apple',
  'icloud.com': 'iCloud',
  'microsoft.com': 'Microsoft',
  'live.com': 'Microsoft',
  'outlook.com': 'Outlook',
  'openai.com': 'OpenAI',
  'chatgpt.com': 'ChatGPT',
  'claude.ai': 'Claude',
  'anthropic.com': 'Anthropic',
  'notion.so': 'Notion',
  'figma.com': 'Figma',
  'discord.com': 'Discord',
  'slack.com': 'Slack',
  'cloudflare.com': 'Cloudflare',
  'vercel.com': 'Vercel',
  'netlify.com': 'Netlify',
  'aws.amazon.com': 'AWS',
  'amazon.com': 'Amazon',
  'steampowered.com': 'Steam',
  'store.steampowered.com': 'Steam',
  'aliyun.com': '阿里云',
  'alibabacloud.com': '阿里云',
  'tencent.com': '腾讯',
  'cloud.tencent.com': '腾讯云',
  'huawei.com': '华为',
  'huaweicloud.com': '华为云',
  'baidu.com': '百度',
  'bilibili.com': 'Bilibili',
  'zhihu.com': '知乎',
  'jd.com': '京东',
  'taobao.com': '淘宝',
  'tmall.com': '天猫',
  'alipay.com': '支付宝',
  'douban.com': '豆瓣',
  '163.com': '网易',
  '126.com': '网易邮箱',
  'qq.com': 'QQ',
  'weibo.com': '微博',
  'xiaohongshu.com': '小红书',
  'jianguoyun.com': '坚果云',
  'feishu.cn': '飞书',
  'dingtalk.com': '钉钉',
  'gitee.com': 'Gitee',
};

String _inferTitleFromUrl(String url) {
  if (url.isEmpty) return '';
  final uri = Uri.tryParse(url.contains('://') ? url : 'https://$url');
  final host = (uri?.host ?? '').toLowerCase();
  if (host.isEmpty) return '';
  final bareHost = host.startsWith('www.') ? host.substring(4) : host;
  if (_knownBrandDomains.containsKey(bareHost)) {
    return _knownBrandDomains[bareHost]!;
  }
  for (final entry in _knownBrandDomains.entries) {
    if (bareHost.endsWith('.${entry.key}')) {
      return entry.value;
    }
  }
  return '';
}

final _cnHeadingPatterns = [
  RegExp(
    r'^(?:欢迎)?(?:注册|创建)\s*([A-Za-z0-9\u4E00-\u9FFF._\- ]{2,24}?)\s*(?:账号|帐号|账户)?$',
  ),
  RegExp(r'^([A-Za-z0-9\u4E00-\u9FFF._\-]{2,20})\s*(?:用户|账号|账户)?注册$'),
];

final _enHeadingPatterns = [
  RegExp(
    r'^(?:sign\s*up|register)\s+(?:for|to|with)\s+([A-Za-z0-9._\- ]{2,28})$',
    caseSensitive: false,
  ),
  RegExp(
    r'^create\s+(?:your|an?)\s+([A-Za-z0-9._\- ]{2,28}?)\s+account$',
    caseSensitive: false,
  ),
];

const _genericHeadingTokens = <String>{
  '新',
  '您的',
  '立即',
  '免费',
  '快速',
  '一键',
  '欢迎',
  '手机',
  '手机号',
  '邮箱',
  '电子邮箱',
  '账号',
  '帐号',
  '账户',
  '用户',
  '新用户',
  '个人',
  '企业',
  '马上',
};

String _inferTitleFromHeadings(List<OcrBlock> sortedBlocks) {
  for (final block in sortedBlocks) {
    if (block.y > 0.35) continue;
    final norm = normalizeCjkSpacing(block.text);
    if (norm.isEmpty ||
        _isUiNoise(norm) ||
        _classifyLabel(norm) != _FieldKind.none) {
      continue;
    }
    for (final re in _cnHeadingPatterns) {
      final m = re.firstMatch(norm);
      if (m != null) {
        final brand = m.group(1)!.trim();
        if (brand.isNotEmpty &&
            !_isUiNoise(brand) &&
            !_genericHeadingTokens.contains(brand)) {
          return brand;
        }
      }
    }
    for (final re in _enHeadingPatterns) {
      final m = re.firstMatch(norm);
      if (m != null) {
        final brand = m.group(1)!.trim();
        if (brand.isNotEmpty && !_isUiNoise(brand)) return brand;
      }
    }
  }
  return '';
}

class _RowItem {
  const _RowItem({required this.block, required this.normalized});

  final OcrBlock block;
  final String normalized;
}

List<OcrBlock> _splitMultiPairBlock(OcrBlock block) {
  final norm = normalizeCjkSpacing(block.text);
  if (norm.isEmpty) return const [];
  final parts = norm.split(RegExp(r'\s{2,}'));
  if (parts.length < 2) return [block];
  var pairCount = 0;
  for (final part in parts) {
    final inline = _splitInlineLabelValue(part);
    if (inline != null && _classifyLabel(inline.label) != _FieldKind.none) {
      pairCount++;
    }
  }
  if (pairCount < 2) return [block];
  final result = <OcrBlock>[];
  final totalLen = math.max(norm.length, 1);
  var offset = 0;
  for (final part in parts) {
    final trimmed = part.trim();
    if (trimmed.isEmpty) continue;
    final idx = norm.indexOf(trimmed, offset);
    final startFrac = idx >= 0 ? idx / totalLen : 0.0;
    final widthFrac = trimmed.length / totalLen;
    result.add(
      OcrBlock(
        text: trimmed,
        x: (block.x + block.w * startFrac).clamp(0.0, 1.0),
        y: block.y,
        w: (block.w * widthFrac).clamp(0.0, 1.0),
        h: block.h,
      ),
    );
    if (idx >= 0) offset = idx + trimmed.length;
  }
  return result.isEmpty ? [block] : result;
}

List<List<_RowItem>> _groupIntoRows(List<OcrBlock> blocks) {
  final expanded = [for (final b in blocks) ..._splitMultiPairBlock(b)];
  final sorted = [...expanded]
    ..sort((a, b) {
      if (a.y != b.y) return a.y.compareTo(b.y);
      return a.x.compareTo(b.x);
    });

  final rows = <List<_RowItem>>[];
  final rowCenterYs = <double>[];
  final rowAvgHeights = <double>[];

  for (final block in sorted) {
    final norm = normalizeCjkSpacing(block.text);
    if (norm.isEmpty) continue;
    final item = _RowItem(block: block, normalized: norm);

    var matchedRow = -1;
    var bestDist = double.infinity;
    for (var i = 0; i < rows.length; i++) {
      final tol = math.max(math.max(block.h, rowAvgHeights[i]) * 0.65, 0.008);
      final dist = (block.centerY - rowCenterYs[i]).abs();
      if (dist <= tol && dist < bestDist) {
        bestDist = dist;
        matchedRow = i;
      }
    }

    if (matchedRow == -1) {
      rows.add([item]);
      rowCenterYs.add(block.centerY);
      rowAvgHeights.add(block.h);
    } else {
      final row = rows[matchedRow];
      row.add(item);
      rowCenterYs[matchedRow] =
          row.map((e) => e.block.centerY).reduce((a, b) => a + b) / row.length;
      rowAvgHeights[matchedRow] =
          row.map((e) => e.block.h).reduce((a, b) => a + b) / row.length;
    }
  }

  for (final row in rows) {
    row.sort((a, b) => a.block.x.compareTo(b.block.x));
  }
  return rows;
}

/// Parses account credentials (title/source, username, password, URL) from
/// OCR blocks detected on a registration or account-setup screenshot.
ParsedCredential parseCredentialFromOcr(List<OcrBlock> blocks) {
  if (blocks.isEmpty) return const ParsedCredential();

  final rows = _groupIntoRows(blocks);
  if (rows.isEmpty) return const ParsedCredential();

  final flatBlocks = [
    for (final r in rows)
      for (final item in r) item.block,
  ];
  final rawLines = [
    for (final row in rows) row.map((item) => item.normalized).join(' '),
  ];

  var title = '';
  var username = '';
  var password = '';
  var confirmPassword = '';
  var url = '';
  var passwordMasked = false;

  final excludedTexts = <String>{};
  final consumedIds = <int>{};
  final candidateValues = <String>[];

  void addCandidate(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty ||
        isMaskedPasswordText(trimmed) ||
        _isUiNoise(trimmed) ||
        _classifyLabel(trimmed) != _FieldKind.none) {
      return;
    }
    if (!candidateValues.contains(trimmed)) {
      candidateValues.add(trimmed);
    }
  }

  void assignValue(
    _FieldKind kind,
    String rawValue, {
    bool fromInline = false,
  }) {
    final trimmed = rawValue.trim();
    if (trimmed.isEmpty) return;

    if (kind == _FieldKind.captcha) {
      excludedTexts.add(trimmed);
      return;
    }

    if ((kind == _FieldKind.password || kind == _FieldKind.confirmPassword) &&
        isMaskedPasswordText(trimmed)) {
      passwordMasked = true;
      return;
    }

    if (_isUiNoise(trimmed)) return;
    if (!fromInline && _classifyLabel(trimmed) != _FieldKind.none) return;

    switch (kind) {
      case _FieldKind.title:
        if (title.isEmpty) title = normalizeCjkSpacing(trimmed);
        addCandidate(normalizeCjkSpacing(trimmed));
      case _FieldKind.url:
        final parsedUrl = _extractUrlCandidate(trimmed) ?? trimmed;
        if (url.isEmpty) url = parsedUrl;
        addCandidate(parsedUrl);
      case _FieldKind.username:
        final cleanUser = trimmed.split(RegExp(r'\s+')).length == 1
            ? trimmed
            : (_extractEmailCandidate(trimmed) ??
                  _extractPhoneCandidate(trimmed) ??
                  trimmed);
        if (username.isEmpty) username = cleanUser;
        addCandidate(cleanUser);
      case _FieldKind.password:
        final cleanPwd = _normalizePasswordToken(trimmed);
        if (password.isEmpty && !isMaskedPasswordText(cleanPwd)) {
          password = cleanPwd;
          addCandidate(cleanPwd);
        }
      case _FieldKind.confirmPassword:
        final cleanPwd = _normalizePasswordToken(trimmed);
        if (confirmPassword.isEmpty && !isMaskedPasswordText(cleanPwd)) {
          confirmPassword = cleanPwd;
          addCandidate(cleanPwd);
        }
      case _FieldKind.captcha:
      case _FieldKind.none:
        break;
    }
  }

  int itemKey(int rowIdx, int colIdx) => rowIdx * 10000 + colIdx;

  // Pass 1: inline `Label: Value`, right-neighbor, and below-neighbor matching.
  for (var r = 0; r < rows.length; r++) {
    final row = rows[r];
    for (var c = 0; c < row.length; c++) {
      final item = row[c];
      final inline = _splitInlineLabelValue(item.normalized);
      if (inline != null) {
        final kind = _classifyLabel(inline.label);
        if (kind != _FieldKind.none) {
          consumedIds.add(itemKey(r, c));
          if (inline.value.isNotEmpty) {
            assignValue(kind, inline.value, fromInline: true);
            continue;
          }
        }
      }

      final kind = _classifyLabel(item.normalized);
      if (kind == _FieldKind.none) continue;
      consumedIds.add(itemKey(r, c));

      // Strategy B: right neighbor in the same visual row.
      var matchedRight = false;
      if (c + 1 < row.length) {
        final rightItem = row[c + 1];
        if (_classifyLabel(rightItem.normalized) == _FieldKind.none &&
            _splitInlineLabelValue(rightItem.normalized) == null) {
          consumedIds.add(itemKey(r, c + 1));
          if (kind == _FieldKind.captcha) {
            excludedTexts.add(rightItem.normalized);
            matchedRight = true;
          } else if (isMaskedPasswordText(rightItem.normalized) &&
              (kind == _FieldKind.password ||
                  kind == _FieldKind.confirmPassword)) {
            passwordMasked = true;
            matchedRight = true;
          } else if (!_isUiNoise(rightItem.normalized)) {
            assignValue(kind, rightItem.normalized);
            matchedRight = true;
          }
        }
      }
      if (matchedRight) continue;

      // Strategy C: below neighbor in the next row (stacked form inputs).
      if (r + 1 < rows.length) {
        final nextRow = rows[r + 1];
        _RowItem? bestBelow;
        var bestScore = double.infinity;
        var bestCol = -1;
        for (var nc = 0; nc < nextRow.length; nc++) {
          if (consumedIds.contains(itemKey(r + 1, nc))) continue;
          final cand = nextRow[nc];
          final vGap = cand.block.y - item.block.bottom;
          final maxGap = math.max(item.block.h * 4.5, 0.16);
          if (vGap > maxGap || vGap < -0.02) continue;

          if (_classifyLabel(cand.normalized) != _FieldKind.none ||
              _splitInlineLabelValue(cand.normalized) != null) {
            continue;
          }

          final hDist = (cand.block.x - item.block.x).abs();
          final overlapsHorizontally =
              cand.block.right >= item.block.x - 0.08 &&
              cand.block.x <= item.block.right + 0.35;
          if (!overlapsHorizontally && nextRow.length > 1) continue;
          if (hDist < bestScore) {
            bestScore = hDist;
            bestBelow = cand;
            bestCol = nc;
          }
        }

        if (bestBelow != null && bestCol >= 0) {
          if (kind == _FieldKind.captcha) {
            consumedIds.add(itemKey(r + 1, bestCol));
            excludedTexts.add(bestBelow.normalized);
          } else if (isMaskedPasswordText(bestBelow.normalized) &&
              (kind == _FieldKind.password ||
                  kind == _FieldKind.confirmPassword)) {
            consumedIds.add(itemKey(r + 1, bestCol));
            passwordMasked = true;
          } else if (!_isUiNoise(bestBelow.normalized)) {
            consumedIds.add(itemKey(r + 1, bestCol));
            assignValue(kind, bestBelow.normalized);
          }
        }
      }
    }
  }

  if (password.isEmpty && confirmPassword.isNotEmpty) {
    password = confirmPassword;
  }

  // Pass 2: fallback heuristics when labels were absent or missed by OCR.
  if (url.isEmpty) {
    for (final row in rows) {
      for (final item in row) {
        if (excludedTexts.contains(item.normalized)) continue;
        final candidate = _extractUrlCandidate(item.normalized);
        if (candidate != null) {
          url = candidate;
          addCandidate(candidate);
          break;
        }
      }
      if (url.isNotEmpty) break;
    }
  }

  int? usernameRowIdx;
  if (username.isEmpty) {
    String? fallbackGenericEmail;
    int? genericEmailRowIdx;
    for (var r = 0; r < rows.length; r++) {
      for (final item in rows[r]) {
        if (excludedTexts.contains(item.normalized) ||
            _isUiNoise(item.normalized)) {
          continue;
        }
        final email = _extractEmailCandidate(item.normalized);
        if (email != null) {
          if (_isGenericServiceEmail(email)) {
            fallbackGenericEmail ??= email;
            genericEmailRowIdx ??= r;
          } else {
            username = email;
            usernameRowIdx = r;
            addCandidate(email);
            break;
          }
        }
      }
      if (username.isNotEmpty) break;
    }
    if (username.isEmpty && fallbackGenericEmail != null) {
      username = fallbackGenericEmail;
      usernameRowIdx = genericEmailRowIdx;
      addCandidate(fallbackGenericEmail);
    }
  } else {
    for (var r = 0; r < rows.length; r++) {
      if (rows[r].any((item) => item.normalized.contains(username))) {
        usernameRowIdx = r;
        break;
      }
    }
  }

  if (username.isEmpty) {
    for (var r = 0; r < rows.length; r++) {
      for (final item in rows[r]) {
        if (excludedTexts.contains(item.normalized) ||
            _isUiNoise(item.normalized)) {
          continue;
        }
        final phone = _extractPhoneCandidate(item.normalized);
        if (phone != null) {
          username = phone;
          usernameRowIdx = r;
          addCandidate(phone);
          break;
        }
      }
      if (username.isNotEmpty) break;
    }
  }

  if (password.isEmpty && !passwordMasked) {
    for (var r = 0; r < rows.length; r++) {
      for (final item in rows[r]) {
        if (isMaskedPasswordText(item.normalized)) {
          passwordMasked = true;
        }
      }
    }
  }

  if (password.isEmpty && !passwordMasked) {
    final searchOrder = <int>{
      if (usernameRowIdx != null && usernameRowIdx + 1 < rows.length)
        usernameRowIdx + 1,
      if (usernameRowIdx != null && usernameRowIdx + 2 < rows.length)
        usernameRowIdx + 2,
      for (var r = 0; r < rows.length; r++) r,
    };
    for (final r in searchOrder) {
      for (var c = 0; c < rows[r].length; c++) {
        final item = rows[r][c];
        final token = item.normalized.trim();
        if (token == username ||
            token == url ||
            token == title ||
            excludedTexts.contains(token)) {
          continue;
        }
        if (_looksLikePasswordToken(token)) {
          password = token;
          addCandidate(token);
          break;
        }
      }
      if (password.isNotEmpty) break;
    }
  }

  // Pass 3: infer title only from a clear domain/brand or registration heading.
  if (title.isEmpty && url.isNotEmpty) {
    title = _inferTitleFromUrl(url);
  }
  if (title.isEmpty) {
    title = _inferTitleFromHeadings(flatBlocks);
  }

  // Collect remaining clean text fragments as quick-assign candidate chips.
  for (final row in rows) {
    for (final item in row) {
      final inline = _splitInlineLabelValue(item.normalized);
      final piece = inline != null ? inline.value : item.normalized;
      if (excludedTexts.contains(piece)) continue;
      addCandidate(piece);
      if (candidateValues.length >= 16) break;
    }
    if (candidateValues.length >= 16) break;
  }

  return ParsedCredential(
    title: title,
    username: username,
    password: password,
    url: url,
    passwordMasked: passwordMasked,
    candidates: candidateValues,
    rawLines: rawLines,
  );
}

const _fullWidthPasswordMap = <int, String>{
  0xFF01: '!', // ！
  0xFF20: '@', // ＠
  0xFF03: '#', // ＃
  0xFF04: r'$', // ＄
  0xFF05: '%', // ％
  0xFF06: '&', // ＆
  0xFF0A: '*', // ＊
  0xFF08: '(', // （
  0xFF09: ')', // ）
  0xFF0D: '-', // －
  0xFF3F: '_', // ＿
  0xFF0B: '+', // ＋
  0xFF1D: '=', // ＝
  0xFF1F: '?', // ？
  0xFF0E: '.', // ．
  0xFF0C: ',', // ，
  0xFF1A: ':', // ：
  0xFF1B: ';', // ；
};

/// OCR engines configured for Chinese+English occasionally emit full-width
/// punctuation adjacent to CJK labels (e.g. `密码：Abc#7890Xy！`). Normalize
/// full-width ASCII symbols back to ASCII when the password is ASCII-based.
String _normalizePasswordToken(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) return '';
  final hasAsciiAlphaNum = RegExp(r'[A-Za-z0-9]').hasMatch(trimmed);
  final hasHanzi = RegExp(_cjkPattern).hasMatch(trimmed);
  if (!hasAsciiAlphaNum || hasHanzi) return trimmed;
  final out = StringBuffer();
  for (final rune in trimmed.runes) {
    final mapped = _fullWidthPasswordMap[rune];
    if (mapped != null) {
      out.write(mapped);
    } else {
      out.writeCharCode(rune);
    }
  }
  return out.toString();
}

/// Convenience parser for plain multiline text (such as copied text or tests).
ParsedCredential parseCredentialFromText(String text) {
  if (text.trim().isEmpty) return const ParsedCredential();
  return parseCredentialFromOcr(_blocksFromPlainText(text));
}
