#!/usr/bin/env bash
# Chạy thí nghiệm H (kênh lệnh) theo docs/tasks/tien_kenh_lenh.md.
# Broker, Gateway và commander chạy CÙNG MỘT MÁY (chung đồng hồ, kiểm tra 2 mới đúng).
#
#   ./scripts/run_H.sh h1 N0 N1 N2 N3   # H1: khứ hồi lệnh, mỗi điều kiện × QoS 0/1 × 3 lần
#   ./scripts/run_H.sh h2               # H2: lệnh tới muộn, kiểm tra bật/tắt × 3 lần
#   ./scripts/run_H.sh h3               # H3: Broker khởi động lại giữa chuỗi lệnh QoS 1 × 3 lần
#   ./scripts/run_H.sh all              # cả ba (H1 với N0..N3)
#
# N1–N3 cần sudo (scripts/netem.sh dùng nsenter). N0 không đặt netem nên không cần sudo.
# Biến môi trường: RUNS=3 (số lần), FORCE=1 (chạy lại thư mục đã có dữ liệu).
# Kết quả: data/H/<tên>/; tổng hợp bằng ./scripts/summarize_H.sh
set -euo pipefail
cd "$(dirname "$0")/.."

GW=./build/gateway/gateway
CMD=./build/commander/commander
RUNS="${RUNS:-3}"
BROKER_IP=172.28.0.10
MQTT=(-h "$BROKER_IP" -u drone -P drone123)

[[ -x $GW && -x $CMD ]] || { echo "Build trước: cmake -B build && cmake --build build -j" >&2; exit 1; }

GW_PID=""
start_gw() {  # start_gw <thư mục> [tham số thêm...]
  local d="$1"; shift
  "$GW" --source fake --out "$d" "$@" >>"$d/gateway.log" 2>&1 &
  GW_PID=$!
  sleep 1.5  # chờ Gateway kết nối và subscribe drone/001/cmd
}
stop_gw() {
  [[ -n $GW_PID ]] || return 0
  kill -INT "$GW_PID" 2>/dev/null || true
  wait "$GW_PID" 2>/dev/null || true
  GW_PID=""
}
cleanup() {
  stop_gw
  [[ ${NETEM_SET:-0} == 1 ]] && ./scripts/netem.sh N0 >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

# Bỏ qua lượt đã có dữ liệu (chạy tiếp được sau khi bị ngắt giữa chừng)
skip_if_done() {
  local d="$1" f="$2"
  if [[ -s $d/$f && ${FORCE:-0} != 1 ]]; then
    echo "  bỏ qua $d (đã có $f, đặt FORCE=1 để chạy lại)"
    return 0
  fi
  rm -rf "$d"; mkdir -p "$d"
  return 1
}

# Chờ Broker nhận kết nối trở lại (sau docker start)
wait_broker() {
  for _ in $(seq 1 50); do
    mosquitto_pub "${MQTT[@]}" -t drone/001/probe -n -q 0 2>/dev/null && return 0
    sleep 0.2
  done
  echo "Broker không lên lại" >&2; return 1
}

# ---------------- H1: khứ hồi lệnh theo điều kiện mạng ----------------
h1() {
  local conds=("$@")
  [[ ${#conds[@]} -gt 0 ]] || conds=(N0 N1 N2 N3)
  for cond in "${conds[@]}"; do
    if [[ $cond != N0 ]]; then
      sudo -v  # hỏi mật khẩu một lần trước khi đo
      ./scripts/netem.sh "$cond" >/dev/null
      NETEM_SET=1
    fi
    for qos in 0 1; do
      for run in $(seq 1 "$RUNS"); do
        local d="data/H/${cond}_qos${qos}_run${run}"
        echo "== H1 $d"
        skip_if_done "$d" cmd_rtt.csv && continue
        ping -c 10 -i 0.2 "$BROKER_IP" >"$d/ping.txt" 2>&1 || true
        start_gw "$d" --scenario "$cond" --run "$run"
        "$CMD" --action hold --count 300 --interval-ms 200 --qos "$qos" \
          --scenario "$cond" --run "$run" --out "$d" | tail -1 | tee "$d/commander.txt"
        stop_gw
      done
    done
    if [[ $cond != N0 ]]; then
      ./scripts/netem.sh N0 >/dev/null
      NETEM_SET=0
    fi
  done
}

# ---------------- H2: lệnh tới muộn ----------------
h2() {
  for mode in on off; do
    for run in $(seq 1 "$RUNS"); do
      local d="data/H/h2_${mode}_run${run}"
      echo "== H2 $d"
      skip_if_done "$d" telemetry_after.txt && continue
      # 1. Gateway chạy 3 s để Broker có phiên bền (clean_session=false) rồi tắt
      start_gw "$d" --cmd-safety "$mode"
      sleep 1.5
      stop_gw
      # 2. Gửi goto lúc Gateway vắng mặt: commander báo timeout, Broker giữ lệnh QoS 1
      "$CMD" --action goto --lat 47.3980 --lon 8.5460 --wait-ms 1000 --out "$d" \
        | tee "$d/commander.txt"
      # 3. Đợi 10 s rồi bật lại Gateway, ghi telemetry 8 s để xem drone có bay không
      sleep 10
      mosquitto_sub "${MQTT[@]}" -v -F '%U %t %p' -t drone/001/velocity -t drone/001/position \
        >"$d/telemetry_after.txt" 2>/dev/null &
      local sub=$!
      start_gw "$d" --cmd-safety "$mode"
      sleep 8
      stop_gw
      kill "$sub" 2>/dev/null || true; wait "$sub" 2>/dev/null || true
      grep goto "$d/cmd_log.csv" | tail -1
    done
  done
}

# ---------------- H3: lệnh trùng khi Broker khởi động lại ----------------
h3() {
  for run in $(seq 1 "$RUNS"); do
    local d="data/H/h3_run${run}"
    echo "== H3 $d"
    skip_if_done "$d" cmd_log.csv && continue
    start_gw "$d" --scenario h3 --run "$run"
    "$CMD" --action hold --count 100 --interval-ms 200 --qos 1 --wait-ms 8000 \
      --scenario h3 --run "$run" --out "$d" >"$d/commander.txt" 2>&1 &
    local cmdpid=$!
    sleep 5
    date +%s%3N >"$d/broker_stop_ms.txt"
    docker stop broker >/dev/null
    sleep 5
    docker start broker >/dev/null
    date +%s%3N >"$d/broker_start_ms.txt"
    wait_broker
    wait "$cmdpid" || true
    sleep 2
    stop_gw
    tail -1 "$d/commander.txt"
  done
}

case "${1:-}" in
  h1) shift; h1 "$@" ;;
  h2) h2 ;;
  h3) h3 ;;
  all) h1 N0 N1 N2 N3; h2; h3 ;;
  *) sed -n 2,13p "$0"; exit 2 ;;
esac
