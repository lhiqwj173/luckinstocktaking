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
      appBar: AppBar(title: const Text('库存差异')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text('基准：${widget.baseline.title}'),
          Text('对照：${widget.target.title}'),
          const SizedBox(height: 8),
          const Text('差值 = 对照单 − 基准单；仅比较双方明确填写的同一货物、位置和单位。'),
          const SizedBox(height: 12),
          Text(
            '${widget.comparison.rows.length} 项可比 · $changed 项差异或单位待核对 · ${widget.comparison.excluded} 项不参与',
            style: theme.textTheme.titleSmall,
          ),
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
                              Text('基准', style: theme.textTheme.bodySmall),
                              StockInventoryView(
                                inventory: row.baseline.inventory,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('对照', style: theme.textTheme.bodySmall),
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
                            label: Text(difference.display),
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
}
