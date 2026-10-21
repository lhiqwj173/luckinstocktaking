import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:luckinstocktaking/main.dart';
import 'package:luckinstocktaking/recent_weighing.dart';
import 'package:luckinstocktaking/recent_weighing_view.dart';
import 'package:luckinstocktaking/stock_history.dart';

Map<String, Object> record([int index = 0]) => {
  'id': 'record-$index',
  'createdAt': DateTime(2026, 10, 22, 10, index).millisecondsSinceEpoch,
  'categoryName': '奶油 $index',
  'weightGrams': 350.0,
  'tareGrams': 300.0,
  'singleServingGrams': 100.0,
  'typeLabel': '份盒称重',
  'result': '0.5（0.500）',
  'source': index.isEven ? 'app' : 'shortcut',
  'allowMultiple': false,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const catalog = MethodChannel('com.luckinstocktaking/catalog');
  late List<Map<String, Object>> records;
  late List<MethodCall> writes;
  PlatformException? saveError;
  Completer<void>? saveGate;

  setUp(() {
    records = [];
    writes = [];
    saveError = null;
    saveGate = null;
    messenger.setMockMethodCallHandler(RecentWeighingStore.channel, (
      call,
    ) async {
      if (call.method == 'append') {
        writes.add(call);
        await saveGate?.future;
        if (saveError != null) throw saveError!;
        records.insert(0, {
          ...record(),
          ...(call.arguments as Map).cast<String, Object>(),
        });
      } else if (call.method == 'delete') {
        records.removeWhere(
          (entry) => entry['id'] == (call.arguments as Map)['id'],
        );
      } else if (call.method == 'clear') {
        records.clear();
      } else if (call.method != 'load') {
        throw StateError('未预期的调用：${call.method}');
      }
      return jsonEncode(records);
    });
    messenger.setMockMethodCallHandler(catalog, (call) async {
      if (call.method == 'diagnostics') {
        return {'version': 'test', 'appBundleId': 'test'};
      }
      if (call.method == 'load') {
        return jsonEncode([
          {
            'name': '奶油',
            'aliases': <String>[],
            'type': 'portionBox',
            'singleServingGrams': 100,
            'allowMultiple': false,
          },
        ]);
      }
      throw StateError('未预期的品类调用：${call.method}');
    });
    messenger.setMockMethodCallHandler(StockHistoryStore.channel, (call) async {
      if (call.method == 'pending') return null;
      throw StateError('未预期的历史调用：${call.method}');
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(RecentWeighingStore.channel, null);
    messenger.setMockMethodCallHandler(catalog, null);
    messenger.setMockMethodCallHandler(StockHistoryStore.channel, null);
  });

  test('记录保留称重快照，拒绝损坏数值和未知来源', () {
    final restored = WeighingRecord.fromJson(record());
    expect(restored.copyText, '奶油 0：0.5（0.500） 份');
    expect(restored.tareGrams, 300);
    for (final invalid in [
      {'weightGrams': 299},
      {'weightGrams': double.nan},
      {'singleServingGrams': 0},
      {'createdAt': 0.5},
      {'createdAt': 8640000000000001},
      {'source': 'unknown'},
      {'result': 'invalid'},
      {'categoryName': ''},
    ]) {
      expect(
        () => WeighingRecord.fromJson({...record(), ...invalid}),
        throwsFormatException,
      );
    }
  });

  test('读取拒绝重复标识和超过容量的记录', () async {
    records = [record(), record()];
    await expectLater(RecentWeighingStore().load(), throwsFormatException);
    records = List.generate(101, record);
    await expectLater(RecentWeighingStore().load(), throwsFormatException);
  });

  Future<void> prepareCalculation(WidgetTester tester, String weight) async {
    await tester.pumpWidget(const StocktakingApp());
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '奶油');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, '奶油').first);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.widgetWithText(TextField, '称重（克）'));
    await tester.enterText(find.widgetWithText(TextField, '称重（克）'), weight);
    await tester.ensureVisible(find.widgetWithText(FilledButton, '计算'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '计算'));
  }

  testWidgets('计算成功保存一次，保存期间禁用按钮，完成后更新最近记录', (tester) async {
    saveGate = Completer<void>();
    await prepareCalculation(tester, '350');
    await tester.pump();
    expect(writes, hasLength(1));
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '正在保存…'))
          .onPressed,
      isNull,
    );
    saveGate!.complete();
    await tester.pumpAndSettle();
    expect(writes.single.arguments, containsPair('result', '0.5（0.500）'));
    expect(writes.single.arguments, containsPair('tareGrams', 300.0));
    expect(find.text('结果：0.5（0.500） 份'), findsOneWidget);
    await tester.ensureVisible(find.text('最近称重'));
    await tester.pumpAndSettle();
    expect(find.text('全部 1 条'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('无效称重不写记录', (tester) async {
    await prepareCalculation(tester, '299');
    await tester.pumpAndSettle();
    expect(writes, isEmpty);
    expect(find.textContaining('称重不能低于皮重'), findsOneWidget);
  });

  testWidgets('保存失败明确提示，保持无成功结果', (tester) async {
    saveError = PlatformException(code: 'WRITE_FAILED', message: '存储空间不足');
    await prepareCalculation(tester, '350');
    await tester.pumpAndSettle();
    expect(find.text('称重记录保存失败：存储空间不足'), findsOneWidget);
    expect(find.text('结果：0.5（0.500） 份'), findsNothing);
    expect(records, isEmpty);
  });

  testWidgets('窄屏预览三条，展开后显示全部和快照，清空需确认', (tester) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    records = List.generate(4, record);
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            padding: EdgeInsets.all(16),
            child: RecentWeighingView(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('奶油 2'), findsOneWidget);
    expect(find.text('奶油 3'), findsNothing);
    await tester.tap(find.text('全部 4 条'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('奶油 3'),
      150,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text('奶油 3'), findsOneWidget);
    expect(find.textContaining('快捷指令'), findsWidgets);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('清空'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(records, hasLength(4));
    await tester.tap(find.text('清空'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '清空'));
    await tester.pumpAndSettle();
    expect(records, isEmpty);
    expect(find.textContaining('还没有称重记录'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
