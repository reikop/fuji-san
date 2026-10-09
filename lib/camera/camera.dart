import 'dart:typed_data';
import '../domain/recipe.dart';
import 'ptp.dart';
import '../diagnostic_log.dart';

class CameraIdentity {
  CameraIdentity(this.model, this.firmware, this.serial, this.properties);
  final String model, firmware, serial;
  final Set<int> properties;
}

class Snapshot {
  Snapshot(this.slot, this.properties);
  final int slot;
  final Map<int, Uint8List> properties;
  String get rawName => Reader(properties[0xd18d]!).string();
  String get name {
    final name = Reader(properties[0xd18d]!).string().trim();
    return name.isEmpty ? '이름 없는 레시피' : name;
  }

  Map<int, int> get values => {
    for (final s in settings)
      s.id: s.id == 0xd195 && Reader(properties[s.id]!).read16() == 6
          ? 1
          : s.signed
          ? ByteData.sublistView(properties[s.id]!).getInt16(0, Endian.little)
          : Reader(properties[s.id]!).read16(),
  };

  String get film => filmNames[values[0xd192]] ?? '알 수 없는 필름';
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
  bool _knownSchemaOnly = false;
  Future<Uint8List> read(int prop) => transport.command(0x1015, params: [prop]);
  Future<void> set(int prop, Uint8List value) async {
    await transport.command(0x1016, params: [prop], outgoing: value);
  }

  Future<void> inspect() async {
    _knownSchemaOnly = false;
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
    DiagnosticLog.instance.protect(serial);
    DiagnosticLog.instance.camera.addAll({
      'model': DiagnosticLog.instance.redact(model, max: 25),
      'firmware': DiagnosticLog.instance.redact(firmware, max: 25),
    });
    DiagnosticLog.instance.add(
      'camera',
      'deviceInfo ops=${ops.map((p) => p.toRadixString(16)).join(',')} properties=${props.map((p) => p.toRadixString(16)).join(',')}',
    );
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
      if (!_same(await read(0xd18c), original)) {
        throw StateError('원래 C 슬롯을 복원하지 못했습니다. 카메라에서 확인하세요.');
      }
    }
    return result;
  }

  bool _same(Uint8List a, Uint8List b) =>
      a.length == b.length &&
      List.generate(a.length, (i) => a[i] == b[i]).every((v) => v);

  Future<void> _validateDescriptor(int id, Uint8List bytes) async {
    if (_knownSchemaOnly) {
      _validateKnownValue(id, bytes);
      return;
    }
    late Uint8List descriptor;
    try {
      descriptor = await transport.command(0x1014, params: [id]);
    } on PtpResponseException catch (e) {
      // Observed on a real X100VI 1.32: 1014 is advertised, but every recipe
      // descriptor returns GeneralError. Value reads work through WPD.
      if (identity?.model == 'X100VI' &&
          identity?.firmware == '1.32' &&
          e.operation == 0x1014 &&
          e.code == 0x2002) {
        _validateKnownValue(id, bytes);
        _knownSchemaOnly = true;
        return;
      }
      rethrow;
    }
    final r = Reader(descriptor);
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

  void _validateKnownValue(int id, Uint8List bytes) {
    if (!identity!.properties.contains(id)) {
      throw StateError('카메라가 지원하지 않는 속성입니다.');
    }
    if (id == 0xd18d) {
      if (bytes.length == 1 && bytes[0] == 0) return;
      final name = Reader(bytes).string();
      if (name.length > 25 || bytes.length != 1 + (name.length + 1) * 2) {
        throw const FormatException('Invalid camera name backup');
      }
      return;
    }
    final setting = settings.firstWhere((s) => s.id == id);
    if (bytes.length != 2) {
      throw const FormatException('Invalid recipe property size');
    }
    final raw = ByteData.sublistView(bytes);
    final value = setting.signed
        ? raw.getInt16(0, Endian.little)
        : raw.getUint16(0, Endian.little);
    if (!setting.accepts(value)) {
      throw StateError('X100VI 설정 범위를 벗어났습니다: ${setting.label}');
    }
  }

  Future<void> _write(int slot, Map<int, Uint8List> p) async {
    _ready();
    final original = await read(0xd18c);
    try {
      await select(slot);
      for (final e in p.entries) {
        await _validateDescriptor(e.key, e.value);
        try {
          await set(e.key, e.value);
        } on PtpResponseException catch (error) {
          // A real X100VI 1.32 refused a restore of values the slot already
          // held. A refused write is tolerated only when nothing has to change;
          // the read-back pass below still checks every property.
          if (error.code != 0x201c ||
              !_holds(e.key, e.value, await read(e.key))) {
            throw StateError(
              'C$slot ${_label(e.key)} 값을 카메라가 거부했습니다 '
              '(응답 0x${error.code.toRadixString(16)}, 보낸 값 ${_hex(e.value)}). '
              '이 항목 이전에 보낸 설정은 적용되었을 수 있습니다.',
            );
          }
        }
      }
      for (final e in p.entries) {
        final got = await read(e.key);
        if (!_holds(e.key, e.value, got)) {
          throw StateError(
            'C$slot 속성 0x${e.key.toRadixString(16)} 읽기 검증 실패. 백업에서 복원하세요.',
          );
        }
      }
    } finally {
      await set(0xd18c, original);
      if (!_equal(await read(0xd18c), original)) {
        throw StateError('원래 C 슬롯 복원 실패. 카메라에서 확인하세요.');
      }
    }
  }

  // Grain "Off" is written as 1 and read back as 6.
  bool _holds(int id, Uint8List wanted, Uint8List got) =>
      _equal(got, wanted) ||
      (id == 0xd195 &&
          Reader(wanted).read16() == 1 &&
          got.length == 2 &&
          Reader(got).read16() == 6);

  String _label(int id) =>
      '${id == 0xd18d ? '이름' : settings.firstWhere((s) => s.id == id).label} '
      '(0x${id.toRadixString(16)})';

  String _hex(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');

  // Diagnostic: writes each known property of each slot back with the bytes just
  // read, so no setting changes, and records the camera's response to each write.
  Future<List<Map<String, dynamic>>> probeWriteBack(Set<int> slots) async {
    _ready();
    final original = await read(0xd18c);
    final result = <Map<String, dynamic>>[];
    try {
      for (final slot in slots.toList()..sort()) {
        await select(slot);
        final writes = <String, dynamic>{};
        for (final id in [...settings.map((s) => s.id), 0xd18d]) {
          final value = await read(id);
          var response = 0x2001;
          try {
            await set(id, value);
          } on PtpResponseException catch (error) {
            response = error.code;
          }
          writes[id.toRadixString(16)] = {
            'value': _hex(value),
            'response': '0x${response.toRadixString(16)}',
            'unchanged': _equal(await read(id), value),
          };
        }
        result.add({'slot': slot, 'writes': writes});
      }
    } finally {
      await set(0xd18c, original);
      if (!_equal(await read(0xd18c), original)) {
        throw StateError('원래 C 슬롯 복원 실패. 카메라에서 확인하세요.');
      }
    }
    return result;
  }

  Future<void> editSlot(
    Snapshot original,
    SlotEdit edit,
    Future<void> Function(List<Snapshot>) persist,
  ) async {
    final changes = edit.changes(original);
    if (changes.isEmpty) return;
    final current = (await backup({original.slot})).single;
    if (original.properties.entries.any(
      (e) =>
          current.properties[e.key] == null ||
          !_equal(e.value, current.properties[e.key]!),
    )) {
      throw StateError('편집 중 카메라 설정이 바뀌었습니다. 닫고 새로고침한 뒤 다시 편집하세요.');
    }
    await persist([current]);
    await _write(original.slot, changes);
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

class SlotEdit {
  SlotEdit(this.name, Map<int, int> values) : values = Map.unmodifiable(values);
  final String name;
  final Map<int, int> values;

  Map<int, Uint8List> changes(Snapshot original) {
    if (values.length != settings.length ||
        settings.any((s) => !values.containsKey(s.id))) {
      throw const FormatException('불완전한 레시피 설정입니다.');
    }
    final before = original.values;
    final result = <int, Uint8List>{};
    for (final setting in settings) {
      if (!applicable(setting.id, values) ||
          values[setting.id] == before[setting.id]) {
        continue;
      }
      if (!setting.accepts(values[setting.id]!)) {
        throw FormatException('${setting.label} 설정값을 확인하세요.');
      }
      result[setting.id] = u16(values[setting.id]!);
    }
    if (name != original.rawName) {
      if (!RegExp(r'^[A-Za-z0-9 _.,+()\-]{0,25}$').hasMatch(name)) {
        throw const FormatException('카메라 이름은 영문·숫자·공백·_.,+()- 25자 이내로 입력하세요.');
      }
      result[0xd18d] = ptpString(name);
    }
    return result;
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
