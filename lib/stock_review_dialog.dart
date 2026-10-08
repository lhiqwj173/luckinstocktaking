import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'stock_history.dart';
import 'stock_inventory.dart';
import 'stock_product.dart';

class StockReviewDialog extends StatefulWidget {
  const StockReviewDialog({
    super.key,
    required this.line,
    required this.products,
    required this.images,
    required this.onCreate,
  });
  final StockLine line;
  final List<StockProduct> products;
  final List<Uint8List> images;
  final Future<void> Function(StockProduct) onCreate;
  @override
  State<StockReviewDialog> createState() => _StockReviewDialogState();
}

class _StockReviewDialogState extends State<StockReviewDialog> {
  late final _inventory = TextEditingController(text: widget.line.cells[1]);
  late final _search = TextEditingController(text: widget.line.cells[0]);
  late final List<StockProduct> _products = [...widget.products];
  StockProduct? _selected;
  bool _identity = false;
  bool _quantity = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final matching = _products
        .where((p) => p.id == widget.line.productId)
        .toList();
    if (matching.length == 1) _selected = matching.single;
    if (_selected == null) {
      final candidates = matchProducts(
        widget.line.cells[0],
        widget.line.category,
        _products,
      );
      if (candidates.isNotEmpty &&
          candidates.first.exactCode &&
          !candidates.first.conflict &&
          candidates.first.score >= 0.6) {
        _selected = candidates.first.product;
      }
    }
    _identity = _selected != null && widget.line.identityConfirmed;
    _quantity = widget.line.inventoryConfirmed;
  }

  @override
  void dispose() {
    _inventory.dispose();
    _search.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final product = await showDialog<StockProduct>(
      context: context,
      builder: (_) => ProductEditor(line: widget.line),
    );
    if (product == null || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onCreate(product);
      if (mounted) {
        setState(() {
          _products.add(product);
          _selected = product;
          _identity = false;
        });
      }
    } on FormatException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } on PlatformException catch (error) {
      if (mounted) setState(() => _error = error.message ?? error.code);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _confirm() {
    if (_selected == null || !_identity || !_quantity) {
      setState(() => _error = '请分别确认货物身份和原图库存');
      return;
    }
    final inventory = StockInventory.parse(_inventory.text.trim());
    final units = inventory.parts.values.expand((part) => part.amounts.keys);
    if (inventory.needsReview ||
        inventory.reviewStatus == '总库存与冷藏、冷冻合计不一致' ||
        units.any((unit) => !_selected!.units.contains(unit))) {
      setState(() => _error = '库存格式、单位或分区合计有误，请对照原图修改');
      return;
    }
    Navigator.pop(
      context,
      widget.line.confirmed(
        cells: [_selected!.display, _inventory.text.trim()],
        productId: _selected!.id,
        allowedUnits: _selected!.units,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final candidates = matchProducts(
      _search.text,
      widget.line.category,
      _products,
    );
    return AlertDialog(
      title: const Text('确认货物与库存'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('对照原图确认数量和单位；空白保持空白，不能填成零。'),
              SizedBox(
                height: 220,
                child: InteractiveViewer(
                  maxScale: 6,
                  child: ListView(
                    children: [
                      for (final image in widget.images)
                        Image.memory(image, fit: BoxFit.fitWidth),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text('原始识别：${widget.line.sourceCells.join(' · ')}'),
              TextField(
                controller: _search,
                maxLines: 3,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(labelText: '搜索货物档案（名称或货号）'),
              ),
              if (candidates.isEmpty) const Text('未找到候选。可修改搜索，或核实后创建新货物。'),
              for (final candidate in candidates)
                ListTile(
                  dense: true,
                  title: Text(candidate.product.display),
                  subtitle: Text(
                    candidate.conflict
                        ? '货号或规格有冲突，须核对原图'
                        : candidate.exactCode
                        ? '货号一致，仍需核对规格'
                        : '模糊匹配候选，须人工确认',
                  ),
                  selected: _selected?.id == candidate.product.id,
                  leading: Icon(
                    _selected?.id == candidate.product.id
                        ? Icons.check_circle
                        : Icons.circle_outlined,
                  ),
                  onTap: _busy
                      ? null
                      : () => setState(() {
                          _selected = candidate.product;
                          _identity = false;
                        }),
                ),
              OutlinedButton(
                onPressed: _busy ? null : _create,
                child: const Text('核实后创建新货物'),
              ),
              if (_selected != null) Text('选中档案：${_selected!.display}'),
              CheckboxListTile(
                value: _identity,
                onChanged: _selected == null || _busy
                    ? null
                    : (value) => setState(() => _identity = value!),
                title: const Text('货号、名称和规格与原图一致'),
              ),
              TextField(
                controller: _inventory,
                maxLines: 3,
                onChanged: (_) => setState(() => _quantity = false),
                decoration: const InputDecoration(labelText: '实盘总库存（保留单位和分区）'),
              ),
              CheckboxListTile(
                value: _quantity,
                onChanged: _busy
                    ? null
                    : (value) => setState(() => _quantity = value!),
                title: const Text('已逐项核对原图数字、单位和所属行'),
              ),
              if (_error != null)
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _busy ? null : _confirm,
          child: const Text('确认此行'),
        ),
      ],
    );
  }
}

class ProductEditor extends StatefulWidget {
  const ProductEditor({super.key, this.line, this.product});
  final StockLine? line;
  final StockProduct? product;
  @override
  State<ProductEditor> createState() => _ProductEditorState();
}

class StockProductPage extends StatefulWidget {
  const StockProductPage({super.key});
  @override
  State<StockProductPage> createState() => _StockProductPageState();
}

class _StockProductPageState extends State<StockProductPage> {
  final _store = StockProductStore();
  final _paste = TextEditingController();
  List<StockProduct> _products = [];
  bool _busy = true;
  bool _loaded = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _paste.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on FormatException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } on PlatformException catch (error) {
      if (mounted) setState(() => _error = error.message ?? error.code);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _load() => _run(() async {
    setState(() => _loaded = false);
    final products = await _store.load();
    if (mounted) {
      setState(() {
        _products = products;
        _loaded = true;
      });
    }
  });
  Future<void> _save(List<StockProduct> products) async {
    await _store.save(products);
    if (mounted) setState(() => _products = products);
  }

  Future<void> _edit([StockProduct? old]) async {
    final product = await showDialog<StockProduct>(
      context: context,
      builder: (_) => ProductEditor(product: old),
    );
    if (product == null || !mounted) return;
    await _run(
      () => _save([
        for (final p in _products)
          if (p.id != old?.id) p,
        product,
      ]),
    );
  }

  Future<void> _import() => _run(() async {
    final additions = importProducts(_paste.text);
    // 冲突明确报错，不静默覆盖已确认的货物档案。
    await _save([..._products, ...additions]);
    if (mounted) _paste.clear();
  });
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('盘点货物档案')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Text('仅导入人工核实的货物列表。库存数量不进入档案。'),
        const Text('从 Excel 复制六列，表头为：货号、名称、规格、库存单位、别名、类别。类别填写“货物”或“预制物料”。'),
        TextField(
          controller: _paste,
          minLines: 3,
          maxLines: 8,
          decoration: const InputDecoration(labelText: '粘贴档案表格（包含表头）'),
        ),
        OutlinedButton(
          onPressed: _busy || !_loaded ? null : _import,
          child: const Text('导入已核实的列表'),
        ),
        FilledButton(
          onPressed: _busy || !_loaded ? null : () => _edit(),
          child: const Text('新增货物'),
        ),
        if (_busy) const LinearProgressIndicator(),
        if (_error != null)
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        if (_error != null)
          TextButton(
            onPressed: _busy ? null : _load,
            child: const Text('重新读取档案'),
          ),
        for (final product in _products)
          ListTile(
            title: Text(product.display),
            subtitle: Text('库存单位：${product.units.join('、')}'),
            onTap: _busy || !_loaded ? null : () => _edit(product),
          ),
      ],
    ),
  );
}

class _ProductEditorState extends State<ProductEditor> {
  late final _code = TextEditingController(text: widget.product?.code ?? '');
  late final _name = TextEditingController(text: widget.product?.name ?? '');
  late final _spec = TextEditingController(
    text: widget.product?.specification ?? '',
  );
  late final _units = TextEditingController(
    text: widget.product?.units.join('、') ?? '',
  );
  late final _aliases = TextEditingController(
    text: widget.product?.aliases.join('、') ?? '',
  );
  late String _category =
      widget.product?.category ?? widget.line?.category ?? 'goods';
  String? _error;
  @override
  void dispose() {
    for (final c in [_code, _name, _spec, _units, _aliases]) {
      c.dispose();
    }
    super.dispose();
  }

  void _save() {
    try {
      final product = StockProduct(
        code: _code.text.trim().toUpperCase(),
        name: _name.text.trim(),
        specification: _spec.text.trim(),
        units: _units.text.split(RegExp('[、,，]')).map((s) => s.trim()).toList(),
        aliases: _aliases.text.trim().isEmpty
            ? []
            : _aliases.text
                  .split(RegExp('[、,，]'))
                  .map((s) => s.trim())
                  .toList(),
        category: _category,
      );
      product.validate();
      Navigator.pop(context, product);
    } on FormatException catch (error) {
      setState(() => _error = error.message);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('货物档案'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.line != null) Text('请根据原图填写：${widget.line!.cells[0]}'),
          DropdownButton<String>(
            value: _category,
            items: const [
              DropdownMenuItem(value: 'goods', child: Text('货物')),
              DropdownMenuItem(value: 'prepared', child: Text('预制物料')),
            ],
            onChanged: widget.line != null
                ? null
                : (value) => setState(() => _category = value!),
          ),
          TextField(
            controller: _code,
            decoration: const InputDecoration(labelText: '货号（预制物料留空）'),
          ),
          TextField(
            controller: _name,
            decoration: const InputDecoration(labelText: '标准名称'),
          ),
          TextField(
            controller: _spec,
            decoration: const InputDecoration(labelText: '包装规格'),
          ),
          TextField(
            controller: _units,
            decoration: const InputDecoration(labelText: '库存单位，多个用顿号分隔'),
          ),
          TextField(
            controller: _aliases,
            decoration: const InputDecoration(labelText: '人工确认的别名（选填）'),
          ),
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: _save, child: const Text('保存档案')),
    ],
  );
}
