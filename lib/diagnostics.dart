import 'dart:convert';
import 'dart:io';
import 'camera/camera.dart';
import 'camera/ptp.dart';

// Uses the exact app transport and model checks, but never changes camera state.
Future<int> diagnoseCamera(String outputPath) async {
  final transport = NativeTransport();
  final report = <String, dynamic>{'appVersion': '0.1.1', 'readOnly': true};
  var code = 0;
  try {
    final devices = await transport.discover();
    report['deviceCount'] = devices.length;
    if (devices.length != 1) {
      throw StateError('Connect exactly one Fujifilm camera.');
    }
    report['transport'] = (devices.single['id'] as String).startsWith('wpd:')
        ? 'WPD'
        : 'USB';
    await transport.open(devices.single['id'] as String);
    final camera = FujiCamera(transport);
    await camera.inspect();
    report['model'] = camera.identity!.model;
    report['firmware'] = camera.identity!.firmware;
    report['currentSlot'] = Reader(await camera.read(0xd18c)).read16();
    report['filmSimulation'] = Reader(await camera.read(0xd192)).read16();
    report['success'] = true;
  } catch (e) {
    report['success'] = false;
    report['error'] = '$e';
    code = 1;
  } finally {
    await transport.close();
  }
  await File(outputPath).writeAsString(
    const JsonEncoder.withIndent('  ').convert(report),
    flush: true,
  );
  return code;
}
