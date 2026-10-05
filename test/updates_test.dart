import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:fuji_san/storage.dart';
import 'package:fuji_san/updates.dart';

Map<String, dynamic> release(String tag, {bool draft = false}) => {
  'tag_name': tag,
  'draft': draft,
  'assets': <dynamic>[],
};

void main() {
  test(
    'version order is numeric, respects prereleases, and never downgrades',
    () {
      final versions = [
        '0.1.1-alpha.1',
        '0.1.1-alpha.2',
        '0.1.1-alpha.10',
        '0.1.1',
        '0.2.0-alpha.1',
        '0.2.0',
        '0.10.0',
        '1.0.0',
      ];
      for (var i = 1; i < versions.length; i++) {
        expect(
          ReleaseVersion(
            versions[i],
          ).compareTo(ReleaseVersion(versions[i - 1])),
          greaterThan(0),
        );
      }
      expect(
        selectRelease([release('v0.1.1')], current: '0.2.0-alpha.1'),
        isNull,
      );
      expect(
        selectRelease([release('v0.2.0-alpha.1')], current: '0.2.0-alpha.1'),
        isNull,
      );
    },
  );
  test(
    'selects newest published version, ignoring order, drafts and unrelated tags',
    () {
      final releases = [
        release('v0.2.1'),
        release('v9.0.0', draft: true),
        release('nightly'),
        release('v0.3.0-alpha.2'),
      ];
      expect(
        selectRelease(releases, current: '0.2.0-alpha.1')!.tag,
        'v0.3.0-alpha.2',
      );
      expect(selectRelease(releases, current: '0.2.0')!.tag, 'v0.2.1');
    },
  );
  test(
    'download requires exact repository asset URL, SHA-256 and bounded size',
    () {
      final asset = <String, dynamic>{
        'browser_download_url':
            'https://github.com/reikop/fuji-san/releases/download/v0.3.0/fuji-san-windows.zip',
        'digest': 'sha256:${'a' * 64}',
        'size': 1234,
      };
      expect(verifiedAssetUrl(asset, 'v0.3.0').scheme, 'https');
      for (final change in [
        {'browser_download_url': 'https://example.com/package.zip'},
        {'browser_download_url': '${asset['browser_download_url']}?redirect=1'},
        {'digest': null},
        {'size': 0},
        {'size': 400 * 1024 * 1024},
      ]) {
        expect(
          () => verifiedAssetUrl({...asset, ...change}, 'v0.3.0'),
          throwsFormatException,
        );
      }
    },
  );
  test(
    'Windows helper launched by the app actually runs and signals ready',
    () async {
      final job = await Directory.systemTemp.createTemp('fuji-launch-test-');
      addTearDown(() async {
        // The helper runs from the job folder and may still be exiting.
        for (var i = 0; i < 20; i++) {
          try {
            await job.delete(recursive: true);
            return;
          } on FileSystemException {
            await Future<void>.delayed(const Duration(milliseconds: 250));
          }
        }
      });
      await File('${job.path}/updater.ps1').writeAsString(
        r'''param([string]$Manifest)
[IO.File]::WriteAllText((Join-Path (Split-Path -Parent $Manifest) 'ready'), 'ready')
''',
      );
      await File('${job.path}/job.json').writeAsString('{}');
      await UpdateService(LibraryStore()).launchWindows(job);
      expect(File('${job.path}/ready').existsSync(), true);
    },
    skip: !Platform.isWindows,
  );
}
