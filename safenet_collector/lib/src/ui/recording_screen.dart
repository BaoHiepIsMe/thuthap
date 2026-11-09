import 'package:flutter/material.dart';

import '../protocol.dart';
import '../recorder.dart';
import 'common.dart';

class RecordingScreen extends StatefulWidget {
  const RecordingScreen({super.key, required this.config});

  final SessionConfig config;

  @override
  State<RecordingScreen> createState() => _RecordingScreenState();
}

class _RecordingScreenState extends State<RecordingScreen> {
  late final Recorder _rec;

  @override
  void initState() {
    super.initState();
    _rec = Recorder(widget.config);
    // Khởi động ngay khi màn hình hiển thị (service chỉ được start khi UI hiện).
    WidgetsBinding.instance.addPostFrameCallback((_) => _rec.start());
  }

  @override
  void dispose() {
    _rec.dispose();
    super.dispose();
  }

  Color _phaseColor(Phase p) {
    switch (p) {
      case Phase.starting:
        return Colors.blueGrey;
      case Phase.prep:
        return Colors.orange.shade800;
      case Phase.active:
        return Colors.red.shade700;
      case Phase.rest:
        return Colors.green.shade700;
      case Phase.done:
        return Colors.blueGrey.shade700;
    }
  }

  Future<void> _confirmStop() async {
    final ok = await confirmDialog(
      context,
      title: 'Dừng buổi thu?',
      message: _rec.isContinuous
          ? 'Kết thúc ghi sinh hoạt liên tục và lưu dữ liệu.'
          : 'Các lượt còn lại sẽ bị bỏ. Lượt đang thực hiện (nếu có) được đánh dấu "aborted".',
      confirmText: 'Dừng',
      danger: true,
    );
    if (ok) await _rec.stop();
  }

  Future<void> _addNote() async {
    final ctrl = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Ghi chú'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLines: 3,
          decoration: const InputDecoration(
            hintText: 'Ví dụ: vừa lên xe buýt, máy rơi khỏi túi…',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Huỷ'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text),
            child: const Text('Lưu'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (text != null && text.trim().isNotEmpty) {
      _rec.addNote(text);
      if (mounted) showSnack(context, 'Đã lưu ghi chú');
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: ListenableBuilder(
        listenable: _rec,
        builder: (context, _) => Scaffold(
          appBar: AppBar(
            automaticallyImplyLeading: false,
            title: Text('Đang ghi · ${widget.config.subject}'),
          ),
          body: SafeArea(child: _body(context)),
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    final r = _rec;
    if (r.fatalError != null) {
      return _centerMessage(r.fatalError!, error: true);
    }
    final theme = Theme.of(context);
    final color = _phaseColor(r.phase);
    final item = r.current;
    final next = r.next;
    final warnings = [
      ...r.warnings,
      if (r.serviceWarning != null) r.serviceWarning!,
    ];

    final String bigTime;
    if (r.phase == Phase.done) {
      bigTime = fmtDuration(r.elapsed);
    } else if (r.phase == Phase.active && (item?.activeSec ?? 0) == 0) {
      bigTime = fmtDuration(r.activeElapsed);
    } else {
      bigTime = fmtDuration(Duration(seconds: r.remaining < 0 ? 0 : r.remaining));
    }

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        for (final w in warnings)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.red.shade700,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                const Icon(Icons.warning, color: Colors.white),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(w,
                      style: const TextStyle(
                          color: Colors.white, fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          ),
        Container(
          padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 12),
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            children: [
              Text(
                (r.paused ? 'Tạm dừng · ' : '') +
                    r.phaseLabel(r.phase).toUpperCase(),
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineMedium?.copyWith(
                    color: Colors.white, fontWeight: FontWeight.bold),
              ),
              Text(
                bigTime,
                style: theme.textTheme.displayLarge?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              if (item != null && r.phase != Phase.done)
                Text(
                  item.def.nameVi,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleLarge
                      ?.copyWith(color: Colors.white),
                ),
              if (!r.isContinuous && r.phase != Phase.done && item != null)
                Text(
                  'Lượt ${r.index + 1}/${r.plan.length} · lần ${item.trialNo} của ${item.def.code}',
                  style: const TextStyle(color: Colors.white),
                ),
              if (r.phase == Phase.done)
                Text(
                  r.endReason == 'completed'
                      ? 'Đã hoàn thành kế hoạch'
                      : 'Đã dừng theo yêu cầu',
                  style: const TextStyle(color: Colors.white),
                ),
            ],
          ),
        ),
        if (next != null && r.phase != Phase.done && !r.isContinuous)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text('Lượt kế tiếp: ${next.def.nameVi}',
                style: theme.textTheme.titleMedium),
          ),
        const SizedBox(height: 8),
        _statsCard(r),
        const SizedBox(height: 8),
        if (r.phase == Phase.done) ..._doneControls(r) else ..._controls(r),
      ],
    );
  }

  Widget _statsCard(Recorder r) {
    final hzBad = r.isRunning && r.elapsed.inSeconds > 5 && r.hz5s < 40;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Wrap(
          spacing: 24,
          runSpacing: 8,
          children: [
            _stat('Hz (5 giây)', r.hz5s.toStringAsFixed(1),
                color: hzBad ? Colors.red.shade700 : null),
            _stat('Tổng mẫu', '${r.totalSamples}'),
            _stat('Đã ghi', fmtDuration(r.elapsed)),
            ValueListenableBuilder<double>(
              valueListenable: r.magnitude,
              builder: (_, m, __) =>
                  _stat('|a| (m/s²)', m.toStringAsFixed(2)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _stat(String label, String value, {Color? color}) {
    return SizedBox(
      width: 130,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.bodySmall),
          Text(value,
              style: TextStyle(
                  fontSize: 22, fontWeight: FontWeight.bold, color: color)),
        ],
      ),
    );
  }

  List<Widget> _controls(Recorder r) {
    const gap = SizedBox(height: 8);
    final big = FilledButton.styleFrom(minimumSize: const Size.fromHeight(52));
    return [
      if (!r.isContinuous) ...[
        Row(
          children: [
            Expanded(
              child: FilledButton.tonalIcon(
                style: big,
                onPressed: r.canPause ? r.togglePause : null,
                icon: Icon(r.paused ? Icons.play_arrow : Icons.pause),
                label: Text(r.paused ? 'Tiếp tục' : 'Tạm dừng'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton.tonalIcon(
                style: big,
                onPressed: r.canSkipRest ? r.skipRest : null,
                icon: const Icon(Icons.skip_next),
                label: const Text('Bỏ qua nghỉ'),
              ),
            ),
          ],
        ),
        gap,
        FilledButton.tonalIcon(
          style: big,
          onPressed: r.canRedo ? r.redoLast : null,
          icon: const Icon(Icons.replay),
          label: const Text('Lượt vừa rồi hỏng – làm lại'),
        ),
        gap,
        if (r.current?.def.kind == ActivityKind.trapLong) ...[
          FilledButton.tonalIcon(
            style: big,
            onPressed: r.canEndActivity ? r.endActivityEarly : null,
            icon: const Icon(Icons.flag),
            label: const Text('Kết thúc hoạt động'),
          ),
          gap,
        ],
      ],
      OutlinedButton.icon(
        style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
        onPressed: r.isRunning ? _addNote : null,
        icon: const Icon(Icons.edit_note),
        label: const Text('Ghi chú'),
      ),
      const SizedBox(height: 24),
      FilledButton.icon(
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(56),
          backgroundColor: Colors.red.shade700,
        ),
        onPressed: r.phase == Phase.starting ? null : _confirmStop,
        icon: const Icon(Icons.stop),
        label: const Text('Dừng buổi thu', style: TextStyle(fontSize: 18)),
      ),
    ];
  }

  List<Widget> _doneControls(Recorder r) {
    final ok = r.events.where((e) => e.status == 'ok' && e.kind != 'note');
    return [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Text(
            'Đã lưu ${r.totalSamples} mẫu, ${ok.length} lượt hợp lệ, '
            '${r.events.where((e) => e.status == 'redo').length} lượt làm lại, '
            '${r.events.where((e) => e.status == 'aborted').length} lượt bị huỷ.\n'
            'Thư mục: ${r.sessionId ?? ''}',
          ),
        ),
      ),
      const SizedBox(height: 8),
      FilledButton.icon(
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
        onPressed: () => Navigator.of(context).pop(),
        icon: const Icon(Icons.home),
        label: const Text('Về trang chủ', style: TextStyle(fontSize: 18)),
      ),
    ];
  }

  Widget _centerMessage(String text, {bool error = false}) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(error ? Icons.error : Icons.info,
                size: 48, color: error ? Colors.red.shade700 : null),
            const SizedBox(height: 12),
            Text(text, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Quay lại'),
            ),
          ],
        ),
      ),
    );
  }
}
