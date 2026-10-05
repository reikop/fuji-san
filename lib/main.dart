import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'camera/camera.dart';
import 'camera/ptp.dart';
import 'domain/recipe.dart';
import 'storage.dart';
import 'diagnostics.dart';
import 'updates.dart';
import 'camera_slot_editor.dart';
import 'wb_shift_grid.dart';
import 'builtin_recipes.dart';
import 'film_icon.dart';
import 'package:url_launcher/url_launcher.dart';

Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (arguments.length == 2 && arguments.first == '--diagnose-camera') {
    exit(await diagnoseCamera(arguments[1]));
  }
  if (arguments.length == 2 && arguments.first == '--diagnose-slots') {
    exit(await diagnoseCamera(arguments[1], scanSlots: true));
  }
  if (arguments.length == 2 && arguments.first == '--diagnose-write-back') {
    exit(await diagnoseCamera(arguments[1], writeBack: true));
  }
  runApp(const FujiSanApp());
}

const ink = Color(0xff222b27),
    green = Color(0xff315b46),
    cream = Color(0xfff5f3ec);

class FujiSanApp extends StatelessWidget {
  const FujiSanApp({super.key, this.store});
  final LibraryStore? store;
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Fuji San',
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: green, surface: cream),
      scaffoldBackgroundColor: cream,
      appBarTheme: const AppBarTheme(
        backgroundColor: cream,
        foregroundColor: ink,
      ),
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        filled: true,
        fillColor: Colors.white,
      ),
    ),
    home: Workspace(store: store),
  );
}

class Workspace extends StatefulWidget {
  const Workspace({super.key, this.store});
  final LibraryStore? store;
  @override
  State<Workspace> createState() => _WorkspaceState();
}

class _WorkspaceState extends State<Workspace> {
  late final store = widget.store ?? LibraryStore();
  final transport = NativeTransport();
  late final FujiCamera camera = FujiCamera(transport);
  List<Recipe> recipes = [];
  Map<int, String> slots = {};
  Map<int, Snapshot> cameraSlots = {};
  DateTime? slotsReadAt;
  AppRelease? update;
  bool checkingUpdate = false;
  String updateStatus = '시작할 때 자동 확인';
  Timer? updateTimer;
  bool busy = true, loaded = false;
  String status = '라이브러리를 여는 중', query = '';
  int page = 0;
  final libraryKey = GlobalKey();
  final libraryScroll = ScrollController();
  Timer? dragScroll;
  double? dragY;
  @override
  void initState() {
    super.initState();
    _load();
    if (widget.store == null) {
      checkUpdates();
      updateTimer = Timer.periodic(
        const Duration(hours: 6),
        (_) => checkUpdates(),
      );
    }
  }

  @override
  void dispose() {
    updateTimer?.cancel();
    dragScroll?.cancel();
    libraryScroll.dispose();
    super.dispose();
  }

  Future<void> checkUpdates() async {
    if (checkingUpdate) return;
    setState(() => checkingUpdate = true);
    try {
      final found = await UpdateService(store).check();
      if (!mounted) return;
      setState(() {
        update = found;
        updateStatus = found == null ? '최신 버전입니다' : '${found.tag} 업데이트 가능';
      });
    } catch (_) {
      if (mounted) setState(() => updateStatus = '확인 실패 · 눌러서 다시 확인');
    } finally {
      if (mounted) setState(() => checkingUpdate = false);
    }
  }

  Future<void> installUpdate() async {
    final release = update;
    if (release == null || busy) return;
    if (!Platform.isWindows) {
      await run(() async {
        if (!await launchUrl(
          release.page,
          mode: LaunchMode.externalApplication,
        )) {
          throw StateError('배포 페이지를 열 수 없습니다: ${release.page}');
        }
      });
      return;
    }
    final accepted = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${release.tag} 업데이트'),
        content: const Text('새 버전을 다운로드·검증한 뒤 앱을 재시작합니다. 라이브러리와 백업은 유지됩니다.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('나중에'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('업데이트 후 재시작'),
          ),
        ],
      ),
    );
    if (accepted != true || !mounted) return;
    await run(() async {
      final service = UpdateService(store);
      final job = await service.prepareWindows(release, report);
      await service.launchWindows(job);
      if (transport.opened) await transport.close();
      await File('${job.path}/commit').writeAsString('install', flush: true);
      exit(0);
    });
  }

  Future<void> refreshSlots() async {
    cameraSlots = {};
    slotsReadAt = null;
    report('카메라 C1–C7 레시피를 읽는 중');
    final snapshots = await camera.backup({1, 2, 3, 4, 5, 6, 7});
    cameraSlots = {for (final s in snapshots) s.slot: s};
    slotsReadAt = DateTime.now();
    report('카메라 C1–C7 읽기 완료 · 원래 슬롯 복원됨');
  }

  Future<void> showCameraSlot(int slot) async {
    final snapshot = cameraSlots[slot]!;
    setState(() => busy = true);
    try {
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => CameraSlotEditor(
            snapshot: snapshot,
            onSave: (edit) async {
              try {
                await camera.editSlot(
                  snapshot,
                  edit,
                  (backup) => store.backup(camera.identity!, backup),
                );
                final updated = (await camera.backup({slot})).single;
                cameraSlots[slot] = updated;
                slotsReadAt = DateTime.now();
                report('C$slot 수정 및 읽기 검증 완료');
              } catch (_) {
                cameraSlots.remove(slot);
                slotsReadAt = null;
                if (!transport.opened) camera.identity = null;
                rethrow;
              }
            },
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _load() async {
    try {
      final data = await store.load();
      if (data != null) {
        if (data['version'] != 1) {
          throw const FormatException('알 수 없는 라이브러리 버전');
        }
        recipes = (data['recipes'] as List)
            .map((j) => Recipe.fromJson(j as Map<String, dynamic>))
            .toList();
        slots = (data['slots'] as Map<String, dynamic>).map(
          (k, v) => MapEntry(int.parse(k), v as String),
        );
        if (slots.keys.any((k) => k < 1 || k > 7) ||
            slots.values.any((id) => !recipes.any((r) => r.id == id))) {
          throw const FormatException('잘못된 슬롯 배치');
        }
      }
      loaded = true;
      status = '카메라를 연결하고 나만의 일곱 가지 색을 준비하세요.';
    } catch (e) {
      status = '저장된 파일을 읽지 못했습니다. 원본을 보존했습니다. $e';
    }
    if (mounted) setState(() => busy = false);
  }

  void report(String message) {
    if (mounted) setState(() => status = message);
  }

  Future<void> run(Future<void> Function() action) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await action();
    } catch (e) {
      report('완료하지 못했습니다: $e');
      if (!transport.opened) {
        camera.identity = null;
        cameraSlots = {};
        slotsReadAt = null;
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$e'), duration: const Duration(seconds: 8)),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Recipe? assigned(int slot) {
    final id = slots[slot];
    for (final r in recipes) {
      if (r.id == id) return r;
    }
    return null;
  }

  Future<void> save() async {
    if (!loaded) throw StateError('라이브러리 읽기 오류를 먼저 해결하세요.');
    await store.save(recipes, slots);
  }

  Future<void> edit([Recipe? recipe]) async {
    final result = await Navigator.of(context).push<Recipe>(
      MaterialPageRoute(
        builder: (_) => RecipeEditor(recipe: recipe ?? Recipe.fresh()),
      ),
    );
    if (result != null) {
      await run(() async {
        final before = List<Recipe>.from(recipes);
        final index = recipes.indexWhere((r) => r.id == result.id);
        recipes = index < 0
            ? [...recipes, result]
            : (List.of(recipes)..[index] = result);
        try {
          await save();
        } catch (_) {
          recipes = before;
          rethrow;
        }
        report('${result.name} 저장됨');
      });
    }
  }

  Future<void> addBuiltin(Recipe recipe) async {
    if (!loaded) throw StateError('라이브러리 읽기 오류를 먼저 해결하세요.');
    final before = recipes;
    recipes = [
      ...recipes,
      Recipe(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        name: recipe.name,
        cameraName: recipe.cameraName,
        values: recipe.values,
      ),
    ];
    try {
      await save();
    } catch (_) {
      recipes = before;
      rethrow;
    }
    report('${recipe.name} 추가됨');
  }

  Future<void> reorder(String moved, String target) async {
    await run(() async {
      final from = recipes.indexWhere((r) => r.id == moved);
      final to = recipes.indexWhere((r) => r.id == target);
      if (from < 0 || to < 0 || from == to) return;
      final before = recipes;
      final next = List.of(recipes);
      next.insert(to, next.removeAt(from));
      recipes = next;
      try {
        await save();
      } catch (_) {
        recipes = before;
        rethrow;
      }
      report('레시피 순서 저장됨');
    });
  }

  // Draggable does not scroll its ancestors, so keep the list moving while a
  // dragged card is held near the top or bottom edge.
  void startDragScroll() {
    dragScroll?.cancel();
    dragScroll = Timer.periodic(const Duration(milliseconds: 16), (_) {
      final y = dragY;
      final box = libraryKey.currentContext?.findRenderObject() as RenderBox?;
      if (y == null || box == null || !libraryScroll.hasClients) return;
      final top = box.localToGlobal(Offset.zero).dy + 80;
      final bottom = top + box.size.height - 160;
      final delta = y < top
          ? y - top
          : y > bottom
          ? y - bottom
          : 0.0;
      if (delta == 0) return;
      final position = libraryScroll.position;
      position.jumpTo(
        (position.pixels + delta.clamp(-80, 80) * 0.25).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        ),
      );
    });
  }

  void stopDragScroll() {
    dragScroll?.cancel();
    dragScroll = null;
    dragY = null;
  }

  Future<void> connect() async {
    await run(() async {
      if (transport.opened) {
        await transport.close();
        camera.identity = null;
        cameraSlots = {};
        slotsReadAt = null;
        report('카메라 연결 해제');
        return;
      }
      report('USB 카메라 검색 중');
      final devices = await transport.discover();
      if (devices.isEmpty) {
        throw StateError(
          '카메라를 찾지 못했습니다. 데이터 케이블과 USB RAW CONV./BACKUP RESTORE 설정을 확인하세요. Windows 기본 WPD 드라이버를 지원합니다.',
        );
      }
      if (!mounted) return;
      final selected = await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (ctx) => SimpleDialog(
          title: const Text('연결할 카메라'),
          children: devices
              .map(
                (d) => SimpleDialogOption(
                  onPressed: () => Navigator.pop(ctx, d),
                  child: Text(d['name'] as String? ?? 'FUJIFILM'),
                ),
              )
              .toList(),
        ),
      );
      if (selected == null) {
        report('카메라 선택 취소');
        return;
      }
      try {
        await transport.open(selected['id'] as String);
        await camera.inspect();
        report('X100VI 연결됨 · 펌웨어 ${camera.identity!.firmware}');
      } catch (_) {
        await transport.close();
        camera.identity = null;
        rethrow;
      }
      await refreshSlots();
    });
  }

  Future<void> assign(int slot) async {
    final id = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text('C$slot에 배치'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, ''),
            child: const Text('배치 해제 · 카메라 설정은 유지'),
          ),
          ...recipes.map(
            (r) => SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, r.id),
              child: Text('${r.name} · ${r.film}'),
            ),
          ),
        ],
      ),
    );
    if (id != null) {
      await run(() async {
        final previous = Map<int, String>.from(slots);
        if (id.isEmpty) {
          slots.remove(slot);
        } else {
          slots[slot] = id;
        }
        try {
          await save();
        } catch (_) {
          slots = previous;
          rethrow;
        }
        report('C$slot 배치 저장됨');
      });
    }
  }

  Future<void> copyJson(String title, String data) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 520,
          height: 300,
          child: SingleChildScrollView(child: SelectableText(data)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('닫기'),
          ),
          FilledButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: data));
              if (ctx.mounted) Navigator.pop(ctx);
            },
            icon: const Icon(Icons.copy),
            label: const Text('JSON 복사'),
          ),
        ],
      ),
    );
  }

  Future<void> importLibrary() async {
    await run(() async {
      final file = await openFile(
        acceptedTypeGroups: [
          const XTypeGroup(
            label: 'JSON',
            extensions: ['json'],
            uniformTypeIdentifiers: ['public.json'],
          ),
        ],
      );
      if (file == null) return;
      if (await file.length() > 2000000) {
        throw const FormatException('2MB 이하 파일을 선택하세요.');
      }
      final imported = importRecipes(await file.readAsString());
      final before = List<Recipe>.from(recipes);
      final stamp = DateTime.now().microsecondsSinceEpoch;
      recipes = [
        ...recipes,
        for (var i = 0; i < imported.length; i++)
          Recipe(
            id: '$stamp-$i',
            name: imported[i].name,
            cameraName: imported[i].cameraName,
            values: imported[i].values,
          ),
      ];
      try {
        await save();
      } catch (_) {
        recipes = before;
        rethrow;
      }
      report('${imported.length}개 레시피 가져옴');
    });
  }

  Future<bool> confirm(String title, String text) async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: SingleChildScrollView(child: Text(text)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('취소'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('적용'),
            ),
          ],
        ),
      ) ??
      false;
  Future<void> apply() async {
    final plan = <int, Recipe>{
      for (var i = 1; i <= 7; i++)
        if (assigned(i) != null) i: assigned(i)!,
    };
    if (plan.isEmpty) return;
    if (!await confirm(
      '카메라 슬롯 덮어쓰기',
      '${plan.entries.map((e) => 'C${e.key} → ${e.value.cameraName}').join('\n')}\n\n선택한 슬롯의 레시피 설정을 백업한 뒤 덮어씁니다. 배치하지 않은 슬롯은 유지합니다. 실기기 전송은 Windows · X100VI 1.32에서 한 번 확인했을 뿐입니다. 실패하면 즉시 멈추며 백업에서 수동 복원할 수 있습니다.',
    )) {
      return;
    }
    await run(() async {
      try {
        await BatchWriter(camera).apply(plan, (snapshots) async {
          await store.backup(camera.identity!, snapshots);
        }, report);
        await refreshSlots();
        report('${plan.length}개 슬롯 적용 및 읽기 검증 완료');
      } catch (e) {
        cameraSlots = {};
        slotsReadAt = null;
        throw StateError('전송 중단. 일부 설정이 적용되었을 수 있습니다. 백업 메뉴에서 복원하세요. $e');
      }
    });
  }

  Future<void> backupMenu() async {
    await run(() async {
      final files = await store.backups();
      if (!mounted) return;
      final file = await showDialog<File>(
        context: context,
        builder: (ctx) => SimpleDialog(
          title: const Text('원본 백업'),
          children: files.isEmpty
              ? [
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('아직 백업이 없습니다. 카메라를 연결해 백업하거나 레시피를 적용하면 생성됩니다.'),
                  ),
                ]
              : files
                    .map(
                      (f) => SimpleDialogOption(
                        onPressed: () => Navigator.pop(ctx, f),
                        child: Text(f.uri.pathSegments.last),
                      ),
                    )
                    .toList(),
        ),
      );
      if (file == null) return;
      final source = await file.readAsString();
      if (!mounted) return;
      final choice = await showDialog<String>(
        context: context,
        builder: (ctx) => SimpleDialog(
          title: const Text('백업 작업'),
          children: [
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, 'export'),
              child: const Text('백업 JSON 보기 / 복사'),
            ),
            SimpleDialogOption(
              onPressed: camera.identity == null
                  ? null
                  : () => Navigator.pop(ctx, 'restore'),
              child: const Text('연결한 카메라에 복원'),
            ),
          ],
        ),
      );
      if (choice == 'export') {
        await copyJson('원본 백업', source);
        return;
      }
      if (choice != 'restore') return;
      final j = jsonDecode(source) as Map<String, dynamic>;
      if (j['format'] != 'fuji-san-backup' ||
          j['version'] != 1 ||
          j['model'] != camera.identity!.model ||
          j['serial'] != camera.identity!.serial) {
        throw StateError('연결한 카메라의 백업이 아닙니다.');
      }
      final snapshots = (j['slots'] as List)
          .map((s) => Snapshot.fromJson(s as Map<String, dynamic>))
          .toList();
      if (!mounted ||
          !await confirm(
            '백업으로 복원',
            '${snapshots.map((s) => 'C${s.slot}').join(', ')} 슬롯을 이 백업으로 덮어씁니다. 현재 값도 먼저 백업합니다.',
          )) {
        return;
      }
      await store.backup(
        camera.identity!,
        await camera.backup(snapshots.map((s) => s.slot).toSet()),
      );
      for (final s in snapshots) {
        report('C${s.slot} 복원 중');
        cameraSlots = {};
        slotsReadAt = null;
        await camera.restore(s);
      }
      report('백업 복원 및 검증 완료');
      await refreshSlots();
    });
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 1000;
    return Scaffold(
      appBar: AppBar(
        title: const FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.landscape_outlined),
              SizedBox(width: 10),
              Text(
                'FUJI SAN',
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  letterSpacing: 3,
                  fontSize: 20,
                ),
              ),
            ],
          ),
        ),
        actions: [
          if (update != null)
            IconButton(
              tooltip: '${update!.tag} 업데이트',
              onPressed: busy ? null : installUpdate,
              icon: const Icon(Icons.system_update_alt),
            ),
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: FilledButton.tonalIcon(
              onPressed: busy ? null : connect,
              icon: Icon(transport.opened ? Icons.usb : Icons.usb_off),
              label: Text(transport.opened ? 'X100VI 연결됨' : '카메라 연결'),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          if (busy) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: wide
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(width: 220, child: sidebar()),
                      const VerticalDivider(width: 1),
                      Expanded(child: library()),
                      const VerticalDivider(width: 1),
                      SizedBox(width: 310, child: kit()),
                    ],
                  )
                : IndexedStack(
                    index: page,
                    children: [library(), kit(), sidebar()],
                  ),
          ),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            color: const Color(0xffe8e9df),
            child: Text(
              status,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
      bottomNavigationBar: wide
          ? null
          : NavigationBar(
              selectedIndex: page,
              onDestinationSelected: busy
                  ? null
                  : (i) => setState(() => page = i),
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.grid_view),
                  label: '레시피',
                ),
                NavigationDestination(
                  icon: Icon(Icons.view_week_outlined),
                  label: 'C1–C7',
                ),
                NavigationDestination(icon: Icon(Icons.tune), label: '도구'),
              ],
            ),
    );
  }

  Widget sidebar() => ListView(
    padding: const EdgeInsets.all(20),
    children: [
      const SizedBox(height: 20),
      const Text(
        'YOUR COLOR,\nREADY TO GO.',
        style: TextStyle(
          fontWeight: FontWeight.w900,
          fontSize: 25,
          height: 1.2,
        ),
      ),
      const SizedBox(height: 12),
      const Text(
        'X100VI 레시피 워크스페이스',
        style: TextStyle(color: green, fontSize: 12),
      ),
      const SizedBox(height: 32),
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.file_open_outlined),
        title: const Text('JSON 가져오기'),
        onTap: busy || !loaded ? null : importLibrary,
      ),
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.ios_share),
        title: const Text('레시피 내보내기'),
        onTap: busy ? null : () => copyJson('레시피 JSON', exportRecipes(recipes)),
      ),
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.history),
        title: const Text('백업 / 복원'),
        onTap: busy ? null : backupMenu,
      ),
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.save_outlined),
        title: const Text('카메라 전체 백업'),
        onTap: busy || camera.identity == null
            ? null
            : () => run(() async {
                await store.backup(
                  camera.identity!,
                  await camera.backup({1, 2, 3, 4, 5, 6, 7}),
                );
                report('C1–C7 레시피 백업 완료');
              }),
      ),
      const Divider(height: 48),
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.system_update_alt),
        title: Text(checkingUpdate ? '새 버전 확인 중' : '앱 업데이트'),
        subtitle: Text(updateStatus),
        onTap: checkingUpdate || busy ? null : checkUpdates,
      ),
      if (update != null)
        FilledButton.tonal(
          onPressed: busy ? null : installUpdate,
          child: Text(Platform.isWindows ? '업데이트 후 재시작' : '새 버전 배포 페이지'),
        ),
      if (!Platform.isWindows)
        const Text(
          '새 버전은 자동 확인합니다. 설치는 OS별 배포 절차를 따릅니다.',
          style: TextStyle(fontSize: 11),
        ),
      const SizedBox(height: 20),
      const Text('연결 안내', style: TextStyle(fontWeight: FontWeight.bold)),
      const SizedBox(height: 12),
      const Text(
        '카메라 USB 모드\nUSB RAW CONV./BACKUP RESTORE\n\n데이터 전송 케이블을 사용하고 X RAW STUDIO 등 다른 카메라 앱은 종료하세요.\n\nWindows: 기본 WPD 드라이버 지원\nAndroid: USB 접근 허용\nApple: 카메라 접근 허용',
        style: TextStyle(fontSize: 12, height: 1.8),
      ),
      const SizedBox(height: 24),
      const Text(
        'v$appRelease · Experimental\nWindows X100VI 1.32 읽기·일괄 쓰기 확인 · 복원 미검증\nFUJIFILM 비공식 오픈소스 앱',
        style: TextStyle(fontSize: 11, color: Colors.black54),
      ),
    ],
  );
  Widget library() {
    final filtered = recipes
        .where(
          (r) =>
              '${r.name} ${r.film}'.toLowerCase().contains(query.toLowerCase()),
        )
        .toList();
    return ListView(
      key: libraryKey,
      controller: libraryScroll,
      padding: const EdgeInsets.all(28),
      children: [
        const Text(
          'THE RECIPE LIBRARY',
          style: TextStyle(
            letterSpacing: 2,
            fontSize: 11,
            color: green,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 12),
        const Text(
          '오늘은 어떤 색으로\n기록할까요?',
          style: TextStyle(
            fontSize: 34,
            fontWeight: FontWeight.w800,
            height: 1.25,
            letterSpacing: -1.5,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          '${recipes.length}개의 레시피 · 기기에 저장 · 계정 없이 사용',
          style: const TextStyle(fontSize: 12, color: Colors.black54),
        ),
        const SizedBox(height: 28),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            FilledButton.icon(
              onPressed: busy || !loaded ? null : () => edit(),
              icon: const Icon(Icons.add),
              label: const Text('레시피 만들기'),
            ),
            OutlinedButton.icon(
              onPressed: busy || !loaded ? null : importLibrary,
              icon: const Icon(Icons.file_open_outlined),
              label: const Text('가져오기'),
            ),
            OutlinedButton.icon(
              onPressed: busy || !loaded
                  ? null
                  : () => Navigator.of(context).push<void>(
                      MaterialPageRoute(
                        builder: (_) => BuiltinCatalog(onAdd: addBuiltin),
                      ),
                    ),
              icon: const Icon(Icons.collections_bookmark_outlined),
              label: const Text('내장 레시피'),
            ),
          ],
        ),
        const SizedBox(height: 20),
        TextField(
          onChanged: (v) => setState(() => query = v),
          decoration: const InputDecoration(
            prefixIcon: Icon(Icons.search),
            hintText: '이름 또는 필름 시뮬레이션 검색',
          ),
        ),
        const SizedBox(height: 24),
        if (filtered.length > 1)
          const Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: Text(
              '카드를 끌어 다른 카드 위에 놓으면 순서가 바뀝니다. 터치 화면에서는 길게 누른 뒤 끌어주세요.',
              style: TextStyle(fontSize: 12, color: Colors.black54),
            ),
          ),
        if (filtered.isEmpty)
          Container(
            padding: const EdgeInsets.symmetric(vertical: 56, horizontal: 24),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(
              children: [
                const Icon(Icons.camera_roll_outlined, size: 44, color: green),
                const SizedBox(height: 18),
                Text(
                  recipes.isEmpty ? '첫 번째 레시피를 만들어보세요.' : '검색 결과가 없습니다.',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  '필름 시뮬레이션과 색감을 정하고\nC1–C7에 원하는 조합으로 배치하세요.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.black54, height: 1.7),
                ),
              ],
            ),
          )
        else
          LayoutBuilder(
            builder: (context, c) => Wrap(
              spacing: 16,
              runSpacing: 16,
              children: filtered
                  .map(
                    (r) => SizedBox(
                      width: c.maxWidth >= 520
                          ? (c.maxWidth - 16) / 2
                          : c.maxWidth,
                      child: reorderableCard(
                        r,
                        c.maxWidth >= 520 ? (c.maxWidth - 16) / 2 : c.maxWidth,
                      ),
                    ),
                  )
                  .toList(),
            ),
          ),
      ],
    );
  }

  Widget reorderableCard(Recipe r, double width) {
    final card = recipeCard(r);
    final feedback = Opacity(
      opacity: 0.85,
      child: SizedBox(width: width, child: card),
    );
    final placeholder = Opacity(opacity: 0.3, child: card);
    final drags = busy || !loaded ? 0 : 1;
    // A mouse drags immediately; touch needs a long press so the list can scroll.
    final mouse = const {
      TargetPlatform.windows,
      TargetPlatform.macOS,
      TargetPlatform.linux,
    }.contains(defaultTargetPlatform);
    return DragTarget<String>(
      onWillAcceptWithDetails: (details) => details.data != r.id,
      onAcceptWithDetails: (details) => reorder(details.data, r.id),
      builder: (context, candidates, _) => DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          border: candidates.isEmpty
              ? null
              : Border.all(color: green, width: 2),
          borderRadius: BorderRadius.circular(14),
        ),
        child: mouse
            ? Draggable<String>(
                data: r.id,
                maxSimultaneousDrags: drags,
                feedback: feedback,
                childWhenDragging: placeholder,
                onDragStarted: startDragScroll,
                onDragUpdate: (d) => dragY = d.globalPosition.dy,
                onDragEnd: (_) => stopDragScroll(),
                child: card,
              )
            : LongPressDraggable<String>(
                data: r.id,
                maxSimultaneousDrags: drags,
                feedback: feedback,
                childWhenDragging: placeholder,
                onDragStarted: startDragScroll,
                onDragUpdate: (d) => dragY = d.globalPosition.dy,
                onDragEnd: (_) => stopDragScroll(),
                child: card,
              ),
      ),
    );
  }

  Widget recipeCard(Recipe r) => Card(
    elevation: 0,
    color: Colors.white,
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: busy ? null : () => edit(r),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            height: 70,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: monoFilms.contains(r.values[0xd192])
                    ? [const Color(0xff858782), const Color(0xffd3d4cc)]
                    : [
                        Color.lerp(
                          const Color(0xffcad3ad),
                          const Color(0xffc9a58e),
                          (r.values[0xd192]! % 5) / 4,
                        )!,
                        const Color(0xffe9e4cd),
                      ],
              ),
            ),
            padding: const EdgeInsets.all(16),
            alignment: Alignment.bottomLeft,
            child: Row(
              children: [
                FilmIcon(r.values[0xd192]!),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    r.film.toUpperCase(),
                    style: const TextStyle(
                      fontSize: 11,
                      letterSpacing: 1.5,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  r.name,
                  style: const TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  r.cameraName,
                  style: const TextStyle(fontSize: 12, color: Colors.black54),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    const Icon(Icons.tune, size: 14),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'R${r.values[0xd19a]} · B${r.values[0xd19b]}',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                    IconButton(
                      tooltip: '삭제',
                      onPressed: busy
                          ? null
                          : () async {
                              if (await confirm(
                                '레시피 삭제',
                                '${r.name}을 라이브러리와 슬롯 배치에서 삭제합니다. 카메라에 저장된 값은 바뀌지 않습니다.',
                              )) {
                                await run(() async {
                                  final oldR = List<Recipe>.from(recipes);
                                  final oldS = Map<int, String>.from(slots);
                                  recipes.removeWhere((v) => v.id == r.id);
                                  slots.removeWhere((k, v) => v == r.id);
                                  try {
                                    await save();
                                  } catch (_) {
                                    recipes = oldR;
                                    slots = oldS;
                                    rethrow;
                                  }
                                  report('레시피 삭제됨');
                                });
                              }
                            },
                      icon: const Icon(Icons.delete_outline, size: 18),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
  Widget kit() => ListView(
    key: const ValueKey('camera-kit'),
    padding: const EdgeInsets.all(24),
    children: [
      const Text(
        'CAMERA KIT',
        style: TextStyle(
          fontSize: 11,
          letterSpacing: 2,
          color: green,
          fontWeight: FontWeight.bold,
        ),
      ),
      const SizedBox(height: 12),
      const Text(
        '나의 일곱 가지 색',
        style: TextStyle(fontSize: 23, fontWeight: FontWeight.w800),
      ),
      const SizedBox(height: 8),
      const Text(
        '카메라의 현재 설정과 전송 대기 레시피입니다. 배치하지 않은 슬롯은 유지합니다.',
        style: TextStyle(fontSize: 12, color: Colors.black54),
      ),
      const SizedBox(height: 24),
      OutlinedButton.icon(
        onPressed: busy || camera.identity == null
            ? null
            : () => run(refreshSlots),
        icon: const Icon(Icons.refresh, size: 16),
        label: const Text('카메라 C1–C7 새로고침'),
      ),
      Text(
        slotsReadAt == null
            ? '카메라 연결 후 현재 레시피를 읽습니다.'
            : '마지막 읽기 ${slotsReadAt!.hour.toString().padLeft(2, '0')}:${slotsReadAt!.minute.toString().padLeft(2, '0')}',
        style: const TextStyle(fontSize: 11, color: Colors.black54),
      ),
      const SizedBox(height: 12),
      for (var slot = 1; slot <= 7; slot++)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Material(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            child: ListTile(
              onTap: busy || !loaded
                  ? null
                  : () => cameraSlots[slot] != null
                        ? showCameraSlot(slot)
                        : assign(slot),
              leading: Text(
                'C$slot',
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  color: green,
                  fontSize: 18,
                ),
              ),
              title: Text(
                cameraSlots[slot]?.name ?? assigned(slot)?.name ?? '레시피 배치',
                style: const TextStyle(fontSize: 13),
              ),
              subtitle: Text(
                [
                  if (cameraSlots[slot] != null)
                    '카메라 · ${cameraSlots[slot]!.film}',
                  if (assigned(slot) != null) '전송 대기 → ${assigned(slot)!.name}',
                  if (assigned(slot) == null && cameraSlots[slot] != null)
                    '눌러서 이름·설정 편집',
                ].join('\n'),
                style: const TextStyle(fontSize: 10),
              ),
              trailing: cameraSlots[slot] == null
                  ? const Icon(Icons.add, size: 16)
                  : IconButton(
                      tooltip: '다른 레시피로 교체',
                      icon: const Icon(Icons.swap_horiz, size: 18),
                      onPressed: busy ? null : () => assign(slot),
                    ),
            ),
          ),
        ),
      const SizedBox(height: 20),
      FilledButton.icon(
        onPressed: busy || camera.identity == null || slots.isEmpty
            ? null
            : apply,
        icon: const Icon(Icons.sync),
        label: Text('${slots.length}개 슬롯 일괄 적용'),
      ),
      const SizedBox(height: 16),
      const Text(
        '원본 백업 → 순차 전송 → 읽기 검증\nUSB 연결이 필요합니다.',
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 11, color: Colors.black54, height: 1.8),
      ),
    ],
  );
}

class RecipeEditor extends StatefulWidget {
  const RecipeEditor({super.key, required this.recipe});
  final Recipe recipe;
  @override
  State<RecipeEditor> createState() => _RecipeEditorState();
}

class _RecipeEditorState extends State<RecipeEditor> {
  late final name = TextEditingController(text: widget.recipe.name),
      cameraName = TextEditingController(text: widget.recipe.cameraName);
  late final values = Map<int, int>.from(widget.recipe.values);
  String? error;
  @override
  void dispose() {
    name.dispose();
    cameraName.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('레시피 편집'),
      actions: [
        TextButton(
          onPressed: () {
            try {
              Navigator.pop(
                context,
                Recipe(
                  id: widget.recipe.id,
                  name: name.text.trim(),
                  cameraName: cameraName.text.trim(),
                  values: values,
                ),
              );
            } catch (e) {
              setState(() => error = '$e');
            }
          },
          child: const Text('저장'),
        ),
      ],
    ),
    body: Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 760),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            TextField(
              controller: name,
              decoration: const InputDecoration(labelText: '라이브러리 이름'),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: cameraName,
              maxLength: 25,
              decoration: const InputDecoration(
                labelText: '카메라에 표시할 이름',
                helperText: '영문·숫자·공백·_.,+()- 사용',
              ),
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(error!, style: const TextStyle(color: Colors.red)),
              ),
            const SizedBox(height: 16),
            for (final s in settings)
              if (applicable(s.id, values) && s.id != 0xd19b)
                Padding(
                  key: ValueKey(s.id),
                  padding: const EdgeInsets.only(bottom: 18),
                  child: s.id == 0xd19a
                      ? WbShiftGrid(
                          red: values[0xd19a]!,
                          blue: values[0xd19b]!,
                          onChanged: (r, b) => setState(() {
                            values[0xd19a] = r;
                            values[0xd19b] = b;
                          }),
                        )
                      : s.options != null
                      ? DropdownButtonFormField<int>(
                          isExpanded: true,
                          initialValue: values[s.id],
                          decoration: InputDecoration(labelText: s.label),
                          items: s.options!.entries
                              .map(
                                (e) => DropdownMenuItem(
                                  value: e.key,
                                  child: s.id == 0xd192
                                      ? Row(
                                          children: [
                                            FilmIcon(e.key, size: 18),
                                            const SizedBox(width: 10),
                                            Text(e.value),
                                          ],
                                        )
                                      : Text(e.value),
                                ),
                              )
                              .toList(),
                          onChanged: (v) => setState(() => values[s.id] = v!),
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(child: Text(s.label)),
                                Text(
                                  s.display(values[s.id]!),
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                            Slider(
                              value: values[s.id]!.toDouble(),
                              min: s.min!.toDouble(),
                              max: s.max!.toDouble(),
                              divisions: (s.max! - s.min!) ~/ s.step,
                              label: s.display(values[s.id]!),
                              onChanged: (v) =>
                                  setState(() => values[s.id] = v.round()),
                            ),
                          ],
                        ),
                ),
            const Text(
              '카메라 상태에 따라 사용 가능한 값이 달라질 수 있습니다. 기종별 설정 범위와 카메라 응답을 확인합니다. X100VI 1.32는 속성 설명 대신 알려진 설정 범위를 사용하며, 쓰기 후 읽기로 검증합니다.',
              style: TextStyle(fontSize: 12, color: Colors.black54),
            ),
          ],
        ),
      ),
    ),
  );
}
