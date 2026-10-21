import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'recent_weighing.dart';

class RecentWeighingView extends StatefulWidget {
  const RecentWeighingView({super.key, this.expanded = false});

  final bool expanded;

  @override
  State<RecentWeighingView> createState() => _RecentWeighingViewState();
}

class _RecentWeighingViewState extends State<RecentWeighingView>
    with WidgetsBindingObserver {
  final _store = RecentWeighingStore();
  late Future<List<WeighingRecord>> _records;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _records = _store.load();
    RecentWeighingStore.changes.addListener(_reload);
    WidgetsBinding.instance.addObserver(this);
  }

  void _reload() {
    setState(() {
      _records = _store.load();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _reload();
  }

  @override
  void dispose() {
    RecentWeighingStore.changes.removeListener(_reload);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _change(Future<List<WeighingRecord>> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      RecentWeighingStore.changes.value++;
    } on PlatformException catch (error) {
      _showError(error.message ?? error.code);
    } on FormatException catch (error) {
      _showError(error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showError(String error) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
  }

  Future<void> _clear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空最近称重？'),
        content: const Text('全部称重记录将被删除，无法恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) await _change(_store.clear);
  }

  Future<void> _copy(WeighingRecord record) async {
    try {
      await Clipboard.setData(ClipboardData(text: record.copyText));
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('已复制称重结果')));
      }
    } on PlatformException catch (error) {
      _showError(error.message ?? error.code);
    }
  }

  String _date(DateTime time) {
    final now = DateTime.now();
    final date = DateTime(time.year, time.month, time.day);
    final today = DateTime(now.year, now.month, now.day);
    if (date == today) return '今天';
    if (date == DateTime(now.year, now.month, now.day - 1)) return '昨天';
    return '${time.year}/${time.month.toString().padLeft(2, '0')}/${time.day.toString().padLeft(2, '0')}';
  }

  String _clock(DateTime time) =>
      '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

  Widget _record(WeighingRecord record) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  record.categoryName,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                Text(
                  '${formatGrams(record.weightGrams)} 克 · ${_date(record.createdAt)} ${_clock(record.createdAt)}',
                  style: TextStyle(
                    fontSize: 12,
                    color: colors.onSurfaceVariant,
                  ),
                ),
                if (widget.expanded) ...[
                  const SizedBox(height: 4),
                  Text(
                    '${record.typeLabel} · 皮重 ${formatGrams(record.tareGrams)} 克 · 单份 ${formatGrams(record.singleServingGrams)} 克\n${record.allowMultiple ? '允许多份' : '限 0.1～0.9 份'} · ${record.source == 'shortcut' ? '快捷指令' : 'App 内计算'}',
                    style: TextStyle(
                      fontSize: 12,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '${record.result.split('（').first} 份',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                    color: colors.primary,
                  ),
                ),
                Text(
                  '比例 ${record.result.split('（').last.replaceAll('）', '')}',
                  style: TextStyle(
                    fontSize: 12,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          PopupMenuButton<String>(
            tooltip: '称重记录操作',
            enabled: !_busy,
            padding: EdgeInsets.zero,
            onSelected: (value) {
              if (value == 'copy') _copy(record);
              if (value == 'delete') _change(() => _store.delete(record.id));
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'copy', child: Text('复制结果')),
              PopupMenuItem(value: 'delete', child: Text('删除记录')),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<List<WeighingRecord>>(
    future: _records,
    builder: (context, snapshot) {
      final records = snapshot.data ?? const <WeighingRecord>[];
      final content = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.history_rounded,
                size: 20,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  '最近称重',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                ),
              ),
              if (widget.expanded && records.isNotEmpty)
                TextButton(
                  onPressed: _busy ? null : _clear,
                  child: const Text('清空'),
                ),
              if (!widget.expanded && records.isNotEmpty)
                TextButton(
                  onPressed: () => showModalBottomSheet<void>(
                    context: context,
                    isScrollControlled: true,
                    showDragHandle: true,
                    useSafeArea: true,
                    builder: (context) => FractionallySizedBox(
                      heightFactor: .85,
                      child: const Padding(
                        padding: EdgeInsets.fromLTRB(20, 0, 20, 16),
                        child: RecentWeighingView(expanded: true),
                      ),
                    ),
                  ),
                  child: Text('全部 ${records.length} 条'),
                ),
            ],
          ),
          if (snapshot.hasError)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '读取称重记录失败：${snapshot.error}',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                  TextButton(onPressed: _reload, child: const Text('重试')),
                ],
              ),
            )
          else if (snapshot.connectionState != ConnectionState.done)
            const Padding(
              padding: EdgeInsets.all(16),
              child: LinearProgressIndicator(),
            )
          else if (records.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(
                '还没有称重记录，计算成功后会自动保存在这里。',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            )
          else if (widget.expanded) ...[
            Text('自动保存最近 100 条', style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.separated(
                itemCount: records.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (_, index) => _record(records[index]),
              ),
            ),
          ] else
            ...records.take(3).map(_record),
        ],
      );
      if (widget.expanded) return content;
      return Card(
        elevation: 0,
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        margin: EdgeInsets.zero,
        child: Padding(padding: const EdgeInsets.all(16), child: content),
      );
    },
  );
}
