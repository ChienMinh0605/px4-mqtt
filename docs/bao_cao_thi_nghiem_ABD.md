# Thí nghiệm A, B, D (phần của Tiên)

Chạy trên một máy Linux: Broker Mosquitto (Docker, 172.28.0.10), Gateway `--source fake` (4 topic × 5 tin/s
= 20 tin/s), App Flutter (Linux desktop) và Logger C++. Ảnh chụp trong `data/A`, `data/B`, `data/D`.

## A – Tắt một client, client còn lại vẫn nhận

| Lượt | Thao tác | Kết quả |
|---|---|---|
| A1 | Ctrl+C Logger (đã nhận 6150 tin) | App vẫn cập nhật: "Cập nhật lúc 20:30:36" đúng giờ hệ thống, cả 4 topic vẫn tăng |
| A2 | App bấm "Ngắt kết nối" | Logger vẫn nhận đều `+20/s` (5100 → 5400 tin) |

![A1](../data/A/tat_logger_app_van_nhan.png)
![A2](../data/A/tat_app_logger_van_nhan.png)

**Nhận xét:** Broker giữ một phiên riêng cho mỗi client và gửi bản sao tin cho từng client đã subscribe.
Một client rời đi không ảnh hưởng client khác, và Gateway (publisher) không cần biết có bao nhiêu client.
Đây là ưu điểm của mô hình publish/subscribe so với kết nối trực tiếp một-một.

## B – Chỉ subscribe topic pin

| Thời điểm | Vị trí | Độ cao | Tốc độ | Pin |
|---|---|---|---|---|
| Sau khi đặt lại bộ đếm và bỏ tích 3 topic (20:38:43) | 5 | 7 | 11 | 62 |
| Sau khoảng 55 s, vừa tích lại cả 4 (20:39:38) | 29 | 34 | 43 | 339 |

![B1](../data/B/chi_nhan_pin.png)
![B2](../data/B/tich_lai.png)

**Nhận xét:**
- Trong khoảng 55 giây chỉ tích Pin, số tin Pin tăng thêm khoảng 277 (≈ 5 tin/s), còn ba topic kia đứng yên.
  Ba topic này chỉ tăng trở lại (khoảng 24–32 tin trong vài giây) sau khi được tích lại.
- App đếm mọi tin Broker gửi tới, không tự lọc. Vì vậy số đếm đứng yên nghĩa là **chính Broker đã ngừng
  gửi** sau gói UNSUBSCRIBE. Việc lọc nằm ở Broker, nên client không tốn băng thông cho dữ liệu không cần.
- Mức pin 0.0 % ở ảnh B là pin giả lập đã cạn do Gateway chạy lâu, không phải lỗi. Sau khi Gateway chạy lại,
  pin về 94.9 % (ảnh D2).

## D – Tắt Gateway: Ctrl+C và kill -9

| Lượt | Cách tắt | Giờ tắt | App hiện "offline" lúc | Thời gian |
|---|---|---|---|---|
| D1 | Ctrl+C | 20:42:48 (tin cuối cùng) | 20:42:48 | dưới 1 s |
| D2 | `kill -9` | 20:45:59 (lệnh `date`) | 20:45:59 | dưới 1 s |

![D1](../data/D/tat_gateway_bang_ctrlC.png)
![D2](../data/D/kill_9.png)

**Nhận xét:** cả hai cách đều làm App hiện offline gần như ngay lập tức, nhưng theo hai cơ chế khác nhau.

- **Ctrl+C:** Gateway bắt tín hiệu, tự publish `{"state":"offline"}` (retained) rồi gửi DISCONNECT.
  Khi ngắt đúng cách, Broker **không** phát Last Will, nên Gateway phải tự báo offline.
- **kill -9:** tiến trình bị huỷ ngay, không kịp gửi gì. Nhưng hệ điều hành vẫn đóng socket TCP, nên Broker
  thấy kết nối đứt mà chưa có DISCONNECT. Khi đó Broker phát **Last Will** `{"state":"offline"}` mà Gateway đã
  đăng ký lúc CONNECT.
- Keep-alive (10 s × 1,5 = 15 s) chỉ cần tới khi kết nối "chết lặng": mạng bị cắt nhưng không ai đóng TCP
  (máy Gateway mất điện, rút cáp). Trường hợp này là thí nghiệm G (netem mất 100 %), lúc đó App sẽ phải đợi
  khoảng 15 s mới hiện offline.
- Topic `status` là tin retained, nên client kết nối sau vẫn biết ngay trạng thái Gateway, như dòng `(retained)`
  ở đầu log Logger trong ảnh A1.
