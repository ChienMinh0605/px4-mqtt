#!/usr/bin/env bash
# Tổng hợp kết quả thí nghiệm H thành bảng Markdown (in ra màn hình).
#   ./scripts/summarize_H.sh [data/H] > data/H/summary.md
set -euo pipefail
export LC_ALL=C  # dấu chấm thập phân cho printf/sort, kể cả máy để locale tiếng Việt
cd "$(dirname "$0")/.."
ROOT="${1:-data/H}"

# Trung vị và p95 theo cách của commander: phần tử thứ n/2 và n*95/100 (đã sắp xếp)
stats() {  # đọc các số (mỗi dòng một số), in "n trung_vị p95 lớn_nhất"
  sort -n | awk '{a[NR-1]=$1} END {
    if (NR == 0) { print "0 - - -"; exit }
    p = int(NR * 95 / 100); if (p > NR - 1) p = NR - 1
    print NR, a[int(NR / 2)], a[p], a[NR - 1] }'
}

# ---------- H1 ----------
echo "## H1 – Thời gian khứ hồi lệnh (gộp 3 lần chạy)"
echo
echo "| Điều kiện | QoS | Số lệnh | accepted | timeout | Khứ hồi trung vị (ms) | p95 (ms) | Lớn nhất (ms) | Đi trung vị (ms) | Về trung vị (ms) | Lệnh nhận >1 ack |"
echo "|---|---|---|---|---|---|---|---|---|---|---|"
for cond in N0 N1 N2 N3; do
  for qos in 0 1; do
    files=( "$ROOT/${cond}_qos${qos}"_run*/cmd_rtt.csv )
    [[ -e ${files[0]} ]] || continue
    # cột: cmd_id,action,qos,sent_ms,ack_recv_ms,rtt_ms,down_ms,up_ms,result,reason,acks,scenario,run
    all=$(tail -q -n +2 "${files[@]}")
    total=$(wc -l <<<"$all")
    acc=$(awk -F, '$9=="accepted"' <<<"$all" | wc -l)
    tmo=$(awk -F, '$9=="timeout"' <<<"$all" | wc -l)
    multi=$(awk -F, '$11>1' <<<"$all" | wc -l)
    read -r _ med p95 max < <(awk -F, '$6>=0 {print $6}' <<<"$all" | stats)
    read -r _ dmed _ _ < <(awk -F, '$7>=0 {print $7}' <<<"$all" | stats)
    read -r _ umed _ _ < <(awk -F, '$8>=0 {print $8}' <<<"$all" | stats)
    echo "| $cond | $qos | $total | $acc | $tmo | $med | $p95 | $max | $dmed | $umed | $multi |"
  done
done
echo
echo "Từng lần chạy:"
echo
echo "| Thư mục | Số lệnh | timeout | Trung vị (ms) | p95 (ms) |"
echo "|---|---|---|---|---|"
for f in "$ROOT"/N?_qos?_run*/cmd_rtt.csv; do
  [[ -e $f ]] || continue
  d=$(basename "$(dirname "$f")")
  total=$(($(wc -l <"$f") - 1))
  tmo=$(awk -F, 'NR>1 && $9=="timeout"' "$f" | wc -l)
  read -r _ med p95 _ < <(awk -F, 'NR>1 && $6>=0 {print $6}' "$f" | stats)
  echo "| $d | $total | $tmo | $med | $p95 |"
done

# ---------- H2 ----------
echo
echo "## H2 – Lệnh goto tới Gateway muộn"
echo
echo "| Thư mục | Kiểm tra | Lệnh bị giữ (ms) | Kết quả | Lý do | Tốc độ lớn nhất sau khi bật lại (m/s) | Drone bay? |"
echo "|---|---|---|---|---|---|---|"
for d in "$ROOT"/h2_*_run*; do
  [[ -d $d ]] || continue
  name=$(basename "$d")
  mode=$(cut -d_ -f2 <<<"$name")
  # cmd_log: gw_recv_ms,from,cmd_id,action,sent_ms,age_ms,retained,dup_flag,result,reason
  line=$(awk -F, '$4=="goto"' "$d/cmd_log.csv" 2>/dev/null | tail -1)
  age=$(cut -d, -f6 <<<"$line"); res=$(cut -d, -f9 <<<"$line"); why=$(cut -d, -f10 <<<"$line")
  vmax=$(grep -o '"ground_mps":[0-9.eE+-]*' "$d/telemetry_after.txt" 2>/dev/null \
    | cut -d: -f2 | sort -g | tail -1)
  vmax=${vmax:-0}
  flew=$(awk -v v="$vmax" 'BEGIN { print (v > 1 ? "có" : "không") }')
  printf '| %s | %s | %s | %s | %s | %.1f | %s |\n' "$name" "$mode" "${age:--}" "${res:--}" \
    "${why:--}" "$vmax" "$flew"
done

# ---------- H3 ----------
echo
echo "## H3 – Broker khởi động lại giữa chuỗi 100 lệnh QoS 1"
echo
echo "| Thư mục | Lệnh tới Gateway | dup_flag = 1 | duplicate | expired | accepted | Kết quả phía commander |"
echo "|---|---|---|---|---|---|---|"
for d in "$ROOT"/h3_run*; do
  [[ -f $d/cmd_log.csv ]] || continue
  f="$d/cmd_log.csv"
  n=$(($(wc -l <"$f") - 1))
  dup=$(awk -F, 'NR>1 && $8=="1"' "$f" | wc -l)
  dupl=$(awk -F, 'NR>1 && $10=="duplicate"' "$f" | wc -l)
  exp=$(awk -F, 'NR>1 && $10=="expired"' "$f" | wc -l)
  acc=$(awk -F, 'NR>1 && $9=="accepted"' "$f" | wc -l)
  cmdres=$(grep -o 'Tong:.*' "$d/commander.txt" 2>/dev/null | sed 's/|/\//g' || true)
  echo "| $(basename "$d") | $n | $dup | $dupl | $exp | $acc | ${cmdres:--} |"
done
