import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'stock_history.dart';
import 'stock_history_page.dart';
import 'stock_inventory_view.dart';
import 'stock_latest.dart';
import 'stock_product.dart';

class LatestStockPage extends StatefulWidget {
  const LatestStockPage({super.key});

  @override
  State<LatestStockPage> createState() => _LatestStockPageState();
}

class _LatestStockPageState extends State<LatestStockPage>
    with WidgetsBindingObserver {
  final _store = StockHistoryStore();
  final _query = TextEditingController();
  List<LatestStockRecord>? _records;
  String? _category;
  String? _error;
  bool _loading = false;
  bool _reloadRequested = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    StockHistoryStore.changes.addListener(_historyChanged);
    _load();
  }

  void _historyChanged() => _load();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    if (_loading) {
      _reloadRequested = true;
      return;
    }
    setState(() {
      _loading = true;
      _records = null;
      _error = null;
    });
    try {
      do {
        _reloadRequested = false;
        final products = await StockProductStore().load();
        final documents = await _store.load();
        final tables = <StockDocument>[];
        for (final document in documents) {
          // 旧格式尚无独立库存列，先使用现有整理流程，禁止漏掉后宣称最新。
          tables.add(
            document.schemaVersion == 2
                ? document
                : await _store.table(document),
          );
        }
        final records = latestStockRecords(tables, products);
        if (!mounted) return;
        if (!_reloadRequested) setState(() => _records = records);
      } while (_reloadRequested);
    } on PlatformException catch (error) {
      if (mounted) setState(() => _error = error.message ?? error.code);
    } on FormatException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _open(LatestStockRecord record) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => StockDocumentPage(document: record.document),
      ),
    );
    if (mounted) await _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    StockHistoryStore.changes.removeListener(_historyChanged);
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final records = _records;
    final matches = records
        ?.where(
          (record) =>
              (_category == null || record.category == _category) &&
              record.matches(_query.text),
        )
        .toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('最新品类库存'),
        actions: [
          IconButton(
            tooltip: '刷新库存',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('每个品类取最近录入且包含它的盘点单，保留原始库存和校对状态。'),
                const SizedBox(height: 12),
                TextField(
                  controller: _query,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    labelText: '搜索品名、别名、规格或货号',
                    prefixIcon: Icon(Icons.search),
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final option in <String?, String>{
                      null: '全部',
                      'goods': '货物',
                      'prepared': '预制物料',
                    }.entries)
                      ChoiceChip(
                        label: Text(option.value),
                        selected: _category == option.key,
                        onSelected: (_) =>
                            setState(() => _category = option.key),
                      ),
                  ],
                ),
              ],
            ),
          ),
          if (_loading) const LinearProgressIndicator(),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Text(
                    '库存查询失败：$_error',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                  TextButton(
                    onPressed: _loading ? null : _load,
                    child: const Text('重试'),
                  ),
                ],
              ),
            ),
          if (matches != null)
            Expanded(
              child: matches.isEmpty
                  ? Center(
                      child: Text(
                        records!.isEmpty ? '暂无盘点记录，请先录入盘点单。' : '没有匹配的品类。',
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      itemCount: matches.length,
                      itemBuilder: (context, index) {
                        final record = matches[index];
                        return Card(
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  record.name,
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleMedium,
                                ),
                                if (record.product case final product?)
                                  Text(
                                    [product.specification, product.code]
                                        .where((text) => text.isNotEmpty)
                                        .join(' · '),
                                  ),
                                Text(
                                  record.category == 'prepared' ? '预制物料' : '货物',
                                ),
                                if (record.sameTimestamp)
                                  const Text('存在录入时间相同的最新单据，已分别列出，请核对来源。'),
                                const SizedBox(height: 8),
                                for (final line in record.lines) ...[
                                  if (!line.identityConfirmed)
                                    Text('品类待确认：${line.cells[0]}'),
                                  StockInventoryView(inventory: line.inventory),
                                  if (!record.confirmed)
                                    Text(
                                      '待校对 · ${line.inventory.reviewStatus}',
                                    ),
                                ],
                                if (record.lines.length > 1)
                                  const Text('同一单据存在重复品类，请打开来源核对。'),
                                if (!record.lines.any(
                                  (line) => line.inventory.hasValue,
                                ))
                                  const Text('最近记录未提供可确认的数量，请核对来源单据。'),
                                const SizedBox(height: 8),
                                Text('来源：${record.document.title}'),
                                Text(
                                  '录入时间：${record.document.createdAt.toLocal().toString().substring(0, 19)}',
                                ),
                                TextButton.icon(
                                  onPressed: () => _open(record),
                                  icon: const Icon(Icons.receipt_long_outlined),
                                  label: const Text('查看来源盘点单'),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
        ],
      ),
    );
  }
}
