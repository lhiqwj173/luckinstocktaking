import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';

class WeighingRecord {
  const WeighingRecord({
    required this.id,
    required this.createdAt,
    required this.categoryName,
    required this.weightGrams,
    required this.tareGrams,
    required this.singleServingGrams,
    required this.typeLabel,
    required this.result,
    required this.source,
    required this.allowMultiple,
    this.returnNetWeight = false,
  });

  final String id;
  final DateTime createdAt;
  final String categoryName;
  final double weightGrams;
  final double tareGrams;
  final double singleServingGrams;
  final String typeLabel;
  final String result;
  final String source;
  final bool allowMultiple;
  final bool returnNetWeight;

  String get copyText => '$categoryName：$result${returnNetWeight ? '' : ' 份'}';

  factory WeighingRecord.fromJson(Map<String, dynamic> json) {
    String text(String key) {
      final value = json[key];
      if (value is! String || value.trim().isEmpty) {
        throw FormatException('称重记录字段无效：$key');
      }
      return value;
    }

    double number(String key) {
      final value = json[key];
      if (value is! num || !value.isFinite || value < 0) {
        throw FormatException('称重记录数值无效：$key');
      }
      return value.toDouble();
    }

    final timestamp = number('createdAt');
    final weight = number('weightGrams');
    final tare = number('tareGrams');
    final serving = number('singleServingGrams');
    final source = text('source');
    if (timestamp > 8640000000000000 ||
        timestamp != timestamp.truncateToDouble() ||
        weight < tare ||
        serving <= 0 ||
        !{'app', 'shortcut'}.contains(source) ||
        json['allowMultiple'] is! bool) {
      throw const FormatException('称重记录的时间、重量或来源无效');
    }
    final returnNetWeight = json.containsKey('returnNetWeight')
        ? json['returnNetWeight'] as bool
        : false;
    final result = text('result');
    if (returnNetWeight
        ? !RegExp(r'^\d+(?:\.\d+)?(?:e[+-]?\d+)? g$').hasMatch(result)
        : !RegExp(r'^\d+\.\d（(?:\d+\.\d{3}|\d+(?:\.\d+)?e[+-]?\d+)）$')
              .hasMatch(result)) {
      throw const FormatException('称重记录结果格式无效');
    }
    return WeighingRecord(
      id: text('id'),
      createdAt: DateTime.fromMillisecondsSinceEpoch(timestamp.toInt()),
      categoryName: text('categoryName'),
      weightGrams: weight,
      tareGrams: tare,
      singleServingGrams: serving,
      typeLabel: text('typeLabel'),
      result: result,
      source: source,
      allowMultiple: json['allowMultiple'] as bool,
      returnNetWeight: returnNetWeight,
    );
  }
}

class RecentWeighingStore {
  static const channel = MethodChannel('com.luckinstocktaking/recent-weighing');
  static final changes = ValueNotifier<int>(0);

  Future<List<WeighingRecord>> _invoke(
    String method, [
    Map<String, Object>? arguments,
  ]) async {
    final json = await channel.invokeMethod<String>(method, arguments);
    if (json == null) throw StateError('无法读取最近称重记录');
    final decoded = jsonDecode(json);
    if (decoded is! List || decoded.length > 100) {
      throw const FormatException('最近称重记录格式无效');
    }
    final records = decoded.map((entry) {
      if (entry is! Map<String, dynamic>) {
        throw const FormatException('称重记录必须为对象');
      }
      return WeighingRecord.fromJson(entry);
    }).toList();
    if (records.map((record) => record.id).toSet().length != records.length) {
      throw const FormatException('称重记录标识重复');
    }
    return records;
  }

  Future<List<WeighingRecord>> load() => _invoke('load');

  Future<List<WeighingRecord>> append({
    required String categoryName,
    required double weightGrams,
    required double tareGrams,
    required double singleServingGrams,
    required String typeLabel,
    required String result,
    required bool allowMultiple,
    bool returnNetWeight = false,
  }) => _invoke('append', {
    'categoryName': categoryName,
    'weightGrams': weightGrams,
    'tareGrams': tareGrams,
    'singleServingGrams': singleServingGrams,
    'typeLabel': typeLabel,
    'result': result,
    'source': 'app',
    'allowMultiple': allowMultiple,
    'returnNetWeight': returnNetWeight,
  });

  Future<List<WeighingRecord>> delete(String id) =>
      _invoke('delete', {'id': id});
  Future<List<WeighingRecord>> clear() => _invoke('clear');
}

String formatGrams(double value) =>
    value == value.truncateToDouble() ? value.toStringAsFixed(0) : '$value';
