import 'dart:convert';
import 'dart:io';

/// Thời điểm theo ISO 8601 có timezone, ví dụ 2026-11-03T14:05:09.123+07:00.
String isoWithOffset(DateTime t) {
  final local = t.toLocal();
  final base = local.toIso8601String(); // không có offset với giờ local
  final off = local.timeZoneOffset;
  final sign = off.isNegative ? '-' : '+';
  final abs = off.abs();
  final hh = abs.inHours.toString().padLeft(2, '0');
  final mm = (abs.inMinutes % 60).toString().padLeft(2, '0');
  return '$base$sign$hh:$mm';
}

String _two(int v) => v.toString().padLeft(2, '0');

String folderTimestamp(DateTime t) =>
    '${t.year}${_two(t.month)}${_two(t.day)}_${_two(t.hour)}${_two(t.minute)}${_two(t.second)}';

/// Chỉ giữ chữ, số, '-' và '_' để làm tên thư mục an toàn.
String sanitizeSubject(String s) {
  final cleaned = s.trim().replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '');
  return cleaned.isEmpty ? 'X' : cleaned;
}

String csvField(String s) {
  if (s.contains(',') ||
      s.contains('"') ||
      s.contains('\n') ||
      s.contains('\r')) {
    return '"${s.replaceAll('"', '""')}"';
  }
  return s;
}

class EventRow {
  EventRow({
    required this.tStartUs,
    required this.tEndUs,
    required this.label,
    required this.kind,
    required this.trialNo,
    required this.status,
    this.note = '',
  });

  final int tStartUs;
  final int tEndUs;
  final String label;
  final String kind;
  final int trialNo;
  String status; // ok | redo | aborted
  final String note;

  String toCsv() => '$tStartUs,$tEndUs,${csvField(label)},$kind,$trialNo,'
      '$status,${csvField(note)}';
}

/// Ghi 4 file của một buổi thu. Dùng RandomAccessFile (không dùng IOSink).
class SessionWriter {
  SessionWriter._(this.dir, this._sensor, this._health);

  static const sensorHeader = 't_us,ax,ay,az,recv_delay_ms\n';
  static const eventsHeader =
      't_start_us,t_end_us,label,kind,trial_no,status,note\n';
  static const healthHeader =
      't_us,samples_last_min,effective_hz,max_gap_ms,battery_pct,screen_on,app_lifecycle\n';

  final Directory dir;
  final RandomAccessFile _sensor;
  final RandomAccessFile _health;
  final StringBuffer _buf = StringBuffer();
  bool _closed = false;

  static SessionWriter create(Directory dir) {
    dir.createSync(recursive: true);
    final sensor = File('${dir.path}/sensor.csv').openSync(mode: FileMode.append)
      ..writeStringSync(sensorHeader);
    final health = File('${dir.path}/health.csv').openSync(mode: FileMode.append)
      ..writeStringSync(healthHeader);
    File('${dir.path}/events.csv').writeAsStringSync(eventsHeader, flush: true);
    return SessionWriter._(dir, sensor, health);
  }

  void addSample(int tUs, double x, double y, double z, double recvDelayMs) {
    _buf
      ..write(tUs)
      ..write(',')
      ..write(x.toStringAsFixed(4))
      ..write(',')
      ..write(y.toStringAsFixed(4))
      ..write(',')
      ..write(z.toStringAsFixed(4))
      ..write(',')
      ..write(recvDelayMs.toStringAsFixed(1))
      ..write('\n');
  }

  /// Gọi mỗi giây; [sync] = true (mỗi 10 giây) thì flush xuống đĩa.
  void flushSamples({bool sync = false}) {
    if (_closed) return;
    if (_buf.isNotEmpty) {
      _sensor.writeStringSync(_buf.toString());
      _buf.clear();
    }
    if (sync) _sensor.flushSync();
  }

  void writeHealthLine(String line) {
    if (_closed) return;
    _health
      ..writeStringSync('$line\n')
      ..flushSync();
  }

  /// events.csv nhỏ nên ghi lại toàn bộ mỗi khi thay đổi (cần để sửa status=redo).
  void writeEvents(List<EventRow> events) {
    final sb = StringBuffer(eventsHeader);
    for (final e in events) {
      sb.writeln(e.toCsv());
    }
    _atomicWrite('events.csv', sb.toString());
  }

  void writeMeta(Map<String, Object?> meta) {
    _atomicWrite('meta.json', const JsonEncoder.withIndent('  ').convert(meta));
  }

  void _atomicWrite(String name, String content) {
    final tmp = File('${dir.path}/$name.tmp');
    tmp.writeAsStringSync(content, flush: true);
    tmp.renameSync('${dir.path}/$name');
  }

  void close() {
    if (_closed) return;
    flushSamples(sync: true);
    _closed = true;
    _sensor.closeSync();
    _health.closeSync();
  }
}

/// Thông tin tóm tắt một buổi thu để hiển thị ở Home.
class SessionSummary {
  SessionSummary({
    required this.dir,
    required this.sessionId,
    required this.subject,
    required this.sessionType,
    required this.position,
    required this.createdAt,
    required this.endedAt,
    required this.totalSamples,
  });

  final Directory dir;
  final String sessionId;
  final String subject;
  final String sessionType;
  final String position;
  final DateTime? createdAt;
  final DateTime? endedAt;
  final int totalSamples;

  Duration? get duration => (createdAt != null && endedAt != null)
      ? endedAt!.difference(createdAt!)
      : null;
}

Directory sessionsRoot(String storageDir) =>
    Directory('$storageDir/sessions');

List<SessionSummary> listSessions(String storageDir) {
  final root = sessionsRoot(storageDir);
  if (!root.existsSync()) return [];
  final out = <SessionSummary>[];
  for (final ent in root.listSync()) {
    if (ent is! Directory) continue;
    final metaFile = File('${ent.path}/meta.json');
    final name = ent.path.split(Platform.pathSeparator).last.split('/').last;
    Map<String, Object?> m = const {};
    if (metaFile.existsSync()) {
      try {
        final decoded = jsonDecode(metaFile.readAsStringSync());
        if (decoded is Map<String, Object?>) m = decoded;
      } catch (_) {
        // meta hỏng: vẫn liệt kê để có thể xoá/xuất.
      }
    }
    out.add(SessionSummary(
      dir: ent,
      sessionId: m['session_id'] as String? ?? name,
      subject: m['subject'] as String? ?? '?',
      sessionType: m['session_type'] as String? ?? '?',
      position: m['phone_position'] as String? ?? '',
      createdAt: DateTime.tryParse(m['created_at'] as String? ?? ''),
      endedAt: DateTime.tryParse(m['ended_at'] as String? ?? ''),
      totalSamples: (m['total_samples'] as num?)?.toInt() ?? 0,
    ));
  }
  out.sort((a, b) => b.sessionId.compareTo(a.sessionId));
  return out;
}
