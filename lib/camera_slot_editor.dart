import 'package:flutter/material.dart';
import 'camera/camera.dart';
import 'domain/recipe.dart';

class CameraSlotEditor extends StatefulWidget {
  const CameraSlotEditor({
    super.key,
    required this.snapshot,
    required this.onSave,
  });
  final Snapshot snapshot;
  final Future<void> Function(SlotEdit edit) onSave;
  @override
  State<CameraSlotEditor> createState() => _CameraSlotEditorState();
}

class _CameraSlotEditorState extends State<CameraSlotEditor> {
  late final name = TextEditingController(text: widget.snapshot.rawName);
  late final values = Map<int, int>.from(widget.snapshot.values);
  bool saving = false;
  String? error;
  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  Future<void> save() async {
    setState(() {
      saving = true;
      error = null;
    });
    try {
      final edit = SlotEdit(name.text, values);
      if (edit.changes(widget.snapshot).isNotEmpty) await widget.onSave(edit);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !saving,
    child: Scaffold(
      appBar: AppBar(
        title: Text('C${widget.snapshot.slot} 레시피 편집'),
        actions: [
          TextButton(
            onPressed: saving ? null : save,
            child: const Text('카메라에 저장'),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Column(
            children: [
              if (saving) const LinearProgressIndicator(),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    error!,
                    style: const TextStyle(color: Colors.red),
                  ),
                ),
              Expanded(
                child: AbsorbPointer(
                  absorbing: saving,
                  child: ListView(
                    padding: const EdgeInsets.all(24),
                    children: [
                      TextField(
                        controller: name,
                        maxLength: 25,
                        decoration: const InputDecoration(
                          labelText: '카메라 레시피 이름',
                          helperText: '영문·숫자·공백·_.,+()- 사용 · 빈 이름도 유지 가능',
                        ),
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        '현재 카메라에 저장된 설정입니다. 저장하면 이 슬롯의 수정한 항목만 적용합니다. 원본을 먼저 백업합니다.',
                      ),
                      const SizedBox(height: 24),
                      for (final s in settings)
                        if (applicable(s.id, values))
                          Padding(
                            key: ValueKey(s.id),
                            padding: const EdgeInsets.only(bottom: 20),
                            child: s.options != null
                                ? DropdownButtonFormField<int>(
                                    key: ValueKey('${s.id}-${values[s.id]}'),
                                    isExpanded: true,
                                    initialValue: values[s.id],
                                    decoration: InputDecoration(
                                      labelText: s.label,
                                    ),
                                    items: [
                                      if (!s.accepts(values[s.id]!))
                                        DropdownMenuItem(
                                          value: values[s.id],
                                          child: Text(
                                            '현재 값 ${values[s.id]} · 유지',
                                          ),
                                        ),
                                      for (final option in s.options!.entries)
                                        DropdownMenuItem(
                                          value: option.key,
                                          child: Text(option.value),
                                        ),
                                    ],
                                    onChanged: (v) =>
                                        setState(() => values[s.id] = v!),
                                  )
                                : !s.accepts(values[s.id]!)
                                ? ListTile(
                                    contentPadding: EdgeInsets.zero,
                                    title: Text(s.label),
                                    subtitle: Text(
                                      '현재 값 ${values[s.id]} · 변경하지 않으면 유지됩니다.',
                                    ),
                                    trailing: TextButton(
                                      onPressed: () => setState(
                                        () => values[s.id] = s.initial,
                                      ),
                                      child: const Text('값 설정'),
                                    ),
                                  )
                                : Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Expanded(child: Text(s.label)),
                                          Text(s.display(values[s.id]!)),
                                        ],
                                      ),
                                      Slider(
                                        value: values[s.id]!.toDouble(),
                                        min: s.min!.toDouble(),
                                        max: s.max!.toDouble(),
                                        divisions: (s.max! - s.min!) ~/ s.step,
                                        label: s.display(values[s.id]!),
                                        onChanged: (v) => setState(
                                          () => values[s.id] = v.round(),
                                        ),
                                      ),
                                    ],
                                  ),
                          ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
