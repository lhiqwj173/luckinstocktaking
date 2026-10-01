import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'stock_history.dart';

const historyInstructions =
    '自动录屏：快捷指令只需添加「开始读取旧盘点单」。\n'
    '运行后点系统录屏按钮，并确认「开始直播」，再切回瑞幸盘滚动单据。\n'
    '结束系统录屏后返回助手，自动拼接、识别并保存为待校对历史，无需选择视频。\n'
    '录屏只保存在本机；专用入口隐藏麦克风按钮，不保存音轨。\n'
    'iOS 仍要求确认开始，且不会保证结束后自动切回助手。\n\n'
    '手动导入已有录屏：\n'
    '1. 在瑞幸盘打开旧盘点单，从顶部开始系统录屏。\n'
    '2. 顶部和底部各停留 1 秒，始终朝下缓慢滚动，到底后停止录屏；不要切换页面或横竖屏。\n'
    '若录屏含控制中心或停止录屏弹窗，先在系统照片中剪掉开头和结尾的遮挡画面。\n'
    '3. 快捷指令添加「选择照片」（选择视频）→「读取旧盘点单」，'
    '把选中视频传入「盘点单文件」，打开「录屏视频」。\n'
    '4. 用「顶部裁剪比例」「底部裁剪比例」排除固定导航和底栏；'
    '默认分别为 0.18 和 0.10，可先在助手内预览调整。\n'
    '5. 添加「打开 App」→称重盘点助手，进入「旧盘点单」校对并保存。\n'
    '也可以直接在本页导入录屏或已有长截图。快捷指令导入的记录会标为待校对。\n'
    '录屏最长 120 秒；一次只处理一张盘点单。搜索覆盖单据名称和所有文字。';

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
  double _top = .18;
  double _bottom = .10;

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
    final document = await _store.pick(
      video: video,
      top: _top,
      bottom: _bottom,
    );
    if (document == null || !mounted) return;
    await _open(document);
  });
  Future<void> _startCapture() =>
      _operation(() => _store.startCapture(top: _top, bottom: _bottom));
  Future<void> _clearCaptureFailures() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清除失败的录屏任务？'),
        content: const Text('将删除失败录屏的临时视频与错误记录。已保存的历史盘点单会保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _operation(() async {
      await _store.clearCaptureFailures();
      final documents = await _store.load();
      if (mounted) setState(() => _documents = documents);
    });
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final matches = _documents
        .where((document) => document.matches(_query.text))
        .toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('旧盘点单'),
        actions: [
          IconButton(
            onPressed: _busy ? null : _load,
            icon: const Icon(Icons.refresh),
            tooltip: '刷新历史',
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
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
                  '录屏拼接 · 本机文字识别 · 历史搜索',
                  style: TextStyle(height: 1.8),
                ),
                const SizedBox(height: 20),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    FilledButton.icon(
                      onPressed: _busy || !_ready ? null : _startCapture,
                      icon: const Icon(Icons.screen_share_outlined),
                      label: const Text('开始自动录屏'),
                    ),
                    FilledButton.icon(
                      onPressed: _busy || !_ready ? null : () => _import(true),
                      icon: const Icon(Icons.video_library_outlined),
                      label: const Text('导入录屏'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _busy || !_ready ? null : () => _import(false),
                      icon: const Icon(Icons.image_outlined),
                      label: const Text('识别长截图'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          ExpansionTile(
            title: const Text('录屏范围与快捷指令'),
            children: [
              const Text('裁剪固定栏（只影响录屏）。选择视频后会先显示首帧范围预览。'),
              Text('顶部裁剪 ${(_top * 100).round()}%'),
              Slider(
                value: _top,
                min: 0,
                max: .4,
                divisions: 40,
                onChanged: _busy
                    ? null
                    : (value) => setState(() => _top = value),
              ),
              Text('底部裁剪 ${(_bottom * 100).round()}%'),
              Slider(
                value: _bottom,
                min: 0,
                max: .3,
                divisions: 30,
                onChanged: _busy
                    ? null
                    : (value) => setState(() => _bottom = value),
              ),
              const SelectableText(
                historyInstructions,
                style: TextStyle(height: 1.8),
              ),
              TextButton(
                onPressed: _busy ? null : _clearCaptureFailures,
                child: const Text('清除失败的录屏任务'),
              ),
              TextButton.icon(
                onPressed: () async {
                  await Clipboard.setData(
                    const ClipboardData(text: historyInstructions),
                  );
                  if (context.mounted) {
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(const SnackBar(content: Text('快捷指令说明已复制')));
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
              child: Text(
                _error!,
                style: TextStyle(color: theme.colorScheme.error),
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
          for (final document in matches)
            Card(
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
                  '${_date(document.createdAt)} · ${document.lines.length} 行 · ${document.reviewed ? '已校对' : '待校对'}',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _operation(() => _open(document)),
              ),
            ),
        ],
      ),
    );
  }
}

String _date(DateTime date) => date.toLocal().toString().substring(0, 16);

class StockDocumentPage extends StatefulWidget {
  const StockDocumentPage({super.key, required this.document});
  final StockDocument document;
  @override
  State<StockDocumentPage> createState() => _StockDocumentPageState();
}

class _StockDocumentPageState extends State<StockDocumentPage> {
  final _store = StockHistoryStore();
  final _query = TextEditingController();
  late final TextEditingController _title;
  late List<StockLine> _lines;
  Uint8List? _image;
  String? _error;
  bool _saving = false;
  bool _showImage = false;

  @override
  void initState() {
    super.initState();
    _title = TextEditingController(text: widget.document.title);
    _lines = [...widget.document.lines];
    _loadImage();
  }

  Future<void> _loadImage() async {
    try {
      final image = await _store.image(widget.document);
      if (mounted) setState(() => _image = image);
    } on PlatformException catch (error) {
      if (mounted) setState(() => _error = error.message ?? error.code);
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
      final document = widget.document.edited(_title.text, _lines);
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

  Future<void> _edit(int index) async {
    final controller = TextEditingController(
      text: _lines[index].cells.join('\t'),
    );
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('校对这一行'),
        content: TextField(
          controller: controller,
          maxLines: 5,
          decoration: const InputDecoration(
            helperText: '用制表符或 | 分隔单元格',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('更新'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result == null || !mounted) return;
    final cells = result
        .split(RegExp(r'[\t|]'))
        .map((cell) => cell.trim())
        .toList();
    if (cells.any((cell) => cell.isEmpty)) {
      setState(() => _error = '单元格不能为空，请重新校对');
      return;
    }
    setState(() {
      _lines[index] = StockLine(cells: cells, confidence: 1);
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final matches = _lines
        .asMap()
        .entries
        .where(
          (entry) => entry.value.text.toLowerCase().contains(
            _query.text.trim().toLowerCase(),
          ),
        )
        .toList();
    return PopScope(
      canPop: !_saving,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('盘点单详情'),
          actions: [
            IconButton(
              onPressed: () => setState(() => _showImage = !_showImage),
              icon: Icon(
                _showImage ? Icons.table_rows_outlined : Icons.image_outlined,
              ),
              tooltip: '原图 / 表格',
            ),
          ],
        ),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: FilledButton.icon(
              onPressed: _saving || _image == null ? null : _save,
              icon: const Icon(Icons.save_outlined),
              label: Text(_saving ? '正在保存…' : '保存修改并标记已校对'),
            ),
          ),
        ),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            TextField(
              controller: _title,
              enabled: !_saving,
              decoration: const InputDecoration(
                labelText: '单据名称（可填写日期 / 门店 / 单号）',
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '导入于 ${_date(widget.document.createdAt)} · ${_lines.length} 行',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            const Text('识别结果已自动保存。请核对品名、数量和单位；点击铅笔可修正，完成后标记已校对。'),
            if (_error != null)
              Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            const SizedBox(height: 16),
            if (_showImage && _image != null) Image.memory(_image!),
            if (!_showImage) ...[
              TextField(
                controller: _query,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: '在这张单据内搜索',
                ),
              ),
              const SizedBox(height: 16),
              if (matches.isEmpty) const Text('没有匹配的文字行'),
              for (final entry in matches)
                Card(
                  color: entry.value.confidence < .8
                      ? theme.colorScheme.errorContainer
                      : null,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 32,
                          child: Text(
                            '${entry.key + 1}',
                            style: theme.textTheme.labelSmall,
                          ),
                        ),
                        Expanded(
                          child: Wrap(
                            spacing: 16,
                            runSpacing: 8,
                            children: [
                              for (final cell in entry.value.cells)
                                SelectableText(cell),
                              if (entry.value.confidence < .8)
                                const Text(
                                  '需重点核对',
                                  style: TextStyle(fontSize: 11),
                                ),
                            ],
                          ),
                        ),
                        IconButton(
                          onPressed: _saving ? null : () => _edit(entry.key),
                          icon: const Icon(Icons.edit_outlined),
                          tooltip: '校对文字',
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
