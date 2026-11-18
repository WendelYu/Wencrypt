import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

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

    return Dialog(
      child: SizedBox(
        width: 480,
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
                padding: const EdgeInsets.all(12),
                child: TextField(
                  autofocus: true,
                  decoration: const InputDecoration(
                    hintText: '搜索命令',
                    prefixIcon: Icon(Icons.search),
                  ),
                  onChanged: (query) => setState(() {
                    _query = query.trim().toLowerCase();
                    _selected = 0;
                    if (_list.hasClients) _list.jumpTo(0);
                  }),
                  onSubmitted: (_) => execute(),
                ),
              ),
              const Divider(height: 1),
              if (matches.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(22),
                  child: Text('没有匹配的命令'),
                )
              else
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 294),
                  child: ListView.builder(
                    controller: _list,
                    shrinkWrap: true,
                    itemExtent: 42,
                    itemCount: matches.length,
                    itemBuilder: (context, index) {
                      final command = matches[index];
                      return ListTile(
                        dense: true,
                        selected: index == _selected,
                        selectedTileColor: Theme.of(context)
                            .colorScheme
                            .primaryContainer,
                        leading: Icon(command.icon, size: 18),
                        title: Text(
                          command.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () => Navigator.pop(context, command),
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
