import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'category.dart';
import 'catalog_store.dart';

void main() => runApp(const StocktakingApp());

class StocktakingApp extends StatelessWidget {
  const StocktakingApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: '称重盘点助手',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
      useMaterial3: true,
    ),
    home: const HomePage(),
  );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _store = CatalogStore();
  final _query = TextEditingController();
  final _weight = TextEditingController();
  List<Category> _categories = [];
  Category? _selected;
  CatalogDiagnostics? _diagnostics;
  String? _result;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
    _query.addListener(_refresh);
    _weight.addListener(_refresh);
  }

  Future<void> _load() async {
    try {
      final diagnostics = await _store.diagnostics();
      if (mounted) setState(() => _diagnostics = diagnostics);
      final data = await _store.load();
      if (mounted) {
        setState(() {
          _categories = data;
          _loading = false;
        });
      }
    } on PlatformException catch (error) {
      if (mounted) {
        setState(() {
          _error = error.message ?? error.code;
          _loading = false;
        });
      }
    } on FormatException catch (error) {
      if (mounted) {
        setState(() {
          _error = error.message;
          _loading = false;
        });
      }
    }
  }

  void _refresh() => setState(() {
    _selected = null;
    _result = null;
    _error = null;
  });

  Future<void> _edit([Category? original]) async {
    final category = await showDialog<Category>(
      context: context,
      builder: (_) => CategoryDialog(original: original),
    );
    if (category == null) return;
    final updated = [..._categories];
    if (original == null) {
      updated.add(category);
    } else {
      updated[updated.indexOf(original)] = category;
    }
    try {
      await _store.save(updated);
      if (mounted) {
        setState(() {
          _categories = updated;
          _error = null;
        });
      }
    } on FormatException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } on PlatformException catch (error) {
      if (mounted) setState(() => _error = error.message ?? error.code);
    }
  }

  Future<void> _delete(Category category) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删除 ${category.name}？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final updated = _categories.where((e) => !identical(e, category)).toList();
    try {
      await _store.save(updated);
      if (mounted) {
        setState(() {
          _categories = updated;
          _selected = null;
          _result = null;
        });
      }
    } on PlatformException catch (error) {
      if (mounted) setState(() => _error = error.message ?? error.code);
    }
  }

  void _calculate() {
    final category = _selected;
    if (category == null) {
      setState(() => _error = '请先选择明确的品类');
      return;
    }
    final weight = double.tryParse(_weight.text.trim());
    if (weight == null) {
      setState(() => _error = '请输入有效的称重（克）');
      return;
    }
    try {
      final result = category.calculate(weight);
      setState(() {
        _result = result;
        _error = null;
      });
    } on FormatException catch (error) {
      setState(() => _error = error.message);
    }
  }

  @override
  void dispose() {
    _query.dispose();
    _weight.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final matches = findCategories(_categories, _query.text);
    return Scaffold(
      appBar: AppBar(title: const Text('称重盘点助手')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (_diagnostics != null)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: SelectableText(
                        '安装诊断：版本 ${_diagnostics!.version}\n'
                        '主 App：${_diagnostics!.appBundleId}\n'
                        '键盘：${_diagnostics!.keyboardBundleId}（${_diagnostics!.keyboardEmbedded ? '已打包' : '缺失'}）\n'
                        '共享数据权限：${_diagnostics!.appGroupAvailable ? '可用' : '不可用'}',
                      ),
                    ),
                  ),
                const Text(
                  '查询计算',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _query,
                  decoration: const InputDecoration(
                    labelText: '品类名称或别名',
                    border: OutlineInputBorder(),
                  ),
                ),
                if (matches.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  ...matches.map(
                    (category) => ListTile(
                      dense: true,
                      title: Text(category.name),
                      subtitle: Text(category.aliases.join('、')),
                      selected: identical(_selected, category),
                      onTap: () => setState(() {
                        _selected = category;
                        _result = null;
                        _error = null;
                      }),
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                TextField(
                  controller: _weight,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: '称重（克）',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton(onPressed: _calculate, child: const Text('计算')),
                if (_selected != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text('已选：${_selected!.name}'),
                  ),
                if (_result != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: SelectableText(
                      '结果：$_result',
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                  ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                const Divider(height: 40),
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '品类与规则',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: () => _edit(),
                      icon: const Icon(Icons.add),
                      tooltip: '新增品类',
                    ),
                  ],
                ),
                if (_categories.isEmpty) const Text('暂无品类。点击右侧加号录入。'),
                ..._categories.map(
                  (category) => Card(
                    child: ListTile(
                      title: Text(category.name),
                      subtitle: Text(
                        '净重 ÷ ${category.referenceGrams} 克 × ${category.referenceQuantity}；容器重 ${category.tareGrams} 克；保留 ${category.decimals} 位小数',
                      ),
                      trailing: PopupMenuButton<String>(
                        onSelected: (value) => value == 'edit'
                            ? _edit(category)
                            : _delete(category),
                        itemBuilder: (_) => const [
                          PopupMenuItem(value: 'edit', child: Text('编辑')),
                          PopupMenuItem(value: 'delete', child: Text('删除')),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                const Text(
                  '跨 App 使用：设置 → 通用 → 键盘 → 键盘 → 添加新键盘，选择“称重盘点键盘”。在其他 App 的普通文本框中先输入品类名，再切换到此键盘；按匹配排序选品类、输入克数、计算结果。iOS 不支持跨 App 常驻悬浮；密码框及部分 App 不支持第三方键盘。',
                ),
              ],
            ),
    );
  }
}

class CategoryDialog extends StatefulWidget {
  const CategoryDialog({super.key, this.original});
  final Category? original;
  @override
  State<CategoryDialog> createState() => _CategoryDialogState();
}

class _CategoryDialogState extends State<CategoryDialog> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController name, aliases, tare, grams, quantity;
  late int decimals;

  @override
  void initState() {
    super.initState();
    final c = widget.original;
    name = TextEditingController(text: c?.name ?? '');
    aliases = TextEditingController(text: c?.aliases.join('、') ?? '');
    tare = TextEditingController(text: c?.tareGrams.toString() ?? '0');
    grams = TextEditingController(text: c?.referenceGrams.toString() ?? '');
    quantity = TextEditingController(
      text: c?.referenceQuantity.toString() ?? '1',
    );
    decimals = c?.decimals ?? 0;
  }

  @override
  void dispose() {
    for (final c in [name, aliases, tare, grams, quantity]) {
      c.dispose();
    }
    super.dispose();
  }

  Widget _number(
    String label,
    TextEditingController controller, {
    bool allowZero = false,
  }) => TextFormField(
    controller: controller,
    keyboardType: const TextInputType.numberWithOptions(decimal: true),
    decoration: InputDecoration(labelText: label),
    validator: (value) {
      final number = double.tryParse((value ?? '').trim());
      return number != null &&
              number.isFinite &&
              (allowZero ? number >= 0 : number > 0)
          ? null
          : '请输入有效数值';
    },
  );

  void _save() {
    if (!_form.currentState!.validate()) return;
    final category = Category(
      name: name.text.trim(),
      aliases: aliases.text
          .split(RegExp(r'[,，、]'))
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList(),
      tareGrams: double.parse(tare.text.trim()),
      referenceGrams: double.parse(grams.text.trim()),
      referenceQuantity: double.parse(quantity.text.trim()),
      decimals: decimals,
    );
    category.validate();
    Navigator.pop(context, category);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.original == null ? '新增品类' : '编辑品类'),
    content: SizedBox(
      width: 400,
      child: Form(
        key: _form,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: name,
                decoration: const InputDecoration(labelText: '品类名称'),
                validator: (value) =>
                    (value ?? '').trim().isEmpty ? '请输入名称' : null,
              ),
              TextFormField(
                controller: aliases,
                decoration: const InputDecoration(labelText: '别名（逗号分隔，可选）'),
              ),
              _number('容器重（克）', tare, allowZero: true),
              _number('参考重量（克）', grams),
              _number('参考数量', quantity),
              DropdownButtonFormField<int>(
                initialValue: decimals,
                decoration: const InputDecoration(labelText: '结果小数位'),
                items: [0, 1, 2, 3]
                    .map((n) => DropdownMenuItem(value: n, child: Text('$n 位')))
                    .toList(),
                onChanged: (value) => setState(() => decimals = value!),
              ),
              const SizedBox(height: 8),
              const Text('计算：(称重 − 容器重) ÷ 参考重量 × 参考数量'),
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: _save, child: const Text('保存')),
    ],
  );
}
