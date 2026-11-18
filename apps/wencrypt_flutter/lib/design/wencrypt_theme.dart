// Wencrypt Design System — design tokens and the global Material theme.
//
// This file is presentation-only: it defines colors, typography, spacing,
// radii, elevation and component themes. It must never contain vault,
// crypto, sync or clipboard logic. Every visual constant used by the app
// lives here so light and dark mode stay in lockstep.

import 'dart:io';

import 'package:material_ui/material_ui.dart';

/// Corner radii used across the product. Keep these values in sync with the
/// design spec (inputs 8, buttons 8, cards 12, dialogs 16, menus 12).
abstract final class WRadius {
  static const double xs = 6;
  static const double sm = 8;
  static const double md = 10;
  static const double lg = 12;
  static const double xl = 16;
  static const double xxl = 20;
  static const double pill = 999;
}

/// 4/8/12/16/20/24/32 spacing scale.
abstract final class WSpace {
  static const double xxs = 2;
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 24;
  static const double xxxl = 32;
}

/// Semantic color tokens. Exposed through [ThemeExtension] so every widget can
/// reach them with `WColors.of(context)` and both brightnesses stay aligned.
@immutable
class WColors extends ThemeExtension<WColors> {
  const WColors({
    required this.canvas,
    required this.surface,
    required this.surfaceMuted,
    required this.surfaceSunken,
    required this.sidebar,
    required this.border,
    required this.borderStrong,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.brand,
    required this.brandHover,
    required this.brandSoft,
    required this.onBrand,
    required this.success,
    required this.successSoft,
    required this.warning,
    required this.warningSoft,
    required this.danger,
    required this.dangerSoft,
    required this.hover,
    required this.pressed,
    required this.shadow,
  });

  final Color canvas;
  final Color surface;
  final Color surfaceMuted;
  final Color surfaceSunken;
  final Color sidebar;
  final Color border;
  final Color borderStrong;
  final Color textPrimary;
  final Color textSecondary;
  final Color textTertiary;
  final Color brand;
  final Color brandHover;
  final Color brandSoft;
  final Color onBrand;
  final Color success;
  final Color successSoft;
  final Color warning;
  final Color warningSoft;
  final Color danger;
  final Color dangerSoft;

  /// Neutral wash used for hover states on rows, menu items and icon buttons.
  final Color hover;

  /// Slightly stronger neutral for pressed/selected states.
  final Color pressed;

  /// Tinted shadow color for floating layers.
  final Color shadow;

  static const WColors light = WColors(
    canvas: Color(0xFFF4F6F9),
    surface: Color(0xFFFFFFFF),
    surfaceMuted: Color(0xFFF2F4F8),
    surfaceSunken: Color(0xFFEDF0F5),
    sidebar: Color(0xFFF8F9FB),
    border: Color(0xFFE6E9EF),
    borderStrong: Color(0xFFD5DAE3),
    textPrimary: Color(0xFF101828),
    textSecondary: Color(0xFF5A6474),
    textTertiary: Color(0xFF8B94A3),
    brand: Color(0xFF2F6BF6),
    brandHover: Color(0xFF1D5CEC),
    brandSoft: Color(0xFFEAF1FF),
    onBrand: Color(0xFFFFFFFF),
    success: Color(0xFF12A150),
    successSoft: Color(0xFFE7F7EE),
    warning: Color(0xFFC77612),
    warningSoft: Color(0xFFFDF3E3),
    danger: Color(0xFFD92D20),
    dangerSoft: Color(0xFFFDECEA),
    hover: Color(0xFFF0F2F6),
    pressed: Color(0xFFE6EAF1),
    shadow: Color(0xFF0B1220),
  );

  static const WColors dark = WColors(
    canvas: Color(0xFF0F1115),
    surface: Color(0xFF17191F),
    surfaceMuted: Color(0xFF1E2128),
    surfaceSunken: Color(0xFF121419),
    sidebar: Color(0xFF131519),
    border: Color(0xFF262A33),
    borderStrong: Color(0xFF353A46),
    textPrimary: Color(0xFFEDEFF3),
    textSecondary: Color(0xFFA5ADBB),
    textTertiary: Color(0xFF767F8D),
    brand: Color(0xFF7B9CFF),
    brandHover: Color(0xFF96B1FF),
    brandSoft: Color(0xFF1D2740),
    onBrand: Color(0xFF0B1428),
    success: Color(0xFF56D68B),
    successSoft: Color(0xFF14291D),
    warning: Color(0xFFF0B35B),
    warningSoft: Color(0xFF2B2114),
    danger: Color(0xFFF97066),
    dangerSoft: Color(0xFF2C1615),
    hover: Color(0xFF21242C),
    pressed: Color(0xFF2A2E37),
    shadow: Color(0xFF000000),
  );

  static WColors of(BuildContext context) =>
      Theme.of(context).extension<WColors>() ?? light;

  bool get isDark => canvas.computeLuminance() < 0.2;

  @override
  WColors copyWith({Color? brand, Color? brandSoft, Color? surface}) => WColors(
    canvas: canvas,
    surface: surface ?? this.surface,
    surfaceMuted: surfaceMuted,
    surfaceSunken: surfaceSunken,
    sidebar: sidebar,
    border: border,
    borderStrong: borderStrong,
    textPrimary: textPrimary,
    textSecondary: textSecondary,
    textTertiary: textTertiary,
    brand: brand ?? this.brand,
    brandHover: brandHover,
    brandSoft: brandSoft ?? this.brandSoft,
    onBrand: onBrand,
    success: success,
    successSoft: successSoft,
    warning: warning,
    warningSoft: warningSoft,
    danger: danger,
    dangerSoft: dangerSoft,
    hover: hover,
    pressed: pressed,
    shadow: shadow,
  );

  @override
  WColors lerp(ThemeExtension<WColors>? other, double t) {
    if (other is! WColors) return this;
    Color mix(Color a, Color b) => Color.lerp(a, b, t) ?? b;
    return WColors(
      canvas: mix(canvas, other.canvas),
      surface: mix(surface, other.surface),
      surfaceMuted: mix(surfaceMuted, other.surfaceMuted),
      surfaceSunken: mix(surfaceSunken, other.surfaceSunken),
      sidebar: mix(sidebar, other.sidebar),
      border: mix(border, other.border),
      borderStrong: mix(borderStrong, other.borderStrong),
      textPrimary: mix(textPrimary, other.textPrimary),
      textSecondary: mix(textSecondary, other.textSecondary),
      textTertiary: mix(textTertiary, other.textTertiary),
      brand: mix(brand, other.brand),
      brandHover: mix(brandHover, other.brandHover),
      brandSoft: mix(brandSoft, other.brandSoft),
      onBrand: mix(onBrand, other.onBrand),
      success: mix(success, other.success),
      successSoft: mix(successSoft, other.successSoft),
      warning: mix(warning, other.warning),
      warningSoft: mix(warningSoft, other.warningSoft),
      danger: mix(danger, other.danger),
      dangerSoft: mix(dangerSoft, other.dangerSoft),
      hover: mix(hover, other.hover),
      pressed: mix(pressed, other.pressed),
      shadow: mix(shadow, other.shadow),
    );
  }
}

/// Monospaced family per platform. Used for URLs, hosts and technical fields.
String get wMonoFamily {
  if (Platform.isMacOS) return 'Menlo';
  if (Platform.isWindows) return 'Consolas';
  return 'monospace';
}

/// Soft, layered shadows. Deliberately subtle: the product should read as a
/// native app, not as a web dashboard.
abstract final class WShadows {
  static List<BoxShadow> card(WColors c) => [
    BoxShadow(
      color: c.shadow.withValues(alpha: c.isDark ? 0.55 : 0.04),
      blurRadius: 2,
      offset: const Offset(0, 1),
    ),
  ];

  static List<BoxShadow> popover(WColors c) => [
    BoxShadow(
      color: c.shadow.withValues(alpha: c.isDark ? 0.55 : 0.10),
      blurRadius: 28,
      spreadRadius: -6,
      offset: const Offset(0, 12),
    ),
    BoxShadow(
      color: c.shadow.withValues(alpha: c.isDark ? 0.40 : 0.05),
      blurRadius: 4,
      offset: const Offset(0, 2),
    ),
  ];

  static List<BoxShadow> floating(WColors c) => [
    BoxShadow(
      color: c.shadow.withValues(alpha: c.isDark ? 0.55 : 0.16),
      blurRadius: 24,
      spreadRadius: -6,
      offset: const Offset(0, 8),
    ),
    BoxShadow(
      color: c.shadow.withValues(alpha: c.isDark ? 0.40 : 0.06),
      blurRadius: 4,
      offset: const Offset(0, 2),
    ),
  ];
}

/// Builds the single source of truth for the app's Material theme.
/// Builds the app theme. [fontFamily] / [fontFamilyFallback] exist so design
/// previews and golden tests can render with the host platform font; the app
/// itself calls this without arguments and inherits the platform default.
ThemeData wencryptTheme(
  Brightness brightness, {
  String? fontFamily,
  List<String>? fontFamilyFallback,
}) {
  final dark = brightness == Brightness.dark;
  final c = dark ? WColors.dark : WColors.light;
  final scheme = ColorScheme(
    brightness: brightness,
    primary: c.brand,
    onPrimary: c.onBrand,
    primaryContainer: c.brandSoft,
    onPrimaryContainer: dark
        ? const Color(0xFFD9E4FF)
        : const Color(0xFF1B3B85),
    secondary: c.brand,
    onSecondary: c.onBrand,
    secondaryContainer: c.brandSoft,
    onSecondaryContainer: dark
        ? const Color(0xFFD9E4FF)
        : const Color(0xFF1B3B85),
    tertiary: dark ? const Color(0xFF8ED0FF) : const Color(0xFF0F6FA8),
    onTertiary: dark ? const Color(0xFF04263A) : Colors.white,
    tertiaryContainer: dark ? const Color(0xFF12293A) : const Color(0xFFE5F4FC),
    onTertiaryContainer: dark
        ? const Color(0xFFCBE8FA)
        : const Color(0xFF0A4C73),
    error: c.danger,
    onError: Colors.white,
    errorContainer: c.dangerSoft,
    onErrorContainer: dark ? const Color(0xFFFFD5D1) : const Color(0xFF8A1C14),
    surface: c.surface,
    onSurface: c.textPrimary,
    surfaceDim: c.surfaceSunken,
    surfaceBright: dark ? const Color(0xFF1D2027) : Colors.white,
    surfaceContainerLowest: dark ? const Color(0xFF0C0E12) : Colors.white,
    surfaceContainerLow: c.surfaceSunken,
    surfaceContainer: c.surfaceMuted,
    surfaceContainerHigh: dark
        ? const Color(0xFF232732)
        : const Color(0xFFF0F2F6),
    surfaceContainerHighest: dark
        ? const Color(0xFF2A2F3A)
        : const Color(0xFFE8ECF3),
    onSurfaceVariant: c.textSecondary,
    outline: c.borderStrong,
    outlineVariant: c.border,
    shadow: c.shadow,
    scrim: const Color(0x66000000),
    inverseSurface: dark ? const Color(0xFFEDEFF3) : const Color(0xFF1B1F27),
    onInverseSurface: dark ? const Color(0xFF1B1F27) : const Color(0xFFF5F6F8),
    inversePrimary: dark ? const Color(0xFF2F6BF6) : const Color(0xFF9FB8FF),
  );

  final textTheme = _textTheme(
    scheme,
    c,
  ).apply(fontFamily: fontFamily, fontFamilyFallback: fontFamilyFallback);

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    extensions: <ThemeExtension<dynamic>>[c],
    textTheme: textTheme,
    primaryColor: c.brand,
    scaffoldBackgroundColor: c.canvas,
    canvasColor: c.canvas,
    dividerColor: c.border,
    dividerTheme: DividerThemeData(color: c.border, thickness: 1, space: 1),
    iconTheme: IconThemeData(color: c.textSecondary, size: 18),
    primaryIconTheme: IconThemeData(color: c.textPrimary, size: 18),
    splashFactory: InkSparkle.splashFactory,
    visualDensity: VisualDensity.standard,
    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    appBarTheme: AppBarTheme(
      elevation: 0,
      scrolledUnderElevation: 0,
      backgroundColor: c.surface,
      foregroundColor: c.textPrimary,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
      titleTextStyle: textTheme.titleLarge,
      shape: Border(bottom: BorderSide(color: c.border)),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: c.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(WRadius.lg),
        side: BorderSide(color: c.border),
      ),
    ),
    dialogTheme: DialogThemeData(
      elevation: 0,
      backgroundColor: c.surface,
      surfaceTintColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      titleTextStyle: textTheme.headlineSmall,
      contentTextStyle: textTheme.bodyMedium?.copyWith(color: c.textSecondary),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(WRadius.xl),
        side: BorderSide(color: c.border),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      elevation: 0,
      color: c.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(WRadius.lg),
        side: BorderSide(color: c.border),
      ),
      textStyle: textTheme.bodyMedium?.copyWith(color: c.textPrimary),
      labelTextStyle: WidgetStatePropertyAll(
        textTheme.labelSmall?.copyWith(
          color: c.textTertiary,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.4,
        ),
      ),
    ),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 450),
      textStyle: textTheme.labelSmall?.copyWith(
        color: dark ? const Color(0xFF0C0E12) : Colors.white,
        fontWeight: FontWeight.w500,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: dark ? const Color(0xFFE7EAF0) : const Color(0xFF20242C),
        borderRadius: BorderRadius.circular(WRadius.xs),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: c.surfaceMuted,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      hintStyle: textTheme.bodyMedium?.copyWith(color: c.textTertiary),
      labelStyle: textTheme.bodyMedium?.copyWith(color: c.textSecondary),
      floatingLabelStyle: textTheme.labelMedium?.copyWith(color: c.brand),
      prefixIconColor: c.textTertiary,
      suffixIconColor: c.textTertiary,
      prefixIconConstraints: const BoxConstraints(minWidth: 40, minHeight: 36),
      suffixIconConstraints: const BoxConstraints(minWidth: 36, minHeight: 36),
      border: _inputBorder(c, c.border),
      enabledBorder: _inputBorder(c, c.border),
      disabledBorder: _inputBorder(c, c.border.withValues(alpha: 0.6)),
      focusedBorder: _inputBorder(c, c.brand, width: 1.4),
      errorBorder: _inputBorder(c, c.danger),
      focusedErrorBorder: _inputBorder(c, c.danger, width: 1.4),
      errorStyle: textTheme.labelSmall?.copyWith(color: c.danger),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style:
          FilledButton.styleFrom(
            elevation: 0,
            minimumSize: const Size(64, 34),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            backgroundColor: c.brand,
            foregroundColor: c.onBrand,
            disabledBackgroundColor: c.surfaceSunken,
            disabledForegroundColor: c.textTertiary,
            textStyle: textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w600,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(WRadius.sm),
            ),
          ).copyWith(
            overlayColor: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.pressed)) {
                return Colors.black.withValues(alpha: 0.06);
              }
              if (states.contains(WidgetState.hovered)) {
                return Colors.white.withValues(alpha: 0.10);
              }
              return null;
            }),
          ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style:
          OutlinedButton.styleFrom(
            minimumSize: const Size(64, 34),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            foregroundColor: c.textPrimary,
            backgroundColor: c.surface,
            disabledForegroundColor: c.textTertiary,
            textStyle: textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w600,
            ),
            side: BorderSide(color: c.borderStrong),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(WRadius.sm),
            ),
          ).copyWith(
            overlayColor: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.pressed)) return c.pressed;
              if (states.contains(WidgetState.hovered)) return c.hover;
              return null;
            }),
          ),
    ),
    textButtonTheme: TextButtonThemeData(
      style:
          TextButton.styleFrom(
            minimumSize: const Size(0, 30),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            foregroundColor: c.brand,
            textStyle: textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w600,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(WRadius.sm),
            ),
          ).copyWith(
            overlayColor: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.hovered)) {
                return c.brand.withValues(alpha: 0.07);
              }
              return null;
            }),
          ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: c.textSecondary,
        highlightColor: c.pressed,
        hoverColor: c.hover,
        minimumSize: const Size(28, 28),
        padding: const EdgeInsets.all(5),
        iconSize: 18,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(WRadius.sm),
        ),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: c.surface,
      selectedColor: c.brandSoft,
      disabledColor: c.surfaceMuted,
      side: BorderSide(color: c.borderStrong),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(WRadius.sm),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      labelPadding: const EdgeInsets.symmetric(horizontal: 2),
      labelStyle: textTheme.labelMedium?.copyWith(color: c.textSecondary),
      secondaryLabelStyle: textTheme.labelMedium?.copyWith(
        color: dark ? const Color(0xFFBBD0FF) : const Color(0xFF1D4ED8),
        fontWeight: FontWeight.w600,
      ),
      showCheckmark: false,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      pressElevation: 0,
    ),
    checkboxTheme: CheckboxThemeData(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(WRadius.xs / 1.5),
      ),
      side: BorderSide(color: c.borderStrong, width: 1.2),
      fillColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected) ? c.brand : null,
      ),
      checkColor: WidgetStatePropertyAll(c.onBrand),
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return dark ? const Color(0xFF0B1428) : Colors.white;
        }
        return dark ? const Color(0xFF8A93A3) : Colors.white;
      }),
      trackColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return c.brand;
        return dark ? const Color(0xFF2B303A) : const Color(0xFFD8DDE6);
      }),
      trackOutlineColor: WidgetStatePropertyAll(Colors.transparent),
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    ),
    radioTheme: RadioThemeData(
      fillColor: WidgetStateProperty.resolveWith(
        (states) =>
            states.contains(WidgetState.selected) ? c.brand : c.borderStrong,
      ),
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: c.brand,
      inactiveTrackColor: c.surfaceSunken,
      thumbColor: c.brand,
      overlayShape: SliderComponentShape.noOverlay,
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: c.brand,
      linearTrackColor: c.surfaceSunken,
      circularTrackColor: Colors.transparent,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: dark ? const Color(0xFFEDEFF3) : const Color(0xFF1B1F27),
      contentTextStyle: textTheme.bodyMedium?.copyWith(
        color: dark ? const Color(0xFF1B1F27) : Colors.white,
      ),
      elevation: 0,
      insetPadding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(WRadius.sm),
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: c.surface,
      surfaceTintColor: Colors.transparent,
      modalBackgroundColor: c.surface,
      elevation: 0,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(WRadius.xl)),
      ),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => c.textTertiary.withValues(
          alpha: states.contains(WidgetState.hovered) ? 0.55 : 0.32,
        ),
      ),
      thickness: const WidgetStatePropertyAll(7),
      radius: const Radius.circular(4),
      crossAxisMargin: 2,
      mainAxisMargin: 4,
      interactive: true,
    ),
    listTileTheme: ListTileThemeData(
      dense: true,
      visualDensity: VisualDensity.compact,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      iconColor: c.textTertiary,
      textColor: c.textPrimary,
      titleTextStyle: textTheme.titleSmall,
      subtitleTextStyle: textTheme.bodySmall?.copyWith(color: c.textSecondary),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(WRadius.sm),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      height: 58,
      elevation: 0,
      backgroundColor: c.surface,
      surfaceTintColor: Colors.transparent,
      indicatorColor: c.brandSoft,
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => textTheme.labelSmall?.copyWith(
          color: states.contains(WidgetState.selected)
              ? c.brand
              : c.textSecondary,
          fontWeight: FontWeight.w600,
        ),
      ),
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          size: 20,
          color: states.contains(WidgetState.selected)
              ? c.brand
              : c.textSecondary,
        ),
      ),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      elevation: 0,
      focusElevation: 0,
      hoverElevation: 0,
      highlightElevation: 0,
      backgroundColor: c.brand,
      foregroundColor: c.onBrand,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(WRadius.md + 2),
      ),
      extendedTextStyle: textTheme.labelLarge?.copyWith(
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}

OutlineInputBorder _inputBorder(WColors c, Color color, {double width = 1}) =>
    OutlineInputBorder(
      borderRadius: BorderRadius.circular(WRadius.sm),
      borderSide: BorderSide(color: color, width: width),
    );

TextTheme _textTheme(ColorScheme scheme, WColors c) {
  final primary = c.textPrimary;
  final secondary = c.textSecondary;
  return TextTheme(
    displayLarge: TextStyle(
      fontSize: 34,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.6,
      height: 1.15,
      color: primary,
    ),
    displayMedium: TextStyle(
      fontSize: 27,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.5,
      height: 1.2,
      color: primary,
    ),
    displaySmall: TextStyle(
      fontSize: 23,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.3,
      height: 1.25,
      color: primary,
    ),
    headlineLarge: TextStyle(
      fontSize: 20,
      fontWeight: FontWeight.w600,
      letterSpacing: -0.2,
      height: 1.3,
      color: primary,
    ),
    headlineMedium: TextStyle(
      fontSize: 18,
      fontWeight: FontWeight.w600,
      letterSpacing: -0.2,
      height: 1.3,
      color: primary,
    ),
    headlineSmall: TextStyle(
      fontSize: 16.5,
      fontWeight: FontWeight.w600,
      letterSpacing: -0.15,
      height: 1.3,
      color: primary,
    ),
    titleLarge: TextStyle(
      fontSize: 14.5,
      fontWeight: FontWeight.w600,
      letterSpacing: -0.1,
      height: 1.3,
      color: primary,
    ),
    titleMedium: TextStyle(
      fontSize: 13.5,
      fontWeight: FontWeight.w600,
      height: 1.35,
      color: primary,
    ),
    titleSmall: TextStyle(
      fontSize: 13,
      fontWeight: FontWeight.w600,
      height: 1.35,
      color: primary,
    ),
    bodyLarge: TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w400,
      height: 1.45,
      color: primary,
    ),
    bodyMedium: TextStyle(
      fontSize: 13,
      fontWeight: FontWeight.w400,
      height: 1.45,
      color: primary,
    ),
    bodySmall: TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w400,
      height: 1.45,
      color: secondary,
    ),
    labelLarge: TextStyle(
      fontSize: 13,
      fontWeight: FontWeight.w600,
      letterSpacing: 0,
      color: primary,
    ),
    labelMedium: TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w500,
      letterSpacing: 0,
      color: secondary,
    ),
    labelSmall: TextStyle(
      fontSize: 11.5,
      fontWeight: FontWeight.w500,
      letterSpacing: 0.1,
      color: c.textTertiary,
    ),
  );
}
