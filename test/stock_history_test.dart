import 'dart:convert';
import 'dart:async';
import 'dart:ui' as ui;

import 'package:excel/excel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:luckinstocktaking/stock_history.dart';
import 'package:luckinstocktaking/stock_history_page.dart';
import 'package:luckinstocktaking/main.dart';
import 'package:luckinstocktaking/stock_product.dart';

Map<String, dynamic> record({String title = '人民路店 2026-09-30'}) => {
  'schemaVersion': 1,
  'id': '12345678-1234-1234-1234-123456789abc',
  'title': title,
  'createdAt': '2026-10-01T02:30:00Z',
  'imageName': '12345678-1234-1234-1234-123456789abc.png',
  'lines': [
    {
      'cells': ['椰乳', '01.20', '盒'],
      'confidence': .72,
    },
    {
      'cells': ['椰乳', '01.20', '盒'],
      'confidence': .91,
    },
  ],
  'reviewed': false,
};

/// 已整理为两列货物表、可以直接导出的盘点单。
Map<String, dynamic> tableRecord({String title = '人民路店 2026-09-30'}) => {
  'schemaVersion': 2,
  'id': '12345678-1234-1234-1234-123456789abc',
  'title': title,
  'createdAt': '2026-10-01T02:30:00Z',
  'imageName': '12345678-1234-1234-1234-123456789abc.png',
  'lines': [
    {
      'cells': ['生椰拿铁（大杯）', '3盒 2瓶'],
      'confidence': .9,
    },
    {
      'cells': ['冰美式', '冷藏12个'],
      'confidence': .9,
    },
  ],
  'reviewed': false,
  'recognitionRevision': 1,
};

/// 长图预览分段必须是能解码的真实 PNG，空列表会被平台通道判为读取失败。
Future<Uint8List> longImageTile(WidgetTester tester) async {
  final png = await tester.runAsync(() async {
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawRect(
      const Rect.fromLTWH(0, 0, 192, 1800),
      Paint()..color = Colors.white,
    );
    final picture = recorder.endRecording();
    final image = await picture.toImage(192, 1800);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    picture.dispose();
    return data!.buffer.asUint8List();
  });
  if (png == null) fail('未能生成长图预览样本');
  return png;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(
    () => messenger.setMockMethodCallHandler(StockHistoryStore.channel, null),
  );
  tearDown(
    () => messenger.setMockMethodCallHandler(
      const MethodChannel('com.luckinstocktaking/catalog'),
      null,
    ),
  );

  for (final conflict in [false, true]) {
    testWidgets(conflict ? '只看疑点过滤自动通过行，库存冲突不放行' : '正常行自动通过后无需逐条确认即可导出', (
      tester,
    ) async {
      final products = [
        for (var i = 1; i <= 2; i++)
          StockProduct(
            code: 'GS1000$i-01',
            name: '测试商品$i',
            specification: '1L*12盒/箱',
            units: ['盒', '箱'],
          ),
      ];
      final table = tableRecord();
      table['lines'] = [
        for (var i = 0; i < 2; i++)
          {
            'cells': [products[i].display, '12盒'],
            'confidence': .9,
            'inventoryReadings': ['12盒', conflict && i == 1 ? '1盒' : '12盒'],
            'inventoryConfidence': .95,
          },
      ];
      Uint8List? shared;
      final png = await longImageTile(tester);
      messenger.setMockMethodCallHandler(StockHistoryStore.channel, (
        call,
      ) async {
        if (call.method == 'loadProducts') {
          return jsonEncode(products.map((p) => p.toJson()).toList());
        }
        if (call.method == 'imageTiles') return [png];
        if (call.method == 'table') return jsonEncode(table);
        if (call.method == 'shareBytes') {
          shared = (call.arguments as Map)['bytes'] as Uint8List;
          return null;
        }
        throw StateError('意外的平台请求：${call.method}');
      });
      await tester.pumpWidget(
        MaterialApp(
          home: StockDocumentPage(document: StockDocument.fromJson(table)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('自动通过 ${conflict ? 1 : 2} 行'), findsOneWidget);
      expect(find.textContaining('需复核 ${conflict ? 1 : 0} 行'), findsOneWidget);
      if (conflict) {
        await tester.ensureVisible(find.text('只看待复核行'));
        await tester.tap(find.text('只看待复核行'));
        await tester.pumpAndSettle();
        expect(find.text(products[0].display), findsNothing);
        await tester.ensureVisible(find.text('库存两次读数不一致'));
        expect(find.text('库存两次读数不一致'), findsOneWidget);
        expect(shared, isNull);
      } else {
        await tester.tap(find.byTooltip('导出与分享'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('导出 Excel'));
        await tester.pumpAndSettle();
        expect(shared, isNotNull);
        final sheet = Excel.decodeBytes(shared!).tables.values.single;
        expect(sheet.rows.length, 3);
        expect(sheet.rows[1][1]!.value, IntCellValue(12));
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('快捷指令导入后自动打开校对页并保存修改', (tester) async {
    final png = await tester.runAsync(() async {
      final picture = ui.PictureRecorder();
      final canvas = Canvas(picture);
      canvas.drawRect(
        const Rect.fromLTWH(0, 0, 1, 1),
        Paint()..color = Colors.white,
      );
      final image = await picture.endRecording().toImage(1, 1);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      return bytes!.buffer.asUint8List();
    });
    var consumed = false;
    var pendingChecks = 0;
    var automaticRecognitions = 0;
    Map<String, dynamic>? saved;
    messenger.setMockMethodCallHandler(
      const MethodChannel('com.luckinstocktaking/catalog'),
      (call) async => call.method == 'diagnostics'
          ? {'version': '1.4.2', 'appBundleId': 'test'}
          : '[]',
    );
    messenger.setMockMethodCallHandler(StockHistoryStore.channel, (call) async {
      if (call.method == 'loadProducts') return '[]';
      switch (call.method) {
        case 'pending':
          pendingChecks++;
          if (consumed) return null;
          consumed = true;
          return jsonEncode(record());
        case 'table':
          automaticRecognitions++;
          final table = record();
          table['title'] = '2026-09-30 月盘';
          table['schemaVersion'] = 2;
          table['recognitionRevision'] = 1;
          table['lines'] = [
            {
              'cells': ['椰乳', '01.30盒'],
              'confidence': .72,
            },
            {
              'cells': ['椰乳', '01.20盒'],
              'confidence': .91,
            },
          ];
          return jsonEncode(table);
        case 'imageTiles':
          return [png!];
        case 'save':
          saved = jsonDecode(call.arguments as String) as Map<String, dynamic>;
          return null;
        default:
          throw StateError('意外的平台请求：${call.method}');
      }
    });
    await tester.pumpWidget(const StocktakingApp());
    await tester.pumpAndSettle();
    expect(find.text('盘点单详情'), findsOneWidget);
    expect(find.byType(Table), findsOneWidget);
    expect(find.text('货物规格名称'), findsOneWidget);
    expect(find.text('实盘总库存'), findsOneWidget);
    expect(find.text('查看长图'), findsOneWidget);
    expect(find.text('需重点核对'), findsNothing);
    expect(find.text('库存数字待确认'), findsNothing);
    tester.binding.channelBuffers.push(
      StockHistoryStore.channel.name,
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('historyReady'),
      ),
      (_) {},
    );
    await tester.pumpAndSettle();
    expect(pendingChecks, 2, reason: '查看历史时仍应响应拼接快捷指令完成通知');
    expect(find.byTooltip('优化识别'), findsNothing);
    expect(automaticRecognitions, 1);
    expect(find.text('1.3盒'), findsOneWidget);
    expect(find.text('2026-09-30 月盘'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextField, '单据名称（可填写日期 / 门店 / 单号）'),
      '已校对的盘点单',
    );
    await tester.ensureVisible(find.text('保存草稿'));
    await tester.tap(find.text('保存草稿'));
    await tester.pumpAndSettle();
    expect(saved!['title'], '已校对的盘点单');
    expect(saved!['reviewed'], false);
    expect(saved!['recognitionRevision'], 1);
    expect((saved!['lines'] as List).length, 2);
    expect(find.text('盘点单详情'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('识别失败仍能按原比例查看长图分段并放大', (tester) async {
    final png = await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawRect(
        const Rect.fromLTWH(0, 0, 192, 1800),
        Paint()..color = Colors.white,
      );
      final picture = recorder.endRecording();
      final image = await picture.toImage(192, 1800);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      picture.dispose();
      return data!.buffer.asUint8List();
    });
    messenger.setMockMethodCallHandler(StockHistoryStore.channel, (call) async {
      if (call.method == 'loadProducts') return '[]';
      if (call.method == 'imageTiles') return [png!, png];
      if (call.method == 'table') {
        throw PlatformException(code: 'OCR_FAILED', message: '库存识别失败');
      }
      throw StateError('意外的平台请求');
    });
    await tester.pumpWidget(
      MaterialApp(
        home: StockDocumentPage(document: StockDocument.fromJson(record())),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('库存识别失败'), findsOneWidget);
    expect(find.textContaining('等待整理货物表'), findsOneWidget);
    expect(find.textContaining('2 项货物'), findsNothing);
    expect(find.textContaining('识别结果已自动保存'), findsNothing);
    await tester.ensureVisible(find.text('查看长图'));
    await tester.tap(find.text('查看长图'));
    await tester.pumpAndSettle();
    final tile = find.byType(Image).first;
    await tester.runAsync(
      () =>
          precacheImage(tester.widget<Image>(tile).image, tester.element(tile)),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(tile);
    final size = tester.getSize(tile);
    expect(size.height / size.width, closeTo(1800 / 192, .001));
    await tester.tapAt(tester.getTopLeft(tile) + const Offset(20, 20));
    await tester.pumpAndSettle();
    expect(find.text('放大查看'), findsOneWidget);
    expect(find.byType(InteractiveViewer), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('低置信度品名不标记为错误，库存零值及混合单位均保留', () {
    for (final inventory in ['0个', '14个', '2捆-个', '-箱13包']) {
      final line = StockLine(
        cells: ['CURTA塑料冷水壶\nGS00712-01', inventory],
        confidence: .2,
      );
      expect(line.reviewIssue, isNull);
      expect(line.confidence, .2);
    }
  });

  test('只为货号和库存中的明确数字字符疑点提示原因', () {
    expect(
      StockLine(cells: ['冷水壶\nGS007I2-01', '14个'], confidence: .9).reviewIssue,
      '货号中有易混淆字符',
    );
    expect(
      StockLine(
        cells: ['冷水壶\nGS00712-01', '总库存：O个\n冷藏：0个'],
        confidence: .9,
      ).reviewIssue,
      '库存数字待确认',
    );
    expect(
      StockLine(cells: ['冷水壶\nGS00712-01', 'O个'], confidence: .9).reviewIssue,
      '库存数字待确认',
    );
  });

  test('周盘规格正常换行不误报，真实漏字仍提示核对', () {
    for (final name in [
      '食品保鲜膜SM 500米*6卷/\n箱\nGS00197-04',
      '瑞幸埃塞铂金咖啡豆1kg*9包/\n箱（拆零）\nGS09888-03',
      '灭蝇纸28*10.5cmSM10张/\n盒\nGS00660-03',
      '单杯手提袋2023 NW 400个/\n箱\nGS03598-12',
      '鑫国扁扁黄油可颂15g*40个\n*6盒\nGS06813-01',
    ]) {
      expect(
        StockLine(cells: [name, '0个'], confidence: .95).reviewIssue,
        isNull,
        reason: name,
      );
    }
    expect(
      StockLine(
        cells: ['新塞尚丝绒风味厚奶1L*12盒/\nGS04465-08', '0盒'],
        confidence: .95,
      ).reviewIssue,
      '名称或规格可能不完整，请对照原图',
    );
    expect(
      StockLine(
        cells: ['新雀巢丝绒风味厚奶1L*12盒\nGS04465-10', '0盒'],
        confidence: .95,
      ).reviewIssue,
      '包装规格可能漏识别，请对照原图',
    );
    expect(
      StockLine(
        cells: ['新雀巢丝绒风味厚奶1L*12盒 GS04465-10', '0盒'],
        confidence: .95,
      ).reviewIssue,
      '包装规格可能漏识别，请对照原图',
      reason: '品名与货号被同一文字块识别时也应检查包装尾部',
    );
    expect(
      StockLine(
        cells: ['热饮杯ZC 300个/箱\n翻\nGS00412-218', '0个'],
        confidence: .95,
      ).reviewIssue,
      '名称或规格可能不完整，请对照原图',
    );
  });

  test('周盘预制物料水印读数保持待确认，修复数量后保留零值与单位', () {
    for (final quantity in ['2A12个', '7TX']) {
      final line = StockLine(
        cells: ['青金桔-预制作', quantity],
        confidence: .95,
        inventoryUncertain: true,
        category: 'prepared',
      );
      expect(line.reviewIssue, '库存数字待确认');
      expect(line.inventory.uncertain, isTrue);
    }
    for (final quantity in ['12个', '7个', '3000毫升', '0克']) {
      final line = StockLine(
        cells: ['青金桔-预制作', quantity],
        confidence: .95,
        category: 'prepared',
      );
      expect(line.reviewIssue, isNull);
      expect(line.inventory.uncertain, isFalse);
    }
  });

  test('往返保留重复行、原始数量、置信度及导入时间', () {
    final document = StockDocument.fromJson(record());
    final decoded = StockDocument.fromJson(
      jsonDecode(jsonEncode(document.toJson())) as Map<String, dynamic>,
    );
    expect(decoded.lines.length, 2);
    expect(decoded.lines[0].cells, ['椰乳', '01.20', '盒']);
    expect(decoded.lines[0].confidence, .72);
    expect(decoded.createdAt, document.createdAt);
    expect(decoded.reviewed, false);
    final edited = decoded.edited(' 修正单据 ', [
      StockLine(cells: ['椰乳', '1.3', '盒'], confidence: 1),
    ]);
    expect(edited.id, document.id);
    expect(edited.title, '修正单据');
    expect(edited.reviewed, false);
  });

  test('未校对历史自动检查算法版本，已校对内容直接保留', () async {
    final data = {
      ...record(),
      'schemaVersion': 2,
      'lines': [
        {
          'cells': ['奶油', '13包'],
          'confidence': .5,
        },
      ],
    };
    var requests = 0;
    messenger.setMockMethodCallHandler(StockHistoryStore.channel, (call) async {
      if (call.method == 'loadProducts') return '[]';
      expect(call.method, 'table');
      requests++;
      return jsonEncode({...data, 'recognitionRevision': 1});
    });
    final upgraded = await StockHistoryStore().table(
      StockDocument.fromJson(data),
    );
    expect(requests, 1);
    expect(upgraded.recognitionRevision, 1);
    expect(
      upgraded.edited('已校对', upgraded.lines).toJson()['recognitionRevision'],
      1,
    );
    final reviewed = StockDocument.fromJson({...data, 'reviewed': true});
    expect(await StockHistoryStore().table(reviewed), same(reviewed));
    expect(requests, 1);
  });

  test('全文搜索覆盖单据和数字，多关键词必须同时命中', () {
    final document = StockDocument.fromJson(record());
    expect(document.matches('人民路 椰乳 01.20'), true);
    expect(document.matches('人民路 牛奶'), false);
    expect(document.matches('  '), true);
  });

  test('两列表格保留多行名称库存并拒绝缺列', () {
    final data = {
      ...record(),
      'schemaVersion': 2,
      'lines': [
        {
          'cells': ['奶油 0.5L\nGS00147-01', '总库存：7个\n冷藏：2个\n冷冻：5个'],
          'confidence': .8,
        },
      ],
    };
    final document = StockDocument.fromJson(data);
    expect(document.schemaVersion, 2);
    expect(document.edited('已校对', document.lines).toJson()['schemaVersion'], 2);
    expect(document.matches('GS00147 冷冻'), true);
    expect(
      () => StockDocument.fromJson({
        ...data,
        'lines': [
          {
            'cells': ['仅有名称'],
            'confidence': .8,
          },
        ],
      }),
      throwsFormatException,
    );
  });

  test('拒绝损坏历史版本、路径、空行和非法置信度', () {
    for (final broken in [
      {...record(), 'schemaVersion': 3},
      {...record(), 'imageName': '../other.png'},
      {...record(), 'title': ' '},
      {...record(), 'lines': []},
      {
        ...record(),
        'lines': [
          {
            'cells': ['椰乳'],
            'confidence': 1.01,
          },
        ],
      },
      {
        ...record(),
        'lines': [
          {
            'cells': [' '],
            'confidence': .8,
          },
        ],
      },
    ]) {
      expect(() => StockDocument.fromJson(broken), throwsFormatException);
    }
  });

  test('空历史是合法初始状态，平台缺失响应不能当作空历史', () async {
    messenger.setMockMethodCallHandler(
      StockHistoryStore.channel,
      (_) async => '[]',
    );
    expect(await StockHistoryStore().load(), isEmpty);
    messenger.setMockMethodCallHandler(
      StockHistoryStore.channel,
      (_) async => null,
    );
    await expectLater(StockHistoryStore().load(), throwsStateError);
  });

  testWidgets('拼接录屏选择用户录制的视频且不启动录屏', (tester) async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(StockHistoryStore.channel, (call) async {
      if (call.method == 'loadProducts') return '[]';
      calls.add(call);
      if (call.method == 'list') return '[]';
      if (call.method == 'import') return null;
      throw StateError('意外的平台请求');
    });
    await tester.pumpWidget(const MaterialApp(home: StockHistoryPage()));
    await tester.pumpAndSettle();
    expect(find.text('开始自动录屏'), findsNothing);
    expect(find.byType(Slider), findsNothing);
    await tester.tap(find.text('拼接录屏'));
    await tester.pumpAndSettle();
    expect(calls.map((call) => call.method).toList(), ['list', 'import']);
    expect(calls.last.arguments, {'video': true});
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('截图组入口调用批量导入，取消后不创建历史', (tester) async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(StockHistoryStore.channel, (call) async {
      if (call.method == 'loadProducts') return '[]';
      calls.add(call);
      if (call.method == 'list') return '[]';
      if (call.method == 'importScreenshots') return null;
      throw StateError('意外的平台请求');
    });
    await tester.pumpWidget(const MaterialApp(home: StockHistoryPage()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('拼接截图组'));
    await tester.pumpAndSettle();
    expect(calls.map((call) => call.method), ['list', 'importScreenshots']);
    expect(find.text('盘点单详情'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('录屏和截图组异步取消后恢复按钮并允许再次导入', (tester) async {
    final calls = <String>[];
    final selections = <Completer<String?>>[];
    messenger.setMockMethodCallHandler(StockHistoryStore.channel, (call) async {
      if (call.method == 'loadProducts') return '[]';
      calls.add(call.method);
      if (call.method == 'list') return '[]';
      if (call.method == 'import' || call.method == 'importScreenshots') {
        final selection = Completer<String?>();
        selections.add(selection);
        return selection.future;
      }
      throw StateError('取消时不应创建或识别盘点单');
    });
    await tester.pumpWidget(const MaterialApp(home: StockHistoryPage()));
    await tester.pumpAndSettle();
    for (final label in ['拼接录屏', '拼接截图组']) {
      await tester.tap(find.text(label));
      await tester.pump();
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '拼接录屏'))
            .onPressed,
        isNull,
      );
      selections.last.complete(null);
      await tester.pumpAndSettle();
      expect(find.byType(LinearProgressIndicator), findsNothing);
      for (final button in ['拼接录屏', '拼接截图组']) {
        expect(
          tester
              .widget<FilledButton>(find.widgetWithText(FilledButton, button))
              .onPressed,
          isNotNull,
        );
      }
      expect(find.text('盘点单详情'), findsNothing);
    }
    expect(calls, ['list', 'import', 'importScreenshots']);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('历史加载拒绝重复标识，系统选择器取消不创建记录', () async {
    messenger.setMockMethodCallHandler(StockHistoryStore.channel, (call) async {
      if (call.method == 'loadProducts') return '[]';
      if (call.method == 'import') return null;
      return jsonEncode([record(), record()]);
    });
    await expectLater(StockHistoryStore().load(), throwsFormatException);
    expect(await StockHistoryStore().pick(video: true), isNull);
  });

  testWidgets('历史页面按品名搜索并明确显示读取失败', (tester) async {
    messenger.setMockMethodCallHandler(
      StockHistoryStore.channel,
      (_) async => jsonEncode([
        record(),
        {
          ...record(title: '另一张单据'),
          'id': '22345678-1234-1234-1234-123456789abc',
          'imageName': '22345678-1234-1234-1234-123456789abc.png',
          'lines': [
            {
              'cells': ['牛奶', '3'],
              'confidence': 1,
            },
          ],
        },
      ]),
    );
    await tester.pumpWidget(const MaterialApp(home: StockHistoryPage()));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '椰乳');
    await tester.pumpAndSettle();
    expect(find.text('人民路店 2026-09-30'), findsOneWidget);
    expect(find.text('另一张单据'), findsNothing);
    messenger.setMockMethodCallHandler(
      StockHistoryStore.channel,
      (_) async => throw PlatformException(code: 'BROKEN', message: '原图损坏'),
    );
    await tester.tap(find.byTooltip('刷新历史'));
    await tester.pumpAndSettle();
    expect(find.text('原图损坏'), findsOneWidget);
  });

  testWidgets('解析失败后可从错误处导出诊断日志', (tester) async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(StockHistoryStore.channel, (call) async {
      if (call.method == 'loadProducts') return '[]';
      calls.add(call.method);
      if (call.method == 'list') {
        throw PlatformException(
          code: 'OCR_FAILED',
          message: '预制物料名称缺少制作/处理尾字，不能与下一行合并，请核对原图',
        );
      }
      if (call.method == 'shareDiagnostics') return null;
      throw StateError('意外的平台请求：${call.method}');
    });
    await tester.pumpWidget(const MaterialApp(home: StockHistoryPage()));
    await tester.pumpAndSettle();
    expect(find.text('预制物料名称缺少制作/处理尾字，不能与下一行合并，请核对原图'), findsOneWidget);
    await tester.tap(find.text('导出诊断日志'));
    await tester.pumpAndSettle();
    expect(calls, ['list', 'shareDiagnostics']);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('删除需确认，失败保留记录，成功只删除指定单据', (tester) async {
    final remaining = [
      record(),
      {
        ...record(title: '另一张单据'),
        'id': '22345678-1234-1234-1234-123456789abc',
        'imageName': '22345678-1234-1234-1234-123456789abc.png',
      },
    ];
    final deleted = <String>[];
    var failDelete = true;
    messenger.setMockMethodCallHandler(StockHistoryStore.channel, (call) async {
      if (call.method == 'loadProducts') return '[]';
      if (call.method == 'list') return jsonEncode(remaining);
      if (call.method == 'delete') {
        if (failDelete) {
          throw PlatformException(code: 'DELETE_FAILED', message: '删除失败');
        }
        deleted.add(call.arguments as String);
        remaining.removeWhere((item) => item['id'] == call.arguments);
        return null;
      }
      throw StateError('意外的平台请求');
    });
    await tester.pumpWidget(const MaterialApp(home: StockHistoryPage()));
    await tester.pumpAndSettle();
    final button = find.byTooltip('删除盘点单').first;
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(find.textContaining('无法恢复'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(deleted, isEmpty);
    await tester.tap(button);
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(find.text('删除失败'), findsOneWidget);
    expect(find.text('人民路店 2026-09-30'), findsOneWidget);
    failDelete = false;
    await tester.tap(button);
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(deleted, ['12345678-1234-1234-1234-123456789abc']);
    expect(find.text('人民路店 2026-09-30'), findsNothing);
    expect(find.text('另一张单据'), findsOneWidget);
    expect(find.text('历史记录 · 1'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('导出 Excel 取当前页面所见，含尚未保存的校对', (tester) async {
    final products = [
      StockProduct(
        code: "GS10001-01",
        name: "生椰拿铁（大杯）",
        specification: "",
        units: ["盒", "瓶"],
      ),
      StockProduct(
        code: "GS10002-01",
        name: "冰美式",
        specification: "",
        units: ["个"],
      ),
    ];
    final table = tableRecord();
    table["lines"] = [
      for (var i = 0; i < products.length; i++)
        {
          "cells": [products[i].display, i == 0 ? "3盒 2瓶" : "冷藏12个"],
          "confidence": .9,
          "productId": products[i].id,
          "identityConfirmed": true,
          "inventoryConfirmed": true,
        },
    ];
    Uint8List? shared;
    String? sharedName;
    final png = await longImageTile(tester);
    messenger.setMockMethodCallHandler(StockHistoryStore.channel, (call) async {
      if (call.method == 'loadProducts') {
        return jsonEncode(products.map((p) => p.toJson()).toList());
      }
      if (call.method == 'imageTiles') return [png, png];
      if (call.method == 'table') return jsonEncode(table);
      if (call.method == 'shareBytes') {
        final arguments = (call.arguments as Map).cast<String, Object?>();
        sharedName = arguments['name'] as String;
        shared = arguments['bytes'] as Uint8List;
        return null;
      }
      throw StateError('意外的平台请求：${call.method}');
    });
    await tester.pumpWidget(
      MaterialApp(
        home: StockDocumentPage(document: StockDocument.fromJson(table)),
      ),
    );
    await tester.pumpAndSettle();

    // 改第二行库存但不点「保存修改」，导出结果必须反映这次校对。
    await tester.ensureVisible(find.byIcon(Icons.edit_outlined).at(1));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.edit_outlined).at(1));
    await tester.pumpAndSettle();
    expect(find.text('更换货物档案'), findsOneWidget);
    expect(find.widgetWithText(TextField, '搜索货物档案（名称或货号）'), findsNothing);
    expect(
      tester.getSize(find.byType(InteractiveViewer)).height,
      lessThanOrEqualTo(160),
    );
    await tester.enterText(
      find.widgetWithText(TextField, '实盘总库存（保留单位和分区）'),
      '冷藏99个',
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('已逐项核对原图数字、单位和所属行'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('已逐项核对原图数字、单位和所属行'));
    await tester.tap(find.text('确认此行'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('导出与分享'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('导出 Excel'));
    await tester.pumpAndSettle();

    expect(sharedName, '人民路店 2026-09-30.xlsx');
    expect(shared, isNotNull);
    expect(find.textContaining('请在分享面板选择微信'), findsOneWidget);
    final excel = Excel.decodeBytes(shared!);
    final sheetName = excel.getDefaultSheet();
    if (sheetName == null) fail('导出的 Excel 缺少默认工作表');
    final sheet = excel[sheetName];
    expect(sheet.sheetName, '人民路店 2026-09-30');
    // 数值列同时覆盖未改动的多单位行和刚校对过的冷藏行。
    expect(sheet.rows[0][0]!.value, TextCellValue('货物规格名称'));
    expect(sheet.rows[0][3]!.value, TextCellValue('冷藏-个'));
    expect(sheet.rows[1][1]!.value, IntCellValue(3));
    expect(sheet.rows[1][2]!.value, IntCellValue(2));
    expect(sheet.rows[2][3]!.value, IntCellValue(99));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('分享长图按标识交给平台，由系统面板负责发送', (tester) async {
    final calls = <MethodCall>[];
    final png = await longImageTile(tester);
    messenger.setMockMethodCallHandler(StockHistoryStore.channel, (call) async {
      if (call.method == 'loadProducts') return '[]';
      calls.add(call);
      if (call.method == 'imageTiles') return [png, png];
      if (call.method == 'table') return jsonEncode(tableRecord());
      if (call.method == 'shareImage') return null;
      throw StateError('意外的平台请求：${call.method}');
    });
    await tester.pumpWidget(
      MaterialApp(
        home: StockDocumentPage(
          document: StockDocument.fromJson(tableRecord()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('导出与分享'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('分享长图'));
    await tester.pumpAndSettle();
    expect(calls.map((call) => call.method), [
      'imageTiles',
      'table',
      'shareImage',
    ]);
    expect(calls.last.arguments, '12345678-1234-1234-1234-123456789abc');
    expect(find.textContaining('可发送长图到微信'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('货物表整理完成前禁用导出，避免导出无效的两列表格', (tester) async {
    final png = await longImageTile(tester);
    messenger.setMockMethodCallHandler(StockHistoryStore.channel, (call) async {
      if (call.method == 'loadProducts') return '[]';
      if (call.method == 'imageTiles') return [png];
      if (call.method == 'table') {
        throw PlatformException(code: 'OCR_FAILED', message: '库存识别失败');
      }
      throw StateError('意外的平台请求：${call.method}');
    });
    await tester.pumpWidget(
      MaterialApp(
        home: StockDocumentPage(document: StockDocument.fromJson(record())),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('导出与分享'));
    await tester.pumpAndSettle();
    // find.byType 按 runtimeType 精确匹配，取不到带泛型的 PopupMenuItem<_ShareAction>。
    PopupMenuItem<Object?> menuItemOf(String label) => tester
        .widgetList<PopupMenuItem<Object?>>(
          find.ancestor(
            of: find.text(label),
            matching: find.byWidgetPredicate(
              (widget) => widget is PopupMenuItem,
            ),
          ),
        )
        .single;
    expect(menuItemOf('导出 Excel').enabled, isFalse);
    expect(menuItemOf('分享长图').enabled, isTrue, reason: '长图已就绪，随时可分享');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('调整顺序要求至少两张，并只把标识按新顺序传给平台', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(StockHistoryStore.channel, (call) async {
      if (call.method == 'loadProducts') return '[]';
      calls.add(call);
      return null;
    });
    final store = StockHistoryStore();
    final first = StockDocument.fromJson(record());
    final second = StockDocument.fromJson({
      ...record(title: '另一张单据'),
      'id': '22345678-1234-1234-1234-123456789abc',
      'imageName': '22345678-1234-1234-1234-123456789abc.png',
    });
    await expectLater(store.reorder([first]), throwsArgumentError);
    var notified = 0;
    void listener() => notified++;
    StockHistoryStore.changes.addListener(listener);
    await store.reorder([second, first]);
    StockHistoryStore.changes.removeListener(listener);
    expect(calls.single.method, 'reorder');
    expect(calls.single.arguments, [second.id, first.id]);
    expect(notified, 1);
  });

  /// 两个可拖拽卡片：首张为「人民路店」，次张为「另一张单据」。
  /// 加高测试视口，保证两张卡片都在 sliver 懒加载范围内可见。
  Future<void> pumpTwoDocuments(
    WidgetTester tester,
    Future<Object?> Function(MethodCall call) handler,
  ) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    messenger.setMockMethodCallHandler(StockHistoryStore.channel, (call) async {
      if (call.method == 'loadProducts') return '[]';
      if (call.method == 'list') {
        return jsonEncode([
          record(),
          {
            ...record(title: '另一张单据'),
            'id': '22345678-1234-1234-1234-123456789abc',
            'imageName': '22345678-1234-1234-1234-123456789abc.png',
            'lines': [
              {
                'cells': ['牛奶', '3'],
                'confidence': 1,
              },
            ],
          },
        ]);
      }
      return handler(call);
    });
    await tester.pumpWidget(const MaterialApp(home: StockHistoryPage()));
    await tester.pumpAndSettle();
  }

  /// 把第二张卡片拖到首张位置：proxy 起点与首项顶部对齐才会判定为插入首位。
  Future<void> dragSecondCardAboveFirst(WidgetTester tester) async {
    final second = find.byIcon(Icons.drag_handle).at(1);
    await tester.ensureVisible(second);
    await tester.pumpAndSettle();
    final secondCenter = tester.getCenter(second);
    final firstCenter = tester.getCenter(find.byIcon(Icons.drag_handle).first);
    final gesture = await tester.startGesture(secondCenter);
    await tester.pump();
    await gesture.moveBy(Offset(0, firstCenter.dy - secondCenter.dy));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
  }

  testWidgets('拖拽手柄调整历史顺序并持久化到平台', (tester) async {
    final calls = <MethodCall>[];
    await pumpTwoDocuments(tester, (call) async {
      if (call.method == 'loadProducts') return '[]';
      calls.add(call);
      if (call.method == 'reorder') return null;
      throw StateError('意外的平台请求：${call.method}');
    });
    expect(find.byIcon(Icons.drag_handle), findsNWidgets(2));
    expect(find.textContaining('长按或拖动右侧手柄'), findsOneWidget);

    await dragSecondCardAboveFirst(tester);

    expect(calls.single.method, 'reorder');
    expect(calls.single.arguments, [
      '22345678-1234-1234-1234-123456789abc',
      '12345678-1234-1234-1234-123456789abc',
    ]);
    expect(
      tester.getTopLeft(find.text('另一张单据')).dy,
      lessThan(tester.getTopLeft(find.text('人民路店 2026-09-30')).dy),
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('搜索过滤时隐藏拖拽手柄，避免只重排可见结果', (tester) async {
    await pumpTwoDocuments(tester, (call) async {
      if (call.method == 'loadProducts') return '[]';
      throw StateError('搜索时不应请求平台：${call.method}');
    });
    expect(find.byIcon(Icons.drag_handle), findsNWidgets(2));
    await tester.enterText(find.byType(TextField).first, '椰乳');
    await tester.pumpAndSettle();
    expect(find.text('另一张单据'), findsNothing);
    expect(find.byIcon(Icons.drag_handle), findsNothing);
    expect(find.textContaining('长按或拖动右侧手柄'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('排序写入失败时回滚原顺序并显示错误', (tester) async {
    await pumpTwoDocuments(tester, (call) async {
      if (call.method == 'loadProducts') return '[]';
      if (call.method == 'reorder') {
        throw PlatformException(code: 'REORDER_FAILED', message: '排序失败');
      }
      throw StateError('意外的平台请求：${call.method}');
    });
    await dragSecondCardAboveFirst(tester);
    expect(find.text('排序失败'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('人民路店 2026-09-30')).dy,
      lessThan(tester.getTopLeft(find.text('另一张单据')).dy),
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
