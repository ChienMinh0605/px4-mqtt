## H1 – Thời gian khứ hồi lệnh (gộp 3 lần chạy)

| Điều kiện | QoS | Số lệnh | accepted | timeout | Khứ hồi trung vị (ms) | p95 (ms) | Lớn nhất (ms) | Đi trung vị (ms) | Về trung vị (ms) | Lệnh nhận >1 ack |
|---|---|---|---|---|---|---|---|---|---|---|
| N0 | 0 | 900 | 900 | 0 | 2 | 41 | 43 | 1 | 1 | 0 |
| N0 | 1 | 900 | 900 | 0 | 42 | 43 | 44 | 1 | 41 | 0 |
| N1 | 0 | 900 | 900 | 0 | 346 | 395 | 499 | 242 | 101 | 0 |
| N1 | 1 | 900 | 900 | 0 | 449 | 498 | 503 | 225 | 201 | 0 |
| N2 | 0 | 900 | 900 | 0 | 2 | 235 | 656 | 1 | 1 | 0 |
| N2 | 1 | 900 | 900 | 0 | 80 | 330 | 834 | 18 | 41 | 0 |
| N3 | 0 | 900 | 900 | 0 | 415 | 843 | 1510 | 209 | 200 | 0 |
| N3 | 1 | 900 | 900 | 0 | 481 | 915 | 1852 | 200 | 254 | 0 |

Từng lần chạy:

| Thư mục | Số lệnh | timeout | Trung vị (ms) | p95 (ms) |
|---|---|---|---|---|
| N0_qos0_run1 | 300 | 0 | 40 | 41 |
| N0_qos0_run2 | 300 | 0 | 2 | 2 |
| N0_qos0_run3 | 300 | 0 | 2 | 2 |
| N0_qos1_run1 | 300 | 0 | 43 | 43 |
| N0_qos1_run2 | 300 | 0 | 42 | 43 |
| N0_qos1_run3 | 300 | 0 | 42 | 43 |
| N1_qos0_run1 | 300 | 0 | 336 | 385 |
| N1_qos0_run2 | 300 | 0 | 348 | 396 |
| N1_qos0_run3 | 300 | 0 | 355 | 396 |
| N1_qos1_run1 | 300 | 0 | 449 | 498 |
| N1_qos1_run2 | 300 | 0 | 452 | 498 |
| N1_qos1_run3 | 300 | 0 | 447 | 499 |
| N2_qos0_run1 | 300 | 0 | 2 | 249 |
| N2_qos0_run2 | 300 | 0 | 2 | 313 |
| N2_qos0_run3 | 300 | 0 | 2 | 235 |
| N2_qos1_run1 | 300 | 0 | 43 | 387 |
| N2_qos1_run2 | 300 | 0 | 43 | 282 |
| N2_qos1_run3 | 300 | 0 | 81 | 325 |
| N3_qos0_run1 | 300 | 0 | 416 | 815 |
| N3_qos0_run2 | 300 | 0 | 450 | 929 |
| N3_qos0_run3 | 300 | 0 | 401 | 802 |
| N3_qos1_run1 | 300 | 0 | 456 | 841 |
| N3_qos1_run2 | 300 | 0 | 462 | 899 |
| N3_qos1_run3 | 300 | 0 | 498 | 1092 |

## H2 – Lệnh goto tới Gateway muộn

| Thư mục | Kiểm tra | Lệnh bị giữ (ms) | Kết quả | Lý do | Tốc độ lớn nhất sau khi bật lại (m/s) | Drone bay? |
|---|---|---|---|---|---|---|
| h2_off_run1 | off | 11124 | accepted | - | 5.0 | có |
| h2_off_run2 | off | 11238 | accepted | - | 5.0 | có |
| h2_off_run3 | off | 11129 | accepted | - | 5.0 | có |
| h2_on_run1 | on | 11232 | rejected | expired | 0.1 | không |
| h2_on_run2 | on | 11236 | rejected | expired | 0.1 | không |
| h2_on_run3 | on | 11130 | rejected | expired | 0.1 | không |

## H3 – Broker khởi động lại giữa chuỗi 100 lệnh QoS 1

| Thư mục | Lệnh tới Gateway | dup_flag = 1 | duplicate | expired | accepted | Kết quả phía commander |
|---|---|---|---|---|---|---|
| h3_run1 | 100 | 0 | 0 | 27 | 73 | Tong: gui 100 lenh / accepted=72 rejected:expired=27 timeout=1 / khu hoi trung vi 42 ms, p95 7420 ms |
| h3_run2 | 100 | 0 | 0 | 27 | 73 | Tong: gui 100 lenh / accepted=73 rejected:expired=27 / khu hoi trung vi 42 ms, p95 7491 ms |
| h3_run3 | 100 | 0 | 0 | 27 | 73 | Tong: gui 100 lenh / accepted=73 rejected:expired=27 / khu hoi trung vi 42 ms, p95 7412 ms |
