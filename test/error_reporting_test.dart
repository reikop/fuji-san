import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fuji_san/diagnostic_log.dart';
import 'package:fuji_san/error_reporting.dart';
import 'package:fuji_san/camera/ptp.dart';
import 'package:fuji_san/main.dart';
import 'ui_test.dart' show MemoryStore;

class FakeReportClient extends ReportClient {
  int calls = 0;
  bool fail = false;
  Map<String, dynamic>? submitted;
  @override
  Future<String> send(Map<String, dynamic> payload) async {
    calls++;
    submitted = payload;
    if (fail) throw StateError('Offline');
    return payload['id'] as String;
  }
}

void main() {
  testWidgets(
    'camera detection failure opens report dialog without submitting',
    (tester) async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        NativeTransport.channel,
        (call) async => <dynamic>[],
      );
      addTearDown(
        () => messenger.setMockMethodCallHandler(NativeTransport.channel, null),
      );
      await tester.pumpWidget(FujiSanApp(store: MemoryStore()));
      await tester.pumpAndSettle();
      await tester.tap(find.text('카메라 연결'));
      await tester.pumpAndSettle();
      expect(find.text('오류 보고'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '보고서 보내기'))
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('닫기'));
      await tester.pumpAndSettle();
      expect(find.text('카메라 연결'), findsOneWidget);
    },
  );
  test(
    'diagnostics redact known serials, recipe names, private paths and tokens',
    () {
      final log = DiagnosticLog()
        ..protect('SERIAL123')
        ..protect('My Private Recipe');
      log.add(
        'test',
        'SERIAL123 My Private Recipe serial=secret token=secret user@example.com 10.0.0.1',
      );
      log.add('test', r'C:\Users\Private Person\app\file.json');
      log.add('test', r'USB\VID_04CB\DEVICE_SECRET');
      final encoded = jsonEncode(log.snapshot());
      for (final secret in [
        'SERIAL123',
        'My Private Recipe',
        'secret',
        'user@example.com',
        '10.0.0.1',
        'Private Person',
        'DEVICE_SECRET',
      ]) {
        expect(encoded, isNot(contains(secret)));
      }
      expect(encoded, contains('[REDACTED]'));
    },
  );
  test('bounded report captures a frozen history and no serial field', () {
    final log = DiagnosticLog();
    for (var i = 0; i < 200; i++) {
      log.add('ptp', 'op=0x1015 $i');
    }
    log.camera.addAll({'model': 'X100VI', 'firmware': '1.32'});
    final report = ErrorReport.capture(
      StateError('0x2002'),
      StackTrace.current,
      'C3 read',
      log: log,
    );
    log.add('ptp', 'later');
    log.camera.clear();
    final payload = report.payload('reproduction', '');
    expect((payload['events'] as List).length, 120);
    expect(jsonEncode(payload), isNot(contains('later')));
    expect((payload['camera'] as Map)['model'], 'X100VI');
    expect((payload['camera'] as Map).containsKey('serial'), false);
    expect(payload['id'], matches(RegExp(r'^[a-f0-9]{32}$')));
    expect(utf8.encode(jsonEncode(payload)).length, lessThan(262144));
  });
  testWidgets(
    'report sends only after consent and keeps draft and id on failed retry',
    (tester) async {
      final client = FakeReportClient()..fail = true;
      final report = ErrorReport.capture(
        StateError('USB test'),
        StackTrace.empty,
        'Camera read',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ErrorReportDialog(report: report, client: client),
          ),
        ),
      );
      expect(client.calls, 0);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '보고서 보내기'))
            .onPressed,
        isNull,
      );
      await tester.enterText(find.byType(TextField).first, 'USB 연결 후 실패했습니다.');
      await tester.ensureVisible(find.byType(CheckboxListTile));
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pump();
      expect(client.calls, 0);
      await tester.tap(find.text('보고서 보내기'));
      await tester.pumpAndSettle();
      expect(client.calls, 1);
      expect(find.textContaining('전송하지 못했습니다.'), findsOneWidget);
      final firstId = client.submitted!['id'];
      client.fail = false;
      await tester.tap(find.text('보고서 보내기'));
      await tester.pumpAndSettle();
      expect(client.calls, 2);
      expect(client.submitted!['id'], firstId);
      expect(client.submitted!['description'], 'USB 연결 후 실패했습니다.');
      expect(client.submitted!['consent'], true);
      expect(find.text('보고서가 접수되었습니다'), findsOneWidget);
    },
  );
}
