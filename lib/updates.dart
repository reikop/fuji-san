import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'storage.dart';

const appRelease = '0.3.0-alpha.1';
const releasesUrl = 'https://github.com/reikop/fuji-san/releases';

class ReleaseVersion implements Comparable<ReleaseVersion> {
  ReleaseVersion(String tag) {
    final match = RegExp(
      r'^v?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?$',
    ).firstMatch(tag);
    if (match == null) throw const FormatException('Invalid release version');
    numbers = [for (var i = 1; i <= 3; i++) int.parse(match[i]!)];
    pre = match[4]?.split('.');
  }
  late final List<int> numbers;
  late final List<String>? pre;
  @override
  int compareTo(ReleaseVersion other) {
    for (var i = 0; i < 3; i++) {
      final c = numbers[i].compareTo(other.numbers[i]);
      if (c != 0) return c;
    }
    if (pre == null) return other.pre == null ? 0 : 1;
    if (other.pre == null) return -1;
    for (var i = 0; i < pre!.length && i < other.pre!.length; i++) {
      final a = pre![i], b = other.pre![i];
      final na = int.tryParse(a), nb = int.tryParse(b);
      final c = na != null && nb != null
          ? na.compareTo(nb)
          : na != null
          ? -1
          : nb != null
          ? 1
          : a.compareTo(b);
      if (c != 0) return c;
    }
    return pre!.length.compareTo(other.pre!.length);
  }
}

class AppRelease {
  AppRelease(this.tag, this.assets);
  final String tag;
  final List<dynamic> assets;
  Uri get page => Uri.parse('$releasesUrl/tag/$tag');
  Map<String, dynamic> get windowsAsset =>
      assets.cast<Map<String, dynamic>>().firstWhere(
        (a) => a['name'] == 'fuji-san-windows.zip' && a['state'] == 'uploaded',
        orElse: () => throw StateError('Windows 업데이트 파일이 아직 준비되지 않았습니다.'),
      );
}

AppRelease? selectRelease(
  List<dynamic> releases, {
  String current = appRelease,
}) {
  final version = ReleaseVersion(current);
  AppRelease? selected;
  for (final value in releases) {
    if (value is! Map ||
        value['draft'] != false ||
        value['tag_name'] is! String) {
      continue;
    }
    try {
      final candidate = ReleaseVersion(value['tag_name'] as String);
      // Stable installations stay stable; alpha installations can receive prereleases.
      if (version.pre == null && candidate.pre != null) continue;
      if (candidate.compareTo(version) <= 0) continue;
      if (selected != null &&
          candidate.compareTo(ReleaseVersion(selected.tag)) <= 0) {
        continue;
      }
      selected = AppRelease(
        value['tag_name'] as String,
        value['assets'] as List,
      );
    } on FormatException {
      continue;
    }
  }
  return selected;
}

Uri verifiedAssetUrl(Map<String, dynamic> asset, String tag) {
  final uri = Uri.parse(asset['browser_download_url'] as String);
  if (uri.toString() !=
          'https://github.com/reikop/fuji-san/releases/download/$tag/fuji-san-windows.zip' ||
      !RegExp(
        r'^sha256:[a-f0-9]{64}$',
      ).hasMatch(asset['digest'] as String? ?? '') ||
      asset['size'] is! int ||
      (asset['size'] as int) <= 0 ||
      (asset['size'] as int) > 300 * 1024 * 1024) {
    throw const FormatException('업데이트 출처·크기·SHA-256 정보를 확인하지 못했습니다.');
  }
  return uri;
}

class UpdateService {
  UpdateService(this.store);
  final LibraryStore store;
  HttpClient client() => HttpClient()
    ..connectionTimeout = const Duration(seconds: 15)
    ..userAgent = 'Fuji-San/$appRelease';

  Future<AppRelease?> check() async {
    final http = client();
    try {
      final request = await http.getUrl(
        Uri.parse(
          'https://api.github.com/repos/reikop/fuji-san/releases?per_page=100',
        ),
      );
      request.headers.set('Accept', 'application/vnd.github+json');
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      if (response.statusCode != 200) {
        throw HttpException('GitHub HTTP ${response.statusCode}');
      }
      final bytes = <int>[];
      await for (final chunk in response.timeout(const Duration(seconds: 20))) {
        bytes.addAll(chunk);
        if (bytes.length > 4 * 1024 * 1024) {
          throw const FormatException('Release response too large');
        }
      }
      return selectRelease(jsonDecode(utf8.decode(bytes)) as List);
    } finally {
      http.close(force: true);
    }
  }

  Future<Directory> prepareWindows(
    AppRelease release,
    void Function(String) report,
  ) async {
    if (!Platform.isWindows) throw UnsupportedError('Windows updater');
    final asset = release.windowsAsset;
    final uri = verifiedAssetUrl(asset, release.tag);
    final root = await store.directory;
    final work = await Directory(
      '${root.path}/updates',
    ).create(recursive: true);
    final job = await work.createTemp('update-');
    final zip = File('${job.path}/package.zip');
    final http = client();
    final sink = zip.openWrite();
    try {
      final response = await (await http.getUrl(
        uri,
      )).close().timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) {
        throw HttpException('Download HTTP ${response.statusCode}');
      }
      var received = 0, lastPercent = -1;
      await for (final chunk in response.timeout(const Duration(seconds: 30))) {
        received += chunk.length;
        if (received > (asset['size'] as int)) {
          throw const FormatException('Unexpected update size');
        }
        sink.add(chunk);
        final percent = received * 100 ~/ (asset['size'] as int);
        if (percent != lastPercent) {
          report('업데이트 다운로드 $percent%');
          lastPercent = percent;
        }
      }
      if (received != asset['size']) {
        throw const FormatException('Incomplete update');
      }
      await sink.flush();
    } finally {
      await sink.close();
      http.close(force: true);
    }
    final digest = await sha256.bind(zip.openRead()).first;
    if ('sha256:$digest' != asset['digest']) {
      throw const FormatException('업데이트 SHA-256 검증 실패');
    }
    await File('${job.path}/updater.ps1').writeAsString(
      await rootBundle.loadString('assets/update_windows.ps1'),
      flush: true,
    );
    await File('${job.path}/job.json').writeAsString(
      jsonEncode({
        'pid': pid,
        'target': File(Platform.resolvedExecutable).parent.path,
        'zip': zip.path,
        'sha256': digest.toString(),
      }),
      flush: true,
    );
    report('업데이트 파일 검증 완료');
    return job;
  }

  Future<void> launchWindows(Directory job) async {
    // Not ProcessStartMode.detached: without a console Windows PowerShell exits
    // before running the script. A normally started helper has a hidden console
    // and keeps running after this app exits.
    await Process.start('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-WindowStyle',
      'Hidden',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      '${job.path}/updater.ps1',
      '-Manifest',
      '${job.path}/job.json',
    ], workingDirectory: job.path);
    for (var i = 0; i < 120; i++) {
      if (await File('${job.path}/error.txt').exists()) {
        throw StateError(await File('${job.path}/error.txt').readAsString());
      }
      if (await File('${job.path}/ready').exists()) return;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    // The helper requires a separate commit file before touching the installation.
    throw StateError('업데이트 준비 시간 초과. 현재 앱은 유지됩니다.');
  }
}
