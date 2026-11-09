import 'package:flutter/material.dart';

import '../native.dart';
import '../protocol.dart';
import '../storage.dart';
import 'common.dart';
import 'recording_screen.dart';
import 'setup_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  String? _storageDir;
  String? _loadError;
  DeviceStatus? _status;
  List<SessionSummary> _sessions = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _reload();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Quay lại từ màn hình cài đặt: cập nhật trạng thái quyền.
    if (state == AppLifecycleState.resumed) _refreshStatus();
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    try {
      final dir = _storageDir ?? await Native.storageDir();
      final sessions = listSessions(dir);
      if (!mounted) return;
      setState(() {
        _storageDir = dir;
        _sessions = sessions;
        _loadError = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadError = errorText(e));
    }
    await _refreshStatus();
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _refreshStatus() async {
    try {
      final st = await Native.status();
      if (mounted) setState(() => _status = st);
    } catch (e) {
      if (mounted) setState(() => _loadError = errorText(e));
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      if (mounted) showSnack(context, errorText(e), error: true);
    }
    await _refreshStatus();
  }

  Future<void> _newSession() async {
    final config = await Navigator.of(context).push<SessionConfig>(
      MaterialPageRoute(builder: (_) => const SetupScreen()),
    );
    if (config == null || !mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (_) => RecordingScreen(config: config)),
    );
    if (mounted) _reload();
  }

  Future<void> _export(String dirPath, String zipName) async {
    showBusy(context, 'Đang nén và lưu file ZIP…');
    String? path;
    Object? err;
    try {
      path = await Native.exportZip(dirPath, zipName);
    } catch (e) {
      err = e;
    }
    if (!mounted) return;
    Navigator.of(context).pop();
    if (err != null) {
      showSnack(context, errorText(err), error: true);
    } else {
      showSnack(context, 'Đã lưu: $path');
    }
  }

  Future<void> _exportAll() async {
    final dir = _storageDir;
    if (dir == null || _sessions.isEmpty) {
      showSnack(context, 'Chưa có buổi thu nào để xuất');
      return;
    }
    final stamp = folderTimestamp(DateTime.now());
    await _export(sessionsRoot(dir).path, 'safenet_all_$stamp.zip');
  }

  Future<void> _delete(SessionSummary s) async {
    final ok = await confirmDialog(
      context,
      title: 'Xoá buổi thu?',
      message: 'Xoá vĩnh viễn ${s.sessionId}?\n'
          'Nên xuất ZIP trước khi xoá. Không thể hoàn tác.',
      confirmText: 'Xoá',
      danger: true,
    );
    if (!ok) return;
    try {
      s.dir.deleteSync(recursive: true);
    } catch (e) {
      if (mounted) showSnack(context, 'Không xoá được: $e', error: true);
    }
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('SafeNet Collector'),
        actions: [
          IconButton(
            tooltip: 'Làm mới',
            icon: const Icon(Icons.refresh),
            onPressed: _reload,
          ),
          IconButton(
            tooltip: 'Xuất tất cả',
            icon: const Icon(Icons.archive_outlined),
            onPressed: _exportAll,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _newSession,
        icon: const Icon(Icons.fiber_manual_record),
        label: const Text('Tạo buổi thu mới'),
      ),
      body: RefreshIndicator(
        onRefresh: _reload,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
          children: [
            _buildPrepCard(),
            if (_loadError != null)
              Card(
                color: Colors.red.shade50,
                child: ListTile(
                  leading: Icon(Icons.error, color: Colors.red.shade700),
                  title: Text(_loadError!),
                ),
              ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Các buổi đã thu (${_sessions.length})',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                TextButton.icon(
                  onPressed: _sessions.isEmpty ? null : _exportAll,
                  icon: const Icon(Icons.archive_outlined),
                  label: const Text('Xuất tất cả'),
                ),
              ],
            ),
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_sessions.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: Text('Chưa có buổi thu nào.')),
              )
            else
              ..._sessions.map(_buildSessionTile),
            if (_storageDir != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  'Thư mục lưu: ${sessionsRoot(_storageDir!).path}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildPrepCard() {
    final st = _status;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Chuẩn bị máy',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            _statusRow(
              ok: st?.notificationsEnabled ?? false,
              label: 'Quyền thông báo',
              okText: 'Đã bật',
              badText: 'Chưa bật',
              action: 'Cấp quyền',
              onAction: () => _run(() async {
                final granted = await Native.requestNotificationPermission();
                if (!granted && mounted) {
                  showSnack(context,
                      'Chưa được cấp. Nếu hộp thoại không hiện, hãy bật thông báo trong "Mở cài đặt app".');
                }
              }),
            ),
            _statusRow(
              ok: st?.ignoringBatteryOptimizations ?? false,
              label: 'Tối ưu pin',
              okText: 'Đã tắt (tốt)',
              badText: 'Đang bật – app có thể bị dừng khi tắt màn hình',
              action: 'Tắt tối ưu',
              onAction: () => _run(Native.requestIgnoreBatteryOptimizations),
            ),
            if (st?.batteryPercent != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('Pin hiện tại: ${st!.batteryPercent}%'),
              ),
            const Divider(height: 20),
            OutlinedButton.icon(
              onPressed: () => _run(Native.openAppSettings),
              icon: const Icon(Icons.settings),
              label: const Text('Mở cài đặt app'),
            ),
            const SizedBox(height: 6),
            Text(
              'Xiaomi/Redmi/POCO: bật "Tự khởi chạy" (Autostart), Tiết kiệm pin → '
              '"Không hạn chế", và khoá app trong màn hình đa nhiệm.\n'
              'Oppo/Realme: Pin → "Cho phép hoạt động nền", bật "Cho phép tự khởi động".\n'
              'Vivo: Pin → "Cho phép mức sử dụng pin cao trong nền", bật "Tự khởi động".',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  Widget _statusRow({
    required bool ok,
    required String label,
    required String okText,
    required String badText,
    required String action,
    required VoidCallback onAction,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(ok ? Icons.check_circle : Icons.warning_amber_rounded,
              color: ok ? Colors.green.shade700 : Colors.orange.shade800),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
                Text(ok ? okText : badText,
                    style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          if (!ok) TextButton(onPressed: onAction, child: Text(action)),
        ],
      ),
    );
  }

  Widget _buildSessionTile(SessionSummary s) {
    final created = s.createdAt;
    final dur = s.duration;
    final lines = <String>[
      '${sessionTypeName(s.sessionType)} · ${positionName(s.position)}',
      [
        if (created != null) fmtDateTime(created),
        dur != null ? fmtDuration(dur) : 'chưa kết thúc',
        '${s.totalSamples} mẫu',
      ].join(' · '),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
        child: Row(
          children: [
            CircleAvatar(child: Text(s.subject.isEmpty ? '?' : s.subject)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Người thu: ${s.subject}',
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  ...lines.map((l) => Text(l)),
                  Text(s.sessionId,
                      style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Xuất ZIP',
              icon: const Icon(Icons.ios_share),
              onPressed: () => _export(s.dir.path, '${s.sessionId}.zip'),
            ),
            IconButton(
              tooltip: 'Xoá',
              icon: Icon(Icons.delete_outline, color: Colors.red.shade700),
              onPressed: () => _delete(s),
            ),
          ],
        ),
      ),
    );
  }
}
