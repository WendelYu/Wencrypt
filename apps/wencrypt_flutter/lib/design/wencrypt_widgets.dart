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
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final double size;
  final double iconSize;
  final Color? color;
  final bool active;
  final bool busy;

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
            child: Center(
              child: busy
                  ? SizedBox(
                      width: iconSize - 3,
                      height: iconSize - 3,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.7,
                        color: c.brand,
                      ),
                    )
                  : Icon(icon, size: iconSize, color: foreground),
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
      dark ? 0.35 : 0.46,
      dark ? 0.26 : 0.94,
    ).toColor();
    final fg = HSLColor.fromAHSL(
      1,
      hue.toDouble(),
      dark ? 0.55 : 0.52,
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
        border: Border.all(color: fg.withValues(alpha: dark ? 0.16 : 0.10)),
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
    this.width = 480,
    this.footer,
    this.scrollable = true,
    this.bodyPadding = const EdgeInsets.fromLTRB(20, 4, 20, 16),
    this.headerTrailing,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
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
    final maxHeight = math.max(320.0, media.size.height * 0.82);
    final maxWidth = math.max(280.0, media.size.width - 48);
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
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
                padding: const EdgeInsets.fromLTRB(20, 18, 14, 14),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (icon != null) ...[
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Icon(icon, size: 17, color: c.brand),
                      ),
                      const SizedBox(width: 9),
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
                            const SizedBox(height: 4),
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
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
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
        ?leading,
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
    this.focusNode,
    this.autofocus = false,
  });

  final TextEditingController controller;
  final String hintText;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final Widget? trailing;
  final FocusNode? focusNode;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final c = WColors.of(context);
    return SizedBox(
      height: 34,
      child: TextField(
        controller: controller,
        focusNode: focusNode,
        autofocus: autofocus,
        onChanged: onChanged,
        onSubmitted: onSubmitted,
        style: Theme.of(context).textTheme.bodyMedium
            ?.copyWith(color: c.textPrimary),
        decoration: InputDecoration(
          hintText: hintText,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 10,
            vertical: 9,
          ),
          fillColor: c.surfaceMuted,
          prefixIcon: Icon(
            Icons.search_rounded,
            size: 16,
            color: c.textTertiary,
          ),
          prefixIconConstraints: const BoxConstraints(
            minWidth: 32,
            minHeight: 32,
          ),
          suffixIcon: trailing,
          suffixIconConstraints: const BoxConstraints(
            minWidth: 30,
            minHeight: 30,
          ),
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
  });

  final List<String> labels;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final c = WColors.of(context);
    return SizedBox(
      height: 26,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 1),
        itemCount: labels.length,
        separatorBuilder: (_, _) => const SizedBox(width: 6),
        itemBuilder: (context, index) {
          final selected = index == selectedIndex;
          return Material(
            color: selected ? c.brandSoft : c.surface,
            borderRadius: BorderRadius.circular(WRadius.xs),
            child: InkWell(
              borderRadius: BorderRadius.circular(WRadius.xs),
              hoverColor: selected ? null : c.hover,
              onTap: () => onSelected(index),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 9),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(WRadius.xs),
                  border: Border.all(
                    color: selected
                        ? c.brand.withValues(alpha: 0.28)
                        : c.border,
                  ),
                ),
                child: Row(
                  children: [
                    if (selected) ...[
                      Icon(Icons.check_rounded, size: 12, color: c.brand),
                      const SizedBox(width: 4),
                    ],
                    Text(
                      labels[index],
                      style: TextStyle(
                        fontSize: 11.5,
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
                fontSize: 12.5,
                fontWeight: FontWeight.w500,
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
    this.selected = false,
    this.selectionMode = false,
    this.showCheckbox = false,
    this.showPin = true,
    this.onOpen,
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
  final bool selected;
  final bool selectionMode;
  final bool showCheckbox;
  final bool showPin;
  final List<WMenuSection> menuSections;
  final VoidCallback? onOpen;
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
    final actionsVisible = _hover || widget.selected;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Material(
        color: widget.selected
            ? c.brandSoft
            : (_hover ? c.hover : Colors.transparent),
        child: InkWell(
          onTap: widget.selectionMode ? widget.onToggleSelect : widget.onOpen,
          hoverColor: Colors.transparent,
          child: Container(
            padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: c.border.withValues(alpha: 0.7)),
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
                    WAvatar(label: widget.title, seed: widget.title, size: 30),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              widget.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontSize: 12.8,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          if (widget.group case final group?
                              when group.isNotEmpty) ...[
                            const SizedBox(width: 6),
                            _groupTag(context, group),
                          ],
                        ],
                      ),
                      const SizedBox(height: 1),
                      Text(
                        widget.meta,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontSize: 11.5,
                          height: 1.3,
                          color: c.textTertiary,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                if (!widget.selectionMode) ...[
                  if (widget.showPin)
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
                      opacity: actionsVisible ? 1 : 0.55,
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
                    opacity: actionsVisible ? 1 : 0.5,
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
                        WIconButton(
                          icon: Icons.person_outline_rounded,
                          tooltip: '查看账号详情',
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
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
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
  });

  final String label;
  final VoidCallback onPressed;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final c = WColors.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(WRadius.md),
        boxShadow: WShadows.floating(c),
      ),
      child: Material(
        color: c.brand,
        borderRadius: BorderRadius.circular(WRadius.md),
        child: InkWell(
          borderRadius: BorderRadius.circular(WRadius.md),
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 16, color: c.onBrand),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: Theme.of(context).textTheme.labelLarge
                      ?.copyWith(fontSize: 12.5, color: c.onBrand),
                ),
              ],
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
