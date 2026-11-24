// Wencrypt Design System — shared presentational components.
//
// Every widget here is stateless/presentation-only: it receives data and
// callbacks, never talks to the vault, crypto, sync or clipboard layers.
// Screens compose these to stay visually identical across the app.

import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'wencrypt_theme.dart';

/// The Wencrypt brand mark. Small sizes use the bundled logo asset.
class WBrandMark extends StatelessWidget {
  const WBrandMark({super.key, this.size = 20, this.radius = 5});

  final double size;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Image.asset(
        'assets/brand/wencrypt-logo.png',
        width: size,
        height: size,
        filterQuality: FilterQuality.high,
      ),
    );
  }
}

/// A compact, consistent icon button (28x28 with a 6px radius hover wash).
class WIconButton extends StatelessWidget {
  const WIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    this.onPressed,
    this.size = 28,
    this.iconSize = 17,
    this.color,
    this.active = false,
    this.busy = false,
    this.badgeColor,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final double size;
  final double iconSize;
  final Color? color;
  final bool active;
  final bool busy;
  final Color? badgeColor;

  @override
  Widget build(BuildContext context) {
    final c = WColors.of(context);
    final disabled = onPressed == null && !busy;
    final foreground = disabled
        ? c.textTertiary.withValues(alpha: 0.6)
        : (color ?? (active ? c.brand : c.textSecondary));
    return Tooltip(
      message: tooltip,
      child: SizedBox(
        width: size,
        height: size,
        child: Material(
          color: active ? c.brandSoft : Colors.transparent,
          borderRadius: BorderRadius.circular(WRadius.sm),
          child: InkWell(
            borderRadius: BorderRadius.circular(WRadius.sm),
            hoverColor: c.hover,
            onTap: busy ? null : onPressed,
            child: Stack(
              alignment: Alignment.center,
              children: [
                if (busy)
                  SizedBox(
                    width: iconSize - 3,
                    height: iconSize - 3,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.7,
                      color: c.brand,
                    ),
                  )
                else
                  Icon(icon, size: iconSize, color: foreground),
                if (badgeColor != null && !busy)
                  Positioned(
                    top: 4,
                    right: 4,
                    child: Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: badgeColor,
                        shape: BoxShape.circle,
                        border: Border.all(color: c.surface, width: 1),
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

/// Base card surface: white, 1px hairline border, 12px radius.
class WSurface extends StatelessWidget {
  const WSurface({
    super.key,
    required this.child,
    this.padding = EdgeInsets.zero,
    this.radius = WRadius.lg,
    this.color,
    this.border = true,
    this.shadow = false,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final Color? color;
  final bool border;
  final bool shadow;

  @override
  Widget build(BuildContext context) {
    final c = WColors.of(context);
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: color ?? c.surface,
        borderRadius: BorderRadius.circular(radius),
        border: border ? Border.all(color: c.border) : null,
        boxShadow: shadow ? WShadows.card(c) : null,
      ),
      child: child,
    );
  }
}

/// Small pill used for status, counts and inline metadata.
enum WTone { neutral, info, success, warning, danger }

class WStatusPill extends StatelessWidget {
  const WStatusPill({
    super.key,
    required this.label,
    this.icon,
    this.tone = WTone.neutral,
    this.busy = false,
    this.compact = false,
  });

  final String label;
  final IconData? icon;
  final WTone tone;
  final bool busy;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final c = WColors.of(context);
    final (bg, fg) = switch (tone) {
      WTone.info => (c.brandSoft, c.isDark ? const Color(0xFFBBD0FF) : c.brand),
      WTone.success => (c.successSoft, c.success),
      WTone.warning => (c.warningSoft, c.warning),
      WTone.danger => (c.dangerSoft, c.danger),
      WTone.neutral => (c.surfaceMuted, c.textSecondary),
    };
    return Container(
      height: compact ? 20 : 22,
      padding: EdgeInsets.symmetric(horizontal: compact ? 7 : 8),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(WRadius.xs),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (busy)
            SizedBox(
              width: 11,
              height: 11,
              child: CircularProgressIndicator(strokeWidth: 1.6, color: fg),
            )
          else if (icon != null)
            Icon(icon, size: compact ? 11.5 : 12.5, color: fg),
          if (busy || icon != null) const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              fontSize: compact ? 11 : 11.5,
              fontWeight: FontWeight.w600,
              height: 1.1,
              color: fg,
            ),
          ),
        ],
      ),
    );
  }
}

/// Inline informational / warning block used inside dialogs and pages.
class WNote extends StatelessWidget {
  const WNote({
    super.key,
    required this.child,
    this.tone = WTone.info,
    this.icon,
  });

  final Widget child;
  final WTone tone;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final c = WColors.of(context);
    final (bg, fg) = switch (tone) {
      WTone.info => (c.brandSoft, c.brand),
      WTone.success => (c.successSoft, c.success),
      WTone.warning => (c.warningSoft, c.warning),
      WTone.danger => (c.dangerSoft, c.danger),
      WTone.neutral => (c.surfaceMuted, c.textSecondary),
    };
    final resolvedIcon =
        icon ??
        switch (tone) {
          WTone.info => Icons.info_outline_rounded,
          WTone.success => Icons.check_circle_outline_rounded,
          WTone.warning => Icons.warning_amber_rounded,
          WTone.danger => Icons.error_outline_rounded,
          WTone.neutral => Icons.info_outline_rounded,
        };
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(WRadius.sm),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(resolvedIcon, size: 15, color: fg),
          const SizedBox(width: 8),
          Expanded(
            child: DefaultTextStyle.merge(
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: c.isDark ? c.textSecondary : fg.withValues(alpha: 0.92),
                height: 1.4,
              ),
              child: child,
            ),
          ),
        ],
      ),
    );
  }
}

/// Section label used above grouped lists.
class WSectionLabel extends StatelessWidget {
  const WSectionLabel({super.key, required this.label, this.trailing});

  final String label;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final c = WColors.of(context);
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.2,
              color: c.textTertiary,
            ),
          ),
        ),
        ?trailing,
      ],
    );
  }
}

/// Round-square avatar with the entry's initial. Colors are derived
/// deterministically from the entry key so they stay stable across rebuilds.
class WAvatar extends StatelessWidget {
  const WAvatar({super.key, required this.label, this.size = 34, this.seed});

  final String label;
  final double size;
  final String? seed;

  static const List<int> _hues = [212, 262, 168, 28, 340, 190, 96, 300];

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final key = (seed ?? label).toLowerCase();
    var hash = 0;
    for (final unit in key.codeUnits) {
      hash = (hash * 31 + unit) & 0x7fffffff;
    }
    final hue = _hues[hash % _hues.length];
    final base = HSLColor.fromAHSL(
      1,
      hue.toDouble(),
      dark ? 0.26 : 0.44,
      dark ? 0.21 : 0.94,
    ).toColor();
    final fg = HSLColor.fromAHSL(
      1,
      hue.toDouble(),
      dark ? 0.48 : 0.50,
      dark ? 0.78 : 0.34,
    ).toColor();
    final initial = label.trim().isEmpty
        ? '?'
        : label.trim().characters.first.toUpperCase();
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: base,
        borderRadius: BorderRadius.circular(size * 0.28),
        border: Border.all(color: fg.withValues(alpha: dark ? 0.14 : 0.10)),
      ),
      child: Text(
        initial,
        style: TextStyle(
          fontSize: size * 0.42,
          fontWeight: FontWeight.w600,
          height: 1,
          color: fg,
        ),
      ),
    );
  }
}

/// Standard dialog shell: fixed header, scrollable body, pinned footer.
class WDialog extends StatelessWidget {
  const WDialog({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
    this.icon,
    this.danger = false,
    this.showClose = false,
    this.width = 480,
    this.footer,
    this.scrollable = true,
    this.bodyPadding = const EdgeInsets.fromLTRB(20, 4, 20, 16),
    this.headerTrailing,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final bool danger;
  final bool showClose;
  final double width;
  final Widget child;
  final Widget? footer;
  final bool scrollable;
  final EdgeInsets bodyPadding;
  final Widget? headerTrailing;

  @override
  Widget build(BuildContext context) {
    final c = WColors.of(context);
    final media = MediaQuery.of(context);
    final narrow = media.size.width < 600;
    final availableHeight = math.max(
      260.0,
      media.size.height - media.viewInsets.bottom,
    );
    final maxHeight = math.max(
      260.0,
      availableHeight * (narrow ? 0.86 : 0.82),
    );
    final maxWidth = math.max(
      280.0,
      media.size.width - (narrow ? 32.0 : 48.0),
    );
    return Dialog(
      elevation: c.isDark ? 0 : 8,
      shadowColor: c.shadow.withValues(alpha: 0.28),
      insetPadding: EdgeInsets.symmetric(
        horizontal: narrow ? 16 : 24,
        vertical: narrow ? 16 : 24,
      ),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: math.min(width, maxWidth),
          maxHeight: maxHeight,
        ),
        child: SizedBox(
          width: width,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(
                  20,
                  16,
                  14,
                  subtitle == null ? 13 : 14,
                ),
                child: Row(
                  crossAxisAlignment: subtitle == null
                      ? CrossAxisAlignment.center
                      : CrossAxisAlignment.start,
                  children: [
                    if (icon != null) ...[
                      Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          color: danger ? c.dangerSoft : c.brandSoft,
                          borderRadius: BorderRadius.circular(WRadius.sm),
                        ),
                        alignment: Alignment.center,
                        child: Icon(
                          icon,
                          size: 16,
                          color: danger ? c.danger : c.brand,
                        ),
                      ),
                      const SizedBox(width: 10),
                    ],
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            style: Theme.of(context).textTheme.headlineSmall,
                          ),
                          if (subtitle != null) ...[
                            const SizedBox(height: 3),
                            Text(
                              subtitle!,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: c.textSecondary,
                                    height: 1.4,
                                  ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    ?headerTrailing,
                    if (showClose)
                      WIconButton(
                        icon: Icons.close_rounded,
                        tooltip: '关闭',
                        size: 26,
                        iconSize: 16,
                        onPressed: () => Navigator.of(context).maybePop(),
                      ),
                  ],
                ),
              ),
              Divider(height: 1, color: c.border),
              Flexible(
                child: scrollable
                    ? SingleChildScrollView(padding: bodyPadding, child: child)
                    : Padding(padding: bodyPadding, child: child),
              ),
              if (footer != null) ...[
                Divider(height: 1, color: c.border),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 11, 16, 11),
                  child: footer!,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Footer row helper: right-aligned actions with an optional left slot.
class WDialogFooter extends StatelessWidget {
  const WDialogFooter({super.key, required this.actions, this.leading});

  final List<Widget> actions;
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        if (leading != null) ...[
          Flexible(child: leading!),
          const SizedBox(width: 8),
        ],
        const Spacer(),
        for (var i = 0; i < actions.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          actions[i],
        ],
      ],
    );
  }
}

/// Label + field wrapper used by every form in the app.
class WLabeledField extends StatelessWidget {
  const WLabeledField({
    super.key,
    required this.label,
    required this.child,
    this.helper,
    this.trailing,
  });

  final String label;
  final Widget child;
  final String? helper;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final c = WColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: c.textSecondary,
                  letterSpacing: 0.1,
                ),
              ),
            ),
            ?trailing,
          ],
        ),
        const SizedBox(height: 6),
        child,
        if (helper != null) ...[
          const SizedBox(height: 5),
          Text(
            helper!,
            style: Theme.of(context).textTheme.labelSmall
                ?.copyWith(color: c.textTertiary, height: 1.35),
          ),
        ],
      ],
    );
  }
}

/// Search input used on the vault page and in pickers.
class WSearchField extends StatelessWidget {
  const WSearchField({
    super.key,
    required this.controller,
    required this.hintText,
    this.onChanged,
    this.onSubmitted,
    this.trailing,
    this.shortcutHint,
    this.focusNode,
    this.autofocus = false,
    this.mobile = false,
  });

  final TextEditingController controller;
  final String hintText;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final Widget? trailing;
  final String? shortcutHint;
  final FocusNode? focusNode;
  final bool autofocus;
  final bool mobile;

  @override
  Widget build(BuildContext context) {
    final c = WColors.of(context);
    final effectiveTrailing =
        trailing ??
        (shortcutHint != null
            ? Padding(
                padding: const EdgeInsets.only(right: 6),
                child: WShortcutBadge(label: shortcutHint!),
              )
            : null);
    final mobileBorder = mobile
        ? OutlineInputBorder(
            borderRadius: BorderRadius.circular(WRadius.md),
            borderSide: BorderSide(color: c.border),
          )
        : null;
    final mobileFocusedBorder = mobile
        ? OutlineInputBorder(
            borderRadius: BorderRadius.circular(WRadius.md),
            borderSide: BorderSide(color: c.brand, width: 1.5),
          )
        : null;
    return SizedBox(
      height: mobile ? 44 : 34,
      child: TextField(
        controller: controller,
        focusNode: focusNode,
        autofocus: autofocus,
        onChanged: onChanged,
        onSubmitted: onSubmitted,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: c.textPrimary,
          fontSize: mobile ? 14.5 : null,
        ),
        decoration: InputDecoration(
          hintText: hintText,
          isDense: !mobile,
          contentPadding: mobile
              ? const EdgeInsets.symmetric(horizontal: 12, vertical: 11)
              : const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          fillColor: c.surfaceMuted,
          border: mobileBorder,
          enabledBorder: mobileBorder,
          focusedBorder: mobileFocusedBorder,
          prefixIcon: Icon(
            Icons.search_rounded,
            size: mobile ? 19 : 16,
            color: c.textTertiary,
          ),
          prefixIconConstraints: mobile
              ? const BoxConstraints(minWidth: 40, minHeight: 40)
              : const BoxConstraints(minWidth: 32, minHeight: 32),
          suffixIcon: effectiveTrailing,
          suffixIconConstraints: mobile
              ? const BoxConstraints(minWidth: 40, minHeight: 40)
              : const BoxConstraints(minWidth: 30, minHeight: 30),
        ),
      ),
    );
  }
}

/// Segmented control used for 全部 / 回收站.
class WSegmented<T> extends StatelessWidget {
  const WSegmented({
    super.key,
    required this.segments,
    required this.value,
    required this.onChanged,
    this.height = 30,
  });

  final List<(T, String, IconData?)> segments;
  final T value;
  final ValueChanged<T> onChanged;
  final double height;

  @override
  Widget build(BuildContext context) {
    final c = WColors.of(context);
    return Container(
      height: height,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: c.surfaceMuted,
        borderRadius: BorderRadius.circular(WRadius.sm),
        border: Border.all(color: c.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final segment in segments)
            _segment(
              context,
              selected: segment.$1 == value,
              label: segment.$2,
              icon: segment.$3,
              onTap: () => onChanged(segment.$1),
            ),
        ],
      ),
    );
  }

  Widget _segment(
    BuildContext context, {
    required bool selected,
    required String label,
    required IconData? icon,
    required VoidCallback onTap,
  }) {
    final c = WColors.of(context);
    return Material(
      color: selected ? c.surface : Colors.transparent,
      borderRadius: BorderRadius.circular(WRadius.xs),
      child: InkWell(
        borderRadius: BorderRadius.circular(WRadius.xs),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(WRadius.xs),
            border: selected ? Border.all(color: c.border) : null,
            boxShadow: selected ? WShadows.card(c) : null,
          ),
          child: Row(
            children: [
              if (icon != null) ...[
                Icon(
                  icon,
                  size: 13,
                  color: selected ? c.textPrimary : c.textTertiary,
                ),
                const SizedBox(width: 5),
              ],
              Text(
                label,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  color: selected ? c.textPrimary : c.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Horizontal, non-wrapping filter chips with counts.
class WFilterChips extends StatelessWidget {
  const WFilterChips({
    super.key,
    required this.labels,
    required this.selectedIndex,
    required this.onSelected,
    this.mobile = false,
  });

  final List<String> labels;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final bool mobile;

  @override
  Widget build(BuildContext context) {
    final c = WColors.of(context);
    final radius = mobile ? WRadius.pill : WRadius.xs;
    return SizedBox(
      height: mobile ? 36 : 26,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 1),
        itemCount: labels.length,
        separatorBuilder: (_, _) => SizedBox(width: mobile ? 8 : 6),
        itemBuilder: (context, index) {
          final selected = index == selectedIndex;
          return Material(
            color: selected ? c.brandSoft : c.surface,
            borderRadius: BorderRadius.circular(radius),
            child: InkWell(
              borderRadius: BorderRadius.circular(radius),
              hoverColor: selected ? null : c.hover,
              onTap: () => onSelected(index),
              child: Container(
                padding: EdgeInsets.symmetric(horizontal: mobile ? 13 : 9),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(radius),
                  border: Border.all(
                    color: selected
                        ? c.brand.withValues(alpha: 0.28)
                        : c.border,
                  ),
                ),
                child: Row(
                  children: [
                    if (selected) ...[
                      Icon(
                        Icons.check_rounded,
                        size: mobile ? 14 : 12,
                        color: c.brand,
                      ),
                      const SizedBox(width: 4),
                    ],
                    Text(
                      labels[index],
                      style: TextStyle(
                        fontSize: mobile ? 13 : 11.5,
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.w500,
                        color: selected
                            ? (c.isDark ? const Color(0xFFBBD0FF) : c.brand)
                            : c.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Menu model: sections of commands. `id`/callbacks are wired by the screen;
/// this layer only knows how to present them.
class WMenuEntry {
  const WMenuEntry({
    required this.label,
    this.icon,
    this.onTap,
    this.danger = false,
    this.enabled = true,
    this.checked,
    this.trailing,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  final bool danger;
  final bool enabled;
  final bool? checked;
  final String? trailing;
}

class WMenuSection {
  const WMenuSection({this.label, required this.entries});
  final String? label;
  final List<WMenuEntry> entries;
}

/// Grouped popover menu with icons, section headers, check marks and danger
/// styling. MenuAnchor handles edge flipping and keyboard navigation.
class WCommandMenu extends StatefulWidget {
  const WCommandMenu({
    super.key,
    required this.sections,
    required this.triggerBuilder,
    this.width = 252,
  });

  final List<WMenuSection> sections;
  final Widget Function(
    BuildContext context,
    MenuController controller,
    bool open,
  )
  triggerBuilder;
  final double width;

  @override
  State<WCommandMenu> createState() => _WCommandMenuState();
}

class _WCommandMenuState extends State<WCommandMenu> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final c = WColors.of(context);
    final theme = Theme.of(context);
    final sections = widget.sections;
    return MenuAnchor(
      alignmentOffset: const Offset(0, 4),
      consumeOutsideTap: true,
      clipBehavior: Clip.none,
      onOpen: () {
        if (!_open) setState(() => _open = true);
      },
      onClose: () {
        if (_open) setState(() => _open = false);
      },
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(c.surface),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        elevation: const WidgetStatePropertyAll(0),
        shadowColor: const WidgetStatePropertyAll(Colors.transparent),
        padding: const WidgetStatePropertyAll(EdgeInsets.all(4)),
        side: WidgetStatePropertyAll(BorderSide(color: c.border)),
        shape: const WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(WRadius.lg)),
          ),
        ),
        minimumSize: WidgetStatePropertyAll(Size(widget.width, 0)),
        maximumSize: WidgetStatePropertyAll(
          Size(widget.width, double.infinity),
        ),
      ),
      menuChildren: [
        for (var s = 0; s < sections.length; s++) ...[
          if (s > 0)
            const Padding(
              padding: EdgeInsets.fromLTRB(4, 4, 4, 4),
              child: Divider(height: 1),
            ),
          if (sections[s].label case final label?)
            Padding(
              padding: EdgeInsets.fromLTRB(8, s == 0 ? 6 : 8, 8, 4),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.4,
                  color: c.textTertiary,
                ),
              ),
            ),
          for (final entry in sections[s].entries)
            _menuItem(context, theme, c, entry),
        ],
      ],
      builder: (context, controller, _) =>
          widget.triggerBuilder(context, controller, _open),
    );
  }

  Widget _menuItem(
    BuildContext context,
    ThemeData theme,
    WColors c,
    WMenuEntry entry,
  ) {
    final fg = !entry.enabled
        ? c.textTertiary.withValues(alpha: 0.55)
        : entry.danger
        ? c.danger
        : c.textPrimary;
    return MenuItemButton(
      onPressed: entry.enabled ? entry.onTap : null,
      requestFocusOnHover: false,
      style: ButtonStyle(
        fixedSize: const WidgetStatePropertyAll(Size.fromHeight(30)),
        minimumSize: const WidgetStatePropertyAll(Size(0, 30)),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 8),
        ),
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.hovered) ||
              states.contains(WidgetState.focused) ||
              states.contains(WidgetState.pressed)) {
            return entry.danger ? c.dangerSoft : c.hover;
          }
          return Colors.transparent;
        }),
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
        shape: const WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(WRadius.xs)),
          ),
        ),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 18,
            child: entry.icon == null
                ? null
                : Icon(
                    entry.icon,
                    size: 15,
                    color: entry.enabled
                        ? (entry.danger ? c.danger : c.textTertiary)
                        : fg,
                  ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              entry.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontSize: theme.platform == TargetPlatform.windows ? 13 : 12.5,
                fontWeight: theme.platform == TargetPlatform.windows
                    ? FontWeight.w400
                    : FontWeight.w500,
                color: fg,
              ),
            ),
          ),
          if (entry.trailing case final trailing?) ...[
            const SizedBox(width: 8),
            Text(
              trailing,
              style: theme.textTheme.labelSmall?.copyWith(
                color: c.textTertiary,
              ),
            ),
          ],
          if (entry.checked case final checked?) ...[
            const SizedBox(width: 6),
            SizedBox(
              width: 14,
              child: checked
                  ? Icon(Icons.check_rounded, size: 14, color: c.brand)
                  : null,
            ),
          ],
        ],
      ),
    );
  }
}

/// A single account row in the vault list.
class WAccountRow extends StatefulWidget {
  const WAccountRow({
    super.key,
    required this.title,
    required this.meta,
    required this.menuSections,
    this.group,
    this.avatar,
    this.pinned = false,
    this.active = false,
    this.selected = false,
    this.selectionMode = false,
    this.showCheckbox = false,
    this.showPin = true,
    this.compactActions = false,
    this.onOpen,
    this.onDoubleTap,
    this.onTogglePin,
    this.onCopyPassword,
    this.onCopyUsername,
    this.onEdit,
    this.onToggleSelect,
    this.onPurge,
  });

  final String title;
  final String meta;
  final String? group;
  final Widget? avatar;
  final bool pinned;
  final bool active;
  final bool selected;
  final bool selectionMode;
  final bool showCheckbox;
  final bool showPin;
  final bool compactActions;
  final List<WMenuSection> menuSections;
  final VoidCallback? onOpen;
  final VoidCallback? onDoubleTap;
  final VoidCallback? onTogglePin;
  final VoidCallback? onCopyPassword;
  final VoidCallback? onCopyUsername;
  final VoidCallback? onEdit;
  final VoidCallback? onToggleSelect;
  final VoidCallback? onPurge;

  @override
  State<WAccountRow> createState() => _WAccountRowState();
}

class _WAccountRowState extends State<WAccountRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = WColors.of(context);
    final theme = Theme.of(context);
    final highlighted = widget.selected || widget.active;
    final actionsVisible = _hover || highlighted;
    final showGroupTag =
        widget.group != null &&
        widget.group!.isNotEmpty &&
        widget.group!.trim().toLowerCase() != widget.title.trim().toLowerCase();
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Material(
        color: highlighted
            ? c.brandSoft
            : (_hover ? c.hover : Colors.transparent),
        child: InkWell(
          onTap: widget.selectionMode ? widget.onToggleSelect : widget.onOpen,
          onDoubleTap: widget.selectionMode ? null : widget.onDoubleTap,
          hoverColor: Colors.transparent,
          child: Container(
            padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(
                  color: widget.active && !widget.selectionMode
                      ? c.brand
                      : Colors.transparent,
                  width: 2.5,
                ),
                bottom: BorderSide(color: c.border.withValues(alpha: 0.6)),
              ),
            ),
            child: Row(
              children: [
                if (widget.showCheckbox) ...[
                  Checkbox(
                    value: widget.selected,
                    onChanged: (_) => widget.onToggleSelect?.call(),
                  ),
                  const SizedBox(width: 8),
                ],
                widget.avatar ??
                    WAvatar(label: widget.title, seed: widget.title, size: 32),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          if (widget.pinned && widget.compactActions) ...[
                            Icon(
                              Icons.push_pin_rounded,
                              size: 11.5,
                              color: c.brand,
                            ),
                            const SizedBox(width: 4),
                          ],
                          Flexible(
                            child: Text(
                              widget.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontSize:
                                    theme.platform == TargetPlatform.windows
                                    ? 13.5
                                    : 13,
                                fontWeight:
                                    theme.platform == TargetPlatform.windows
                                    ? FontWeight.w400
                                    : FontWeight.w600,
                                color: widget.active ? c.brand : c.textPrimary,
                              ),
                            ),
                          ),
                          if (showGroupTag) ...[
                            const SizedBox(width: 6),
                            _groupTag(context, widget.group!),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        widget.meta,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontSize: theme.platform == TargetPlatform.windows
                              ? 12
                              : 11.5,
                          height: 1.3,
                          color: c.textSecondary.withValues(alpha: 0.85),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                if (!widget.selectionMode) ...[
                  if (widget.showPin && !widget.compactActions)
                    AnimatedOpacity(
                      duration: const Duration(milliseconds: 120),
                      opacity: actionsVisible || widget.pinned ? 1 : 0,
                      child: WIconButton(
                        icon: widget.pinned
                            ? Icons.push_pin_rounded
                            : Icons.push_pin_outlined,
                        tooltip: widget.pinned ? '取消置顶' : '置顶',
                        onPressed: widget.onTogglePin,
                        active: widget.pinned,
                        size: 26,
                        iconSize: 15,
                      ),
                    ),
                  if (widget.onPurge != null)
                    AnimatedOpacity(
                      duration: const Duration(milliseconds: 120),
                      opacity: actionsVisible ? 1 : 0.45,
                      child: WIconButton(
                        icon: Icons.delete_forever_outlined,
                        tooltip: '从回收站清除',
                        color: c.danger,
                        onPressed: widget.onPurge,
                        size: 26,
                        iconSize: 15,
                      ),
                    ),
                  AnimatedOpacity(
                    duration: const Duration(milliseconds: 120),
                    opacity: actionsVisible
                        ? 1
                        : (widget.compactActions ? 0 : 0.35),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        WIconButton(
                          icon: Icons.key_outlined,
                          tooltip: '复制密码',
                          onPressed: widget.onCopyPassword,
                          size: 26,
                          iconSize: 15,
                        ),
                        if (!widget.compactActions)
                          WIconButton(
                            icon: Icons.edit_outlined,
                            tooltip: '编辑详情',
                            onPressed: widget.onEdit,
                            size: 26,
                            iconSize: 15,
                          ),
                        WCommandMenu(
                          width: 224,
                          sections: widget.menuSections,
                          triggerBuilder: (context, controller, open) =>
                              WIconButton(
                                icon: Icons.more_horiz_rounded,
                                tooltip: '更多操作',
                                active: open,
                                size: 26,
                                iconSize: 16,
                                onPressed: () => open
                                    ? controller.close()
                                    : controller.open(),
                              ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _groupTag(BuildContext context, String group) {
    final c = WColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: c.surfaceMuted,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: c.border),
      ),
      child: Text(
        group,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w500,
          height: 1.2,
          color: c.textSecondary,
        ),
      ),
    );
  }
}

/// Page-level empty state.
class WEmptyState extends StatelessWidget {
  const WEmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.action,
  });

  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final c = WColors.of(context);
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 46,
              height: 46,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: c.surfaceMuted,
                borderRadius: BorderRadius.circular(WRadius.lg),
                border: Border.all(color: c.border),
              ),
              child: Icon(icon, size: 22, color: c.textTertiary),
            ),
            const SizedBox(height: 14),
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: 5),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: c.textSecondary,
              ),
            ),
            if (action != null) ...[const SizedBox(height: 16), action!],
          ],
        ),
      ),
    );
  }
}

/// Floating "add account" action pinned to the bottom-right of the vault list.
class WFloatingAction extends StatelessWidget {
  const WFloatingAction({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon = Icons.add_rounded,
    this.mobile = false,
  });

  final String label;
  final VoidCallback onPressed;
  final IconData icon;
  final bool mobile;

  @override
  Widget build(BuildContext context) {
    final c = WColors.of(context);
    final radius = mobile ? WRadius.lg : WRadius.md;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        boxShadow: WShadows.floating(c),
      ),
      child: Material(
        color: c.brand,
        borderRadius: BorderRadius.circular(radius),
        child: InkWell(
          borderRadius: BorderRadius.circular(radius),
          onTap: onPressed,
          child: Padding(
            padding: mobile
                ? const EdgeInsets.symmetric(horizontal: 18, vertical: 14)
                : const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: mobile ? 20 : 16, color: c.onBrand),
                SizedBox(width: mobile ? 8 : 6),
                Text(
                  label,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    fontSize: mobile ? 14.5 : 12.5,
                    fontWeight: FontWeight.w600,
                    color: c.onBrand,
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

/// Touch-first card row for mobile account lists.
class WMobileAccountTile extends StatelessWidget {
  const WMobileAccountTile({
    super.key,
    required this.title,
    required this.meta,
    this.group,
    this.pinned = false,
    this.hasConflict = false,
    this.selectionMode = false,
    this.selected = false,
    this.avatar,
    this.onOpen,
    this.onLongPress,
    this.onToggleSelect,
    this.onQuickAction,
    this.quickActionIcon = Icons.copy_rounded,
    this.quickActionTooltip = '复制密码',
  });

  final String title;
  final String meta;
  final String? group;
  final bool pinned;
  final bool hasConflict;
  final bool selectionMode;
  final bool selected;
  final Widget? avatar;
  final VoidCallback? onOpen;
  final VoidCallback? onLongPress;
  final VoidCallback? onToggleSelect;
  final VoidCallback? onQuickAction;
  final IconData quickActionIcon;
  final String quickActionTooltip;

  @override
  Widget build(BuildContext context) {
    final c = WColors.of(context);
    final theme = Theme.of(context);
    final showGroupTag =
        group != null &&
        group!.isNotEmpty &&
        group!.trim().toLowerCase() != title.trim().toLowerCase();
    return WSurface(
      radius: WRadius.md,
      color: selected ? c.brandSoft : c.surface,
      border: true,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(WRadius.md),
          onTap: selectionMode ? onToggleSelect : onOpen,
          onLongPress: selectionMode ? null : onLongPress,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
            child: Row(
              children: [
                if (selectionMode) ...[
                  Container(
                    width: 22,
                    height: 22,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: selected ? c.brand : Colors.transparent,
                      border: Border.all(
                        color: hasConflict
                            ? c.border
                            : (selected ? c.brand : c.borderStrong),
                        width: 1.5,
                      ),
                    ),
                    child: selected
                        ? Icon(Icons.check_rounded, size: 14, color: c.onBrand)
                        : null,
                  ),
                  const SizedBox(width: 12),
                ],
                avatar ?? WAvatar(label: title, seed: title, size: 40),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          if (pinned) ...[
                            Icon(
                              Icons.push_pin_rounded,
                              size: 13,
                              color: c.brand,
                            ),
                            const SizedBox(width: 4),
                          ],
                          Flexible(
                            child: Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                color: c.textPrimary,
                              ),
                            ),
                          ),
                          if (showGroupTag) ...[
                            const SizedBox(width: 6),
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 96),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: c.surfaceMuted,
                                  borderRadius: BorderRadius.circular(5),
                                  border: Border.all(color: c.border),
                                ),
                                child: Text(
                                  group!,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w500,
                                    height: 1.15,
                                    color: c.textSecondary,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        meta,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontSize: 13,
                          height: 1.35,
                          color: hasConflict ? c.warning : c.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                if (!selectionMode && onQuickAction != null) ...[
                  const SizedBox(width: 8),
                  Tooltip(
                    message: quickActionTooltip,
                    child: Material(
                      color: c.surfaceMuted,
                      borderRadius: BorderRadius.circular(WRadius.sm),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(WRadius.sm),
                        onTap: onQuickAction,
                        child: SizedBox(
                          width: 40,
                          height: 40,
                          child: Icon(
                            quickActionIcon,
                            size: 18,
                            color: c.textSecondary,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Grouped settings section for mobile screens.
class WMobileSettingsGroup extends StatelessWidget {
  const WMobileSettingsGroup({
    super.key,
    required this.title,
    required this.children,
  });

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final c = WColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
          child: Text(
            title,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: c.textTertiary,
            ),
          ),
        ),
        WSurface(
          radius: WRadius.lg,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(WRadius.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < children.length; i++) ...[
                  if (i > 0) Divider(height: 1, indent: 58, color: c.border),
                  children[i],
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Touch-friendly setting row inside [WMobileSettingsGroup].
class WMobileSettingTile extends StatelessWidget {
  const WMobileSettingTile({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailingText,
    this.trailing,
    this.danger = false,
    this.enabled = true,
    this.showChevron = true,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final String? trailingText;
  final Widget? trailing;
  final bool danger;
  final bool enabled;
  final bool showChevron;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = WColors.of(context);
    final fg = danger ? c.danger : c.textPrimary;
    final badgeBg = danger ? c.dangerSoft : c.brandSoft;
    final badgeFg = danger ? c.danger : c.brand;
    return Opacity(
      opacity: enabled ? 1 : 0.52,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: enabled ? onTap : null,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 54),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: badgeBg,
                      borderRadius: BorderRadius.circular(WRadius.sm),
                    ),
                    child: Icon(icon, size: 18, color: badgeFg),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          title,
                          style: TextStyle(
                            fontSize: 14.5,
                            fontWeight: FontWeight.w500,
                            color: fg,
                          ),
                        ),
                        if (subtitle != null) ...[
                          const SizedBox(height: 2),
                          Text(
                            subtitle!,
                            style: TextStyle(
                              fontSize: 12.5,
                              color: c.textSecondary,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (trailing != null) ...[
                    const SizedBox(width: 8),
                    trailing!,
                  ] else if (trailingText != null) ...[
                    const SizedBox(width: 8),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 130),
                      child: Text(
                        trailingText!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 13, color: c.textSecondary),
                      ),
                    ),
                  ],
                  if (showChevron && onTap != null && trailing == null) ...[
                    const SizedBox(width: 4),
                    Icon(
                      Icons.chevron_right_rounded,
                      size: 18,
                      color: c.textTertiary,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Monospaced technical text (hosts, URLs, WebDAV paths).
class WMono extends StatelessWidget {
  const WMono(
    this.text, {
    super.key,
    this.size = 11.5,
    this.color,
    this.maxLines = 1,
    this.weight = FontWeight.w400,
  });

  final String text;
  final double size;
  final Color? color;
  final int maxLines;
  final FontWeight weight;

  @override
  Widget build(BuildContext context) {
    final c = WColors.of(context);
    return Text(
      text,
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontFamily: wMonoFamily,
        fontSize: size,
        height: 1.4,
        fontWeight: weight,
        color: color ?? c.textTertiary,
        letterSpacing: -0.1,
      ),
    );
  }
}

/// Subtle keyboard shortcut cap (e.g. `⌘K`, `⌘F`).
class WShortcutBadge extends StatelessWidget {
  const WShortcutBadge({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final c = WColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: c.border),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontFamily: wMonoFamily,
          fontSize: 10.5,
          fontWeight: FontWeight.w500,
          height: 1.1,
          color: c.textTertiary,
        ),
      ),
    );
  }
}

/// Pure visual password strength meter based on length and character classes.
class WPasswordStrength extends StatelessWidget {
  const WPasswordStrength({super.key, required this.password});

  final String password;

  static (int score, String label) evaluate(String value) {
    if (value.isEmpty) return (0, '未填写');
    var classes = 0;
    if (RegExp(r'[a-z]').hasMatch(value)) classes++;
    if (RegExp(r'[A-Z]').hasMatch(value)) classes++;
    if (RegExp(r'[0-9]').hasMatch(value)) classes++;
    if (RegExp(r'[^a-zA-Z0-9]').hasMatch(value)) classes++;
    final len = value.characters.length;
    if (len >= 14 && classes >= 3) return (4, '强');
    if (len >= 10 && classes >= 3) return (3, '较强');
    if (len >= 8 && classes >= 2) return (2, '一般');
    return (1, '较弱');
  }

  @override
  Widget build(BuildContext context) {
    if (password.isEmpty) return const SizedBox.shrink();
    final c = WColors.of(context);
    final (score, label) = evaluate(password);
    final color = switch (score) {
      4 => c.success,
      3 => c.brand,
      2 => c.warning,
      _ => c.danger,
    };
    return Row(
      children: [
        for (var i = 1; i <= 4; i++) ...[
          if (i > 1) const SizedBox(width: 4),
          Expanded(
            child: Container(
              height: 3,
              decoration: BoxDecoration(
                color: i <= score ? color : c.border,
                borderRadius: BorderRadius.circular(WRadius.pill),
              ),
            ),
          ),
        ],
        const SizedBox(width: 8),
        Text(
          '$label · ${password.characters.length} 位',
          style: TextStyle(
            fontSize: 10.8,
            fontWeight: FontWeight.w500,
            color: color,
          ),
        ),
      ],
    );
  }
}

/// Desktop master-detail inspector for a selected vault account.
class WAccountDetailPanel extends StatelessWidget {
  const WAccountDetailPanel({
    super.key,
    required this.title,
    required this.username,
    required this.password,
    required this.url,
    required this.notes,
    required this.groups,
    required this.pinned,
    required this.trash,
    required this.hasConflict,
    required this.revealPassword,
    required this.onToggleReveal,
    required this.onCopyUsername,
    required this.onCopyPassword,
    required this.onCopyUrl,
    required this.onCopyNotes,
    required this.onTogglePin,
    required this.onEdit,
    required this.onHistory,
    this.onExport,
    this.onTrashOrRestore,
    this.onPurge,
    this.avatar,
    this.busy = false,
  });

  final String title;
  final String username;
  final String password;
  final String url;
  final String notes;
  final List<String> groups;
  final bool pinned;
  final bool trash;
  final bool hasConflict;
  final bool revealPassword;
  final VoidCallback onToggleReveal;
  final VoidCallback? onCopyUsername;
  final VoidCallback? onCopyPassword;
  final VoidCallback? onCopyUrl;
  final VoidCallback? onCopyNotes;
  final VoidCallback? onTogglePin;
  final VoidCallback? onEdit;
  final VoidCallback? onHistory;
  final VoidCallback? onExport;
  final VoidCallback? onTrashOrRestore;
  final VoidCallback? onPurge;
  final Widget? avatar;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final c = WColors.of(context);
    final theme = Theme.of(context);
    final displayTitle = title.isEmpty ? '未命名账号' : title;
    final visibleGroups = groups
        .where(
          (g) =>
              g.trim().isNotEmpty &&
              g.trim().toLowerCase() != displayTitle.trim().toLowerCase(),
        )
        .toList();

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header card
          WSurface(
            radius: WRadius.lg,
            padding: const EdgeInsets.fromLTRB(18, 16, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    avatar ??
                        WAvatar(
                          label: displayTitle,
                          seed: displayTitle,
                          size: 42,
                        ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            displayTitle,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.headlineSmall?.copyWith(
                              fontSize: 17,
                            ),
                          ),
                          if (visibleGroups.isNotEmpty || pinned || trash) ...[
                            const SizedBox(height: 6),
                            Wrap(
                              spacing: 6,
                              runSpacing: 4,
                              children: [
                                if (pinned)
                                  const WStatusPill(
                                    label: '已置顶',
                                    icon: Icons.push_pin_rounded,
                                    tone: WTone.info,
                                    compact: true,
                                  ),
                                if (trash)
                                  const WStatusPill(
                                    label: '在回收站中',
                                    icon: Icons.delete_outline_rounded,
                                    tone: WTone.warning,
                                    compact: true,
                                  ),
                                for (final g in visibleGroups)
                                  WStatusPill(label: g, compact: true),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    if (!trash)
                      WIconButton(
                        icon: pinned
                            ? Icons.push_pin_rounded
                            : Icons.push_pin_outlined,
                        tooltip: pinned ? '取消置顶' : '置顶',
                        active: pinned,
                        onPressed: busy ? null : onTogglePin,
                      ),
                    const SizedBox(width: 4),
                    SizedBox(
                      height: 30,
                      child: OutlinedButton.icon(
                        onPressed: busy ? null : onEdit,
                        icon: const Icon(Icons.edit_outlined, size: 14),
                        label: Text(hasConflict ? '解决冲突' : '编辑'),
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(0, 30),
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          textStyle: theme.textTheme.labelLarge?.copyWith(
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                if (hasConflict) ...[
                  const SizedBox(height: 14),
                  WNote(
                    tone: WTone.warning,
                    child: const Text(
                      '检测到多设备并发修改，点击右上角「解决冲突」选择保留的版本。',
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),
          // Credentials surface
          WSurface(
            radius: WRadius.lg,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _detailRow(
                  context,
                  label: '用户名',
                  value: username.isEmpty ? '未填写' : username,
                  muted: username.isEmpty,
                  actions: [
                    if (username.isNotEmpty)
                      _copyChip(
                        context,
                        label: '复制',
                        icon: Icons.copy_outlined,
                        onTap: onCopyUsername,
                      ),
                  ],
                ),
                Divider(height: 1, color: c.border),
                _detailRow(
                  context,
                  label: '密码',
                  value: password.isEmpty
                      ? '未填写'
                      : (revealPassword ? password : '••••••••••••••••'),
                  muted: password.isEmpty,
                  mono: revealPassword,
                  extra: password.isEmpty
                      ? null
                      : Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: WPasswordStrength(password: password),
                        ),
                  actions: [
                    if (password.isNotEmpty)
                      WIconButton(
                        icon: revealPassword
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined,
                        tooltip: revealPassword ? '隐藏密码' : '显示密码',
                        size: 28,
                        iconSize: 16,
                        onPressed: onToggleReveal,
                      ),
                    if (password.isNotEmpty) ...[
                      const SizedBox(width: 4),
                      _copyChip(
                        context,
                        label: '复制密码',
                        icon: Icons.key_outlined,
                        primary: true,
                        onTap: onCopyPassword,
                      ),
                    ],
                  ],
                ),
                if (url.isNotEmpty) ...[
                  Divider(height: 1, color: c.border),
                  _detailRow(
                    context,
                    label: '网址',
                    value: url,
                    mono: true,
                    actions: [
                      _copyChip(
                        context,
                        label: '复制',
                        icon: Icons.copy_outlined,
                        onTap: onCopyUrl,
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          if (notes.trim().isNotEmpty) ...[
            const SizedBox(height: 12),
            WSurface(
              radius: WRadius.lg,
              padding: const EdgeInsets.fromLTRB(16, 12, 12, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '备注',
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                            color: c.textTertiary,
                          ),
                        ),
                      ),
                      WIconButton(
                        icon: Icons.copy_outlined,
                        tooltip: '复制备注',
                        size: 26,
                        iconSize: 14,
                        onPressed: onCopyNotes,
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  SelectableText(
                    notes,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: c.textPrimary,
                      height: 1.55,
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 14),
          // Secondary actions bar
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _secondaryAction(
                context,
                icon: Icons.history_rounded,
                label: '历史版本',
                onTap: busy ? null : onHistory,
              ),
              if (onExport != null)
                _secondaryAction(
                  context,
                  icon: Icons.image_outlined,
                  label: '导出账号',
                  onTap: busy ? null : onExport,
                ),
              if (onTrashOrRestore != null)
                _secondaryAction(
                  context,
                  icon: trash
                      ? Icons.restore_rounded
                      : Icons.delete_outline_rounded,
                  label: trash ? '恢复账号' : '移入回收站',
                  danger: !trash,
                  onTap: busy ? null : onTrashOrRestore,
                ),
              if (onPurge != null)
                _secondaryAction(
                  context,
                  icon: Icons.delete_forever_outlined,
                  label: '彻底清除',
                  danger: true,
                  onTap: busy ? null : onPurge,
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _detailRow(
    BuildContext context, {
    required String label,
    required String value,
    required List<Widget> actions,
    bool muted = false,
    bool mono = false,
    Widget? extra,
  }) {
    final c = WColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 11.2,
                        fontWeight: FontWeight.w600,
                        color: c.textTertiary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    SelectableText(
                      value,
                      style: TextStyle(
                        fontFamily: mono ? wMonoFamily : null,
                        fontSize: mono ? 12.8 : 13.5,
                        fontWeight: muted ? FontWeight.w400 : FontWeight.w500,
                        color: muted ? c.textTertiary : c.textPrimary,
                        letterSpacing: !mono && label == '密码' && !muted
                            ? 2.0
                            : 0,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              ...actions,
            ],
          ),
          ?extra,
        ],
      ),
    );
  }

  Widget _copyChip(
    BuildContext context, {
    required String label,
    required IconData icon,
    required VoidCallback? onTap,
    bool primary = false,
  }) {
    final c = WColors.of(context);
    return Material(
      color: primary ? c.brandSoft : c.surfaceMuted,
      borderRadius: BorderRadius.circular(WRadius.sm),
      child: InkWell(
        borderRadius: BorderRadius.circular(WRadius.sm),
        hoverColor: primary ? c.brand.withValues(alpha: 0.14) : c.hover,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 13.5,
                color: primary ? c.brand : c.textSecondary,
              ),
              const SizedBox(width: 5),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11.8,
                  fontWeight: FontWeight.w600,
                  color: primary ? c.brand : c.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _secondaryAction(
    BuildContext context, {
    required IconData icon,
    required String label,
    required VoidCallback? onTap,
    bool danger = false,
  }) {
    final c = WColors.of(context);
    final fg = danger ? c.danger : c.textSecondary;
    return Material(
      color: c.surface,
      borderRadius: BorderRadius.circular(WRadius.sm),
      child: InkWell(
        borderRadius: BorderRadius.circular(WRadius.sm),
        hoverColor: danger ? c.dangerSoft : c.hover,
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(WRadius.sm),
            border: Border.all(
              color: danger ? c.danger.withValues(alpha: 0.25) : c.border,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: fg),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11.8,
                  fontWeight: FontWeight.w500,
                  color: fg,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
