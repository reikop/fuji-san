import 'dart:typed_data';
import '../domain/recipe.dart';
import 'ptp.dart';

class CameraIdentity {
  CameraIdentity(this.model, this.firmware, this.serial, this.properties);
  final String model, firmware, serial;
  final Set<int> properties;
}

class Snapshot {
  Snapshot(this.slot, this.properties);
  final int slot;
  final Map<int, Uint8List> properties;
  Map<String, dynamic> toJson() => {
    'slot': slot,
    'properties': properties.map(
      (k, v) => MapEntry(k.toRadixString(16), v.toList()),
    ),
  };
  factory Snapshot.fromJson(Map<String, dynamic> j) {
    final slot = j['slot'] as int;
    if (slot < 1 || slot > 7) {
      throw const FormatException('Invalid backup slot');
    }
    final p = (j['properties'] as Map<String, dynamic>).map(
      (k, v) => MapEntry(
        int.parse(k, radix: 16),
        Uint8List.fromList((v as List).cast<int>()),
      ),
    );
    if (!p.containsKey(0xd18d) || settings.any((s) => p[s.id]?.length != 2)) {
      throw const FormatException('Incomplete backup');
    }
    return Snapshot(slot, p);
  }
}

abstract interface class RecipeCamera {
  Future<List<Snapshot>> backup(Set<int> slots);
  Future<void> write(int slot, Recipe recipe);
  Future<void> restore(Snapshot snapshot);
}

class FujiCamera implements RecipeCamera {
  FujiCamera(this.transport);
  final CameraTransport transport;
  CameraIdentity? identity;
  Future<Uint8List> read(int prop) => transport.command(0x1015, params: [prop]);
  Future<void> set(int prop, Uint8List value) async {
    await transport.command(0x1016, params: [prop], outgoing: value);
  }

  Future<void> inspect() async {
    final r = Reader(await transport.command(0x1001));
    r.read16();
    r.read32();
    r.read16();
    r.string();
    r.read16();
    final ops = r.array16();
    r.array16();
    final props = r.array16().toSet();
    r.array16();
    r.array16();
    final manufacturer = r.string(),
        model = r.string(),
        firmware = r.string(),
        serial = r.string();
    if (!manufacturer.toUpperCase().contains('FUJI') ||
        model.toUpperCase() != 'X100VI') {
      throw StateError('이 버전은 FUJIFILM X100VI 전용입니다. 감지: $manufacturer $model');
    }
    if (!ops.contains(0x1014) ||
        !ops.contains(0x1015) ||
        !ops.contains(0x1016) ||
        !props.contains(0xd18c) ||
        !props.contains(0xd18d) ||
        settings.any((s) => !props.contains(s.id))) {
      throw StateError(
        '카메라가 필요한 레시피 속성을 제공하지 않습니다. USB RAW CONV./BACKUP RESTORE 모드를 확인하세요.',
      );
    }
    identity = CameraIdentity(model, firmware, serial, props);
  }

  void _ready() {
    if (identity == null) throw StateError('카메라 모델을 먼저 확인하세요.');
  }

  Future<void> select(int slot) async {
    if (slot < 1 || slot > 7) throw RangeError.range(slot, 1, 7);
    await set(0xd18c, u16(slot));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    if (Reader(await read(0xd18c)).read16() != slot) {
      throw StateError('슬롯 선택 검증 실패');
    }
  }

  @override
  Future<List<Snapshot>> backup(Set<int> slots) async {
    _ready();
    final original = await read(0xd18c);
    final result = <Snapshot>[];
    try {
      for (final slot in slots.toList()..sort()) {
        await select(slot);
        final p = <int, Uint8List>{0xd18d: await read(0xd18d)};
        for (final s in settings) {
          p[s.id] = await read(s.id);
          if (p[s.id]!.length != 2) throw StateError('백업 속성 길이 오류');
        }
        result.add(Snapshot(slot, p));
      }
    } finally {
      await set(0xd18c, original);
    }
    return result;
  }

  Future<void> _validateDescriptor(int id, Uint8List bytes) async {
    final r = Reader(await transport.command(0x1014, params: [id]));
    if (r.read16() != id) {
      throw const FormatException('Property descriptor mismatch');
    }
    final type = r.read16(), writable = r.read8();
    if (writable != 1) {
      throw StateError('속성 0x${id.toRadixString(16)}은 현재 수정할 수 없습니다.');
    }
    if (type == 0xffff && id == 0xd18d) return;
    if (type != 3 && type != 4) throw StateError('지원하지 않는 속성 자료형: $type');
    int number() {
      final n = r.read16();
      return type == 3 && n >= 32768 ? n - 65536 : n;
    }

    number();
    number();
    final form = r.read8();
    final b = ByteData.sublistView(bytes);
    final value = type == 3
        ? b.getInt16(0, Endian.little)
        : b.getUint16(0, Endian.little);
    if (form == 1) {
      final min = number(), max = number(), step = number();
      if (value < min ||
          value > max ||
          (step > 0 && (value - min) % step != 0)) {
        throw StateError('카메라 범위를 벗어난 설정: 0x${id.toRadixString(16)}');
      }
    } else if (form == 2) {
      final count = r.read16();
      final allowed = List.generate(count, (_) => number());
      if (!allowed.contains(value)) {
        throw StateError('카메라가 허용하지 않는 설정: 0x${id.toRadixString(16)}=$value');
      }
    } else if (form != 0) {
      throw const FormatException('Unknown property descriptor form');
    }
  }

  Future<void> _write(int slot, Map<int, Uint8List> p) async {
    _ready();
    final original = await read(0xd18c);
    try {
      await select(slot);
      for (final e in p.entries) {
        await _validateDescriptor(e.key, e.value);
        await set(e.key, e.value);
      }
      for (final e in p.entries) {
        final got = await read(e.key);
        final grainOff =
            e.key == 0xd195 &&
            Reader(e.value).read16() == 1 &&
            got.length == 2 &&
            Reader(got).read16() == 6;
        if (!grainOff && !_equal(got, e.value)) {
          throw StateError(
            'C$slot 속성 0x${e.key.toRadixString(16)} 읽기 검증 실패. 백업에서 복원하세요.',
          );
        }
      }
    } finally {
      await set(0xd18c, original);
    }
  }

  @override
  Future<void> write(int slot, Recipe recipe) => _write(slot, {
    for (final e in recipe.writeValues.entries) e.key: u16(e.value),
    0xd18d: ptpString(recipe.cameraName),
  });
  @override
  Future<void> restore(Snapshot snapshot) async {
    final values = <int, int>{};
    for (final s in settings) {
      final b = ByteData.sublistView(snapshot.properties[s.id]!);
      values[s.id] = s.signed
          ? b.getInt16(0, Endian.little)
          : b.getUint16(0, Endian.little);
    }
    final p = <int, Uint8List>{};
    for (final s in settings) {
      if (applicable(s.id, values)) {
        p[s.id] = s.id == 0xd195 && values[s.id] == 6
            ? u16(1)
            : snapshot.properties[s.id]!;
      }
    }
    p[0xd18d] = snapshot.properties[0xd18d]!;
    await _write(snapshot.slot, p);
  }
}

bool _equal(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

class BatchWriter {
  BatchWriter(this.camera);
  final RecipeCamera camera;
  bool _running = false;
  Future<void> apply(
    Map<int, Recipe> plan,
    Future<void> Function(List<Snapshot>) persist,
    void Function(String) report,
  ) async {
    if (_running) throw StateError('이미 전송 중입니다.');
    if (plan.isEmpty || plan.keys.any((s) => s < 1 || s > 7)) {
      throw ArgumentError('슬롯 C1~C7을 선택하세요.');
    }
    _running = true;
    try {
      report('원본 슬롯 백업 중');
      final backup = await camera.backup(plan.keys.toSet());
      if (backup.length != plan.length ||
          backup.map((s) => s.slot).toSet().length != plan.length ||
          backup
              .map((s) => s.slot)
              .toSet()
              .difference(plan.keys.toSet())
              .isNotEmpty) {
        throw StateError('백업이 완전하지 않습니다.');
      }
      await persist(
        backup,
      ); // A durable backup is required before any recipe write.
      for (final slot in plan.keys.toList()..sort()) {
        report('C$slot 쓰기 및 검증 중');
        await camera.write(slot, plan[slot]!);
        report('C$slot 검증 완료');
      }
    } finally {
      _running = false;
    }
  }
}
