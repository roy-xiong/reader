import 'dart:async';
import 'dart:isolate';
import 'package:flutter/services.dart';
import '../domain/chinese_conversion.dart';
import '../domain/models.dart';

class ScriptConversionCancelled implements Exception {}

/// 转换在可终止的独立线程中执行，切换选项时及时释放旧任务的字典和正文。
class ChineseScriptService {
  int _generation = 0;
  void Function()? _stop;
  final _tables = <String, Future<String>>{};
  void cancel() {
    _generation++;
    _stop?.call();
    _stop = null;
  }

  Future<ConvertedDocument> convert(BookDocument source, String mode) async {
    cancel();
    final ticket = _generation;
    if (mode == 'original') {
      return ConvertedDocument(source, const TextOffsetMap());
    }
    final prefix = mode == 'traditional' ? 'ST' : 'TS';
    Future<String> table(String name) => _tables.putIfAbsent(
      name,
      () => rootBundle.loadString('assets/opencc/$name.txt'),
    );
    final dictionaries = await Future.wait([
      table('${prefix}Characters'),
      table('${prefix}Phrases'),
    ]);
    if (ticket != _generation) {
      throw ScriptConversionCancelled();
    }
    final port = ReceivePort();
    final completer = Completer<ConvertedDocument>();
    completer.future.ignore();
    Isolate? isolate;
    final subscription = port.listen((message) {
      if (completer.isCompleted) {
        return;
      }
      if (message is Map && message['document'] is Map) {
        try {
          final document = BookDocument.fromJson(
            Map<String, dynamic>.from(message['document'] as Map),
          );
          final edits = (message['edits'] as List)
              .map((e) => List<int>.from(e as List))
              .toList();
          completer.complete(ConvertedDocument(document, TextOffsetMap(edits)));
        } catch (error, stack) {
          completer.completeError(error, stack);
        }
      } else {
        completer.completeError(const FormatException('简繁转换失败'));
      }
    });
    _stop = () {
      isolate?.kill(priority: Isolate.immediate);
      if (!completer.isCompleted) {
        completer.completeError(ScriptConversionCancelled());
      }
    };
    try {
      isolate = await Isolate.spawn(
        _worker,
        [port.sendPort, source.toJson(), dictionaries],
        onError: port.sendPort,
        onExit: port.sendPort,
      );
      if (ticket != _generation) {
        isolate.kill(priority: Isolate.immediate);
        throw ScriptConversionCancelled();
      }
      return await completer.future.timeout(const Duration(seconds: 45));
    } finally {
      isolate?.kill(priority: Isolate.immediate);
      await subscription.cancel();
      port.close();
      if (ticket == _generation) {
        _stop = null;
      }
    }
  }

  static void _worker(List<Object> input) {
    final send = input[0] as SendPort;
    final source = BookDocument.fromJson(
      Map<String, dynamic>.from(input[1] as Map),
    );
    final tables = List<String>.from(input[2] as List);
    final result = ChineseTextConverter(tables[0], tables[1]).document(source);
    send.send({
      'document': result.document.toJson(),
      'edits': result.offsets.edits,
    });
  }
}
