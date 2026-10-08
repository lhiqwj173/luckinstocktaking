import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'stock_export.dart';
import 'stock_history.dart';
import 'stock_inventory_view.dart';
import 'stock_comparison.dart';
import 'stock_comparison_page.dart';
import 'stock_product.dart';
import 'stock_review_dialog.dart';

const historyInstructions =
    '1. 在瑞幸盘打开旧盘点单，使用系统录屏，从顶部缓慢滚动到底。\n'
    '画面须包含「货物规格名称 / 实盘总库存」表头，顶部和底部各停留一秒。\n'
    '2. 结束录屏，点击「拼接录屏」选择视频。请先剪掉控制中心和停止录屏弹窗。\n'
    '3. 应用自动拼接、识别并保存两列盘点表，无需调整参数。\n'
    '点击「查看长图」核对拼接，再校对品名和库存。\n'
    '\n'
    '快捷指令：「选择照片」（选择录屏视频）→「拼接盘点单录屏」，将选中视频传入「盘点单文件」，保持「录屏视频」开启。\n'
    '运行后自动处理并打开结果；也可在快捷指令的分享表单中接收相册视频作为输入。\n'
    '录屏最长 120 秒，一次只处理一张盘点单；也支持直接识别长截图。\n';

class StockHistoryPage extends StatefulWidget {
  const StockHistoryPage({super.key});
  @override
  State<StockHistoryPage> createState() => _StockHistoryPageState();
}

class _StockHistoryPageState extends State<StockHistoryPage>
    with WidgetsBindingObserver {
  final _store = StockHistoryStore();
  final _query = TextEditingController();
  List<StockDocument> _documents = [];
  String? _error;
  bool _busy = false;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    StockHistoryStore.changes.addListener(_historyChanged);
    _load();
  }

  void _historyChanged() {
    if (!_busy) _load();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_busy) _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    StockHistoryStore.changes.removeListener(_historyChanged);
    _query.dispose();
    super.dispose();
  }

  Future<void> _operation(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on PlatformException catch (error) {
      if (mounted) setState(() => _error = error.message ?? error.code);
    } on FormatException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _load() => _operation(() async {
    final documents = await _store.load();
    if (mounted) {
      setState(() {
        _documents = documents;
        _ready = true;
      });
    }
  });

  Future<void> _import(bool video) => _operation(() async {
    final document = await _store.pick(video: video);
    if (document == null || !mounted) return;
    await _open(document);
  });
  Future<void> _importScreenshots() => _operation(() async {
    final document = await _store.pickScreenshots();
    if (document == null || !mounted) return;
    await _open(document);
  });

  /// 把最近一次识别任务的诊断日志交给系统分享面板，用于定位解析失败。
  Future<void> _shareDiagnostics() async {
    try {
      await _store.shareDiagnostics();
    } on PlatformException catch (error) {
      if (mounted) setState(() => _error = error.message ?? error.code);
    }
  }

  Future<void> _open(StockDocument document) async {
    await Navigator.of(context).push<StockDocument>(
      MaterialPageRoute(builder: (_) => StockDocumentPage(document: document)),
    );
    if (mounted) {
      final documents = await _store.load();
      if (mounted) {
        setState(() {
          _documents = documents;
          _ready = true;
        });
      }
    }
  }

  Future<void> _compare() async {
    var baseline = _documents[1].id;
    var target = _documents[0].id;
    final chosen = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('对比盘点单'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                initialValue: baseline,
                isExpanded: true,
                decoration: const InputDecoration(labelText: '原盘点单'),
                items: [
                  for (final document in _documents)
                    DropdownMenuItem(
                      value: document.id,
                      child: Text(
                        document.title,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (value) => update(() => baseline = value!),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Icon(Icons.arrow_downward_rounded, size: 20),
              ),
              DropdownButtonFormField<String>(
                initialValue: target,
                isExpanded: true,
                decoration: const InputDecoration(labelText: '新盘点单'),
                items: [
                  for (final document in _documents)
                    DropdownMenuItem(
                      value: document.id,
                      child: Text(
                        document.title,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (value) => update(() => target = value!),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: baseline == target
                  ? null
                  : () => Navigator.pop(context, true),
              child: const Text('查看差异'),
            ),
          ],
        ),
      ),
    );
    if (chosen != true || !mounted) return;
    await _operation(() async {
      final a = await _store.table(
        _documents.singleWhere((document) => document.id == baseline),
      );
      final b = await _store.table(
        _documents.singleWhere((document) => document.id == target),
      );
      final comparison = StockComparison(a, b);
      if (mounted) {
        await Navigator.of(context).push<void>(
          MaterialPageRoute(
            builder: (_) => StockComparisonPage(
              baseline: a,
              target: b,
              comparison: comparison,
            ),
          ),
        );
      }
      final documents = await _store.load();
      if (mounted) setState(() => _documents = documents);
    });
  }

  Future<void> _delete(StockDocument document) async {
    if (_busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除盘点单？'),
        content: Text('将删除「${document.title}」及其原始长图，无法恢复。'),
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
    if (confirmed != true || !mounted) return;
    await _operation(() async {
      await _store.delete(document);
      if (mounted) {
        setState(
          () => _documents.removeWhere((item) => item.id == document.id),
        );
      }
    });
  }

  /// 拖拽后先本地乐观更新，平台写盘失败时回滚为调整前的顺序。
  /// onReorderItem 的 newIndex 已按移除旧位置调整，无需再减一。
  Future<void> _reorder(int oldIndex, int newIndex) async {
    if (_busy || _query.text.trim().isNotEmpty) return;
    if (newIndex == oldIndex) return;
    final previous = [..._documents];
    final moved = _documents.removeAt(oldIndex);
    _documents.insert(newIndex, moved);
    setState(() {});
    await _operation(() => _store.reorder(_documents));
    if (mounted && _error != null) {
      setState(() => _documents = previous);
    }
  }

  Widget _documentCard(
    StockDocument document,
    int? index, {
    required bool draggable,
  }) {
    final card = Card(
      child: ListTile(
        enabled: !_busy,
        contentPadding: const EdgeInsets.all(16),
        leading: CircleAvatar(
          child: Icon(
            document.reviewed
                ? Icons.fact_check_outlined
                : Icons.pending_actions,
          ),
        ),
        title: Text(
          document.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          document.schemaVersion == 2
              ? '${_date(document.createdAt)} · ${document.lines.length} 项货物 · ${document.reviewed ? '已校对' : '待校对'}'
              : '${_date(document.createdAt)} · 待整理为两列表格',
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: '删除盘点单',
              onPressed: _busy ? null : () => _delete(document),
              icon: const Icon(Icons.delete_outline),
            ),
            if (index != null && draggable)
              ReorderableDragStartListener(
                index: index,
                child: const Padding(
                  padding: EdgeInsets.all(8),
                  child: Icon(Icons.drag_handle),
                ),
              )
            else
              const Icon(Icons.chevron_right),
          ],
        ),
        onTap: () => _operation(() => _open(document)),
      ),
    );
    final key = ValueKey(document.id);
    if (index == null || !draggable) {
      return KeyedSubtree(key: key, child: card);
    }
    // 长按卡片任意位置也可拖动，手柄用于更明确地开始拖动。
    return ReorderableDelayedDragStartListener(
      key: key,
      index: index,
      child: card,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final searching = _query.text.trim().isNotEmpty;
    final matches = _documents
        .where((document) => document.matches(_query.text))
        .toList();
    final reorderable = _ready && !searching && matches.length > 1;
    return Scaffold(
      appBar: AppBar(
        title: const Text('旧盘点单'),
        actions: [
          IconButton(
            onPressed: _busy || !_ready || _documents.length < 2
                ? null
                : _compare,
            icon: const Icon(Icons.compare_arrows),
            tooltip: '对比盘点单',
          ),
          IconButton(
            onPressed: _busy ? null : _load,
            icon: const Icon(Icons.refresh),
            tooltip: '刷新历史',
          ),
        ],
      ),
      body: CustomScrollView(
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.all(20),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        theme.colorScheme.primaryContainer,
                        theme.colorScheme.surfaceContainerLow,
                      ],
                    ),
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.receipt_long,
                        size: 36,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(height: 16),
                      Text('让旧盘点单，随时可查', style: theme.textTheme.headlineSmall),
                      const SizedBox(height: 8),
                      const Text(
                        '录屏 / 截图拼接 · 本机文字识别 · 历史搜索',
                        style: TextStyle(height: 1.8),
                      ),
                      const SizedBox(height: 20),
                      Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          FilledButton.icon(
                            onPressed: _busy || !_ready
                                ? null
                                : () => _import(true),
                            icon: const Icon(Icons.video_library_outlined),
                            label: const Text('拼接录屏'),
                          ),
                          FilledButton.tonalIcon(
                            onPressed: _busy || !_ready
                                ? null
                                : _importScreenshots,
                            icon: const Icon(Icons.collections_outlined),
                            label: const Text('拼接截图组'),
                          ),
                          OutlinedButton.icon(
                            onPressed: _busy || !_ready
                                ? null
                                : () => _import(false),
                            icon: const Icon(Icons.image_outlined),
                            label: const Text('识别长截图'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 0, 20, 12),
                  child: Text('截图组按拍摄时间从旧到新拼接，相邻截图请保留两三行重叠。'),
                ),
                ExpansionTile(
                  title: const Text('录屏使用说明'),
                  children: [
                    const SelectableText(
                      historyInstructions,
                      style: TextStyle(height: 1.8),
                    ),
                    TextButton.icon(
                      onPressed: () async {
                        await Clipboard.setData(
                          const ClipboardData(text: historyInstructions),
                        );
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('快捷指令说明已复制')),
                          );
                        }
                      },
                      icon: const Icon(Icons.copy),
                      label: const Text('复制设置说明'),
                    ),
                  ],
                ),
                if (_busy) ...[
                  const LinearProgressIndicator(),
                  const SizedBox(height: 12),
                  const Text('正在处理，请保持助手打开。录屏拼接和文字识别可能需要一些时间。'),
                ],
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _error!,
                          style: TextStyle(color: theme.colorScheme.error),
                        ),
                        const SizedBox(height: 8),
                        OutlinedButton.icon(
                          onPressed: _busy ? null : _shareDiagnostics,
                          icon: const Icon(Icons.bug_report_outlined, size: 18),
                          label: const Text('导出诊断日志'),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 20),
                Text(
                  '历史记录 · ${_documents.length}',
                  style: theme.textTheme.titleLarge,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _query,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    hintText: '搜索单据、品名或数字',
                    prefixIcon: const Icon(Icons.search),
                    filled: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                if (_ready && matches.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(
                      _documents.isEmpty ? '还没有历史盘点单，导入第一份吧。' : '没有找到匹配的记录。',
                      textAlign: TextAlign.center,
                    ),
                  ),
                if (reorderable)
                  const Padding(
                    padding: EdgeInsets.only(top: 4),
                    child: Text('长按或拖动右侧手柄可调整盘点单顺序。'),
                  ),
              ]),
            ),
          ),
          if (reorderable)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              sliver: SliverReorderableList(
                itemCount: matches.length,
                onReorderItem: _reorder,
                itemBuilder: (context, index) =>
                    _documentCard(matches[index], index, draggable: !_busy),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              sliver: SliverList.builder(
                itemCount: matches.length,
                itemBuilder: (context, index) =>
                    _documentCard(matches[index], null, draggable: false),
              ),
            ),
        ],
      ),
    );
  }
}

String _date(DateTime date) => date.toLocal().toString().substring(0, 16);

/// 详情页「更多」菜单里的导出与分享动作。
enum _ShareAction { excel, image }

class StockDocumentPage extends StatefulWidget {
  const StockDocumentPage({super.key, required this.document});
  final StockDocument document;
  @override
  State<StockDocumentPage> createState() => _StockDocumentPageState();
}

class _StockDocumentPageState extends State<StockDocumentPage> {
  final _store = StockHistoryStore();
  final _productStore = StockProductStore();
  List<StockProduct> _products = [];
  bool _productsLoaded = false;
  final _query = TextEditingController();
  late final TextEditingController _title;
  late List<StockLine> _lines;
  late StockDocument _document;
  bool _preparing = false;
  List<Uint8List>? _images;
  String? _error;
  bool _saving = false;
  bool _sharing = false;
  bool _showImage = false;
  bool _onlyPending = false;

  @override
  void initState() {
    super.initState();
    _document = widget.document;
    _title = TextEditingController(text: _document.title);
    _lines = [...widget.document.lines];
    _prepare();
  }

  Future<void> _prepare() async {
    setState(() => _preparing = true);
    try {
      final images = await _store.imageTiles(_document);
      if (mounted) setState(() => _images = images);
      final products = await _productStore.load();
      if (mounted) {
        setState(() {
          _products = products;
          _productsLoaded = true;
        });
      }
      final table = await _store.table(_document);
      if (mounted) {
        setState(() {
          if (_title.text == _document.title) _title.text = table.title;
          _document = table;
          _lines = _reconcileProducts(table.lines, products);
          _products = products;
        });
      }
    } on PlatformException catch (error) {
      if (mounted) setState(() => _error = error.message ?? error.code);
    } on FormatException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _preparing = false);
    }
  }

  @override
  void dispose() {
    _query.dispose();
    _title.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final document = _document.edited(_title.text, _lines);
      await _store.save(document);
      if (mounted) Navigator.pop(context, document);
    } on FormatException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } on PlatformException catch (error) {
      if (mounted) setState(() => _error = error.message ?? error.code);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 导出与分享共用一套忙碌与错误呈现，避免和保存逻辑各写一份。
  Future<void> _run(Future<void> Function() action) async {
    if (_sharing) return;
    setState(() {
      _sharing = true;
      _error = null;
    });
    try {
      await action();
    } on FormatException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } on PlatformException catch (error) {
      if (mounted) setState(() => _error = error.message ?? error.code);
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  void _share(_ShareAction action) => switch (action) {
    _ShareAction.excel => _exportExcel(),
    _ShareAction.image => _shareImage(),
  };

  /// 导出当前页面所见，包括尚未点「保存修改」的校对改动。
  Future<void> _exportExcel() => _run(() async {
    final table = buildConfirmedStockExportTable(_title.text, _lines);
    await _store.shareBytes(
      name: '${sanitizeFileName(_title.text)}.xlsx',
      bytes: Uint8List.fromList(encodeStockWorkbook(table)),
    );
    if (mounted) _notify('已生成 ${table.rows.length} 行 Excel，请在分享面板选择微信');
  });

  Future<void> _shareImage() => _run(() async {
    await _store.shareImage(_document);
    if (mounted) _notify('已打开分享面板，可发送长图到微信');
  });

  /// 把最近一次识别任务的诊断日志交给系统分享面板，用于定位解析失败。
  Future<void> _shareDiagnostics() => _run(() => _store.shareDiagnostics());

  void _notify(String message) =>
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));

  PopupMenuItem<_ShareAction> _shareItem(
    _ShareAction action,
    IconData icon,
    String label, {
    required bool enabled,
  }) {
    return PopupMenuItem(
      value: action,
      enabled: enabled,
      // ListTile 自身负责把禁用项的标题与图标画成灰色。
      child: ListTile(
        enabled: enabled,
        dense: true,
        contentPadding: EdgeInsets.zero,
        leading: Icon(icon),
        title: Text(label),
      ),
    );
  }

  Future<void> _edit(int index) async {
    await _run(() async {
      final line = _lines[index];
      final images = line.sourceTop != null && line.sourceBottom != null
          ? [await _store.rowImage(_document, line)]
          : _images!;
      if (!mounted) return;
      final updated = await showDialog<StockLine>(
        context: context,
        builder: (_) => StockReviewDialog(
          line: line,
          products: _products,
          images: images,
          onCreate: (product) async {
            final next = [..._products, product];
            await _productStore.save(next);
            if (mounted) setState(() => _products = next);
          },
        ),
      );
      if (updated != null && mounted) setState(() => _lines[index] = updated);
    });
  }

  Future<void> _manageProducts() async {
    await Navigator.of(
      context,
    ).push<void>(MaterialPageRoute(builder: (_) => const StockProductPage()));
    if (!mounted) return;
    setState(() => _productsLoaded = false);
    await _run(() async {
      final products = await _productStore.load();
      if (mounted) {
        setState(() {
          _products = products;
          _productsLoaded = true;
          _lines = _reconcileProducts(_lines, products);
        });
      }
    });
  }

  List<StockLine> _reconcileProducts(
    List<StockLine> lines,
    List<StockProduct> products,
  ) => reconcileStockLines(lines, products);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final matches = _lines
        .asMap()
        .entries
        .where(
          (entry) =>
              entry.value.text.toLowerCase().contains(
                _query.text.trim().toLowerCase(),
              ) &&
              (!_onlyPending || !entry.value.ready),
        )
        .toList();
    return PopScope(
      canPop: !_saving,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('盘点单详情'),
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(76),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: TextField(
                controller: _title,
                enabled: !_saving,
                decoration: const InputDecoration(
                  labelText: '单据名称（可填写日期 / 门店 / 单号）',
                ),
              ),
            ),
          ),
          actions: [
            IconButton(
              onPressed: _saving || _preparing || _sharing
                  ? null
                  : _manageProducts,
              icon: const Icon(Icons.inventory_2_outlined),
              tooltip: '盘点货物档案',
            ),
            IconButton(
              onPressed: () => setState(() => _showImage = !_showImage),
              icon: Icon(
                _showImage ? Icons.table_rows_outlined : Icons.image_outlined,
              ),
              tooltip: '原图 / 表格',
            ),
            PopupMenuButton<_ShareAction>(
              onSelected: _share,
              tooltip: '导出与分享',
              itemBuilder: (context) => [
                _shareItem(
                  _ShareAction.excel,
                  Icons.table_view_outlined,
                  '导出 Excel',
                  // 货物表整理完成前导不出两列数据，长图未就绪时也无处可分享。
                  enabled:
                      _document.schemaVersion == 2 &&
                      !_preparing &&
                      !_saving &&
                      !_sharing &&
                      _lines.every((line) => line.ready),
                ),
                _shareItem(
                  _ShareAction.image,
                  Icons.ios_share_outlined,
                  '分享长图',
                  enabled: _images != null && !_saving,
                ),
              ],
            ),
          ],
        ),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: FilledButton.icon(
              onPressed:
                  _saving ||
                      _preparing ||
                      _document.schemaVersion != 2 ||
                      _images == null
                  ? null
                  : _save,
              icon: const Icon(Icons.save_outlined),
              label: Text(
                _saving
                    ? '正在保存…'
                    : _lines.every((line) => line.ready)
                    ? '保存已确认盘点单'
                    : '保存草稿',
              ),
            ),
          ),
        ),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(
              '导入于 ${_date(widget.document.createdAt)} · ${_document.schemaVersion == 2 ? '${_lines.length} 项货物' : '等待整理货物表'}',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Text(
              _document.schemaVersion == 2
                  ? '自动通过 ${_lines.where((line) => line.ready && line.autoConfirmed).length} 行，人工确认 ${_lines.where((line) => line.ready && !line.autoConfirmed).length} 行，需复核 ${_lines.where((line) => !line.ready).length} 行。只需处理疑点，完成后确认单据即可导出。'
                  : '原始长图已保留，货物表尚未整理完成。可切换查看长图核对。',
            ),
            if (_error != null) ...[
              Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _sharing ? null : _shareDiagnostics,
                icon: const Icon(Icons.bug_report_outlined, size: 18),
                label: const Text('导出诊断日志'),
              ),
            ],
            const SizedBox(height: 16),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(
                  value: false,
                  label: Text('两列表格'),
                  icon: Icon(Icons.table_chart_outlined),
                ),
                ButtonSegment(
                  value: true,
                  label: Text('查看长图'),
                  icon: Icon(Icons.image_outlined),
                ),
              ],
              selected: {_showImage},
              onSelectionChanged: (selection) =>
                  setState(() => _showImage = selection.single),
            ),
            const SizedBox(height: 16),
            if (_preparing) ...[
              const LinearProgressIndicator(),
              const Text('正在从历史长图整理两列盘点表，请保持助手打开…'),
            ],
            if (_showImage && _images != null) ...[
              const Text('长图按原比例显示，上下滚动查看；点击任意一段可放大核对。'),
              const SizedBox(height: 12),
              for (final image in _images!)
                GestureDetector(
                  onTap: () => Navigator.of(context).push<void>(
                    MaterialPageRoute(
                      builder: (context) => Scaffold(
                        appBar: AppBar(title: const Text('放大查看')),
                        body: InteractiveViewer(
                          minScale: 1,
                          maxScale: 6,
                          child: Center(
                            child: Image.memory(image, fit: BoxFit.contain),
                          ),
                        ),
                      ),
                    ),
                  ),
                  child: Image.memory(
                    image,
                    width: double.infinity,
                    fit: BoxFit.fitWidth,
                  ),
                ),
            ],
            if (!_showImage && !_preparing && _document.schemaVersion == 2) ...[
              SwitchListTile(
                value: _onlyPending,
                onChanged: (value) => setState(() => _onlyPending = value),
                title: const Text('只看待复核行'),
              ),
              OutlinedButton.icon(
                onPressed:
                    _saving ||
                        _sharing ||
                        _images == null ||
                        !_productsLoaded ||
                        _lines.every((line) => line.ready)
                    ? null
                    : () => _edit(_lines.indexWhere((line) => !line.ready)),
                icon: const Icon(Icons.fact_check_outlined),
                label: const Text('复核下一条疑点'),
              ),
              TextField(
                controller: _query,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: '在这张单据内搜索',
                ),
              ),
              const SizedBox(height: 16),
              if (matches.isEmpty) const Text('没有匹配的货物'),
              if (matches.isNotEmpty)
                Table(
                  columnWidths: const {
                    0: FlexColumnWidth(3),
                    1: FlexColumnWidth(2),
                  },
                  border: TableBorder.all(
                    color: theme.colorScheme.outlineVariant,
                  ),
                  defaultVerticalAlignment: TableCellVerticalAlignment.middle,
                  children: [
                    TableRow(
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primaryContainer,
                      ),
                      children: const [
                        Padding(
                          padding: EdgeInsets.all(12),
                          child: Text(
                            '货物规格名称',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                        Padding(
                          padding: EdgeInsets.all(12),
                          child: Text(
                            '实盘总库存',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    ),
                    for (final entry in matches)
                      TableRow(
                        decoration: BoxDecoration(
                          color: entry.key.isEven
                              ? theme.colorScheme.surfaceContainerLow
                              : theme.colorScheme.surface,
                        ),
                        children: [
                          Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (entry.value.isPrepared)
                                  Text(
                                    '预制物料',
                                    style: theme.textTheme.labelSmall,
                                  ),
                                SelectableText(entry.value.cells[0]),
                                Text(
                                  entry.value.ready
                                      ? (entry.value.autoConfirmed
                                            ? '自动通过'
                                            : '已确认')
                                      : entry.value.pendingReason,
                                  style: TextStyle(
                                    color: entry.value.ready
                                        ? null
                                        : theme.colorScheme.error,
                                  ),
                                ),
                                if (entry.value.reviewIssue != null &&
                                    entry.value.reviewIssue != '库存数字待确认')
                                  Text(
                                    entry.value.reviewIssue!,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: theme.colorScheme.error,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.only(left: 12),
                            child: Row(
                              children: [
                                Expanded(
                                  child: StockInventoryView(
                                    inventory: entry.value.inventory,
                                  ),
                                ),
                                IconButton(
                                  onPressed:
                                      _saving ||
                                          _sharing ||
                                          _images == null ||
                                          !_productsLoaded
                                      ? null
                                      : () => _edit(entry.key),
                                  icon: const Icon(Icons.edit_outlined),
                                  tooltip: '校对货物',
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
            ],
          ],
        ),
      ),
    );
  }
}
