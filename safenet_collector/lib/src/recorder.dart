import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:sensors_plus/sensors_plus.dart';

import 'native.dart';
import 'protocol.dart';
import 'storage.dart';

enum Phase { starting, prep, active, rest, done }

const int kRequestedSamplingUs = 20000;
const String kAppVersionFallback = '1.0.0';

int _nowUs() => DateTime.now().microsecondsSinceEpoch;

/// Điều khiển một buổi thu: đọc cảm biến, ghi file và chạy kịch bản giọng nói.
/// Toàn bộ chạy trong main isolate; foreground service chỉ giữ process sống.
class Recorder extends ChangeNotifier with WidgetsBindingObserver {
  Recorder(this.config) : plan = List.of(config.plan);

  final SessionConfig config;

  /// Kế hoạch thực tế (có thể được chèn thêm lượt làm lại).
  final List<PlanItem> plan;

  final List<EventRow> events = [];
  final ValueNotifier<double> magnitude = ValueNotifier<double>(0);

  SessionWriter? _w;
  StreamSubscription<AccelerometerEvent>? _sub;
  Timer? _timer;
  Map<String, Object?> _device = const {};
  DateTime? _createdAt;
  DateTime? _endedAt;

  String? sessionId;
  Directory? dir;

  Phase phase = Phase.starting;
  int index = 0;
  int remaining = 0;
  bool paused = false;
  bool _redoMarked = false;
  int _activeStartUs = 0;

  /// Lỗi khiến buổi thu không bắt đầu được.
  String? fatalError;
  String? serviceWarning;
  String? sensorError;
  String? endReason; // completed | stopped

  // ---- Thống kê ----
  int totalSamples = 0;
  int _lastTUs = 0;
  int _lastRecvUs = 0;
  int _maxGapUs = 0;
  int _startWallUs = 0;
  int _tickCount = 0;
  double hz5s = 0;
  final ListQueue<List<int>> _snapshots = ListQueue<List<int>>();
  int _healthLastUs = 0;
  int _healthBaseSamples = 0;
  AppLifecycleState _lifecycle = AppLifecycleState.resumed;

  final List<String> _speech = [];
  bool _disposed = false;

  // ------------------------------------------------------------------
  // Getters cho UI
  // ------------------------------------------------------------------

  bool get isContinuous => config.type == SessionType.continuous;
  PlanItem? get current => index < plan.length ? plan[index] : null;
  PlanItem? get next => index + 1 < plan.length ? plan[index + 1] : null;

  Duration get elapsed => _startWallUs == 0
      ? Duration.zero
      : Duration(
          microseconds: (_endedAt?.microsecondsSinceEpoch ?? _nowUs()) -
              _startWallUs);

  /// Thời gian đã thực hiện lượt hiện tại (dùng cho continuous).
  Duration get activeElapsed => phase == Phase.active
      ? Duration(microseconds: _nowUs() - _activeStartUs)
      : Duration.zero;

  bool get canPause => phase == Phase.prep || phase == Phase.rest;
  bool get canSkipRest => phase == Phase.rest;
  bool get canRedo =>
      !isContinuous &&
      ((phase == Phase.active) || (phase == Phase.rest && !_redoMarked));
  bool get canEndActivity =>
      phase == Phase.active && current?.def.kind == ActivityKind.trapLong;
  bool get isRunning =>
      phase == Phase.prep || phase == Phase.active || phase == Phase.rest;

  List<String> get warnings {
    if (!isRunning) return const [];
    final out = <String>[];
    if (sensorError != null) out.add('Lỗi cảm biến: $sensorError');
    final el = elapsed.inMilliseconds;
    final silentMs = (_nowUs() - _lastRecvUs) ~/ 1000;
    if (el > 2000 && silentMs > 2000) {
      out.add('Không nhận được mẫu nào trong ${(silentMs / 1000).toStringAsFixed(0)} giây!');
    }
    if (el > 5000 && hz5s < 40) {
      out.add('Tần số thấp: ${hz5s.toStringAsFixed(1)} Hz (< 40 Hz)');
    }
    return out;
  }

  // ------------------------------------------------------------------
  // Bắt đầu
  // ------------------------------------------------------------------

  Future<void> start() async {
    try {
      final storage = await Native.storageDir();
      try {
        _device = await Native.deviceInfo();
      } catch (e) {
        _device = {'error': errorText(e)};
      }
      final created = DateTime.now();
      _createdAt = created;
      final id = '${folderTimestamp(created)}_'
          '${sanitizeSubject(config.subject)}_${config.type.code}';
      sessionId = id;
      final d = Directory('${sessionsRoot(storage).path}/$id');
      dir = d;
      _w = SessionWriter.create(d);
      _writeMeta();
    } catch (e) {
      fatalError = 'Không tạo được buổi thu: ${errorText(e)}';
      phase = Phase.done;
      notifyListeners();
      return;
    }

    try {
      await Native.startService(
          'SafeNet đang ghi · ${config.subject}', 'Đang khởi động…');
    } catch (e) {
      serviceWarning =
          'Không chạy được dịch vụ nền: ${errorText(e)}. Ghi khi tắt màn hình có thể bị gián đoạn.';
    }

    WidgetsBinding.instance.addObserver(this);
    final now = _nowUs();
    _startWallUs = now;
    _lastRecvUs = now;
    _healthLastUs = now;
    _sub = accelerometerEventStream(
      samplingPeriod: const Duration(milliseconds: 20),
    ).listen(
      _onSample,
      onError: (Object e) {
        sensorError = e.toString();
        notifyListeners();
      },
      cancelOnError: false,
    );
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());

    if (isContinuous) {
      _say('Bắt đầu ghi sinh hoạt liên tục.');
      _beginActive(announce: false);
    } else if (plan.isEmpty) {
      await _finish(completed: true);
      return;
    } else {
      _enterPrep(0);
    }
    _flushSpeech();
    notifyListeners();
  }

  // ------------------------------------------------------------------
  // Cảm biến & đồng hồ
  // ------------------------------------------------------------------

  void _onSample(AccelerometerEvent e) {
    if (phase == Phase.done) return;
    final recv = _nowUs();
    final t = e.timestamp.microsecondsSinceEpoch;
    if (_lastTUs != 0) {
      final gap = t - _lastTUs;
      if (gap > _maxGapUs) _maxGapUs = gap;
    }
    _lastTUs = t;
    _lastRecvUs = recv;
    totalSamples++;
    _w?.addSample(t, e.x, e.y, e.z, (recv - t) / 1000.0);
    if (totalSamples % 5 == 0) {
      magnitude.value = math.sqrt(e.x * e.x + e.y * e.y + e.z * e.z);
    }
  }

  void _tick() {
    if (phase == Phase.done) return;
    _tickCount++;
    try {
      _w?.flushSamples(sync: _tickCount % 10 == 0);
    } catch (e) {
      sensorError = 'Lỗi ghi file: ${errorText(e)}';
    }

    final now = _nowUs();
    _snapshots.add([now, totalSamples]);
    while (_snapshots.length > 6) {
      _snapshots.removeFirst();
    }
    if (_snapshots.length >= 2) {
      final first = _snapshots.first;
      final dt = (now - first[0]) / 1e6;
      if (dt > 0) hz5s = (totalSamples - first[1]) / dt;
    }

    if (now - _healthLastUs >= 60 * 1000000) {
      _writeHealth(now);
      _writeMeta();
    }

    _advance();
    _flushSpeech();
    notifyListeners();
  }

  void _advance() {
    if (paused) return;
    switch (phase) {
      case Phase.prep:
        remaining--;
        if (remaining <= 0) {
          _beginActive();
        } else if (remaining <= 3) {
          _say(const ['Một', 'Hai', 'Ba'][remaining - 1]);
        }
        break;
      case Phase.active:
        final item = current;
        if (item != null && item.activeSec > 0) {
          remaining--;
          if (remaining <= 0) _endActive('ok');
        }
        break;
      case Phase.rest:
        remaining--;
        if (remaining <= 0) _enterPrep(index + 1);
        break;
      case Phase.starting:
      case Phase.done:
        break;
    }
  }

  // ------------------------------------------------------------------
  // State machine
  // ------------------------------------------------------------------

  void _enterPrep(int i) {
    index = i;
    final item = plan[i];
    phase = Phase.prep;
    paused = false;
    _redoMarked = false;
    remaining = item.prepSec;
    _say('Lượt ${i + 1} trên ${plan.length}. ${item.def.nameVi}. Chuẩn bị.');
    _updateNotification();
    if (remaining <= 0) _beginActive();
  }

  void _beginActive({bool announce = true}) {
    phase = Phase.active;
    paused = false;
    _activeStartUs = _nowUs();
    remaining = current?.activeSec ?? 0;
    if (announce) _say('Bắt đầu.');
    _updateNotification();
  }

  void _endActive(String status, {bool redo = false}) {
    final item = plan[index];
    _addEvent(EventRow(
      tStartUs: _activeStartUs,
      tEndUs: _nowUs(),
      label: item.def.code,
      kind: item.def.kind.code,
      trialNo: item.trialNo,
      status: status,
    ));
    final isFall = item.def.kind == ActivityKind.fall;
    if (redo) {
      plan.insert(index + 1, item);
      _say(isFall ? 'Lượt hỏng, sẽ làm lại. Đứng dậy.' : 'Lượt hỏng, sẽ làm lại.');
    } else {
      _say(isFall ? 'Xong. Đứng dậy.' : 'Xong.');
    }
    _afterTrial(redoMarked: redo);
  }

  void _afterTrial({required bool redoMarked}) {
    if (index >= plan.length - 1) {
      _finish(completed: true);
      return;
    }
    final item = plan[index];
    if (item.restSec > 0) {
      phase = Phase.rest;
      paused = false;
      remaining = item.restSec;
      _redoMarked = redoMarked;
      _say('Nghỉ. Lượt tiếp theo: ${plan[index + 1].def.nameVi}.');
      _updateNotification();
    } else {
      _enterPrep(index + 1);
    }
  }

  void _addEvent(EventRow e) {
    events.add(e);
    _saveEvents();
  }

  void _saveEvents() {
    try {
      _w?.writeEvents(events);
    } catch (e) {
      sensorError = 'Lỗi ghi events.csv: ${errorText(e)}';
    }
  }

  // ------------------------------------------------------------------
  // Nút điều khiển
  // ------------------------------------------------------------------

  void togglePause() {
    if (!canPause) return;
    paused = !paused;
    _say(paused ? 'Tạm dừng.' : 'Tiếp tục.');
    _flushSpeech();
    notifyListeners();
  }

  void skipRest() {
    if (!canSkipRest) return;
    _enterPrep(index + 1);
    _flushSpeech();
    notifyListeners();
  }

  void redoLast() {
    if (!canRedo) return;
    if (phase == Phase.active) {
      _endActive('redo', redo: true);
    } else if (phase == Phase.rest) {
      final item = plan[index];
      for (var i = events.length - 1; i >= 0; i--) {
        final e = events[i];
        if (e.label == item.def.code &&
            e.trialNo == item.trialNo &&
            e.status == 'ok') {
          e.status = 'redo';
          break;
        }
      }
      _saveEvents();
      plan.insert(index + 1, item);
      _redoMarked = true;
      _say('Sẽ làm lại lượt vừa rồi. Lượt tiếp theo: ${item.def.nameVi}.');
    }
    _flushSpeech();
    notifyListeners();
  }

  void endActivityEarly() {
    if (!canEndActivity) return;
    _endActive('ok');
    _flushSpeech();
    notifyListeners();
  }

  void addNote(String text) {
    final t = text.trim();
    if (t.isEmpty || _w == null) return;
    final now = _nowUs();
    _addEvent(EventRow(
      tStartUs: now,
      tEndUs: now,
      label: 'note',
      kind: 'note',
      trialNo: 0,
      status: 'ok',
      note: t,
    ));
    notifyListeners();
  }

  Future<void> stop() async {
    if (phase == Phase.done) return;
    if (phase == Phase.active) {
      final item = plan[index];
      _addEvent(EventRow(
        tStartUs: _activeStartUs,
        tEndUs: _nowUs(),
        label: item.def.code,
        kind: item.def.kind.code,
        trialNo: item.trialNo,
        status: isContinuous ? 'ok' : 'aborted',
      ));
    }
    await _finish(completed: false);
  }

  Future<void> _finish({required bool completed}) async {
    if (phase == Phase.done) return;
    phase = Phase.done;
    paused = false;
    endReason = completed ? 'completed' : 'stopped';
    _endedAt = DateTime.now();
    _timer?.cancel();
    _timer = null;
    final sub = _sub;
    _sub = null;
    _say(completed ? 'Đã hoàn thành buổi thu.' : 'Đã dừng buổi thu.');
    _flushSpeech();
    notifyListeners();

    await sub?.cancel();
    try {
      _w?.flushSamples(sync: true);
      await _writeHealth(_nowUs());
      _writeMeta();
      _w?.close();
    } catch (e) {
      sensorError = 'Lỗi khi đóng file: ${errorText(e)}';
    }
    WidgetsBinding.instance.removeObserver(this);
    try {
      await Native.stopService();
    } catch (_) {}
    notifyListeners();
  }

  // ------------------------------------------------------------------
  // health.csv, meta.json, notification, giọng nói
  // ------------------------------------------------------------------

  Future<void> _writeHealth(int now) async {
    final samples = totalSamples - _healthBaseSamples;
    final dt = (now - _healthLastUs) / 1e6;
    final hz = dt > 0 ? samples / dt : 0.0;
    final maxGapMs = _maxGapUs / 1000.0;
    final lifecycle = _lifecycle.name;
    _healthBaseSamples = totalSamples;
    _healthLastUs = now;
    _maxGapUs = 0;
    if (samples == 0 && dt < 1) return;

    DeviceStatus? st;
    try {
      st = await Native.status();
    } catch (_) {}
    final screen = st?.screenOn;
    final line = '$now,$samples,${hz.toStringAsFixed(2)},'
        '${maxGapMs.toStringAsFixed(1)},${st?.batteryPercent ?? ''},'
        '${screen == null ? '' : (screen ? 1 : 0)},$lifecycle';
    try {
      _w?.writeHealthLine(line);
    } catch (e) {
      sensorError = 'Lỗi ghi health.csv: ${errorText(e)}';
    }
  }

  void _writeMeta() {
    final w = _w;
    final created = _createdAt;
    if (w == null || created == null) return;
    final meta = <String, Object?>{
      'app_version': _device['appVersion'] ?? kAppVersionFallback,
      'session_id': sessionId,
      'created_at': isoWithOffset(created),
      'ended_at': _endedAt == null ? null : isoWithOffset(_endedAt!),
      'end_reason': endReason,
      'subject': config.subject,
      'phone_position': config.position,
      'session_type': config.type.code,
      'note': config.note,
      'plan': [
        for (var i = 0; i < config.plan.length; i++)
          {'index': i + 1, ...config.plan[i].toJson()},
      ],
      'device': _device,
      'requested_sampling_us': kRequestedSamplingUs,
      'total_samples': totalSamples,
      'columns': {
        'sensor.csv': {
          't_us':
              'Thời điểm mẫu, micro giây từ Unix epoch (timestamp gốc SensorEvent đã quy đổi)',
          'ax': 'Gia tốc trục x của máy, m/s^2, đã gồm trọng lực',
          'ay': 'Gia tốc trục y của máy, m/s^2, đã gồm trọng lực',
          'az': 'Gia tốc trục z của máy, m/s^2, đã gồm trọng lực',
          'recv_delay_ms': 'Thời điểm Dart nhận mẫu trừ t_us, mili giây',
        },
        'events.csv': {
          't_start_us': 'Bắt đầu phase thực hiện, micro giây từ Unix epoch',
          't_end_us': 'Kết thúc phase thực hiện, micro giây từ Unix epoch',
          'label': 'Mã hoạt động (hoặc note)',
          'kind': 'fall | trap_short | trap_long | continuous | note',
          'trial_no': 'Số thứ tự lượt của hoạt động (lượt làm lại giữ nguyên số)',
          'status': 'ok | redo | aborted',
          'note': 'Ghi chú tự do',
        },
        'health.csv': {
          't_us': 'Thời điểm ghi, micro giây từ Unix epoch',
          'samples_last_min': 'Số mẫu nhận được từ lần ghi trước',
          'effective_hz': 'Tần số thực tế trong khoảng đó, Hz',
          'max_gap_ms': 'Khoảng cách lớn nhất giữa 2 mẫu liên tiếp, ms',
          'battery_pct': 'Phần trăm pin',
          'screen_on': '1 = màn hình bật, 0 = tắt',
          'app_lifecycle': 'Trạng thái vòng đời Flutter',
        },
      },
      'units': {
        'time': 'us (epoch)',
        'acceleration': 'm/s^2 (gồm trọng lực)',
        'recv_delay': 'ms',
      },
    };
    try {
      w.writeMeta(meta);
    } catch (e) {
      sensorError = 'Lỗi ghi meta.json: ${errorText(e)}';
    }
  }

  String phaseLabel(Phase p) {
    switch (p) {
      case Phase.starting:
        return 'Đang khởi động';
      case Phase.prep:
        return 'Chuẩn bị';
      case Phase.active:
        return 'Đang thực hiện';
      case Phase.rest:
        return 'Nghỉ';
      case Phase.done:
        return 'Đã kết thúc';
    }
  }

  void _updateNotification() {
    final item = current;
    final text = isContinuous
        ? 'Sinh hoạt liên tục'
        : '${phaseLabel(phase)} · Lượt ${index + 1}/${plan.length} · ${item?.def.nameVi ?? ''}';
    Native.startService('SafeNet đang ghi · ${config.subject}', text)
        .catchError((Object _) {});
  }

  void _say(String s) => _speech.add(s);

  void _flushSpeech() {
    if (_speech.isEmpty) return;
    final text = _speech.join(' ');
    _speech.clear();
    Native.speak(text);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycle = state;
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    if (phase != Phase.done) {
      phase = Phase.done;
      _timer?.cancel();
      _sub?.cancel();
      try {
        _w?.close();
      } catch (_) {}
      WidgetsBinding.instance.removeObserver(this);
      Native.stopService().catchError((Object _) {});
    }
    magnitude.dispose();
    super.dispose();
  }
}
