import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Trạng thái máy trả về từ `status()`.
class DeviceStatus {
  const DeviceStatus({
    this.batteryPercent,
    this.screenOn,
    this.ignoringBatteryOptimizations = false,
    this.notificationsEnabled = false,
    this.serviceRunning = false,
  });

  factory DeviceStatus.fromMap(Map<Object?, Object?> m) => DeviceStatus(
        batteryPercent: (m['batteryPercent'] as num?)?.toInt(),
        screenOn: m['screenOn'] as bool?,
        ignoringBatteryOptimizations:
            m['ignoringBatteryOptimizations'] as bool? ?? false,
        notificationsEnabled: m['notificationsEnabled'] as bool? ?? false,
        serviceRunning: m['serviceRunning'] as bool? ?? false,
      );

  final int? batteryPercent;
  final bool? screenOn;
  final bool ignoringBatteryOptimizations;
  final bool notificationsEnabled;
  final bool serviceRunning;
}

/// Bọc MethodChannel `safenet/native` (code Kotlin trong NativeTools.kt).
class Native {
  Native._();

  static const MethodChannel _ch = MethodChannel('safenet/native');

  static Future<void> startService(String title, String text) =>
      _ch.invokeMethod<void>('startService', {'title': title, 'text': text});

  static Future<void> stopService() => _ch.invokeMethod<void>('stopService');

  /// Đọc text; lỗi TTS chỉ ghi log, không làm hỏng buổi thu.
  static Future<void> speak(String text) async {
    try {
      await _ch.invokeMethod<void>('speak', {'text': text});
    } catch (e) {
      debugPrint('speak lỗi: $e');
    }
  }

  static Future<Map<String, Object?>> deviceInfo() async {
    final m = await _ch.invokeMapMethod<String, Object?>('deviceInfo');
    return _deepCast(m ?? const {});
  }

  static Future<DeviceStatus> status() async {
    final m = await _ch.invokeMapMethod<Object?, Object?>('status');
    return DeviceStatus.fromMap(m ?? const {});
  }

  static Future<String> storageDir() async {
    final s = await _ch.invokeMethod<String>('storageDir');
    if (s == null) throw StateError('storageDir trả về null');
    return s;
  }

  static Future<bool> requestNotificationPermission() async =>
      await _ch.invokeMethod<bool>('requestNotificationPermission') ?? false;

  static Future<void> requestIgnoreBatteryOptimizations() =>
      _ch.invokeMethod<void>('requestIgnoreBatteryOptimizations');

  static Future<void> openAppSettings() =>
      _ch.invokeMethod<void>('openAppSettings');

  /// Trả về đường dẫn hiển thị của file zip trong Downloads.
  static Future<String> exportZip(String dirPath, String zipName) async {
    final s = await _ch.invokeMethod<String>(
        'exportZip', {'dirPath': dirPath, 'zipName': zipName});
    return s ?? '';
  }

  static Map<String, Object?> _deepCast(Map<Object?, Object?> m) => m.map(
        (k, v) => MapEntry(
          k.toString(),
          v is Map<Object?, Object?> ? _deepCast(v) : v,
        ),
      );
}

/// Lấy message dễ đọc từ lỗi MethodChannel.
String errorText(Object e) {
  if (e is PlatformException) return e.message ?? e.code;
  return e.toString();
}
