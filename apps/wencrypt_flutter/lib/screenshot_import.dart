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

class ClipboardOcrResult {
  const ClipboardOcrResult({
    required this.imageBytes,
    required this.recognition,
  });

  final Uint8List imageBytes;
  final OcrRecognitionResult recognition;
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

  OcrRecognitionResult _parseRecognitionPayload(Map<String, dynamic> raw) {
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
  }

  /// Single-hop native clipboard read + preview generation + OCR when
  /// supported by the platform host, falling back cleanly otherwise.
  Future<ClipboardOcrResult?> readAndRecognizeClipboardImage() async {
    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>(
        'readAndRecognizeClipboardImage',
      );
      if (raw != null) {
        if (raw['hasImage'] == false) return null;
        final image = raw['image'];
        if (image is Uint8List && image.isNotEmpty) {
          return ClipboardOcrResult(
            imageBytes: image,
            recognition: _parseRecognitionPayload(raw),
          );
        }
        if (raw.containsKey('hasImage')) return null;
      }
    } on MissingPluginException {
      // Fall back to two-step channel calls below (e.g. unit test mocks).
    } on PlatformException catch (error) {
      throw ScreenshotOcrException(error.code, friendlyError(error));
    }

    final bytes = await readClipboardImage();
    if (bytes == null || bytes.isEmpty) return null;
    final recognition = await recognizeImage(bytes);
    return ClipboardOcrResult(imageBytes: bytes, recognition: recognition);
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
      return _parseRecognitionPayload(raw);
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
  '(?<=$_cjkPattern)[ \\t]+(?=[：:，,。.！？（）【】]|\\([\\d$_cjkPattern])',
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
  '复制',
  '已复制',
  '複製',
  '拷贝',
  '复制密码',
  '复制账号',
  '显示',
  '隐藏',
  '顯示',
  '隱藏',
  '查看',
  '显示密码',
  '隐藏密码',
  '登录/注册',
  '注册/登录',
  '立即登入',
  '免費註冊',
  '忘記密碼',
  '忘記密碼?',
  '忘記密碼？',
  '记住我',
  '記住我',
  '切换账号',
  '忘记账号',
  'copy',
  'copied',
  'copy password',
  'show',
  'hide',
  'show password',
  'hide password',
  'remember me',
  'keep me signed in',
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
  out = out.replaceAll(RegExp(r'^[\*\s•·\-▪■✦○●]+'), '');
  out = out.replaceAll(RegExp(r'[\*\s：:]+$'), '');
  return out.trim();
}

final _labelBracketQualifierRe = RegExp(
  r'[\(（\[【][^\)）\]】]{1,24}[\)）\]】]',
);
final _labelTrailingWordQualifierRe = RegExp(
  r'(?:必填|选填|可选|\brequired\b|\boptional\b)$',
  caseSensitive: false,
);

String _stripLabelQualifiers(String cleaned) {
  var out = cleaned.replaceAll(_labelBracketQualifierRe, ' ');
  out = out.replaceAll(RegExp(r'\s+'), ' ').trim();
  out = out.replaceAll(RegExp(r'^[\*\s•·\-]+|[\*\s：:]+$'), '').trim();
  out = out.replaceAll(_labelTrailingWordQualifierRe, '').trim();
  return out.replaceAll(RegExp(r'[\*\s：:]+$'), '').trim();
}

final _inlineLeadingPictographRe = RegExp(
  r'^[\s\u{1F4CB}\u{1F511}\u{1F512}\u2709\uFE0F\u{1F441}]+',
  unicode: true,
);
final _inlineTrailingActionWithSpaceRe = RegExp(
  r'(?:[ \t]+)(?:复制密码|复制账号|复制链接|已复制|复制|複製|拷贝|显示密码|隐藏密码|显示|隐藏|顯示|隱藏|查看|随机生成|重新生成|生成|换一个|打开|访问|前往|清空|清除|copy\s+password|copy|copied|show|hide|reveal|view|clear|open|generate|\u{1F4CB}|\u{1F441}\uFE0F?|\u2715|\u00D7|\u2713|\u2714)[ \t]*$',
  caseSensitive: false,
  unicode: true,
);
final _inlineTrailingCjkActionAttachedRe = RegExp(
  r'(?<=[A-Za-z0-9!@#\$%\^&\*\(\)_+\-=\[\]{};:\x27",.<>/?\\|`~])(?:复制密码|复制账号|复制链接|已复制|复制|複製|显示密码|隐藏密码|显示|隐藏|顯示|隱藏|查看|打开|前往)$',
);

String _stripInlineActionSuffix(String value) {
  var out = value.trim().replaceFirst(_inlineLeadingPictographRe, '').trim();
  for (var i = 0; i < 2; i++) {
    final next = out
        .replaceFirst(_inlineTrailingActionWithSpaceRe, '')
        .replaceFirst(_inlineTrailingCjkActionAttachedRe, '')
        .trim();
    if (next == out) break;
    out = next;
  }
  return out;
}

final _standaloneSeparatorRe = RegExp(r'^[:：=\*\-•·|｜\s]+$');

const _captchaLabels = [
  '图形验证码',
  '图片验证码',
  '短信验证码',
  '邮箱验证码',
  '手机验证码',
  '动态验证码',
  '人机验证码',
  '动态口令',
  '二次验证码',
  '圖形驗證碼',
  '簡訊驗證碼',
  '郵箱驗證碼',
  '驗證碼',
  '校驗碼',
  '安全碼',
  '邀請碼',
  '验证码',
  '校验码',
  '动态码',
  '安全码',
  '邀请码',
  '推荐码',
  'verification code',
  'verify code',
  'confirmation code',
  'security code',
  'one-time code',
  'one time code',
  'auth code',
  '2fa code',
  'mfa code',
  '2fa',
  'totp',
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
  '再次确认密码',
  '重复输入密码',
  '确认登录密码',
  '确认新密码',
  '确认新登录密码',
  '密码确认',
  '確認密碼',
  '重複密碼',
  '再次輸入密碼',
  '確認新密碼',
  '密碼確認',
  'confirm password',
  'confirm new password',
  'confirm your password',
  'password confirmation',
  're-enter password',
  'reenter password',
  're-type password',
  'retype password',
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
  '新登录密码',
  '管理密码',
  '管理员密码',
  '注册密码',
  '访问密码',
  '临时密码',
  '随机密码',
  '登录口令',
  '账户口令',
  '密码设置',
  '账户密码',
  '账号密码',
  '通行密码',
  '登入密碼',
  '初始密碼',
  '預設密碼',
  '設定密碼',
  '新密碼',
  '帳戶密碼',
  '帳號密碼',
  '管理密碼',
  '密碼',
  '密码',
  '口令',
  'new password',
  'set password',
  'create password',
  'login password',
  'account password',
  'admin password',
  'user password',
  'initial password',
  'default password',
  'temp password',
  'temporary password',
  'password',
  'passwd',
  'pwd',
  'passcode',
  'passphrase',
  'secret',
];

const _usernameLabels = [
  '登录账号',
  '登录帐号',
  '登录账户',
  '登录邮箱',
  '注册邮箱',
  '绑定邮箱',
  '联系邮箱',
  '工作邮箱',
  '企业邮箱',
  '用户邮箱',
  '注册手机号',
  '登录手机号',
  '绑定手机',
  '绑定手机号',
  '管理账号',
  '管理员账号',
  '登录名',
  '用户名',
  '账户名',
  '会员名',
  '通行证',
  '电子邮箱',
  '邮箱地址',
  '手机号码',
  '用户名/邮箱/手机号',
  '用户名/邮箱',
  '用户名/手机号',
  '账号/手机号',
  '账号/用户名',
  '手机号/邮箱',
  '邮箱/手机号',
  '账号/邮箱',
  '用户id',
  '登入帳號',
  '登入帳戶',
  '登入名',
  '使用者名稱',
  '用戶名',
  '用戶名稱',
  '帳戶名',
  '電子郵件',
  '電子信箱',
  '信箱',
  '郵箱地址',
  '郵箱',
  '手機號碼',
  '手機號',
  '帳號',
  '帳戶',
  '账号',
  '帐号',
  '账户',
  '邮箱',
  '手机号',
  'uid',
  'user name',
  'username',
  'user id',
  'userid',
  'user account',
  'account name',
  'account id',
  'account',
  'member id',
  'login id',
  'login name',
  'login email',
  'login account',
  'login',
  'sign-in email',
  'sign in email',
  'email address',
  'e-mail address',
  'work email',
  'e-mail',
  'email',
  'phone number',
  'mobile number',
  'cell phone',
  'phone/email',
  'email or username',
  'username or email',
  'email / username',
  'phone',
  'mobile',
];

const _urlLabels = [
  '登录网址',
  '登录地址',
  '网站地址',
  '后台地址',
  '管理地址',
  '控制台地址',
  '面板地址',
  '系统地址',
  '访问地址',
  '服务地址',
  '接口地址',
  '注册地址',
  '首页地址',
  '服务器地址',
  '登入網址',
  '登入地址',
  '網站地址',
  '伺服器地址',
  '網址',
  '網站',
  '官網',
  '伺服器',
  '網域',
  '网址',
  '网站',
  '地址',
  '官网',
  '服务器',
  '域名',
  '链接',
  '入口',
  'website',
  'web site',
  'web address',
  'login url',
  'site url',
  'server url',
  'console url',
  'admin url',
  'panel url',
  'portal url',
  'dashboard url',
  'access url',
  'homepage',
  'url',
  'site',
  'host',
  'server',
  'domain',
  'endpoint',
  'address',
  'link',
];

const _titleLabels = [
  '网站名称',
  '平台名称',
  '系统名称',
  '应用名称',
  '服务名称',
  '产品名称',
  '项目名称',
  '所属平台',
  '所属系统',
  '網站名稱',
  '平台名稱',
  '系統名稱',
  '應用名稱',
  '服務名稱',
  '來源',
  '名稱',
  '應用',
  '服務',
  '来源',
  '平台',
  '系统',
  '项目',
  '产品',
  '名称',
  '应用',
  '服务',
  'service name',
  'app name',
  'site name',
  'platform',
  'project',
  'product',
  'workspace',
  'organization',
  'company',
  'provider',
  'source',
  'title',
  'name',
];

final List<({String label, _FieldKind kind})> _sortedInlineLabels = (() {
  final all = <({String label, _FieldKind kind})>[
    for (final l in _captchaLabels) (label: l, kind: _FieldKind.captcha),
    for (final l in _confirmPasswordLabels)
      (label: l, kind: _FieldKind.confirmPassword),
    for (final l in _passwordLabels) (label: l, kind: _FieldKind.password),
    for (final l in _usernameLabels) (label: l, kind: _FieldKind.username),
    for (final l in _urlLabels) (label: l, kind: _FieldKind.url),
    for (final l in _titleLabels) (label: l, kind: _FieldKind.title),
  ];
  all.sort((a, b) => b.label.length.compareTo(a.label.length));
  return all;
})();

bool _matchesLabelList(String cleanedLower, List<String> candidates) {
  for (final label in candidates) {
    if (cleanedLower == label) return true;
  }
  return false;
}

_FieldKind _classifyExactNormalizedLabel(String lower) {
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

_FieldKind _classifyLabel(String raw) {
  final cleaned = _stripLabelDecorations(raw);
  if (cleaned.isEmpty || cleaned.length > 36) return _FieldKind.none;

  if (!_isUiNoise(cleaned)) {
    final direct = _classifyExactNormalizedLabel(cleaned.toLowerCase());
    if (direct != _FieldKind.none) return direct;
  }

  final qualifierStripped = _stripLabelQualifiers(cleaned);
  if (qualifierStripped.isNotEmpty &&
      qualifierStripped != cleaned &&
      !_isUiNoise(qualifierStripped)) {
    final kind = _classifyExactNormalizedLabel(qualifierStripped.toLowerCase());
    if (kind != _FieldKind.none) return kind;
  }

  if (!_isUiNoise(cleaned)) {
    for (final match in _labelBracketQualifierRe.allMatches(cleaned)) {
      final innerRaw = match.group(0)!;
      final inner = _stripLabelDecorations(
        innerRaw.substring(1, innerRaw.length - 1),
      );
      if (inner.isEmpty) continue;
      final innerKind = _classifyExactNormalizedLabel(inner.toLowerCase());
      if (innerKind != _FieldKind.none) return innerKind;
    }
  }

  return _FieldKind.none;
}

({String label, String value})? _splitInlineLabelValue(String raw) {
  final normalized = normalizeCjkSpacing(raw).trim();
  if (normalized.isEmpty) return null;

  // Prefer explicit separators (ignoring URL scheme `://`).
  for (var i = 0; i < normalized.length; i++) {
    final ch = normalized[i];
    if (ch == '：' ||
        ch == ':' ||
        ch == '=' ||
        ch == '｜' ||
        ch == '|' ||
        ch == '；' ||
        ch == ';') {
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

  // Fallback for space-separated or annotated inline pairs like
  // "账号 alice@example.com" or "登录密码(8-20位) MySecret99!".
  final lower = normalized.toLowerCase();
  for (final entry in _sortedInlineLabels) {
    final candidate = entry.label;
    if (!lower.startsWith(candidate)) continue;
    var labelEnd = candidate.length;
    var rest = normalized.substring(labelEnd);
    if (rest.isEmpty) continue;

    final parenMatch = RegExp(
      r'^[\(（\[【][^\)）\]】]{1,24}[\)）\]】]',
    ).firstMatch(rest);
    if (parenMatch != null) {
      labelEnd += parenMatch.end;
      rest = normalized.substring(labelEnd);
      if (rest.isEmpty) continue;
    }

    final startsWithGap = rest.startsWith(' ') || rest.startsWith('\t');
    final isCjkLabelToAsciiValue =
        candidate.runes.any((r) => r >= 0x4E00) &&
        RegExp(r'^[A-Za-z0-9@._+!\-#/~*]').hasMatch(rest);
    if (startsWithGap || isCjkLabelToAsciiValue) {
      final value = rest.trim();
      if (value.isNotEmpty) {
        return (label: normalized.substring(0, labelEnd), value: value);
      }
    }
  }
  return null;
}

final _emailRe = RegExp(
  r'\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\b',
);
final _urlWithSchemeRe = RegExp(
  r'https?://[^\s<>\]\)"\x27\u4E00-\u9FFF]+',
  caseSensitive: false,
);
final _ipWithPortRe = RegExp(
  r'(?<![\d.\-])((?:localhost|(?:\d{1,3}\.){3}\d{1,3}):\d{2,5}(?:/[^\s<>\]\)"\x27\u4E00-\u9FFF]*)?)',
  caseSensitive: false,
);
final _domainRe = RegExp(
  r'(?<![@\w.\-])([a-zA-Z0-9\-]+(?:\.[a-zA-Z0-9\-]+)*\.(?:com|cn|com\.cn|org\.cn|net\.cn|gov\.cn|net|org|io|app|dev|co|ai|me|cc|tv|jp|uk|edu|gov|cloud|tech|xyz|so|top|vip|site|online|store|gg|sh|work|pro|hk|tw|sg|de|fr|ca|au|kr|in|im|to|la|icu|run|fun|ink|link|club|space|live|info|biz|page)(?:/[^\s<>\]\)"\x27\u4E00-\u9FFF]*)?)(?!@|\w)',
  caseSensitive: false,
);
final _cnPhoneRe = RegExp(r'(?<!\d)(?:\+?86[-\s]?)?(1[3-9]\d{9})(?!\d)');
final _intlPhoneRe = RegExp(r'(?<!\w)(\+\d{1,3}[\s\-]?\d{6,12})(?!\d)');

String? _extractUrlCandidate(String raw) {
  final trimmed = _stripInlineActionSuffix(raw).trim();
  if (trimmed.isEmpty) return null;
  final withScheme = _urlWithSchemeRe.firstMatch(trimmed);
  if (withScheme != null) {
    return _cleanTrailingUrlPunct(withScheme.group(0)!);
  }
  final ipPort = _ipWithPortRe.firstMatch(trimmed);
  if (ipPort != null) {
    final matched = _cleanTrailingUrlPunct(ipPort.group(1)!);
    return 'http://$matched';
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

String? _extractEmailCandidate(String raw) {
  final normalized = raw
      .replaceAll('\uFF20', '@')
      .replaceAll('\uFF0E', '.')
      .replaceAll('\uFF0D', '-')
      .replaceAll('\uFF3F', '_');
  return _emailRe.firstMatch(normalized)?.group(0);
}

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
      lower.startsWith('contact@') ||
      lower.startsWith('info@') ||
      lower.startsWith('hello@') ||
      lower.startsWith('sales@') ||
      lower.startsWith('security@') ||
      lower.startsWith('privacy@') ||
      lower.startsWith('legal@') ||
      lower.startsWith('official@') ||
      lower.startsWith('admin@');
}

final _dateTokenRe = RegExp(
  r'^(?:\d{4}[-/.]\d{1,2}[-/.]\d{1,2}|\d{1,2}[-/.]\d{1,2}[-/.]\d{2,4})$',
);
final _timeTokenRe = RegExp(r'^\d{1,2}:\d{2}(?::\d{2})?$');
final _versionTokenRe = RegExp(
  r'^v?\d+\.\d+(?:\.\d+)*(?:[-+][A-Za-z0-9.]+)?$',
  caseSensitive: false,
);
final _ipOnlyRe = RegExp(r'^(?:\d{1,3}\.){3}\d{1,3}(?::\d+)?$');
final _docRefIdRe = RegExp(
  r'^(?:DOC|NO|ERR|REF|REQ|MSG|BUG|SKU|ORD|INV|UTF|TLS|SSL|AES|SHA)[-_]\d+(?:\.\d+)*$',
  caseSensitive: false,
);
final _filenameTokenRe = RegExp(
  r'^[A-Za-z0-9._\-]+\.(?:png|jpe?g|webp|gif|svg|pdf|zip|dmg|exe|msi|apk|html?|css|js|ts|json|ya?ml|xml|txt|md|log)$',
  caseSensitive: false,
);
final _numericPunctOnlyRe = RegExp(r'^[\d,._+\-%$¥€£:;/\\]+$');

bool _looksLikePasswordToken(String value) {
  final s = _normalizePasswordToken(value);
  if (s.length < 6 || s.length > 64) return false;
  if (s.contains(RegExp(r'\s'))) return false;
  if (s.runes.any((r) => r < 0x21 || r > 0x7E)) return false;
  if (_urlWithSchemeRe.hasMatch(s) ||
      _ipWithPortRe.hasMatch(s) ||
      _emailRe.hasMatch(s)) {
    return false;
  }
  final domainMatch = _domainRe.firstMatch(s);
  if (domainMatch != null && domainMatch.group(0) == s) return false;
  final cnPhoneMatch = _cnPhoneRe.firstMatch(s);
  if (cnPhoneMatch != null && cnPhoneMatch.group(0) == s) return false;
  final intlPhoneMatch = _intlPhoneRe.firstMatch(s);
  if (intlPhoneMatch != null && intlPhoneMatch.group(0) == s) return false;
  if (_dateTokenRe.hasMatch(s) ||
      _timeTokenRe.hasMatch(s) ||
      _versionTokenRe.hasMatch(s) ||
      _ipOnlyRe.hasMatch(s) ||
      _docRefIdRe.hasMatch(s) ||
      _filenameTokenRe.hasMatch(s) ||
      _numericPunctOnlyRe.hasMatch(s)) {
    return false;
  }
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
  'deepseek.com': 'DeepSeek',
  'cursor.com': 'Cursor',
  'perplexity.ai': 'Perplexity',
  'openrouter.ai': 'OpenRouter',
  'huggingface.co': 'Hugging Face',
  'siliconflow.cn': '硅基流动',
  'moonshot.cn': 'Kimi',
  'kimi.com': 'Kimi',
  'bigmodel.cn': '智谱清言',
  'zhipuai.cn': '智谱清言',
  'doubao.com': '豆包',
  'volcengine.com': '火山引擎',
  'x.ai': 'xAI',
  'notion.so': 'Notion',
  'figma.com': 'Figma',
  'linear.app': 'Linear',
  'discord.com': 'Discord',
  'slack.com': 'Slack',
  'zoom.us': 'Zoom',
  'x.com': 'X',
  'twitter.com': 'X',
  'reddit.com': 'Reddit',
  'linkedin.com': 'LinkedIn',
  'youtube.com': 'YouTube',
  'netflix.com': 'Netflix',
  'spotify.com': 'Spotify',
  'twitch.tv': 'Twitch',
  'dropbox.com': 'Dropbox',
  'proton.me': 'Proton',
  'protonmail.com': 'Proton Mail',
  'cloudflare.com': 'Cloudflare',
  'vercel.com': 'Vercel',
  'netlify.com': 'Netlify',
  'supabase.com': 'Supabase',
  'docker.com': 'Docker',
  'npmjs.com': 'npm',
  'pypi.org': 'PyPI',
  'jetbrains.com': 'JetBrains',
  'atlassian.com': 'Atlassian',
  'digitalocean.com': 'DigitalOcean',
  'vultr.com': 'Vultr',
  'hetzner.com': 'Hetzner',
  'namecheap.com': 'Namecheap',
  'porkbun.com': 'Porkbun',
  'paypal.com': 'PayPal',
  'stripe.com': 'Stripe',
  'aws.amazon.com': 'AWS',
  'amazon.com': 'Amazon',
  'steampowered.com': 'Steam',
  'store.steampowered.com': 'Steam',
  'epicgames.com': 'Epic Games',
  'nintendo.com': 'Nintendo',
  'aliyun.com': '阿里云',
  'alibabacloud.com': '阿里云',
  'tencent.com': '腾讯',
  'cloud.tencent.com': '腾讯云',
  'huawei.com': '华为',
  'huaweicloud.com': '华为云',
  'xiaomi.com': '小米',
  'mi.com': '小米',
  'baidu.com': '百度',
  'quark.cn': '夸克',
  'alipan.com': '阿里云盘',
  'aliyundrive.com': '阿里云盘',
  'wps.cn': 'WPS',
  'kdocs.cn': '金山文档',
  'bilibili.com': 'Bilibili',
  'douyin.com': '抖音',
  'kuaishou.com': '快手',
  'zhihu.com': '知乎',
  'juejin.cn': '掘金',
  'csdn.net': 'CSDN',
  'cnblogs.com': '博客园',
  'v2ex.com': 'V2EX',
  'yuque.com': '语雀',
  'jd.com': '京东',
  'taobao.com': '淘宝',
  'tmall.com': '天猫',
  'alipay.com': '支付宝',
  'meituan.com': '美团',
  'pinduoduo.com': '拼多多',
  'ctrip.com': '携程',
  '12306.cn': '12306',
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
  'gitea.com': 'Gitea',
  'tailscale.com': 'Tailscale',
  'synology.com': '群晖',
  'fnos.net': '飞牛 fnOS',
};

String _inferKnownBrandFromUrl(String url) {
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

const _compoundPublicSuffixes = <String>{
  'com.cn',
  'org.cn',
  'net.cn',
  'gov.cn',
  'co.uk',
  'org.uk',
  'co.jp',
  'ne.jp',
  'com.hk',
  'com.tw',
  'com.sg',
  'com.au',
};

String _inferFallbackDomainTitle(String url) {
  if (url.isEmpty) return '';
  final uri = Uri.tryParse(url.contains('://') ? url : 'https://$url');
  final host = (uri?.host ?? '').toLowerCase();
  if (host.isEmpty || host == 'localhost' || _ipOnlyRe.hasMatch(host)) {
    return '';
  }
  final bareHost = host.startsWith('www.') ? host.substring(4) : host;
  final parts = bareHost.split('.').where((p) => p.isNotEmpty).toList();
  if (parts.length < 2) return '';
  if (parts.length >= 3) {
    final tail2 = '${parts[parts.length - 2]}.${parts.last}';
    if (_compoundPublicSuffixes.contains(tail2)) {
      return parts.sublist(parts.length - 3).join('.');
    }
    return tail2;
  }
  return bareHost;
}

final _cnHeadingPatterns = [
  RegExp(
    r'^(?:欢迎|歡迎)?(?:注册|註冊|创建|創建|登录|登錄|登陆|登入|使用|加入)\s*([A-Za-z0-9\u4E00-\u9FFF._\- ]{2,24}?)\s*(?:账号|帳號|帐号|账户|帳戶|系统|系統|平台|控制台)?$',
  ),
  RegExp(
    r'^([A-Za-z0-9\u4E00-\u9FFF._\-]{2,20})\s*(?:用户|用戶|账号|帳號|账户|帳戶)?(?:注册|註冊|登录|登錄|登陆|登入)$',
  ),
];

final _enHeadingPatterns = [
  RegExp(
    r'^(?:sign\s*up|sign\s*in|log\s*in|register)\s+(?:for|to|with|into)\s+([A-Za-z0-9._\- ]{2,28})$',
    caseSensitive: false,
  ),
  RegExp(
    r'^welcome\s+to\s+([A-Za-z0-9._\- ]{2,28})$',
    caseSensitive: false,
  ),
  RegExp(
    r'^create\s+(?:your|an?)\s+([A-Za-z0-9._\- ]{2,28}?)\s+account$',
    caseSensitive: false,
  ),
  RegExp(
    r'^([A-Za-z0-9][A-Za-z0-9._\- ]{1,24})\s+(?:login|sign\s*in|console|portal)$',
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
  '您的账号',
  '您的账户',
  '密码',
  '用户',
  '新用户',
  '个人',
  '企业',
  '马上',
  '系统',
  '后台',
  '平台',
  '管理',
  '控制台',
  'sign in',
  'log in',
  'login',
  'account',
  'your account',
  'your',
  'the',
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
            !_genericHeadingTokens.contains(brand.toLowerCase())) {
          return brand;
        }
      }
    }
    for (final re in _enHeadingPatterns) {
      final m = re.firstMatch(norm);
      if (m != null) {
        final brand = m.group(1)!.trim();
        if (brand.isNotEmpty &&
            !_isUiNoise(brand) &&
            !_genericHeadingTokens.contains(brand.toLowerCase())) {
          return brand;
        }
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

final _inlinePairBoundaryRe = RegExp(
  r'[ \t]+(?=[A-Za-z\u4E00-\u9FFF][A-Za-z0-9\u4E00-\u9FFF\s/\-（）\(\)]{0,18}[：:=])',
);

List<String> _splitPartsIfMultiPair(String norm) {
  final wideParts = norm.split(RegExp(r'\s{2,}|\s+[|｜]\s+'));
  if (wideParts.length >= 2) {
    var pairCount = 0;
    for (final part in wideParts) {
      final inline = _splitInlineLabelValue(part);
      if (inline != null && _classifyLabel(inline.label) != _FieldKind.none) {
        pairCount++;
      }
    }
    if (pairCount >= 2) return wideParts;
  }

  final boundaryMatches = _inlinePairBoundaryRe.allMatches(norm).toList();
  if (boundaryMatches.isEmpty) return const [];
  final cuts = <int>[0];
  for (final m in boundaryMatches) {
    final suffix = norm.substring(m.end);
    final inline = _splitInlineLabelValue(suffix);
    if (inline != null &&
        _classifyLabel(inline.label) != _FieldKind.none &&
        inline.value.isNotEmpty) {
      cuts.add(m.end);
    }
  }
  if (cuts.length < 2) return const [];
  final parts = <String>[];
  for (var i = 0; i < cuts.length; i++) {
    final start = cuts[i];
    final end = i + 1 < cuts.length ? cuts[i + 1] : norm.length;
    final segment = norm.substring(start, end).trim();
    if (segment.isNotEmpty) parts.add(segment);
  }
  if (parts.length < 2) return const [];
  var validCount = 0;
  for (final part in parts) {
    final inline = _splitInlineLabelValue(part);
    if (inline != null &&
        _classifyLabel(inline.label) != _FieldKind.none &&
        inline.value.isNotEmpty) {
      validCount++;
    }
  }
  return validCount >= 2 ? parts : const [];
}

List<OcrBlock> _splitMultiPairBlock(OcrBlock block) {
  final norm = normalizeCjkSpacing(block.text);
  if (norm.isEmpty) return const [];
  final parts = _splitPartsIfMultiPair(norm);
  if (parts.length < 2) return [block];
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

bool _isBoilerplateUrl(String url) {
  final uri = Uri.tryParse(url.contains('://') ? url : 'https://$url');
  final host = (uri?.host ?? '').toLowerCase();
  if (host.isEmpty) return false;
  return host == 'beian.miit.gov.cn' ||
      host.endsWith('.beian.miit.gov.cn') ||
      host == 'miit.gov.cn' ||
      host == 'w3.org' ||
      host == 'www.w3.org' ||
      host == 'schema.org';
}

bool _isPolicyUrl(String url) {
  final uri = Uri.tryParse(url.contains('://') ? url : 'https://$url');
  final path = (uri?.path ?? '').toLowerCase();
  return path.contains('/privacy') ||
      path.contains('/terms') ||
      path.contains('/legal') ||
      path.contains('/help') ||
      path.contains('/agreement');
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
  OcrBlock? usernameBlock;
  OcrBlock? passwordBlock;

  final excludedTexts = <String>{};
  final consumedIds = <int>{};
  final candidateValues = <String>[];

  void addCandidate(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty ||
        isMaskedPasswordText(trimmed) ||
        _isUiNoise(trimmed) ||
        _standaloneSeparatorRe.hasMatch(trimmed) ||
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
    OcrBlock? sourceBlock,
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

    if (_isUiNoise(trimmed) || _standaloneSeparatorRe.hasMatch(trimmed)) return;
    if (!fromInline && _classifyLabel(trimmed) != _FieldKind.none) return;

    switch (kind) {
      case _FieldKind.title:
        final cleanTitle = normalizeCjkSpacing(trimmed);
        if (title.isEmpty) title = cleanTitle;
        addCandidate(cleanTitle);
      case _FieldKind.url:
        final cleanedRawUrl = _stripInlineActionSuffix(trimmed);
        final parsedUrl = _extractUrlCandidate(cleanedRawUrl) ?? cleanedRawUrl;
        if (parsedUrl.isEmpty) return;
        if (url.isEmpty) url = parsedUrl;
        addCandidate(parsedUrl);
      case _FieldKind.username:
        final stripped = _stripInlineActionSuffix(trimmed);
        if (stripped.isEmpty || _isUiNoise(stripped)) return;
        final cleanUser = stripped.split(RegExp(r'\s+')).length == 1
            ? stripped
            : (_extractEmailCandidate(stripped) ??
                  _extractPhoneCandidate(stripped) ??
                  stripped);
        if (username.isEmpty) {
          username = cleanUser;
          usernameBlock = sourceBlock;
        }
        addCandidate(cleanUser);
      case _FieldKind.password:
        final cleanPwd = _normalizePasswordToken(trimmed);
        if (cleanPwd.isEmpty) return;
        if (isMaskedPasswordText(cleanPwd)) {
          passwordMasked = true;
          return;
        }
        if (password.isEmpty) {
          password = cleanPwd;
          passwordBlock = sourceBlock;
          addCandidate(cleanPwd);
        }
      case _FieldKind.confirmPassword:
        final cleanPwd = _normalizePasswordToken(trimmed);
        if (cleanPwd.isEmpty) return;
        if (isMaskedPasswordText(cleanPwd)) {
          passwordMasked = true;
          return;
        }
        if (confirmPassword.isEmpty) {
          confirmPassword = cleanPwd;
          passwordBlock ??= sourceBlock;
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
            assignValue(
              kind,
              inline.value,
              fromInline: true,
              sourceBlock: item.block,
            );
            continue;
          }
        }
      }

      final kind = _classifyLabel(item.normalized);
      if (kind == _FieldKind.none) continue;
      consumedIds.add(itemKey(r, c));

      // Strategy B: right neighbor in the same visual row (skipping lone separators).
      var matchedRight = false;
      for (var nc = c + 1; nc < row.length; nc++) {
        final rightItem = row[nc];
        if (rightItem.block.x - item.block.right > 0.42) break;
        if (_classifyLabel(rightItem.normalized) != _FieldKind.none ||
            _splitInlineLabelValue(rightItem.normalized) != null) {
          break;
        }
        if (_standaloneSeparatorRe.hasMatch(rightItem.normalized)) {
          consumedIds.add(itemKey(r, nc));
          continue;
        }
        if (kind == _FieldKind.captcha) {
          consumedIds.add(itemKey(r, nc));
          excludedTexts.add(rightItem.normalized);
          matchedRight = true;
          break;
        }
        if (isMaskedPasswordText(rightItem.normalized) &&
            (kind == _FieldKind.password ||
                kind == _FieldKind.confirmPassword)) {
          consumedIds.add(itemKey(r, nc));
          passwordMasked = true;
          matchedRight = true;
          break;
        }
        if (_isUiNoise(rightItem.normalized)) {
          break;
        }
        consumedIds.add(itemKey(r, nc));
        assignValue(kind, rightItem.normalized, sourceBlock: rightItem.block);
        matchedRight = true;
        break;
      }
      if (matchedRight) continue;

      // Strategy C: below neighbor in the next 1-2 rows (stacked form inputs,
      // allowing a helper hint or action link row in between if not another field).
      for (var rowOffset = 1; rowOffset <= 2; rowOffset++) {
        final targetRowIdx = r + rowOffset;
        if (targetRowIdx >= rows.length) break;

        if (rowOffset == 2) {
          final interveningRow = rows[r + 1];
          final hasAlignedNextLabel = interveningRow.any((cand) {
            final isLabel =
                _classifyLabel(cand.normalized) != _FieldKind.none ||
                _splitInlineLabelValue(cand.normalized) != null;
            if (!isLabel) return false;
            return cand.block.right >= item.block.x - 0.08 &&
                cand.block.x <= item.block.right + 0.35;
          });
          if (hasAlignedNextLabel) break;
        }

        final nextRow = rows[targetRowIdx];
        _RowItem? bestBelow;
        var bestScore = double.infinity;
        var bestCol = -1;
        final maxGap = math.max(
          item.block.h * (rowOffset == 1 ? 4.5 : 6.5),
          rowOffset == 1 ? 0.16 : 0.22,
        );
        for (var nc = 0; nc < nextRow.length; nc++) {
          if (consumedIds.contains(itemKey(targetRowIdx, nc))) continue;
          final cand = nextRow[nc];
          final vGap = cand.block.y - item.block.bottom;
          if (vGap > maxGap || vGap < -0.02) continue;

          if (_classifyLabel(cand.normalized) != _FieldKind.none ||
              _splitInlineLabelValue(cand.normalized) != null ||
              _standaloneSeparatorRe.hasMatch(cand.normalized)) {
            continue;
          }

          final hDist = (cand.block.x - item.block.x).abs();
          final overlapsHorizontally =
              cand.block.right >= item.block.x - 0.08 &&
              cand.block.x <=
                  math.max(item.block.right + 0.35, item.block.x + 0.45);
          if (!overlapsHorizontally && nextRow.length > 1) continue;
          if (hDist < bestScore) {
            bestScore = hDist;
            bestBelow = cand;
            bestCol = nc;
          }
        }

        if (bestBelow != null && bestCol >= 0) {
          if (kind == _FieldKind.captcha) {
            consumedIds.add(itemKey(targetRowIdx, bestCol));
            excludedTexts.add(bestBelow.normalized);
            break;
          } else if (isMaskedPasswordText(bestBelow.normalized) &&
              (kind == _FieldKind.password ||
                  kind == _FieldKind.confirmPassword)) {
            consumedIds.add(itemKey(targetRowIdx, bestCol));
            passwordMasked = true;
            break;
          } else if (!_isUiNoise(bestBelow.normalized)) {
            consumedIds.add(itemKey(targetRowIdx, bestCol));
            assignValue(
              kind,
              bestBelow.normalized,
              sourceBlock: bestBelow.block,
            );
            break;
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
    String? bestUrl;
    var bestUrlScore = double.negativeInfinity;
    for (var r = 0; r < rows.length; r++) {
      for (final item in rows[r]) {
        if (excludedTexts.contains(item.normalized)) continue;
        final candidate = _extractUrlCandidate(item.normalized);
        if (candidate == null || _isBoilerplateUrl(candidate)) continue;
        var score = 0.0 - r * 0.01;
        if (item.block.y <= 0.16) {
          score += 35.0;
        } else if (item.block.y < 0.82) {
          score += 10.0;
        }
        final lowerRaw = item.normalized.toLowerCase();
        if (lowerRaw.contains('https://') || lowerRaw.contains('http://')) {
          score += 15.0;
        }
        if (!_isPolicyUrl(candidate)) {
          score += 12.0;
        }
        if (score > bestUrlScore) {
          bestUrlScore = score;
          bestUrl = candidate;
        }
      }
    }
    if (bestUrl != null) {
      url = bestUrl;
      addCandidate(bestUrl);
    }
  }

  int? usernameRowIdx;
  if (username.isEmpty) {
    final emailCandidates = <({String email, int rowIdx, OcrBlock block, double score})>[];
    for (var r = 0; r < rows.length; r++) {
      for (final item in rows[r]) {
        if (excludedTexts.contains(item.normalized) ||
            _isUiNoise(item.normalized)) {
          continue;
        }
        final email = _extractEmailCandidate(item.normalized);
        if (email == null) continue;
        var score = _isGenericServiceEmail(email) ? -50.0 : 20.0;
        if (passwordBlock != null) {
          final dy = passwordBlock!.centerY - item.block.centerY;
          if (dy >= -0.02 && dy <= 0.28) score += 25.0 - dy * 30.0;
          if ((item.block.x - passwordBlock!.x).abs() <= 0.28) score += 15.0;
        } else {
          if (item.block.x >= 0.10 && item.block.right <= 0.90) score += 8.0;
          score -= r * 0.05;
        }
        emailCandidates.add((
          email: email,
          rowIdx: r,
          block: item.block,
          score: score,
        ));
      }
    }
    if (emailCandidates.isNotEmpty) {
      emailCandidates.sort((a, b) => b.score.compareTo(a.score));
      final chosen = emailCandidates.first;
      username = chosen.email;
      usernameRowIdx = chosen.rowIdx;
      usernameBlock = chosen.block;
      addCandidate(chosen.email);
    }
  } else {
    for (var r = 0; r < rows.length; r++) {
      if (rows[r].any((item) => item.normalized.contains(username))) {
        usernameRowIdx = r;
        usernameBlock ??= rows[r]
            .firstWhere((item) => item.normalized.contains(username))
            .block;
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
          usernameBlock = item.block;
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
    String? bestPassword;
    var bestPasswordScore = double.negativeInfinity;
    for (var r = 0; r < rows.length; r++) {
      for (var c = 0; c < rows[r].length; c++) {
        final item = rows[r][c];
        final rawTrimmed = item.normalized.trim();
        final normalizedToken = _normalizePasswordToken(rawTrimmed);
        if (normalizedToken.isEmpty ||
            normalizedToken == username ||
            rawTrimmed == username ||
            normalizedToken == url ||
            rawTrimmed == url ||
            normalizedToken == title ||
            excludedTexts.contains(rawTrimmed) ||
            excludedTexts.contains(normalizedToken)) {
          continue;
        }
        if (!_looksLikePasswordToken(rawTrimmed)) continue;

        var score = 0.0 - r * 0.01;
        if (usernameBlock != null) {
          final dy = item.block.centerY - usernameBlock!.centerY;
          final dx = (item.block.x - usernameBlock!.x).abs();
          if (dy >= -0.01 && dy <= 0.25 && dx <= 0.28) {
            score += 45.0 - dy * 40.0 - dx * 20.0;
          } else if (dy.abs() <= 0.03 && item.block.x > usernameBlock!.x) {
            score += 28.0;
          }
        } else if (usernameRowIdx != null &&
            (r == usernameRowIdx + 1 || r == usernameRowIdx + 2)) {
          score += 22.0;
        }
        if (item.block.x >= 0.12 && item.block.right <= 0.88) {
          score += 8.0;
        }
        if (RegExp(r'[^a-zA-Z0-9]').hasMatch(normalizedToken)) {
          score += 5.0;
        }
        if (score > bestPasswordScore) {
          bestPasswordScore = score;
          bestPassword = normalizedToken;
        }
      }
    }
    if (bestPassword != null) {
      password = bestPassword;
      addCandidate(bestPassword);
    }
  }

  // Pass 3: infer title from known domain brand, clear headings, or fallback host.
  if (title.isEmpty && url.isNotEmpty) {
    title = _inferKnownBrandFromUrl(url);
  }
  if (title.isEmpty) {
    title = _inferTitleFromHeadings(flatBlocks);
  }
  if (title.isEmpty && url.isNotEmpty) {
    title = _inferFallbackDomainTitle(url);
  }

  // Collect remaining clean text fragments as quick-assign candidate chips.
  for (final row in rows) {
    for (final item in row) {
      final inline = _splitInlineLabelValue(item.normalized);
      final rawPiece = inline != null ? inline.value : item.normalized;
      final piece = _stripInlineActionSuffix(rawPiece);
      if (excludedTexts.contains(rawPiece) || excludedTexts.contains(piece)) {
        continue;
      }
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

const _fullWidthOffset = 0xFEE0;
const _homoglyphPasswordMap = <int, String>{
  0x0410: 'A', // Cyrillic А
  0x0412: 'B', // Cyrillic В
  0x0421: 'C', // Cyrillic С
  0x0415: 'E', // Cyrillic Е
  0x041D: 'H', // Cyrillic Н
  0x041A: 'K', // Cyrillic К
  0x041C: 'M', // Cyrillic М
  0x041E: 'O', // Cyrillic О
  0x0420: 'P', // Cyrillic Р
  0x0422: 'T', // Cyrillic Т
  0x0425: 'X', // Cyrillic Х
  0x0406: 'I', // Cyrillic І
  0x0408: 'J', // Cyrillic Ј
  0x0405: 'S', // Cyrillic Ѕ
  0x0430: 'a', // Cyrillic а
  0x0441: 'c', // Cyrillic с
  0x0435: 'e', // Cyrillic е
  0x043E: 'o', // Cyrillic о
  0x0440: 'p', // Cyrillic р
  0x0445: 'x', // Cyrillic х
  0x0443: 'y', // Cyrillic у
  0x0456: 'i', // Cyrillic і
  0x0455: 's', // Cyrillic ѕ
  0x0391: 'A', // Greek Α
  0x0392: 'B', // Greek Β
  0x0395: 'E', // Greek Ε
  0x0396: 'Z', // Greek Ζ
  0x0397: 'H', // Greek Η
  0x0399: 'I', // Greek Ι
  0x039A: 'K', // Greek Κ
  0x039C: 'M', // Greek Μ
  0x039D: 'N', // Greek Ν
  0x039F: 'O', // Greek Ο
  0x03A1: 'P', // Greek Ρ
  0x03A4: 'T', // Greek Τ
  0x03A7: 'X', // Greek Χ
  0x03BF: 'o', // Greek ο
};

/// OCR engines configured for Chinese+English occasionally emit full-width
/// punctuation/letters (e.g. `密码：Abc#7890Xy！`) or Cyrillic/Greek lookalikes
/// (e.g. `Х` U+0425 instead of `X`). Strip inline button suffixes first, then
/// normalize ASCII-based passwords back to clean ASCII.
String _normalizePasswordToken(String value) {
  final cleaned = _stripInlineActionSuffix(value).trim();
  if (cleaned.isEmpty) return '';
  final hasAlphaNum = RegExp(r'[A-Za-z0-9\uFF10-\uFF19\uFF21-\uFF3A\uFF41-\uFF5A]')
      .hasMatch(cleaned);
  final hasHanzi = RegExp(_cjkPattern).hasMatch(cleaned);
  if (!hasAlphaNum || hasHanzi) return cleaned;
  final out = StringBuffer();
  for (final rune in cleaned.runes) {
    if (rune >= 0xFF01 && rune <= 0xFF5E) {
      out.writeCharCode(rune - _fullWidthOffset);
    } else {
      final mapped = _homoglyphPasswordMap[rune];
      if (mapped != null) {
        out.write(mapped);
      } else {
        out.writeCharCode(rune);
      }
    }
  }
  return out.toString();
}

/// Convenience parser for plain multiline text (such as copied text or tests).
ParsedCredential parseCredentialFromText(String text) {
  if (text.trim().isEmpty) return const ParsedCredential();
  return parseCredentialFromOcr(_blocksFromPlainText(text));
}
