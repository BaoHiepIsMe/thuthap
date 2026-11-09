/// Danh mục hoạt động, vị trí đặt máy và kế hoạch buổi thu.
library;

enum ActivityKind {
  fall('fall'),
  trapShort('trap_short'),
  trapLong('trap_long'),
  continuous('continuous');

  const ActivityKind(this.code);
  final String code;
}

class ActivityDef {
  const ActivityDef({
    required this.code,
    required this.nameVi,
    required this.kind,
    required this.prepSec,
    required this.activeSec,
    required this.restSec,
    required this.defaultTrials,
    this.defaultMinutes = 0,
  });

  /// Mã tiếng Anh, dùng trong file CSV và script Python.
  final String code;
  final String nameVi;
  final ActivityKind kind;
  final int prepSec;

  /// Thời gian thực hiện (giây). Với trap_long tính từ [defaultMinutes];
  /// với continuous là 0 (chạy đến khi bấm Dừng).
  final int activeSec;
  final int restSec;
  final int defaultTrials;

  /// Chỉ dùng cho trap_long.
  final int defaultMinutes;
}

ActivityDef _fall(String code, String name) => ActivityDef(
      code: code,
      nameVi: name,
      kind: ActivityKind.fall,
      prepSec: 6,
      activeSec: 20,
      restSec: 20,
      defaultTrials: 3,
    );

ActivityDef _short(String code, String name) => ActivityDef(
      code: code,
      nameVi: name,
      kind: ActivityKind.trapShort,
      prepSec: 5,
      activeSec: 10,
      restSec: 8,
      defaultTrials: 5,
    );

ActivityDef _long(String code, String name, int minutes) => ActivityDef(
      code: code,
      nameVi: name,
      kind: ActivityKind.trapLong,
      prepSec: 5,
      activeSec: minutes * 60,
      restSec: 0,
      defaultTrials: 1,
      defaultMinutes: minutes,
    );

final List<ActivityDef> kActivities = [
  _fall('fall_forward', 'Ngã sấp về trước'),
  _fall('fall_backward', 'Ngã ngửa ra sau'),
  _fall('fall_left', 'Ngã nghiêng trái'),
  _fall('fall_right', 'Ngã nghiêng phải'),
  _fall('fall_from_chair', 'Ngã từ ghế'),
  _fall('fall_trip', 'Vấp ngã khi đang đi'),
  _fall('fall_syncope', 'Khuỵu từ từ (mô phỏng ngất)'),
  _short('sit_hard', 'Ngồi phịch xuống ghế/sofa'),
  _short('lie_bed', 'Nằm vật xuống giường'),
  _short('jump', 'Nhảy tại chỗ'),
  _short('phone_drop', 'Làm rơi máy xuống sàn/thảm'),
  _short('phone_toss_bed', 'Ném máy lên giường'),
  _short('squat_pickup', 'Cúi nhặt đồ'),
  _long('walking', 'Đi bộ', 5),
  _long('running', 'Chạy bộ', 5),
  _long('stairs', 'Lên xuống cầu thang', 5),
  _long('motorbike', 'Đi xe máy', 30),
  _long('in_bag', 'Máy trong balo/túi xách', 30),
];

const ActivityDef kAdlContinuous = ActivityDef(
  code: 'adl_continuous',
  nameVi: 'Sinh hoạt liên tục',
  kind: ActivityKind.continuous,
  prepSec: 0,
  activeSec: 0,
  restSec: 0,
  defaultTrials: 1,
);

class PhonePosition {
  const PhonePosition(this.code, this.nameVi);
  final String code;
  final String nameVi;
}

const List<PhonePosition> kPositions = [
  PhonePosition('pocket_front_trouser', 'Túi quần trước'),
  PhonePosition('pocket_back_trouser', 'Túi quần sau'),
  PhonePosition('jacket_pocket', 'Túi áo khoác'),
  PhonePosition('hand', 'Cầm tay'),
  PhonePosition('bag', 'Balo/túi xách'),
  PhonePosition('other', 'Khác'),
];

String positionName(String code) {
  for (final p in kPositions) {
    if (p.code == code) return p.nameVi;
  }
  return code;
}

enum SessionType {
  fall('fall', 'Ngã thử lên nệm', [ActivityKind.fall]),
  trap('trap', 'Tình huống dễ báo nhầm',
      [ActivityKind.trapShort, ActivityKind.trapLong]),
  continuous('continuous', 'Sinh hoạt liên tục', [ActivityKind.continuous]);

  const SessionType(this.code, this.nameVi, this.kinds);
  final String code;
  final String nameVi;
  final List<ActivityKind> kinds;

  static SessionType? fromCode(String? code) {
    for (final t in SessionType.values) {
      if (t.code == code) return t;
    }
    return null;
  }

  List<ActivityDef> get activities => this == SessionType.continuous
      ? const [kAdlContinuous]
      : kActivities.where((a) => kinds.contains(a.kind)).toList();
}

/// Một lượt trong kế hoạch buổi thu.
class PlanItem {
  const PlanItem({
    required this.def,
    required this.trialNo,
    required this.activeSec,
  });

  final ActivityDef def;
  final int trialNo;

  /// 0 = không giới hạn (continuous).
  final int activeSec;

  int get prepSec => def.prepSec;
  int get restSec => def.restSec;

  Map<String, Object?> toJson() => {
        'label': def.code,
        'name_vi': def.nameVi,
        'kind': def.kind.code,
        'trial_no': trialNo,
        'prep_s': prepSec,
        'active_s': activeSec,
        'rest_s': restSec,
      };
}

/// Lựa chọn của người thu cho một hoạt động trên màn hình Tạo buổi thu.
class ActivityChoice {
  ActivityChoice(this.def)
      : selected = true,
        trials = def.defaultTrials,
        minutes = def.defaultMinutes;

  final ActivityDef def;
  bool selected;
  int trials;
  int minutes;

  int get activeSec =>
      def.kind == ActivityKind.trapLong ? minutes * 60 : def.activeSec;
}

/// Lập kế hoạch: lần lượt từng hoạt động, mỗi hoạt động đủ số lượt.
List<PlanItem> buildPlan(SessionType type, List<ActivityChoice> choices) {
  if (type == SessionType.continuous) {
    return const [PlanItem(def: kAdlContinuous, trialNo: 1, activeSec: 0)];
  }
  final plan = <PlanItem>[];
  for (final c in choices) {
    if (!c.selected || c.trials <= 0) continue;
    for (var i = 1; i <= c.trials; i++) {
      plan.add(PlanItem(def: c.def, trialNo: i, activeSec: c.activeSec));
    }
  }
  return plan;
}

/// Ước lượng tổng thời lượng kế hoạch (giây).
int estimatePlanSeconds(List<PlanItem> plan) {
  var total = 0;
  for (var i = 0; i < plan.length; i++) {
    final p = plan[i];
    total += p.prepSec + p.activeSec;
    if (i < plan.length - 1) total += p.restSec;
  }
  return total;
}

class SessionConfig {
  const SessionConfig({
    required this.subject,
    required this.position,
    required this.type,
    required this.plan,
    required this.note,
  });

  final String subject;
  final String position;
  final SessionType type;
  final List<PlanItem> plan;
  final String note;
}
