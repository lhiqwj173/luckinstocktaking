import 'package:flutter/material.dart';

import 'stock_comparison.dart';
import 'stock_history.dart';
import 'stock_inventory_view.dart';

class StockComparisonPage extends StatefulWidget {
  const StockComparisonPage({
    super.key,
    required this.baseline,
    required this.target,
    required this.comparison,
  });
  final StockDocument baseline;
  final StockDocument target;
  final StockComparison comparison;
  @override
  State<StockComparisonPage> createState() => _StockComparisonPageState();
}

class _StockComparisonPageState extends State<StockComparisonPage> {
  String _query = '';
  bool _onlyChanges = true;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rows = widget.comparison.rows
        .where(
          (row) =>
              (!_onlyChanges || row.changed) &&
              '${row.code} ${row.baseline.text} ${row.target.text}'
                  .toLowerCase()
                  .contains(_query.trim().toLowerCase()),
        )
        .toList();
    final changed = widget.comparison.rows.where((row) => row.changed).length;
    return Scaffold(
      appBar: AppBar(
        title: const Text('库存差异'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(84),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _documentHeading(theme, '原盘点单', widget.baseline),
                const SizedBox(height: 8),
                _documentHeading(theme, '新盘点单', widget.target),
              ],
            ),
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            '$changed 项有变化 · ${widget.comparison.rows.length} 项参与对比',
            style: theme.textTheme.titleSmall,
          ),
          const SizedBox(height: 4),
          Text('仅比较两张单都有库存的项目', style: theme.textTheme.bodySmall),
          TextField(
            onChanged: (value) => setState(() => _query = value),
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: '搜索货号或品名',
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('只看差异'),
            value: _onlyChanges,
            onChanged: (value) => setState(() => _onlyChanges = value),
          ),
          if (rows.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('没有符合条件的差异项目', textAlign: TextAlign.center),
            ),
          for (final row in rows)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      row.target.cells[0],
                      style: theme.textTheme.titleSmall,
                    ),
                    const SizedBox(height: 12),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('原库存', style: theme.textTheme.bodySmall),
                              StockInventoryView(
                                inventory: row.baseline.inventory,
                              ),
                            ],
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Icon(
                            Icons.arrow_forward_rounded,
                            size: 18,
                            color: theme.colorScheme.outline,
                          ),
                        ),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('新库存', style: theme.textTheme.bodySmall),
                              StockInventoryView(
                                inventory: row.target.inventory,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        for (final difference in row.differences.where(
                          (item) => !item.amount.isZero,
                        ))
                          Chip(
                            avatar: Icon(
                              difference.amount.coefficient.isNegative
                                  ? Icons.trending_down_rounded
                                  : Icons.trending_up_rounded,
                              size: 16,
                            ),
                            label: Text(
                              '${difference.section == '库存' ? '' : '${difference.section} '}'
                              '${difference.amount.coefficient.isNegative ? '减少' : '增加'} '
                              '${difference.amount.format().replaceFirst('-', '')}${difference.unit}',
                            ),
                            backgroundColor:
                                difference.amount.coefficient.isNegative
                                ? theme.colorScheme.surfaceContainerHighest
                                : theme.colorScheme.primaryContainer,
                            side: BorderSide.none,
                            visualDensity: VisualDensity.compact,
                          ),
                        if (row.unitMismatch)
                          const Chip(label: Text('单位不同，无法直接计算差值')),
                        if (!row.changed) const Text('库存相同'),
                      ],
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _documentHeading(
    ThemeData theme,
    String label,
    StockDocument document,
  ) {
    return Row(
      children: [
        Text(label, style: theme.textTheme.bodySmall),
        const SizedBox(width: 12),
        Expanded(
          child: Tooltip(
            message: document.title,
            child: Text(
              document.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall,
            ),
          ),
        ),
      ],
    );
  }
}
