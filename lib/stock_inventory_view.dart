import 'package:flutter/material.dart';

import 'stock_inventory.dart';

class StockInventoryView extends StatelessWidget {
  const StockInventoryView({super.key, required this.inventory});
  final StockInventory inventory;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (!inventory.hasValue && !inventory.needsReview) {
      return Text('未填写', style: TextStyle(color: theme.colorScheme.outline));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (inventory.parts['库存'] case final total? when total.hasValue)
          SelectableText(
            total.display,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final label in ['冷藏', '冷冻'])
              if (inventory.parts[label] case final quantity?
                  when quantity.hasValue)
                Container(
                  margin: const EdgeInsets.only(top: 6),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: label == '冷冻'
                        ? theme.colorScheme.secondaryContainer
                        : theme.colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '$label ${quantity.display}',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
          ],
        ),
        if (inventory.needsReview)
          Text(
            '库存待确认',
            style: TextStyle(color: theme.colorScheme.error, fontSize: 12),
          ),
        for (final part in inventory.parts.values)
          if (part.uncertain && part.raw.trim().isNotEmpty)
            SelectableText(part.raw.trim(), style: theme.textTheme.bodySmall),
      ],
    );
  }
}
