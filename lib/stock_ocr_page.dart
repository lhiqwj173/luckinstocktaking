import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'stock_history.dart';
import 'stock_ocr.dart';
import 'stock_product.dart';
import 'stock_debug.dart';

class StockOCRPage extends StatefulWidget {
  const StockOCRPage({super.key, this.document});
  final StockDocument? document;
  @override
  State<StockOCRPage> createState() => _StockOCRPageState();
}

class _StockOCRPageState extends State<StockOCRPage> {
  final _store = StockOCRStore();
  StockOCREngine? _selected;
  StockOCREngine? _choice;
  bool _onlyPending = true;
  StockDocument? _reference;
  List<StockProduct> _products = [];
  final _runs = <StockOCREngine, StockOCRRun>{};
  bool _busy = true;
  bool _loaded = false;
  bool _captureInputs = false;
  String? _error;
  String _progress = '读取模型设置';
  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() => _perform(() async {
    _loaded = false;
    _selected = await _store.selected();
    _choice = _selected;
    final capture = await StockHistoryStore.channel.invokeMethod<bool>(
      'getOCRDebugInputs',
    );
    if (capture == null) throw const FormatException('未返回调试采集设置');
    _captureInputs = capture;
    if (widget.document != null) {
      _products = await StockProductStore().load();
      _reference = await _store.reference(widget.document!.id);
      final runs = await _store.runs(widget.document!.id);
      _runs.clear();
      for (final run in runs) {
        _runs[run.engine] = run;
      }
    }
    _loaded = true;
  });

  Future<void> _perform(Future<void> Function() operation) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await operation();
    } on PlatformException catch (error) {
      if (mounted) {
        setState(() => _error = '$_progress：${error.message ?? error.code}');
      }
    } on FormatException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _evaluate(List<StockOCREngine> engines) => _perform(() async {
    // 全部模型使用同一份档案，原生使用同一原图和识别规则。
    _products = await StockProductStore().load();
    for (final engine in engines) {
      if (!mounted) return;
      setState(() {
        _progress = '正在评估 ${engine.label}';
        _runs.remove(engine);
      });
      final run = await _store.evaluate(widget.document!.id, engine);
      if (_runs.values.any(
        (previous) =>
            previous.metrics['imageSHA256'] != run.metrics['imageSHA256'] ||
            previous.metrics['policyRevision'] != run.metrics['policyRevision'],
      )) {
        throw const FormatException('原图或处理规则已变化，请重新打开对比页面');
      }
      if (!mounted) return;
      setState(() => _runs[engine] = run);
    }
  });
  Future<void> _setReference() async {
    bool checked = false;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('设置人工参考单'),
          content: CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('我已逐项对照原图核实货物、库存、单位、分区，并检查没有漏行或多行。'),
            subtitle: const Text('自动通过不代表人工核实。参考单只用于评估，独立保存。'),
            value: checked,
            onChanged: (value) => update(() => checked = value!),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: checked ? () => Navigator.pop(context, true) : null,
              child: const Text('设为参考单'),
            ),
          ],
        ),
      ),
    );
    if (accepted != true || !mounted) return;
    await _perform(() async {
      final doc = widget.document!.edited(
        widget.document!.title,
        widget.document!.lines,
      );
      await _store.saveReference(doc);
      _reference = doc;
    });
  }

  String _percent(double value) => '${(value * 100).toStringAsFixed(1)}%';
  List<StockLine> _lines(StockOCRRun run) =>
      reconcileStockLines(run.document.lines, _products);
  Widget _comparison() {
    final runs = [
      for (final engine in StockOCREngine.values)
        if (_runs[engine] != null) _runs[engine]!,
    ];
    if (runs.isEmpty) return const Text('尚无评估结果。可先评估单个模型或对比全部模型。');
    final lines = [for (final run in runs) _lines(run)];
    final scores = [
      for (final rows in lines)
        _reference == null
            ? null
            : StockOCRScore(reference: _reference!.lines, actual: rows),
    ];
    final rows = <String, List<String>>{
      'OCR 与分行耗时（秒）': [
        for (final run in runs)
          ((run.metrics['elapsedMs'] as num) / 1000).toStringAsFixed(2),
      ],
      '评估时间（本地）': [
        for (final run in runs)
          run.evaluatedAt.toLocal().toString().split('.').first,
      ],
      '其中模型加载（秒）': [
        for (final run in runs)
          ((run.metrics['modelLoadMs'] as num) / 1000).toStringAsFixed(2),
      ],
      '识别行数': [for (final list in lines) '${list.length}'],
      '自动通过率': [
        for (final list in lines)
          _percent(
            list.where((line) => line.ready && line.autoConfirmed).length /
                list.length,
          ),
      ],
      '待复核行数': [
        for (final list in lines) '${list.where((line) => !line.ready).length}',
      ],
      '库存整行准确率': [
        for (final score in scores)
          score == null ? '尚未评估' : _percent(score.inventoryAccuracy),
      ],
      '货物匹配准确率': [
        for (final score in scores)
          score == null ? '尚未评估' : _percent(score.identityAccuracy),
      ],
      '漏行 / 额外行': [
        for (final score in scores)
          score == null ? '尚未评估' : '${score.missing} / ${score.extras}',
      ],
      '错误自动通过行数': [
        for (final score in scores)
          score == null ? '尚未评估' : '${score.wrongAutomatic}',
      ],
      '结束时进程内存（MiB）': [
        for (final run in runs)
          ((run.metrics['residentBytes'] as num) / 1048576).toStringAsFixed(1),
      ],
      '附带模型权重（MiB）': [
        for (final run in runs)
          run.engine == StockOCREngine.vision
              ? '系统提供'
              : ((run.metrics['modelBytes'] as num) / 1048576).toStringAsFixed(
                  1,
                ),
      ],
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('结果只看待复核行'),
          value: _onlyPending,
          onChanged: (value) => setState(() => _onlyPending = value),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            columns: [
              const DataColumn(label: Text('指标')),
              for (final run in runs) DataColumn(label: Text(run.engine.label)),
            ],
            rows: [
              for (final entry in rows.entries)
                DataRow(
                  cells: [
                    DataCell(Text(entry.key)),
                    for (final value in entry.value) DataCell(Text(value)),
                  ],
                ),
            ],
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Text(
            '耗时包含分行和库存复读；模型加载为 0 表示本次复用了会话，Vision 加载由系统管理。内存是整个 App 结束时的占用，不是模型峰值内存。自动通过率不是准确率。准确率按参考行数＋额外行数计算，库存的数字、单位和分区须全部一致。不同引擎的置信度不用于排名。',
          ),
        ),
        for (var i = 0; i < runs.length; i++)
          Card(
            child: ExpansionTile(
              title: Text(
                '${runs[i].engine.label} · 待复核 ${lines[i].where((line) => !line.ready).length} / ${lines[i].length} 行',
              ),
              children: [
                if (_onlyPending && lines[i].every((line) => line.ready))
                  const ListTile(title: Text('全部自动通过，可关闭“只看待复核行”查看完整结果')),
                for (final line in lines[i].where(
                  (line) => !_onlyPending || !line.ready,
                ))
                  ListTile(
                    tileColor: line.ready
                        ? null
                        : Theme.of(context).colorScheme.errorContainer,
                    leading: Icon(
                      line.ready
                          ? Icons.check_circle_outline
                          : Icons.warning_amber_rounded,
                      color: line.ready
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.error,
                    ),
                    title: Text(line.cells[0]),
                    subtitle: Text(
                      '${line.cells[1]}\n${line.ready ? '自动通过' : '待复核：${line.pendingReason}'}',
                    ),
                  ),
                if (scores[i] != null)
                  ListTile(
                    title: Text('与人工参考单的差异：${scores[i]!.differences.length} 行'),
                  ),
                if (scores[i] != null)
                  for (final difference in scores[i]!.differences)
                    ListTile(
                      tileColor: Theme.of(context).colorScheme.errorContainer,
                      title: Text(
                        (difference.reference ?? difference.actual)!.cells[0],
                      ),
                      subtitle: Text(
                        '${difference.issue}\n参考：${difference.reference?.cells[1] ?? '无此行'}\n识别：${difference.actual?.cells[1] ?? '未识别'}',
                      ),
                    ),
              ],
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: Scaffold(
      appBar: AppBar(title: const Text('识别模型与对比')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text(
            '选择本次使用的模型',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('详细调试采集（下次识别生效）'),
            subtitle: const Text('记录实际送入模型的每张局部 PNG。开启后增加耗时和空间；候选、坐标及参数默认记录。'),
            value: _captureInputs,
            onChanged: _busy || !_loaded
                ? null
                : (value) => _perform(() async {
                    _progress = '保存调试采集设置';
                    await StockHistoryStore.channel.invokeMethod<void>(
                      'setOCRDebugInputs',
                      value,
                    );
                    _captureInputs = value;
                  }),
          ),
          Text(
            '后续导入默认：${_selected?.label ?? '正在读取'}。选择模型后，点击下方“重新识别此单”查看当前单据的结果；保存为默认才会影响后续导入。',
          ),
          for (final engine in StockOCREngine.values)
            ListTile(
              title: Text(engine.label),
              leading: Icon(
                _choice == engine
                    ? Icons.radio_button_checked
                    : Icons.radio_button_off,
              ),
              subtitle: Text(
                engine == StockOCREngine.vision
                    ? 'iOS 系统识别'
                    : engine == StockOCREngine.tiny
                    ? '轻量模型，优先考虑速度和内存'
                    : '较大模型，准确性需按实际盘点单评估',
              ),
              onTap: _busy ? null : () => setState(() => _choice = engine),
            ),
          OutlinedButton(
            onPressed: _busy || _choice == null
                ? null
                : () => _perform(() async {
                    _progress = '保存默认模型 ${_choice!.label}';
                    await _store.select(_choice!);
                    _selected = _choice;
                  }),
            child: const Text('将所选模型设为后续导入默认'),
          ),
          if (_busy) ...[const LinearProgressIndicator(), Text(_progress)],
          if (_error != null) ...[
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            TextButton(
              onPressed: _busy ? null : _initialize,
              child: const Text('重试读取设置'),
            ),
          ],
          if (widget.document != null) ...[
            const Divider(),
            Text(
              '同图对比：${widget.document!.title}',
              style: const TextStyle(fontSize: 20),
            ),
            const Text('读取这张单据保存的同一原图。评估结果独立保存，原盘点单和人工修改保持完整。'),
            OutlinedButton.icon(
              onPressed: _busy || !_loaded
                  ? null
                  : () => _perform(() async {
                      _progress = '生成模型对比调试包';
                      final products = await StockProductStore().load();
                      await shareStockDebug(
                        StockHistoryStore(),
                        document: widget.document,
                        products: products,
                      );
                    }),
              icon: const Icon(Icons.bug_report_outlined),
              label: const Text('导出解析与模型对比调试包'),
            ),
            FilledButton(
              onPressed: _busy || !_loaded || _choice == null
                  ? null
                  : () => _evaluate([_choice!]),
              child: Text('使用 ${_choice?.label ?? '所选模型'} 重新识别此单'),
            ),
            FilledButton(
              onPressed: _busy || !_loaded
                  ? null
                  : () => _evaluate(StockOCREngine.values),
              child: const Text('对比全部三个模型（不更改默认模型）'),
            ),
            OutlinedButton(
              onPressed:
                  _busy ||
                      !_loaded ||
                      widget.document!.lines.any((line) => !line.ready)
                  ? null
                  : _setReference,
              child: Text(_reference == null ? '将人工核实的当前单据设为参考单' : '更新人工参考单'),
            ),
            Text(
              _reference == null
                  ? '核实整张盘点单并完成所有疑点后，可设置参考单来评估准确率。'
                  : '已保存人工参考单：${_reference!.lines.length} 行',
            ),
            _comparison(),
          ] else
            const Text('打开一张盘点单，从详情页进入本页，即可对同一原图评估三个模型。'),
        ],
      ),
    ),
  );
}
