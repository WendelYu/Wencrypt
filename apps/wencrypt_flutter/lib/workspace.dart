import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'design/wencrypt_theme.dart';
import 'design/wencrypt_widgets.dart';

class WorkspaceSection extends StatelessWidget {
  const WorkspaceSection({
    super.key,
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
    this.count,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;
  final int? count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 1),
      child: Material(
        color: selected ? colors.primaryContainer : Colors.transparent,
        borderRadius: BorderRadius.circular(7),
        child: InkWell(
          borderRadius: BorderRadius.circular(7),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 17,
                  color: selected ? colors.primary : colors.onSurfaceVariant,
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (count != null && count! > 0)
                  Text('$count', style: theme.textTheme.labelSmall),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class WorkspaceCommand {
  const WorkspaceCommand(this.label, this.icon, this.run);

  final String label;
  final IconData icon;
  final VoidCallback run;
}

Future<WorkspaceCommand?> showWorkspaceCommands(
  BuildContext context,
  List<WorkspaceCommand> commands,
) => showDialog<WorkspaceCommand>(
  context: context,
  builder: (_) => _CommandDialog(commands),
);

class _CommandDialog extends StatefulWidget {
  const _CommandDialog(this.commands);
  final List<WorkspaceCommand> commands;

  @override
  State<_CommandDialog> createState() => _CommandDialogState();
}

class _CommandDialogState extends State<_CommandDialog> {
  String _query = '';
  int _selected = 0;
  final _list = ScrollController();

  @override
  void dispose() {
    _list.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final matches = widget.commands
        .where((command) => command.label.toLowerCase().contains(_query))
        .toList();
    void move(int delta) {
      if (matches.isEmpty) return;
      setState(
        () => _selected = (_selected + delta).clamp(0, matches.length - 1),
      );
      if (!_list.hasClients) return;
      final top = _selected * 42.0;
      final viewport = _list.position.viewportDimension;
      if (top < _list.offset) _list.jumpTo(top);
      if (top + 42 > _list.offset + viewport) {
        _list.jumpTo(
          (top + 42 - viewport).clamp(0, _list.position.maxScrollExtent),
        );
      }
    }

    void execute() {
      if (matches.isNotEmpty) Navigator.pop(context, matches[_selected]);
    }

    final c = WColors.of(context);
    final theme = Theme.of(context);
    return Dialog(
      backgroundColor: c.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(WRadius.xl),
        side: BorderSide(color: c.border),
      ),
      child: SizedBox(
        width: 500,
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.arrowUp): () => move(-1),
            const SingleActivator(LogicalKeyboardKey.arrowDown): () => move(1),
            const SingleActivator(LogicalKeyboardKey.enter): execute,
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
                child: TextField(
                  autofocus: true,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: c.textPrimary,
                  ),
                  decoration: InputDecoration(
                    hintText: '搜索命令或快捷操作…',
                    fillColor: c.surfaceMuted,
                    prefixIcon: Icon(
                      Icons.search_rounded,
                      size: 18,
                      color: c.textTertiary,
                    ),
                    suffixIcon: const Padding(
                      padding: EdgeInsets.only(right: 8),
                      child: WShortcutBadge(label: 'ESC'),
                    ),
                    suffixIconConstraints: const BoxConstraints(
                      minWidth: 32,
                      minHeight: 24,
                    ),
                  ),
                  onChanged: (query) => setState(() {
                    _query = query.trim().toLowerCase();
                    _selected = 0;
                    if (_list.hasClients) _list.jumpTo(0);
                  }),
                  onSubmitted: (_) => execute(),
                ),
              ),
              Divider(height: 1, color: c.border),
              if (matches.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 28),
                  child: Text(
                    '没有匹配的命令',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: c.textTertiary,
                    ),
                  ),
                )
              else
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 300),
                  child: ListView.builder(
                    controller: _list,
                    shrinkWrap: true,
                    padding: const EdgeInsets.all(6),
                    itemExtent: 42,
                    itemCount: matches.length,
                    itemBuilder: (context, index) {
                      final command = matches[index];
                      final active = index == _selected;
                      return Material(
                        color: active ? c.brandSoft : Colors.transparent,
                        borderRadius: BorderRadius.circular(WRadius.sm),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(WRadius.sm),
                          hoverColor: c.hover,
                          onTap: () => Navigator.pop(context, command),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            child: Row(
                              children: [
                                Icon(
                                  command.icon,
                                  size: 16,
                                  color: active ? c.brand : c.textSecondary,
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    command.label,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      fontSize: 13,
                                      fontWeight: active
                                          ? FontWeight.w600
                                          : FontWeight.w500,
                                      color: active ? c.brand : c.textPrimary,
                                    ),
                                  ),
                                ),
                                if (active)
                                  Icon(
                                    Icons.keyboard_return_rounded,
                                    size: 14,
                                    color: c.brand.withValues(alpha: 0.7),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              Divider(height: 1, color: c.border),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    Text(
                      '↑↓ 选择  ·  ↵ 执行  ·  Esc 关闭',
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontSize: 11,
                        color: c.textTertiary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
