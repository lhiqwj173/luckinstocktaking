import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:luckinstocktaking/stock_history.dart';
import 'package:luckinstocktaking/stock_ocr.dart';
import 'package:luckinstocktaking/stock_ocr_page.dart';

StockLine row(String id, String inventory, {bool automatic = false}) =>
    StockLine(
      cells: [id, inventory],
      confidence: .9,
      productId: id,
      identityConfirmed: true,
      inventoryConfirmed: true,
      autoConfirmed: automatic,
    );
StockDocument doc(List<StockLine> lines, {String engine = 'vision'}) =>
    StockDocument(
      id: '12345678-1234-1234-1234-123456789abc',
      title: '评估单',
      createdAt: DateTime.utc(2026, 10, 8),
      imageName: '12345678-1234-1234-1234-123456789abc.png',
      lines: lines,
      reviewed: false,
      schemaVersion: 2,
      recognitionRevision: 22,
      ocrEngine: engine,
    );
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('库存准确率计入漏行和额外行，错误自动通过单独计数', () {
    final score = StockOCRScore(
      reference: [row('a', '1.5袋'), row('b', '0盒'), row('c', '2桶')],
      actual: [
        row('a', '15袋', automatic: true),
        row('b', '0.0盒', automatic: true),
        row('d', '1袋', automatic: true),
      ],
    );
    expect(score.total, 3);
    expect(score.inventories, 1);
    expect(score.identities, 2);
    expect(score.missing, 1);
    expect(score.extras, 1);
    expect(score.inventoryAccuracy, .25);
    expect(score.identityAccuracy, .5);
    expect(score.wrongAutomatic, 2);
    expect(score.differences.length, 3);
  });
  test('重复识别不任选正确的一条；空白、零和分区必须分开', () {
    final duplicated = StockOCRScore(
      reference: [row('a', '1袋')],
      actual: [row('a', '1袋'), row('a', '3袋')],
    );
    expect(duplicated.inventoryAccuracy, 0);
    expect(duplicated.missing, 1);
    expect(duplicated.extras, 2);
    final blank = StockOCRScore(
      reference: [row('a', '-袋'), row('b', '总库存2盒\n冷藏1盒\n冷冻1盒')],
      actual: [row('a', '0袋'), row('b', '2盒')],
    );
    expect(blank.inventories, 0);
  });
  test('未核实或重复的参考单被拒绝，旧单默认 Vision，模型信息往返保存', () {
    expect(
      () => StockOCRScore(
        reference: [
          StockLine(cells: ['a', '1袋'], confidence: .9),
        ],
        actual: [],
      ),
      throwsFormatException,
    );
    expect(
      () => StockOCRScore(
        reference: [row('a', '1袋'), row('a', '1袋')],
        actual: [],
      ),
      throwsFormatException,
    );
    final json = doc([row('a', '1袋')]).toJson()..remove('ocrEngine');
    expect(StockDocument.fromJson(json).ocrEngine, 'vision');
    final tiny = doc([row('a', '1袋')], engine: 'paddle_tiny');
    expect(
      StockDocument.fromJson(tiny.edited('新标题', tiny.lines).toJson()).ocrEngine,
      'paddle_tiny',
    );
    expect(() => StockOCREngine.parse('unknown'), throwsFormatException);
  });
  testWidgets('模型选择持久化；加载失败明确显示，不假切换', (tester) async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var selected = 'vision';
    var captureInputs = false;
    var failSmall = false;
    messenger.setMockMethodCallHandler(StockHistoryStore.channel, (call) async {
      if (call.method == 'getOCREngine') return selected;
      if (call.method == 'getOCRDebugInputs') return captureInputs;
      if (call.method == 'setOCRDebugInputs') {
        captureInputs = call.arguments as bool;
        return null;
      }
      if (call.method == 'setOCREngine') {
        if (failSmall && call.arguments == 'paddle_small') {
          throw PlatformException(code: 'missing_model', message: '模型文件缺失');
        }
        selected = call.arguments as String;
        return null;
      }
      throw StateError('非预期调用 ${call.method}');
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(StockHistoryStore.channel, null),
    );
    await tester.pumpWidget(const MaterialApp(home: StockOCRPage()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('PP-OCRv6 tiny'));
    await tester.pumpAndSettle();
    expect(selected, 'vision');
    await tester.ensureVisible(find.text('将所选模型设为后续导入默认'));
    await tester.tap(find.text('将所选模型设为后续导入默认'));
    await tester.pumpAndSettle();
    expect(selected, 'paddle_tiny');
    await tester.ensureVisible(find.text('详细调试采集（下次识别生效）'));
    await tester.tap(find.text('详细调试采集（下次识别生效）'));
    await tester.pumpAndSettle();
    expect(captureInputs, true);
    failSmall = true;
    await tester.tap(find.text('PP-OCRv6 small'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('将所选模型设为后续导入默认'));
    await tester.pumpAndSettle();
    expect(selected, 'paddle_tiny');
    expect(find.textContaining('模型文件缺失'), findsOneWidget);
  });
  testWidgets('同图评估使用本次模型且不改变默认，待复核结果高亮', (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final pending = StockLine(cells: ['待复核货物', '8.4袋'], confidence: .9);
    Map<String, dynamic> run(String engine) => {
      'engine': engine,
      'evaluatedAt': '2026-10-09T10:00:00Z',
      'document': doc([pending], engine: engine).toJson()
        ..['recognitionRevision'] = 23,
      'metrics': {
        'elapsedMs': 100.0,
        'modelLoadMs': 10.0,
        'ocrCalls': 2,
        'processedPixels': 1000,
        'modelBytes': 100,
        'residentBytes': 1000,
        'policyRevision': 23,
        'imageSHA256': 'a' * 64,
      },
    };
    final called = <String>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(StockHistoryStore.channel, (call) async {
      switch (call.method) {
        case 'getOCREngine':
          return 'vision';
        case 'getOCRDebugInputs':
          return false;
        case 'loadProducts':
          return '[]';
        case 'loadOCRReference':
          return null;
        case 'loadModelRuns':
          return '[]';
        case 'evaluateModel':
          final engine = (call.arguments as Map)['engine'] as String;
          called.add(engine);
          return jsonEncode(run(engine));
        default:
          throw StateError('非预期调用 ${call.method}');
      }
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(StockHistoryStore.channel, null),
    );
    await tester.pumpWidget(
      MaterialApp(home: StockOCRPage(document: doc([pending]))),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('PP-OCRv6 tiny'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('使用 PP-OCRv6 tiny 重新识别此单'));
    await tester.pumpAndSettle();
    expect(called, ['paddle_tiny']);
    expect(find.textContaining('后续导入默认：Apple Vision'), findsOneWidget);
    final card = find.text('PP-OCRv6 tiny · 待复核 1 / 1 行');
    await tester.ensureVisible(card);
    await tester.tap(card);
    await tester.pumpAndSettle();
    expect(find.textContaining('待复核：货物未匹配或规格有疑点'), findsOneWidget);
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
  });
  test('评估响应验证模型、策略版本、原图哈希和数值', () {
    final json = {
      'engine': 'paddle_tiny',
      'evaluatedAt': '2026-10-08T10:00:00Z',
      'document': doc([row('a', '1袋')], engine: 'paddle_tiny').toJson(),
      'metrics': {
        'elapsedMs': 100.0,
        'modelLoadMs': 10.0,
        'ocrCalls': 2,
        'processedPixels': 1000,
        'modelBytes': 100,
        'residentBytes': 1000,
        'policyRevision': 22,
        'imageSHA256': 'a' * 64,
      },
    };
    expect(StockOCRRun.fromJson(json).engine, StockOCREngine.tiny);
    final wrong = (jsonDecode(jsonEncode(json)) as Map).cast<String, dynamic>();
    (wrong['metrics'] as Map)['elapsedMs'] = -1;
    expect(() => StockOCRRun.fromJson(wrong), throwsFormatException);
    json['engine'] = 'vision';
    expect(() => StockOCRRun.fromJson(json), throwsFormatException);
  });
}
