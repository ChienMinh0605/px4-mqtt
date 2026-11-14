// Test kênh lệnh với Broker và Gateway THẬT (không chạy mặc định).
//
// Chuẩn bị (ở thư mục gốc repo):
//   ./scripts/setup_broker.sh
//   ./build/gateway/gateway --source fake --out /tmp/cmd &
// Chạy (trong app/):
//   flutter test test/cmd_channel_live_test.dart --dart-define=LIVE=true
//
// Kiểm tra các tiêu chí "Xong khi" trong docs/tasks/tien_kenh_lenh.md:
// hạ cánh, cất cánh 15 m, cất cánh lần hai bị invalid_state, bay tới, quay về,
// tranh quyền với commander op2 (not_owner), và "Không có phản hồi" khi Gateway tắt.
import 'dart:io';

import 'package:drone_monitor/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const live = bool.fromEnvironment('LIVE');
const host = String.fromEnvironment('HOST', defaultValue: '127.0.0.1');
// Đường dẫn commander, tính từ thư mục app/
const commander = '../build/commander/commander';

void main() {
  testWidgets('kênh lệnh với Gateway thật', (tester) async {
    tester.view.physicalSize = const Size(1200, 5000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    // Chờ thật (không phải đồng hồ giả của flutter_test) rồi vẽ lại
    Future<void> wait(int ms) async {
      await tester.runAsync(() => Future.delayed(Duration(milliseconds: ms)));
      await tester.pump();
    }

    // Bấm trong vùng chạy thật, để hẹn giờ 3 s của app là hẹn giờ thật
    Future<void> tap(String text) async {
      await tester.runAsync(() async => tester.tap(find.text(text)));
      await tester.pump();
    }

    String state() => tester.state<State>(find.byType(HomePage)).toString();
    String lastResult() {
      final s = tester.state(find.byType(HomePage)) as dynamic;
      final c = s.lastCmd;
      return c == null ? '' : c.statusText() as String;
    }

    Future<String> waitResult() async {
      for (var i = 0; i < 40 && lastResult().startsWith('Đang chờ'); i++) {
        await wait(100);
      }
      return lastResult();
    }

    double altitude() {
      final s = tester.state(find.byType(HomePage)) as dynamic;
      final t = (s.values['altitude'] as String).replaceAll(' m', '');
      return double.tryParse(t) ?? double.nan;
    }

    Future<double> waitAltitude(bool Function(double) ok, int maxMs) async {
      for (var t = 0; t < maxMs && !ok(altitude()); t += 250) {
        await wait(250);
      }
      return altitude();
    }

    await tester.pumpWidget(const MaterialApp(home: HomePage()));
    await tester.enterText(find.byType(TextField).first, host);
    await tap('Kết nối');
    for (var i = 0; i < 30 && find.text('Hạ cánh').evaluate().isEmpty; i++) {
      await wait(100);
    }
    expect(find.text('Hạ cánh'), findsOneWidget, reason: state());
    await wait(1500); // nhận vài tin telemetry

    // 1. Hạ cánh: accepted, độ cao về 0
    await tap('Hạ cánh');
    expect(await waitResult(), 'accepted');
    final s0 = tester.state(find.byType(HomePage)) as dynamic;
    expect(s0.lastCmd.rttMs, isNotNull);
    debugPrint('Hạ cánh: khứ hồi ${s0.lastCmd.rttMs} ms');
    debugPrint('  độ cao sau khi chạm đất: ${await waitAltitude((a) => a < 0.2, 20000)}');
    expect(altitude(), lessThan(0.2));

    // 2. Cất cánh 15 m, rồi cất cánh lần nữa khi đang bay -> invalid_state
    await tester.enterText(find.widgetWithText(TextField, 'Độ cao (m)'), '15');
    await tap('Cất cánh');
    expect(await waitResult(), 'accepted');
    await wait(1000);
    await tap('Cất cánh');
    expect(await waitResult(), 'rejected: invalid_state');
    debugPrint('  độ cao sau cất cánh: ${await waitAltitude((a) => a > 14.5, 20000)}');
    expect(altitude(), greaterThan(14.5));

    // 3. Bay tới điểm demo
    await tap('Bay tới');
    expect(await waitResult(), 'accepted');
    await wait(2000);
    final s1 = tester.state(find.byType(HomePage)) as dynamic;
    debugPrint('  đang bay tới: ${s1.values['position']}, ${s1.values['velocity']}');

    // 4. Tranh quyền: app vừa gửi lệnh, op2 gửi hold -> not_owner
    var r = await tester.runAsync(
        () => Process.run(commander, ['--action', 'hold', '--from', 'op2']));
    debugPrint('  commander op2: ${r!.stdout}');
    expect(r.stdout as String, contains('not_owner'));
    await wait(300);
    expect(find.textContaining('app-tien (mình)'), findsOneWidget);

    // Nhả quyền, op2 lấy được quyền, app hiện owner = op2, lệnh app bị not_owner
    await tap('Nhả quyền');
    expect(await waitResult(), 'accepted');
    r = await tester.runAsync(
        () => Process.run(commander, ['--action', 'hold', '--from', 'op2']));
    expect(r!.stdout as String, contains('accepted'));
    await wait(300);
    expect(find.text('op2'), findsOneWidget);
    await tap('Đứng yên');
    expect(await waitResult(), 'rejected: not_owner');

    // Đợi quyền của op2 tự nhả (5 s), rồi Quay về
    await wait(5500);
    await tap('Quay về');
    expect(await waitResult(), 'accepted');
    debugPrint('  sau RTL, độ cao: ${await waitAltitude((a) => a < 0.2, 90000)}');
    final s2 = tester.state(find.byType(HomePage)) as dynamic;
    debugPrint('  vị trí sau RTL: ${s2.values['position']}');
    expect(altitude(), lessThan(0.2));

    // 5. Gateway tắt: không có ack trong 3 s -> "Không có phản hồi"
    await tester.runAsync(
        () => Process.run('pkill', ['-INT', '-x', 'gateway']));
    await wait(1000);
    await tap('Đứng yên');
    await wait(3500);
    expect(lastResult(), startsWith('Không có phản hồi'));

    await tap('Ngắt kết nối');
    await wait(300);
  }, skip: !live, timeout: const Timeout(Duration(minutes: 4)));
}
