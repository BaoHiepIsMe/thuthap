# SafeNet Collector

App Android (Flutter) ghi dữ liệu gia tốc kế để nhóm SafeNet tự thu dữ liệu điện thoại thật cho model 1D-CNN phát hiện té ngã (train trên UniMiB SHAR: gia tốc có trọng lực, m/s², 50 Hz, cửa sổ 151 mẫu).

- Đọc `accelerometerEventStream` (sensors_plus) với chu kỳ 20 ms, lấy timestamp gốc của SensorEvent (epoch µs).
- Dẫn dắt bằng giọng nói (TextToSpeech tiếng Việt) để người thu không cần chạm máy khi máy nằm trong túi.
- Foreground service + `PARTIAL_WAKE_LOCK` giữ app chạy khi tắt màn hình. Code cảm biến và ghi file nằm ở Dart main isolate.
- Mỗi buổi thu lưu 4 file: `meta.json`, `sensor.csv`, `events.csv`, `health.csv`. Có thể xuất ZIP vào `Download/SafeNetCollector/`.

## 1. Build và cài APK

Yêu cầu: Flutter SDK (Dart ≥ 3.3), Android SDK, JDK 17.

```bash
cd safenet_collector
flutter pub get
flutter build apk --release
# file: build/app/outputs/flutter-apk/app-release.apk
```

Cài lên máy:

```bash
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

Hoặc chép file APK sang điện thoại rồi mở để cài (cần cho phép "Cài ứng dụng không rõ nguồn gốc").

> APK release đang ký bằng debug key, đủ để cài nội bộ, không dùng để đưa lên Play Store.

## 2. Chuẩn bị máy (làm một lần cho mỗi điện thoại)

Trên màn hình chính, thẻ **Chuẩn bị máy**:

1. **Quyền thông báo** → bấm *Cấp quyền* (Android 13+).
2. **Tối ưu pin** → bấm *Tắt tối ưu*, chọn *Cho phép*.
3. **Mở cài đặt app** và làm thêm theo hãng:
   - **Xiaomi/Redmi/POCO**: bật *Tự khởi chạy (Autostart)*; *Tiết kiệm pin* → *Không hạn chế*; trong màn hình đa nhiệm, nhấn giữ app → biểu tượng khoá.
   - **Oppo/Realme**: *Pin* → *Cho phép hoạt động nền*, bật *Cho phép tự khởi động*.
   - **Vivo**: *Pin* → *Cho phép mức sử dụng pin cao trong nền*, bật *Tự khởi động*.
   - **Samsung**: *Pin* → *Không hạn chế*; bỏ app khỏi danh sách *Ứng dụng ngủ*.
4. Bật âm lượng **media** đủ lớn (giọng nói dùng luồng media).
5. Kiểm tra máy có giọng tiếng Việt: *Cài đặt → Hệ thống → Ngôn ngữ → Chuyển văn bản thành giọng nói*. Nếu không có tiếng Việt, app dùng ngôn ngữ mặc định.

## 3. Quy trình thu

Chung cho mọi buổi:

1. Bấm **Tạo buổi thu mới**, chọn mã người thu (A/B hoặc nhập, ví dụ `P03`), vị trí đặt máy, loại buổi, các hoạt động và số lượt.
2. Ghi vào ô *Ghi chú* các điều kiện: độ dày nệm, giày dép, quần áo, ai đỡ…
3. Bấm **Bắt đầu**, đặt máy vào đúng vị trí đã chọn rồi làm theo giọng nói.
4. Kịch bản mỗi lượt:
   - **Chuẩn bị**: "Lượt i trên n. {tên hoạt động}. Chuẩn bị." rồi đếm "Ba, Hai, Một".
   - **Thực hiện**: "Bắt đầu" → làm động tác → "Xong. Đứng dậy" (ngã) hoặc "Xong".
   - **Nghỉ**: "Nghỉ. Lượt tiếp theo: …", hết giờ thì tự sang lượt sau.
5. Nếu một lượt làm sai (vấp chân, máy văng khỏi túi, ngã không đúng kiểu…), lấy máy ra bấm **Lượt vừa rồi hỏng – làm lại** trong lúc đang thực hiện hoặc đang nghỉ. Lượt đó được đánh dấu `redo` và được chèn lại ngay sau.
6. Hết kế hoạch, app tự dừng. Muốn dừng sớm thì bấm **Dừng buổi thu** (lượt đang làm dở được ghi `aborted`).
7. Về trang chủ → **Xuất ZIP** → gửi file trong `Download/SafeNetCollector/` cho người xử lý dữ liệu.

### 3.1. Buổi "Ngã thử lên nệm" (fall)

7 kiểu ngã, mỗi kiểu mặc định 3 lượt. Mỗi lượt: chuẩn bị 6 s, thực hiện 20 s, nghỉ 20 s.

- Ngã trong khoảng 2–5 giây đầu sau "Bắt đầu", sau đó **nằm yên** đến khi nghe "Xong. Đứng dậy". Đoạn nằm yên sau ngã cũng là dữ liệu quan trọng.
- Đổi vị trí đặt máy giữa các buổi (túi quần trước, túi quần sau, túi áo khoác…). Mỗi vị trí là một buổi riêng.
- *Khuỵu từ từ*: gập gối, ngồi xuống rồi đổ nghiêng lên nệm, chậm khoảng 2–3 s.

### 3.2. Buổi "Tình huống dễ báo nhầm" (trap)

- **Ngắn** (trap_short: ngồi phịch, nằm vật, nhảy, làm rơi máy, ném máy lên giường, cúi nhặt đồ): chuẩn bị 5 s, thực hiện 10 s, nghỉ 8 s, mặc định 5 lượt. Làm rơi máy xuống thảm hoặc nệm mỏng, đừng để rơi lên nền cứng.
- **Dài** (trap_long: đi bộ, chạy, cầu thang, xe máy, trong balo): đặt số phút trên màn hình Tạo buổi thu. Bấm **Kết thúc hoạt động** để kết thúc sớm. Không có thời gian nghỉ.
- **Đi xe máy**: người thu **chỉ ngồi sau**, không cầm máy, không thao tác trên đường. Bật app trước khi lên xe.

### 3.3. Buổi "Sinh hoạt liên tục" (continuous)

- App đọc "Bắt đầu ghi sinh hoạt liên tục" và ghi cho đến khi bấm **Dừng buổi thu**. Không có lượt, không đếm ngược.
- Bỏ máy vào túi và sinh hoạt bình thường trong nhiều giờ: đi học, làm việc, ăn uống, đi xe.
- Có chuyện đặc biệt (máy rơi, chạy gấp, ngồi xe buýt…) thì mở app và bấm **Ghi chú**.
- Cắm sạc trước. Thu 4 giờ thường tốn khoảng 10–25% pin, tuỳ máy.

## 4. ⚠️ Lưu ý an toàn khi thu ngã

- **Nệm dày từ 20 cm trở lên**, đủ rộng để cả người rơi trọn trên nệm. Dọn sạch vật cứng xung quanh (cạnh bàn, ghế, tường).
- **Luôn có người đỡ/giám sát** đứng cạnh nệm. Không bao giờ thu ngã một mình.
- **Không ngã đập đầu trước**. Ngã sấp: chống hai tay và gối. Ngã ngửa: cằm gập vào ngực, tay đập xuống nệm. Đầu không được là bộ phận chạm nệm đầu tiên.
- Khởi động kỹ trước khi thu. Dừng ngay khi thấy chóng mặt, đau hoặc mệt. Nghỉ thêm nếu cần (bấm **Tạm dừng** trong lúc nghỉ).
- Không đổi máy sang túi khác giữa các lượt. Không để vật cứng (chìa khoá, sạc dự phòng) cùng túi với máy.
- Người có bệnh tim mạch, xương khớp, đang mang thai hoặc từng chấn thương đầu **không tham gia** thu ngã.
- Ngã từ ghế: dùng ghế thấp, đặt ghế ngay mép nệm và chèn chân ghế cho chắc.

## 5. Bài test độ bền (chạy nền, tắt màn hình)

Mục đích: kiểm tra từng điện thoại có giữ được 50 Hz khi tắt màn hình nhiều giờ hay không.

1. Hoàn tất mục 2 (Chuẩn bị máy).
2. Tạo buổi thu loại **Sinh hoạt liên tục**, ghi chú `test do ben`.
3. Bấm Bắt đầu, **tắt màn hình**, để máy yên trên bàn (hoặc mang trong túi) đủ thời gian cần test: 10 phút, 1 giờ, 4 giờ…
4. Mở màn hình, bấm **Dừng buổi thu**, xuất ZIP và chép về máy tính.
5. Chạy:

   ```bash
   python tools/read_sessions.py duong_dan/file.zip --no-save
   ```

6. Tiêu chí đạt:
   - `health.csv`: mọi dòng `effective_hz` > 45 và `max_gap_ms` < 5000.
   - `khoảng trống > 1 s` gần bằng 0.
   - `screen_on` = 0 trong phần lớn thời gian (chứng tỏ màn hình thật sự tắt).
   - `recv_delay_ms` p95 nhỏ (dưới vài trăm ms). Nếu lớn thì hệ điều hành đang gom mẫu (batching) khi tắt màn hình. `t_us` vẫn đúng nên dữ liệu vẫn dùng được, chỉ không còn real-time.

Nếu không đạt, kiểm tra lại autostart/tối ưu pin theo hãng (mục 2), thử khoá app trong đa nhiệm rồi test lại.

## 6. Định dạng dữ liệu

```
{getExternalFilesDir}/sessions/{yyyyMMdd_HHmmss}_{subject}_{sessionType}/
  meta.json    thông tin buổi thu, máy, cảm biến, kế hoạch, tổng số mẫu
  sensor.csv   t_us,ax,ay,az,recv_delay_ms
  events.csv   t_start_us,t_end_us,label,kind,trial_no,status,note
  health.csv   t_us,samples_last_min,effective_hz,max_gap_ms,battery_pct,screen_on,app_lifecycle
```

- `t_us`: epoch micro giây. Thời gian mẫu lấy từ timestamp gốc của SensorEvent, thời gian sự kiện lấy từ `DateTime.now()`, cùng hệ epoch µs.
- `ax, ay, az`: m/s², **đã gồm trọng lực** (giống UniMiB SHAR), 4 chữ số thập phân.
- `status`: `ok` | `redo` | `aborted`. Ghi chú là dòng có `label=note`.
- Trên máy, thư mục nằm ở `Android/data/com.safenet.safenet_collector/files/sessions/`.

## 7. Script Python `tools/read_sessions.py`

Chỉ cần `numpy` và `pandas`.

```bash
# kiểm tra toàn bộ quy trình bằng dữ liệu giả
python tools/read_sessions.py --selftest

# thống kê + cắt cửa sổ từ nhiều buổi/zip
python tools/read_sessions.py data/*.zip data/sessions --out safenet_windows.npz --peak-index 75
```

- In thống kê: tần số trung bình, phân phối khoảng cách mẫu, số khoảng trống > 1 s, phân phối `recv_delay_ms`, thống kê `health.csv`.
- Resample về đúng 50 Hz bằng `np.interp` theo `t_us`.
- Với mỗi sự kiện `fall`/`trap_short` có `status=ok`: tìm đỉnh độ lớn gia tốc trong `[t_start, t_end]` và cắt 151 mẫu sao cho đỉnh nằm ở `--peak-index` (mặc định 75; nên đo lại vị trí đỉnh trong UniMiB rồi đặt cho khớp).
- Bỏ cửa sổ có đỉnh quá sát đầu/cuối bản ghi, hoặc nội suy qua khoảng trống dữ liệu gốc lớn hơn `--max-gap-ms` (mặc định 100 ms).
- Đầu ra `.npz`: `X (N,151,3)`, `y` (1 = fall), `label`, `subject`, `position`, `session_id`, `trial_no`.

> Trục của điện thoại khác trục cảm biến của UniMiB (máy để trong túi quần). Khi train hoặc đánh giá, nên dùng augmentation xoay ngẫu nhiên hoặc các đặc trưng không phụ thuộc hướng.

## 8. Checklist test trên máy thật

1. **Ghi 10 phút khi tắt màn hình**: buổi *Sinh hoạt liên tục* → tắt màn hình 10 phút → Dừng → Xuất ZIP → `python tools/read_sessions.py file.zip --no-save`. Đạt khi `health.csv` có ≥ 9 dòng, mọi `effective_hz` > 45 và `max_gap_ms` < 5000.
2. **Kịch bản ngã 2 lượt**: buổi *Ngã thử*, chỉ chọn 1 kiểu ngã, số lượt = 2 → Bắt đầu → tắt màn hình ngay, bỏ máy vào túi. Kiểm tra giọng nói vẫn phát đủ (Chuẩn bị, Ba-Hai-Một, Bắt đầu, Xong. Đứng dậy, Nghỉ…) khi màn hình tắt. Sau đó mở `events.csv`: có 2 dòng `ok`, `t_end_us - t_start_us` ≈ 20 000 000, và đỉnh gia tốc trong `sensor.csv` rơi vào giữa `[t_start_us, t_end_us]`.
3. **Xuất ZIP**: bấm Xuất ZIP một buổi và Xuất tất cả. Mở app *Files/Quản lý tệp* → `Download/SafeNetCollector/`, thấy file `.zip`, mở được và có đủ 4 file.
