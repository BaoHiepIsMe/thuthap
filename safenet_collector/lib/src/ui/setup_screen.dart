import 'package:flutter/material.dart';

import '../native.dart';
import '../protocol.dart';
import 'common.dart';

/// Màn hình tạo buổi thu. Trả về [SessionConfig] khi bấm Bắt đầu.
class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key});

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  final _subjectCtrl = TextEditingController(text: 'A');
  final _noteCtrl = TextEditingController();
  String _position = kPositions.first.code;
  SessionType _type = SessionType.fall;
  final Map<SessionType, List<ActivityChoice>> _choices = {
    for (final t in SessionType.values)
      t: t.activities.map((a) => ActivityChoice(a)).toList(),
  };
  bool _starting = false;

  @override
  void dispose() {
    _subjectCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  List<PlanItem> get _plan => buildPlan(_type, _choices[_type]!);

  Future<void> _start() async {
    final subject = _subjectCtrl.text.trim();
    if (subject.isEmpty) {
      showSnack(context, 'Hãy nhập mã người thu', error: true);
      return;
    }
    final plan = _plan;
    if (plan.isEmpty) {
      showSnack(context, 'Hãy chọn ít nhất một hoạt động', error: true);
      return;
    }
    setState(() => _starting = true);
    try {
      final ready = await _checkPermissions();
      if (!ready || !mounted) return;
      Navigator.of(context).pop(SessionConfig(
        subject: subject,
        position: _position,
        type: _type,
        plan: plan,
        note: _noteCtrl.text.trim(),
      ));
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  /// Kiểm tra thông báo + tối ưu pin. Trả về true nếu được phép bắt đầu.
  Future<bool> _checkPermissions() async {
    DeviceStatus st;
    try {
      st = await Native.status();
      if (!st.notificationsEnabled) {
        await Native.requestNotificationPermission();
        st = await Native.status();
      }
    } catch (e) {
      if (mounted) showSnack(context, errorText(e), error: true);
      return false;
    }
    final problems = <String>[
      if (!st.notificationsEnabled)
        'Chưa bật thông báo: dịch vụ nền vẫn chạy nhưng không thấy thông báo, '
            'và một số máy sẽ dừng app khi tắt màn hình.',
      if (!st.ignoringBatteryOptimizations)
        'Tối ưu pin đang bật: app có thể bị hệ thống dừng khi tắt màn hình.',
    ];
    if (problems.isEmpty || !mounted) return mounted;
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Máy chưa sẵn sàng'),
        content: Text(problems.map((p) => '• $p').join('\n\n')),
        actions: [
          if (!st.ignoringBatteryOptimizations)
            TextButton(
              onPressed: () {
                Navigator.of(ctx).pop(false);
                Native.requestIgnoreBatteryOptimizations()
                    .catchError((Object _) {});
              },
              child: const Text('Tắt tối ưu pin'),
            ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Vẫn bắt đầu'),
          ),
        ],
      ),
    );
    return go ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final plan = _plan;
    final est = estimatePlanSeconds(plan);
    return Scaffold(
      appBar: AppBar(title: const Text('Tạo buổi thu')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 120),
        children: [
          _section('Mã người thu'),
          Row(
            children: [
              for (final s in const ['A', 'B'])
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(s),
                    selected: _subjectCtrl.text.trim() == s,
                    onSelected: (_) => setState(() => _subjectCtrl.text = s),
                  ),
                ),
              Expanded(
                child: TextField(
                  controller: _subjectCtrl,
                  decoration: const InputDecoration(
                    hintText: 'hoặc nhập, ví dụ P03',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
            ],
          ),
          _section('Vị trí đặt máy'),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final p in kPositions)
                ChoiceChip(
                  label: Text(p.nameVi),
                  selected: _position == p.code,
                  onSelected: (_) => setState(() => _position = p.code),
                ),
            ],
          ),
          _section('Loại buổi'),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final t in SessionType.values)
                ChoiceChip(
                  label: Text(t.nameVi),
                  selected: _type == t,
                  onSelected: (_) => setState(() => _type = t),
                ),
            ],
          ),
          _section('Hoạt động'),
          if (_type == SessionType.continuous)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(12),
                child: Text(
                  'Ghi liên tục cho đến khi bấm "Dừng buổi thu". Không có lượt, '
                  'không đếm ngược. Dùng ghi chú để đánh dấu các việc đặc biệt.',
                ),
              ),
            )
          else
            ..._choices[_type]!.map(_activityTile),
          _section('Ghi chú'),
          TextField(
            controller: _noteCtrl,
            maxLines: 3,
            decoration: const InputDecoration(
              hintText: 'Ví dụ: nệm 25 cm, giày thể thao, quần jean…',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          if (_type != SessionType.continuous)
            Text(
              'Tổng: ${plan.length} lượt · ước tính ${fmtDuration(Duration(seconds: est))}',
              style: Theme.of(context).textTheme.titleSmall,
            ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(52)),
            onPressed: _starting ? null : _start,
            icon: const Icon(Icons.play_arrow),
            label: const Text('Bắt đầu', style: TextStyle(fontSize: 18)),
          ),
        ),
      ),
    );
  }

  Widget _section(String text) => Padding(
        padding: const EdgeInsets.only(top: 16, bottom: 8),
        child: Text(text, style: Theme.of(context).textTheme.titleMedium),
      );

  Widget _activityTile(ActivityChoice c) {
    final isLong = c.def.kind == ActivityKind.trapLong;
    final timing = isLong
        ? 'chuẩn bị ${c.def.prepSec}s · ${c.minutes} phút'
        : 'chuẩn bị ${c.def.prepSec}s · làm ${c.def.activeSec}s · nghỉ ${c.def.restSec}s';
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 8, 4),
        child: Column(
          children: [
            Row(
              children: [
                Checkbox(
                  value: c.selected,
                  onChanged: (v) => setState(() => c.selected = v ?? false),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(c.def.nameVi,
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      Text('${c.def.code} · $timing',
                          style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
                ),
              ],
            ),
            if (c.selected)
              Padding(
                padding: const EdgeInsets.only(left: 48),
                child: Wrap(
                  spacing: 16,
                  children: [
                    _stepper(
                      label: 'Số lượt',
                      value: c.trials,
                      min: 1,
                      max: 20,
                      onChanged: (v) => setState(() => c.trials = v),
                    ),
                    if (isLong)
                      _stepper(
                        label: 'Phút',
                        value: c.minutes,
                        min: 1,
                        max: 180,
                        step: c.minutes >= 10 ? 5 : 1,
                        onChanged: (v) => setState(() => c.minutes = v),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _stepper({
    required String label,
    required int value,
    required int min,
    required int max,
    int step = 1,
    required ValueChanged<int> onChanged,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$label:'),
        IconButton(
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.remove_circle_outline),
          onPressed: value > min
              ? () => onChanged((value - step).clamp(min, max))
              : null,
        ),
        SizedBox(
          width: 32,
          child: Text('$value',
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.bold)),
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.add_circle_outline),
          onPressed: value < max
              ? () => onChanged((value + step).clamp(min, max))
              : null,
        ),
      ],
    );
  }
}
