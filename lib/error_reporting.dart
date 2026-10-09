import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'diagnostic_log.dart';
import 'updates.dart';

const reportEndpoint = 'https://reikop.io/fuji-san/report.php';

class ErrorReport {
  ErrorReport.capture(
    Object error,
    StackTrace stack,
    String context, {
    DiagnosticLog? log,
  }) {
    final source = log ?? DiagnosticLog.instance;
    final random = Random.secure();
    data = {
      'schema': 1,
      'id': List.generate(
        16,
        (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join(),
      'appVersion': appRelease,
      'os': Platform.operatingSystem,
      'osVersion': source.redact(Platform.operatingSystemVersion, max: 100),
      'locale': Platform.localeName,
      'context': source.redact(context, max: 75),
      'error': source.redact('$error', max: 2000),
      'stack': source.redact('$stack', max: 6000),
      'camera': Map<String, String>.from(source.camera),
      'events': source.snapshot(),
    };
    while (utf8.encode(jsonEncode(data)).length > 200000 &&
        (data['events'] as List).isNotEmpty) {
      (data['events'] as List).removeAt(0);
    }
  }
  late final Map<String, dynamic> data;
  Map<String, dynamic> payload(String description, String contact) => {
    ...data,
    'consent': true,
    'description': DiagnosticLog.instance.redact(description, max: 3000),
    'contact': contact.trim(),
  };
}

class ReportClient {
  Future<String> send(Map<String, dynamic> payload) async {
    final body = utf8.encode(jsonEncode(payload));
    if (body.length > 262144) throw StateError('보고서가 너무 큽니다. 설명을 줄여 주세요.');
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final request = await client
          .postUrl(Uri.parse(reportEndpoint))
          .timeout(const Duration(seconds: 20));
      request.followRedirects = false;
      request.headers.contentType = ContentType.json;
      request.add(body);
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      final bytes = <int>[];
      await for (final chunk in response.timeout(const Duration(seconds: 20))) {
        bytes.addAll(chunk);
        if (bytes.length > 4096) {
          throw const FormatException('Invalid report response');
        }
      }
      if (response.statusCode == 429) {
        throw StateError('전송 횟수가 많습니다. 한 시간 뒤 다시 시도해 주세요.');
      }
      if (response.statusCode != 200 && response.statusCode != 201) {
        throw StateError('오류 보고 서버에 접속하지 못했습니다 (${response.statusCode}).');
      }
      final result = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      if (result['received'] != true || result['id'] != payload['id']) {
        throw const FormatException('접수 확인 응답이 올바르지 않습니다.');
      }
      return result['id'] as String;
    } finally {
      client.close(force: true);
    }
  }
}

Future<void> showErrorReport(
  BuildContext context,
  ErrorReport report, {
  ReportClient? client,
}) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (_) =>
      ErrorReportDialog(report: report, client: client ?? ReportClient()),
);

class ErrorReportDialog extends StatefulWidget {
  const ErrorReportDialog({
    super.key,
    required this.report,
    required this.client,
  });
  final ErrorReport report;
  final ReportClient client;
  @override
  State<ErrorReportDialog> createState() => _ErrorReportDialogState();
}

class _ErrorReportDialogState extends State<ErrorReportDialog> {
  final description = TextEditingController(),
      contact = TextEditingController();
  bool consent = false, sending = false;
  String? failure, receipt;
  @override
  void dispose() {
    description.dispose();
    contact.dispose();
    super.dispose();
  }

  Map<String, dynamic> get payload => {
    ...widget.report.payload(description.text, contact.text),
    'consent': consent,
  };
  String get json => const JsonEncoder.withIndent('  ').convert(payload);

  Future<void> send() async {
    if (!consent || sending) return;
    final email = contact.text.trim();
    if (email.isNotEmpty &&
        !RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(email)) {
      setState(() => failure = '답변 받을 이메일 주소를 확인해 주세요.');
      return;
    }
    setState(() {
      sending = true;
      failure = null;
    });
    try {
      final id = await widget.client.send(payload);
      if (mounted) setState(() => receipt = id);
    } catch (_) {
      if (mounted) {
        setState(
          () =>
              failure = '전송하지 못했습니다. 입력 내용은 유지됩니다. 잠시 후 다시 시도하거나 보고서를 복사해 주세요.',
        );
      }
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !sending,
    child: AlertDialog(
      title: Text(receipt == null ? '오류 보고' : '보고서가 접수되었습니다'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: receipt != null
              ? SelectableText('접수 번호\n$receipt\n\n개발자가 비공개로 확인합니다.')
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.report.data['context'] as String,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      widget.report.data['error'] as String,
                      maxLines: 5,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: description,
                      enabled: !sending,
                      maxLines: 4,
                      maxLength: 3000,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(
                        labelText: '어떤 상황에서 발생했나요?',
                        hintText: '직전에 한 작업, 예상한 결과, 실제 결과, 다시 발생하는 방법',
                      ),
                    ),
                    TextField(
                      controller: contact,
                      enabled: !sending,
                      maxLength: 254,
                      keyboardType: TextInputType.emailAddress,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(
                        labelText: '답변 받을 이메일 (선택)',
                      ),
                    ),
                    ExpansionTile(
                      title: const Text('전송할 상세 보고서 확인'),
                      children: [
                        SelectableText(
                          json,
                          style: const TextStyle(fontSize: 11),
                        ),
                      ],
                    ),
                    const Text(
                      '앱·OS·카메라 모델/펌웨어, 오류와 최근 명령 기록을 reikop.io로 전송합니다. 시리얼·개인 경로·레시피 이름/사진은 자동 수집하지 않습니다. 설명에 개인정보를 적지 마세요. 보고서는 개발자만 열람합니다. 30일이 지나면 다음 서버 접수·조회 시 삭제됩니다. 서버 접속 로그는 별도로 남을 수 있습니다.',
                      style: TextStyle(fontSize: 12),
                    ),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('내용을 확인했고 오류 보고서 전송에 동의합니다.'),
                      value: consent,
                      onChanged: sending
                          ? null
                          : (value) => setState(() => consent = value!),
                    ),
                    if (failure != null)
                      Text(failure!, style: const TextStyle(color: Colors.red)),
                    if (sending) const LinearProgressIndicator(),
                  ],
                ),
        ),
      ),
      actions: [
        if (receipt == null)
          TextButton(
            onPressed: sending
                ? null
                : () async {
                    await Clipboard.setData(ClipboardData(text: json));
                  },
            child: const Text('보고서 복사'),
          ),
        TextButton(
          onPressed: sending ? null : () => Navigator.pop(context),
          child: Text(receipt == null ? '닫기' : '확인'),
        ),
        if (receipt == null)
          FilledButton(
            onPressed: consent && !sending ? send : null,
            child: const Text('보고서 보내기'),
          ),
      ],
    ),
  );
}
