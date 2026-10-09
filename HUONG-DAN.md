# Hướng dẫn YayBot cho người mới

YayBot đọc ticket hỗ trợ của **một plugin** trong các kênh Slack bạn chọn và để **Claude** xử lý từng ticket. Kết quả được gửi vào thread của ticket, **chỉ mình bạn thấy**, kèm thông báo về điện thoại. YayBot không tự trả lời khách.

Mọi thao tác dùng một lệnh: `yb <việc>`. Cấu hình nằm trong `~/.yaybot`.

## Thiết lập (làm một lần)

### 1. Chuẩn bị

- Máy Mac hoặc Linux, bật trong lúc YayBot chạy.
- [Claude Code](https://docs.claude.com/en/docs/claude-code) đã đăng nhập (`claude` → `/login`).
- App **Claude** trên điện thoại, cùng tài khoản claude.ai, đã bật thông báo.

```bash
brew install jq tmux
```

```bash
claude update
```

### 2. Cài lệnh `yb`

Đặt thư mục YayBot **trong `wp-content/plugins`**, cạnh mã nguồn plugin, để Claude đọc được code.

```bash
git clone https://github.com/khoata91/YayBot.git
```

```bash
cd YayBot && ./yaybot.sh install
```

Nếu lệnh in dòng `Add to ~/.zshrc …`, thêm dòng đó vào `~/.zshrc` và mở Terminal mới.

✔ Gõ `yb` thấy danh sách lệnh.

### 3. Lấy token Slack

Nếu nhóm đã có Slack app YayBot, xin token `xoxb-…` từ người quản lý app. Nếu chưa:

```bash
yb manifest
```

1. Mở <https://api.slack.com/apps> → **Create New App** → **From an app manifest**.
2. Dán manifest (đã có sẵn trong clipboard) → **Create** → **Install to Workspace**.
3. Vào **OAuth & Permissions**, chép **Bot User OAuth Token** (`xoxb-…`).

Không dán token vào Slack hay commit vào git.

### 4. Thiết lập

```bash
yb setup xoxb-TOKEN-CỦA-BẠN
```

Lệnh sẽ hỏi ba thứ:

| Câu hỏi | Trả lời |
|---|---|
| Plugin nào? | Tên plugin, ví dụ `YayExtra` |
| Kênh Slack nào? | Số thứ tự trong danh sách, ví dụ `2 3`. Thêm `:all` (ví dụ `2:all`) nếu mọi tin nhắn trong kênh đều là ticket |
| Bạn là ai trên Slack? | Tên Slack hoặc member ID của bạn |

Kênh private chỉ hiện sau khi bạn gõ `/invite @YayBot` trong kênh đó.

✔ `yb check` báo token hợp lệ; `yb plugin` hiện đúng plugin và kênh.

### 5. Xem thử ticket

```bash
yb scan
```

Chỉ đọc và liệt kê ticket 7 ngày gần nhất, không gửi gì. Xem xa hơn: `yb scan 30`.

### 6. Thử thông báo

```bash
yb ping
```

✔ Điện thoại nhận một thông báo từ app Claude.

### 7. Chạy

```bash
yb start
```

YayBot chạy nền và cứ 10 phút lấy ticket mới một lần. Muốn xử lý ngay ticket mới nhất:

```bash
yb try
```

Lần đầu, chạy `yb attach`. Nếu Claude hỏi *"Do you trust the files in this folder?"*, chọn **Yes**, rồi bấm **Ctrl+B, D** để thoát.

✔ `yb status` báo phiên chính và watchdog đang bật.

### 8. Tự chạy lại sau khi tắt máy

```bash
yb autostart on
```

Khi đăng nhập lại vào Mac, YayBot tự khởi động và làm tiếp các ticket đang dở.

## Làm việc hằng ngày

Mỗi ticket được xếp vào một loại, và Claude xử lý theo loại đó:

| Loại | Ví dụ | Kết quả | Việc của bạn |
|---|---|---|---|
| `how-to` | "Làm sao hiện giá option?" | ✅ Câu trả lời gợi ý cho khách | Đọc lại rồi gửi cho khách |
| `trivial` | lỗi chính tả, CSS | ✅ Một PR sửa lỗi | Review và merge |
| `technical` | xung đột plugin, cache | 🧑‍💻 Nguyên nhân và hướng sửa | Tự sửa |
| `major` | sai giá, sai phí | 🧑‍💻 Nguyên nhân và hướng sửa | Tự sửa |
| `fatal` | trắng trang, lỗi 500 | 🧑‍💻 Nguyên nhân và hướng sửa | Tự sửa |

Ticket mà Claude không chắc chắn cũng được chuyển thành 🧑‍💻.

- **Đọc kết quả** trong thread Slack của ticket. Tin nhắn này biến mất khi tải lại Slack; bản lưu nằm trong `~/.yaybot/reports/`.
- **Hỏi thêm** trong app Claude, ở phiên của ticket (tên dạng `T7 · YayExtra · major · Anna`).
- **Xem tình hình:** `yb status`, `yb sessions`.
- **Dọn phiên đã xong:** `yb cleanup`.
- **Dừng hẳn:** `yb stop all`.

## Nhiều máy tính (tuỳ chọn)

Dùng khi bạn có hai máy và muốn máy thứ hai làm tiếp khi máy thứ nhất tắt. Các máy chia sẻ hàng đợi qua một repo git **private**, và mỗi lúc chỉ một máy làm việc. Đừng dùng chung repo với người khác.

Trên mỗi máy, làm xong bước 1–7 với cùng token, plugin và kênh, rồi:

```bash
yb device ten-may
```

```bash
yb cloud https://github.com/khoata91/yaybot-state.git
```

```bash
yb start
```

Thay URL bằng repo của bạn và dùng dạng **HTTPS**. Nếu báo `Cannot reach …`, máy chưa có quyền vào repo; thử `git ls-remote <url>`.

- Máy chạy `yb start` trước sẽ làm việc; máy còn lại ở trạng thái *Standby*.
- Máy đang làm im lặng quá 5 phút thì máy standby tự tiếp quản.
- `yb stop` bàn giao ngay; `yb takeover` lấy quyền ngay; `yb cloud off` tắt cloud.

## Bảng lệnh

Lệnh **in đậm** là lệnh chính.

| Lệnh | Tác dụng |
|---|---|
| **`yb setup [token] [thư-mục]`** | Thiết lập token, plugin, kênh, người nhận |
| **`yb scan [ngày]`** | Liệt kê ticket, không thay đổi gì |
| **`yb start`** | Khởi động chạy nền |
| **`yb stop [all]`** | Dừng; `all` dừng cả các phiên ticket |
| **`yb status`** | Xem trạng thái |
| **`yb try [ngày]`** | Xử lý ngay ticket mới nhất |
| **`yb sessions`** | Danh sách phiên ticket |
| **`yb doctor`** | Chẩn đoán lỗi |
| `yb plugin [Tên] [#kênh …]` | Xem hoặc đổi plugin |
| `yb channels [#kênh …]` | Đổi kênh |
| `yb slack [bạn]` | Đổi người nhận câu trả lời |
| `yb device [tên]` | Xem hoặc đặt tên máy |
| `yb autostart [on\|off]` | Tự chạy lại khi đăng nhập Mac |
| `yb check` | Kiểm tra token và quyền Slack |
| `yb run` | Chạy một lượt ngay (phiên chính tự gọi mỗi 10 phút) |
| `yb collect` | Thu ngay kết quả các phiên đã xong |
| `yb rescan [ngày]` | Đọc lại các kênh sau khi đổi plugin, kênh, từ khoá |
| `yb report` | In báo cáo ngay |
| `yb close T7\|all` | Đóng phiên ticket |
| `yb cleanup [-y]` | Đóng phiên đã xong và xoá worktree |
| `yb attach` | Xem phiên chính (Ctrl+B, D để thoát) |
| `yb ping` | Thử thông báo điện thoại |
| `yb log` | Xem log trực tiếp |
| `yb cloud [url\|off]` | Xem, bật hoặc tắt chia sẻ giữa các máy |
| `yb takeover` | Máy này lấy quyền làm việc ngay |
| `yb boot` | Việc autostart chạy; có thể gọi tay |
| `yb reset` | Xoá hàng đợi và lịch sử ticket, giữ cấu hình |
| `yb manifest` · `yb install` | In manifest Slack app · cài lệnh `yb` |

## Sự cố thường gặp

Chạy `yb doctor` trước.

| Hiện tượng | Cách xử lý |
|---|---|
| `invalid_auth` | Token sai: chạy lại `yb setup xoxb-…` |
| `missing_scope`, không thấy kênh nào | `yb check` chỉ ra quyền thiếu; thêm ở *Bot Token Scopes*, **Reinstall to Workspace**, rồi `yb setup` lại |
| Thiếu một kênh | Kênh private: `/invite @YayBot`, rồi `yb channels` |
| Không ticket nào được xử lý | Chưa có ticket mới: `yb try` hoặc `yb scan 30` |
| Sót ticket | Thêm kênh bằng `yb channels` hoặc dùng `:all`, rồi `yb rescan 7` |
| Không có trả lời trong thread | Bạn phải là thành viên kênh; chạy `yb collect` |
| Không có thông báo | `yb ping`; mở app Claude; bật thông báo; tắt Không làm phiền |
| Không thấy phiên trên điện thoại | Dùng cùng tài khoản claude.ai; `claude update`; `yb attach` để xem lỗi |
| Phiên ticket "working" mãi | `tmux attach -t yb-T7` để xem |
| `Cannot reach …` (cloud) | `git ls-remote <url>`; dùng URL HTTPS hoặc đăng nhập đúng tài khoản GitHub |

Cấu hình nâng cao và các sự cố khác: xem [README.md](README.md).
