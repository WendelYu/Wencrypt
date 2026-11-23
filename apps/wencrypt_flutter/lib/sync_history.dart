import 'package:material_ui/material_ui.dart';

import 'design/wencrypt_theme.dart';
import 'design/wencrypt_widgets.dart';

class SyncHistoryRecord {
  SyncHistoryRecord.fromJson(Map<String, dynamic> item)
    : sequence = item['sequence'] as int,
      data = (item['record'] as Map).cast<String, dynamic>();

  final int sequence;
  final Map<String, dynamic> data;

  String get id => data['id'] as String;
  String get folder => data['folder'] as String;
  int get uploaded => data['uploaded'] as int;
  int get downloaded => data['downloaded'] as int;
  bool get automatic => data['automatic'] as bool;
  String get outcome => data['outcome'] as String;
  Map<String, dynamic>? get issue =>
      (data['issue'] as Map?)?.cast<String, dynamic>();
  DateTime get started => DateTime.fromMillisecondsSinceEpoch(
    (data['started_at'] as int) * 1000,
    isUtc: true,
  ).toLocal();
}

enum _Filter { all, failed, unfinished }

class SyncHistoryView extends StatefulWidget {
  const SyncHistoryView({
    super.key,
    required this.load,
    required this.revision,
    required this.runningId,
    required this.copyDirectory,
    required this.describeIssue,
  });

  final Future<Map<String, dynamic>> Function(int? before) load;
  final int revision;
  final String? runningId;
  final void Function(String folder) copyDirectory;
  final String Function(Map<String, dynamic> issue) describeIssue;

  @override
  State<SyncHistoryView> createState() => _SyncHistoryViewState();
}

class _SyncHistoryViewState extends State<SyncHistoryView> {
  List<SyncHistoryRecord> _records = [];
  _Filter _filter = _Filter.all;
  int? _cursor;
  bool _loading = false;
  bool _refreshAgain = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant SyncHistoryView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.revision != widget.revision) _load();
  }

  Future<void> _load({bool earlier = false}) async {
    if (_loading) {
      if (!earlier) _refreshAgain = true;
      return;
    }
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final page = await widget.load(earlier ? _cursor : null);
      final incoming = [
        for (final raw in page['records'] as List)
          SyncHistoryRecord.fromJson((raw as Map).cast<String, dynamic>()),
      ];
      if (!mounted) return;
      setState(() {
        final alreadyHasOlder =
            !earlier &&
            incoming.isNotEmpty &&
            _records.isNotEmpty &&
            _records.last.sequence < incoming.last.sequence;
        final bySequence = {
          for (final record in _records) record.sequence: record,
          for (final record in incoming) record.sequence: record,
        };
        _records = bySequence.values.toList()
          ..sort((a, b) => b.sequence.compareTo(a.sequence));
        if (!alreadyHasOlder) _cursor = page['cursor'] as int?;
      });
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) {
        setState(() => _loading = false);
        if (_refreshAgain) {
          _refreshAgain = false;
          _load();
        }
      }
    }
  }

  String _outcome(SyncHistoryRecord record) =>
      record.outcome == 'running' && record.id != widget.runningId
      ? 'interrupted'
      : record.outcome;

  String _time(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${time.year}-${two(time.month)}-${two(time.day)} '
        '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
  }

  WStatusPill _status(BuildContext context, String outcome) {
    final (label, tone) = switch (outcome) {
      'running' => ('同步中', WTone.info),
      'success' => ('完成', WTone.success),
      'partial' => ('待续传', WTone.warning),
      'failed' => ('失败', WTone.danger),
      _ => ('未完成', WTone.neutral),
    };
    return WStatusPill(label: label, tone: tone, compact: true);
  }

  Widget _row(BuildContext context, SyncHistoryRecord record, bool wide) {
    final theme = Theme.of(context);
    final outcome = _outcome(record);
    final reason = record.issue != null
        ? widget.describeIssue(record.issue!)
        : switch (outcome) {
            'partial' => '本轮达到同步额度，已完成的传输会保留。',
            'interrupted' => '同步中断，未记录最终结果。',
            _ => null,
          };
    final time = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        WMono(
          _time(record.started),
          size: 11.5,
          color: WColors.of(context).textSecondary,
        ),
        Text(
          record.automatic ? '自动同步' : '手动同步',
          style: theme.textTheme.bodySmall?.copyWith(
            fontSize: 10.8,
            color: WColors.of(context).textTertiary,
          ),
        ),
      ],
    );
    final folder = Row(
      children: [
        Flexible(
          child: Tooltip(
            message: record.folder,
            child: Text(
              record.folder,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        IconButton(
          tooltip: '复制目录名',
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.copy_outlined, size: 16),
          onPressed: () => widget.copyDirectory(record.folder),
        ),
      ],
    );
    final status = _status(context, outcome);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (wide)
            Row(
              children: [
                SizedBox(width: 172, child: time),
                Expanded(child: folder),
                SizedBox(
                  width: 70,
                  child: Text(
                    '${record.uploaded}',
                    textAlign: TextAlign.center,
                  ),
                ),
                SizedBox(
                  width: 70,
                  child: Text(
                    '${record.downloaded}',
                    textAlign: TextAlign.center,
                  ),
                ),
                SizedBox(width: 94, child: status),
              ],
            )
          else ...[
            Row(
              children: [
                Expanded(child: time),
                status,
              ],
            ),
            folder,
            Text('上传 ${record.uploaded} 条 · 下载 ${record.downloaded} 条'),
          ],
          if (reason != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                reason,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: outcome == 'failed' ? theme.colorScheme.error : null,
                ),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final visible = _records.where((record) {
      final result = _outcome(record);
      return switch (_filter) {
        _Filter.all => true,
        _Filter.failed => result == 'failed',
        _Filter.unfinished => result != 'success' && result != 'failed',
      };
    }).toList();
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 690;
        final c = WColors.of(context);
        return Padding(
          padding: EdgeInsets.symmetric(
            horizontal: wide ? 24 : 16,
            vertical: 16,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: WFilterChips(
                      labels: const ['全部', '失败', '未完成'],
                      selectedIndex: _Filter.values.indexOf(_filter),
                      onSelected: (index) =>
                          setState(() => _filter = _Filter.values[index]),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (_failed)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: WNote(
                    tone: WTone.danger,
                    child: Row(
                      children: [
                        const Expanded(child: Text('无法读取同步记录')),
                        TextButton(onPressed: _load, child: const Text('重试')),
                      ],
                    ),
                  ),
                ),
              Expanded(
                child: visible.isEmpty && !_loading && !_failed
                    ? WEmptyState(
                        icon: Icons.history_rounded,
                        title: _filter == _Filter.all ? '还没有同步记录' : '没有符合条件的记录',
                        message: _filter == _Filter.all
                            ? '完成首次云端同步后，传输记录会保存在本机并显示在这里'
                            : '尝试切换到「全部」查看所有同步记录',
                      )
                    : WSurface(
                        radius: WRadius.lg,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(WRadius.lg),
                          child: Column(
                            children: [
                              if (wide && visible.isNotEmpty)
                                Container(
                                  color: c.surfaceMuted,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 10,
                                  ),
                                  child: DefaultTextStyle(
                                    style: theme.textTheme.labelMedium!
                                        .copyWith(
                                          fontSize: 11.5,
                                          fontWeight: FontWeight.w600,
                                          color: c.textTertiary,
                                        ),
                                    child: const Row(
                                      children: [
                                        SizedBox(width: 172, child: Text('时间')),
                                        Expanded(child: Text('同步目录')),
                                        SizedBox(
                                          width: 70,
                                          child: Text(
                                            '上传',
                                            textAlign: TextAlign.center,
                                          ),
                                        ),
                                        SizedBox(
                                          width: 70,
                                          child: Text(
                                            '下载',
                                            textAlign: TextAlign.center,
                                          ),
                                        ),
                                        SizedBox(width: 94, child: Text('结果')),
                                      ],
                                    ),
                                  ),
                                ),
                              if (wide && visible.isNotEmpty)
                                Divider(height: 1, color: c.border),
                              Expanded(
                                child: ListView(
                                  children: [
                                    for (final record in visible) ...[
                                      _row(context, record, wide),
                                      Divider(
                                        height: 1,
                                        color: c.border.withValues(alpha: 0.7),
                                      ),
                                    ],
                                    if (_loading)
                                      const Padding(
                                        padding: EdgeInsets.all(14),
                                        child: Center(
                                          child: SizedBox.square(
                                            dimension: 20,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                            ),
                                          ),
                                        ),
                                      )
                                    else if (_cursor != null)
                                      Padding(
                                        padding: const EdgeInsets.symmetric(
                                          vertical: 8,
                                        ),
                                        child: Center(
                                          child: TextButton(
                                            onPressed: () =>
                                                _load(earlier: true),
                                            child: const Text('加载更早的记录'),
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}
