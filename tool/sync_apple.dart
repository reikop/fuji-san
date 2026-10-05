import 'dart:io';

void main(List<String> args) {
  final source = File('native/apple/FujiUsb.swift').readAsStringSync();
  for (final platform in ['ios', 'macos']) {
    final output = File('$platform/Runner/FujiUsb.swift');
    if (args.contains('--check')) {
      if (!output.existsSync() || output.readAsStringSync() != source) {
        stderr.writeln('Run dart run tool/sync_apple.dart');
        exitCode = 1;
      }
    } else {
      output.writeAsStringSync(source);
    }
  }
}
