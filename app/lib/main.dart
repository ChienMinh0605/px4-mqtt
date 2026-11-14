import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

void main() {
  // Khi Broker tắt đột ngột, thư viện mqtt_client có thể ném lỗi mạng
  // (SocketException, ConnectionException) ở bên trong nó. runZonedGuarded bắt các lỗi đó
  // để log không hiện "Unhandled Exception". App vẫn tự kết nối lại nhờ autoReconnect.
  // Lỗi khác vẫn in đầy đủ (kèm vị trí lỗi) để không che mất lỗi thật.
  runZonedGuarded(() {
    WidgetsFlutterBinding.ensureInitialized();
    runApp(const MaterialApp(home: HomePage()));
  }, (error, stack) {
    if (error is SocketException || error is ConnectionException) {
      debugPrint('Mất kết nối Broker, đang thử lại...');
    } else {
      debugPrint('Lỗi chưa xử lý: $error\n$stack');
    }
  });
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  // Ô nhập thông tin Broker
  final hostController = TextEditingController(text: '127.0.0.1');
  final userController = TextEditingController(text: 'drone');
  final passController = TextEditingController(text: 'drone123');

  MqttServerClient? client;
  bool connected = false; // đang kết nối được với Broker hay không
  String error = '';

  // Trạng thái Gateway (topic drone/001/status)
  String gateway = 'chưa rõ';
  String gatewayTime = '';

  // 4 topic số liệu: drone/001/position, drone/001/altitude, ...
  final labels = {
    'position': 'Vị trí',
    'altitude': 'Độ cao',
    'velocity': 'Tốc độ',
    'battery': 'Pin',
  };

  // Giá trị đang hiển thị của từng topic
  final values = {
    'position': '-',
    'altitude': '-',
    'velocity': '-',
    'battery': '-',
  };

  // Số tin đã nhận của từng topic (thí nghiệm B)
  final counts = {
    'position': 0,
    'altitude': 0,
    'velocity': 0,
    'battery': 0,
  };

  // Topic nào đang được chọn nhận (thí nghiệm B: chỉ tích Pin)
  final selected = {
    'position': true,
    'altitude': true,
    'velocity': true,
    'battery': true,
  };

  String dataTime = '';

  // ---------------- Kênh lệnh (docs/command_channel.md) ----------------
  static const cmdTopic = 'drone/001/cmd';
  static const ackTopic = 'drone/001/cmd/ack';
  static const ackTimeoutMs = 3000; // 3 giây không có ack => "Không có phản hồi"

  // cmd_id tăng dần, bắt đầu từ giờ hiện tại để không trùng giữa các lần mở app
  int _cmdId = DateTime.now().millisecondsSinceEpoch;
  final String operatorName = 'app-tien'; // trường "from"

  final altController = TextEditingController(text: '10');
  final latController = TextEditingController(text: '47.3980');
  final lonController = TextEditingController(text: '8.5460');

  // Lệnh đã gửi mà chưa có ack: cmd_id -> lệnh (để tính khứ hồi khi ack về)
  final Map<int, SentCommand> pending = {};
  SentCommand? lastCmd; // lệnh gần nhất, hiện trên màn hình
  final List<SentCommand> history = []; // vài lệnh gần đây (mới nhất ở đầu)
  String owner = ''; // người đang giữ quyền điều khiển (trường "owner" trong ack)

  // Lấy giờ hiện tại dạng 15:04:05
  String timeNow() {
    final t = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  Future<void> connect() async {
    final c = MqttServerClient(
        hostController.text, 'app-${DateTime.now().millisecondsSinceEpoch}');
    c.port = 1883;
    c.keepAlivePeriod = 20;
    c.setProtocolV311();
    c.autoReconnect = true; // mất mạng thì tự kết nối lại

    // Khi mất / có lại kết nối thì vẽ lại màn hình
    c.onAutoReconnect = () => setState(() => connected = false);
    c.onAutoReconnected = () => setState(() => connected = true);
    c.onDisconnected = () => setState(() => connected = false);

    try {
      await c.connect(userController.text, passController.text);
    } catch (e) {
      c.disconnect();
      setState(() => error = 'Không kết nối được: $e');
      return;
    }

    client = c;
    c.updates!.listen(onMessage);

    // status luôn nhận, còn 4 topic số liệu thì chỉ nhận topic đang được tích
    c.subscribe('drone/001/status', MqttQos.atLeastOnce);
    c.subscribe(ackTopic, MqttQos.atLeastOnce); // kết quả lệnh điều khiển
    for (final name in labels.keys) {
      if (selected[name] == true) {
        c.subscribe('drone/001/$name', MqttQos.atLeastOnce);
      }
    }

    setState(() {
      connected = true;
      error = '';
    });
  }

  void disconnect() {
    client?.autoReconnect = false;
    client?.disconnect();
    for (final c in pending.values) {
      c.timer?.cancel();
    }
    setState(() {
      client = null;
      connected = false;
      gateway = 'chưa rõ';
      pending.clear();
      owner = '';
    });
  }

  @override
  void dispose() {
    for (final c in pending.values) {
      c.timer?.cancel();
    }
    client?.autoReconnect = false;
    client?.disconnect();
    super.dispose();
  }

  // Gửi một lệnh lên drone/001/cmd: QoS 1, KHÔNG retained.
  // Mỗi lần bấm là một lệnh mới (cmd_id mới); không tự gửi lại khi chưa có ack.
  void sendCommand(String action, {double? alt, double? lat, double? lon}) {
    if (client == null || !connected) return;
    final sentMs = DateTime.now().millisecondsSinceEpoch;
    final id = ++_cmdId;
    final cmd = {
      'cmd_id': id,
      'from': operatorName,
      'action': action,
      'sent_ms': sentMs,
      'ttl_ms': 3000,
      'alt': ?alt,
      'lat': ?lat,
      'lon': ?lon,
    };
    final b = MqttClientPayloadBuilder()..addString(jsonEncode(cmd));
    client!.publishMessage(cmdTopic, MqttQos.atLeastOnce, b.payload!,
        retain: false);

    final sc = SentCommand(id, action, sentMs, describe(action, alt, lat, lon));
    // Hết 3 giây mà chưa có ack thì báo "Không có phản hồi" (không gửi lại)
    sc.timer = Timer(const Duration(milliseconds: ackTimeoutMs), () {
      if (!mounted || sc.result != 'pending') return;
      setState(() => sc.result = 'timeout');
    });
    setState(() {
      pending[id] = sc;
      lastCmd = sc;
      history.insert(0, sc);
      if (history.length > 6) history.removeLast();
    });
  }

  String describe(String action, double? alt, double? lat, double? lon) {
    final parts = [actionNames[action] ?? action];
    if (alt != null) parts.add('${alt.toStringAsFixed(1)} m');
    if (lat != null && lon != null) parts.add('$lat, $lon');
    return parts.join(' ');
  }

  static const actionNames = {
    'takeoff': 'Cất cánh',
    'land': 'Hạ cánh',
    'rtl': 'Quay về',
    'hold': 'Đứng yên',
    'goto': 'Bay tới',
    'release': 'Nhả quyền',
  };

  // Đọc số từ ô nhập, chấp nhận cả dấu phẩy (10,5)
  double? readNumber(TextEditingController c) =>
      double.tryParse(c.text.trim().replaceAll(',', '.'));

  void takeoff() {
    final alt = readNumber(altController);
    if (alt == null) return showInputError('Độ cao không hợp lệ');
    sendCommand('takeoff', alt: alt);
  }

  void gotoPoint() {
    final lat = readNumber(latController);
    final lon = readNumber(lonController);
    if (lat == null || lon == null) return showInputError('Lat/Lon không hợp lệ');
    sendCommand('goto', lat: lat, lon: lon);
  }

  void showInputError(String text) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(text)));
  }

  // Tin trên drone/001/cmd/ack
  void onAck(Map<String, dynamic> data) {
    final recvMs = DateTime.now().millisecondsSinceEpoch;
    setState(() {
      // Mọi ack (kể cả của người khác) đều cho biết ai đang giữ quyền
      owner = (data['owner'] ?? '').toString();
      if (data['from'] != operatorName) return; // ack của người điều khiển khác
      final id = data['cmd_id'];
      final sc = id is int ? pending.remove(id) : null;
      if (sc == null) return; // ack trùng hoặc của lần mở app trước
      sc.timer?.cancel();
      sc.lateAck = sc.result == 'timeout'; // ack về sau khi đã báo hết giờ
      sc.result = (data['result'] ?? '').toString();
      sc.reason = (data['reason'] ?? '').toString();
      sc.rttMs = recvMs - sc.sentMs;
      final gwRecv = data['gw_recv_ms'];
      final gwAck = data['ack_ms'];
      if (gwRecv is int) sc.downMs = gwRecv - sc.sentMs;
      if (gwAck is int) sc.upMs = recvMs - gwAck;
    });
  }

  // Tích / bỏ tích một topic
  void selectTopic(String name, bool value) {
    setState(() {
      selected[name] = value;
      if (value) {
        client!.subscribe('drone/001/$name', MqttQos.atLeastOnce);
      } else {
        client!.unsubscribe('drone/001/$name');
        values[name] = '-';
      }
    });
  }

  // Đổi phần "value" trong JSON thành chữ để hiển thị
  String formatValue(String name, Map v) {
    if (name == 'position') {
      return '${v['lat'].toStringAsFixed(6)}, ${v['lon'].toStringAsFixed(6)}';
    }
    if (name == 'altitude') {
      return '${v['rel_m'].toStringAsFixed(1)} m';
    }
    if (name == 'velocity') {
      return '${v['ground_mps'].toStringAsFixed(1)} m/s';
    }
    if (name == 'battery') {
      return '${v['percent'].toStringAsFixed(1)} %   '
          '${v['voltage'].toStringAsFixed(2)} V';
    }
    return '$v';
  }

  // Nhận bản tin từ Broker
  void onMessage(List<MqttReceivedMessage<MqttMessage>> messages) {
    for (final m in messages) {
      final publish = m.payload as MqttPublishMessage;
      final text =
          MqttPublishPayload.bytesToStringAsString(publish.payload.message);

      Map<String, dynamic> data;
      try {
        data = jsonDecode(text);
      } catch (e) {
        continue; // bỏ qua bản tin không phải JSON
      }

      // Ack của lệnh: drone/001/cmd/ack -> phần cuối là "ack", phải tách riêng
      // trước khi xét status và 4 topic số liệu.
      if (m.topic == ackTopic) {
        onAck(data);
        continue;
      }

      // Tên topic cuối cùng: drone/001/battery -> battery
      final name = m.topic.split('/').last;

      setState(() {
        if (name == 'status') {
          gateway = data['state'];
          gatewayTime = timeNow();
        } else if (counts.containsKey(name)) {
          // Không lọc theo ô tích: Broker gửi tin nào tới thì đếm tin đó.
          // Bỏ tích mà số đếm đứng yên => Broker đã thật sự ngừng gửi.
          counts[name] = counts[name]! + 1;
          values[name] = formatValue(name, data['value']);
          dataTime = timeNow();
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Drone Monitor')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: client == null ? loginView() : dataView(),
      ),
    );
  }

  // Màn hình nhập IP, user, mật khẩu
  Widget loginView() {
    return ListView(
      children: [
        TextField(
          controller: hostController,
          decoration: const InputDecoration(labelText: 'IP Broker'),
        ),
        TextField(
          controller: userController,
          decoration: const InputDecoration(labelText: 'User'),
        ),
        TextField(
          controller: passController,
          obscureText: true,
          decoration: const InputDecoration(labelText: 'Mật khẩu'),
        ),
        const SizedBox(height: 16),
        ElevatedButton(onPressed: connect, child: const Text('Kết nối')),
        const SizedBox(height: 8),
        Text(error, style: const TextStyle(color: Colors.red)),
      ],
    );
  }

  // Màn hình số liệu
  Widget dataView() {
    Color color = Colors.grey;
    if (gateway == 'online') color = Colors.green;
    if (gateway == 'offline') color = Colors.red;

    return ListView(
      children: [
        if (!connected)
          const Text('Mất kết nối Broker, đang thử lại...',
              style: TextStyle(color: Colors.orange)),
        Row(
          children: [
            Icon(Icons.circle, color: color),
            const SizedBox(width: 8),
            Text('Gateway: $gateway',
                style: TextStyle(fontSize: 20, color: color)),
          ],
        ),
        Text('Đổi trạng thái lúc: $gatewayTime'),
        const Divider(),
        const Text('Tích vào topic muốn nhận:'),
        for (final name in labels.keys)
          CheckboxListTile(
            title: Text('${labels[name]}: ${values[name]}',
                style: const TextStyle(fontSize: 18)),
            subtitle: Text('Đã nhận: ${counts[name]} tin'),
            value: selected[name],
            // Đang mất kết nối thì khoá ô tích (không subscribe được)
            onChanged: connected ? (value) => selectTopic(name, value!) : null,
          ),
        Text('Cập nhật lúc: $dataTime'),
        TextButton(
          onPressed: () => setState(() {
            for (final name in counts.keys) {
              counts[name] = 0;
            }
          }),
          child: const Text('Đặt lại bộ đếm'),
        ),
        const Divider(),
        controlView(),
        const Divider(),
        ElevatedButton(onPressed: disconnect, child: const Text('Ngắt kết nối')),
      ],
    );
  }

  // Khối nút điều khiển drone
  Widget controlView() {
    // Mất kết nối thì khoá các nút, giống cách khoá ô tích topic
    final enabled = connected;
    Widget btn(String label, IconData icon, VoidCallback onPressed) {
      return ElevatedButton.icon(
        onPressed: enabled ? onPressed : null,
        icon: Icon(icon),
        label: Text(label),
      );
    }

    final ownerText = owner.isEmpty
        ? 'chưa ai'
        : (owner == operatorName ? '$owner (mình)' : owner);
    final ownerColor = owner.isEmpty
        ? Colors.grey
        : (owner == operatorName ? Colors.green : Colors.orange);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Điều khiển drone',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        Text('Người gửi: $operatorName'),
        Row(
          children: [
            const Text('Đang giữ quyền: '),
            Text(ownerText,
                style: TextStyle(color: ownerColor, fontWeight: FontWeight.bold)),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            SizedBox(
              width: 110,
              child: TextField(
                controller: altController,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Độ cao (m)'),
              ),
            ),
            const SizedBox(width: 12),
            btn('Cất cánh', Icons.flight_takeoff, takeoff),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            btn('Hạ cánh', Icons.flight_land, () => sendCommand('land')),
            btn('Quay về', Icons.home, () => sendCommand('rtl')),
            btn('Đứng yên', Icons.pause, () => sendCommand('hold')),
            btn('Nhả quyền', Icons.lock_open, () => sendCommand('release')),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: latController,
                keyboardType: const TextInputType.numberWithOptions(
                    decimal: true, signed: true),
                decoration: const InputDecoration(labelText: 'Lat'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: lonController,
                keyboardType: const TextInputType.numberWithOptions(
                    decimal: true, signed: true),
                decoration: const InputDecoration(labelText: 'Lon'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            btn('Bay tới', Icons.place, gotoPoint),
            TextButton(
              onPressed: () => setState(() {
                latController.text = '47.3980';
                lonController.text = '8.5460';
              }),
              child: const Text('Điểm demo 47.3980, 8.5460'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (lastCmd != null) resultView(lastCmd!),
        if (history.length > 1) ...[
          const SizedBox(height: 8),
          const Text('Lệnh gần đây:'),
          for (final c in history.skip(1))
            Text(c.summary(), style: TextStyle(color: c.color(), fontSize: 13)),
        ],
        const SizedBox(height: 4),
        const Text(
          'Lưu ý: đồng hồ máy phải để tự động đồng bộ, nếu lệch quá 3 giây '
          'Gateway sẽ từ chối "expired".',
          style: TextStyle(fontSize: 12, color: Colors.grey),
        ),
      ],
    );
  }

  // Kết quả lệnh gần nhất: xanh = accepted, đỏ = rejected / không phản hồi
  Widget resultView(SentCommand c) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: c.color().withValues(alpha: 0.12),
        border: Border.all(color: c.color()),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Lệnh gần nhất: ${c.label}  (cmd_id ${c.id})'),
          Text(c.statusText(),
              style: TextStyle(
                  fontSize: 18, fontWeight: FontWeight.bold, color: c.color())),
          if (c.rttMs != null)
            Text('Khứ hồi: ${c.rttMs} ms'
                '${c.downMs != null ? '  (đi ${c.downMs} ms, về ${c.upMs} ms)' : ''}'),
        ],
      ),
    );
  }
}

// Một lệnh đã gửi và kết quả của nó
class SentCommand {
  SentCommand(this.id, this.action, this.sentMs, this.label);

  final int id;
  final String action;
  final int sentMs;
  final String label;
  Timer? timer;

  String result = 'pending'; // pending | accepted | rejected | timeout
  String reason = '';
  int? rttMs, downMs, upMs;
  bool lateAck = false;

  String statusText() {
    switch (result) {
      case 'pending':
        return 'Đang chờ phản hồi...';
      case 'timeout':
        return 'Không có phản hồi (quá 3 giây)';
      case 'accepted':
        return 'accepted${lateAck ? ' (ack về muộn)' : ''}';
      default:
        return '$result: $reason${lateAck ? ' (ack về muộn)' : ''}';
    }
  }

  Color color() {
    switch (result) {
      case 'accepted':
        return Colors.green;
      case 'pending':
        return Colors.grey;
      default:
        return Colors.red;
    }
  }

  String summary() =>
      '$label → ${statusText()}${rttMs != null ? ', $rttMs ms' : ''}';
}
