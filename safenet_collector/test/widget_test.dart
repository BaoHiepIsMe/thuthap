import 'package:flutter_test/flutter_test.dart';
import 'package:safenet_collector/src/protocol.dart';

void main() {
  test('danh mục hoạt động đủ và kế hoạch lập đúng', () {
    expect(SessionType.fall.activities.length, 7);
    expect(SessionType.trap.activities.length, 11);
    final choices =
        SessionType.fall.activities.map((a) => ActivityChoice(a)).toList();
    final plan = buildPlan(SessionType.fall, choices);
    expect(plan.length, 7 * 3);
    expect(plan.first.def.code, 'fall_forward');
    expect(plan.first.trialNo, 1);
  });
}
