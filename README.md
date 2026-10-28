# TrialShelf

TrialShelf là ứng dụng macOS để gom bản sao của các file vào những folder có cấu trúc, sau đó xuất một folder thành file ZIP. Ứng dụng cũng có thể đặt lịch chạy file `.sh` đã lưu.

## Yêu cầu

- macOS 13 trở lên.
- Máy Mac Apple Silicon (arm64) cho bản build hiện tại.
- Xcode Command Line Tools nếu muốn tự build từ mã nguồn.

## Cài đặt và mở ứng dụng

1. Tải `TrialShelf-arm64.zip` từ mục **Releases** nếu có bản phát hành, hoặc tự tạo ZIP theo hướng dẫn build.
2. Giải nén và kéo `TrialShelf.app` vào **Applications**.
3. Mở ứng dụng. Khi được macOS hỏi, cho phép TrialShelf mở cùng lúc đăng nhập để tính năng chạy file đến hạn hoạt động sau khi khởi động máy.

## Bắt đầu sử dụng

### 1. Tạo folder

Chọn **Tạo mục lớn** để tạo folder ở cấp cao nhất. Dùng nút tạo mục con cạnh một folder để thêm folder lồng bên trong. Cây folder và file được hiển thị trên cùng một trang.

### 2. Thêm file hoặc nhập folder

Ở dòng folder đích, dùng nút **Upload file vào folder này** để chọn một hay nhiều file, hoặc **Nhập thư mục vào folder này** để sao chép các file trong một folder. Ứng dụng bỏ qua file ẩn và nội dung bên trong các app bundle.

TrialShelf tạo bản sao riêng trong thư mục dữ liệu của ứng dụng. Thay đổi hay xóa bản sao trong TrialShelf không làm thay đổi file nguồn. Nhập lại cùng một file nguồn vào cùng folder sẽ không tạo thêm bản trùng.

### 3. Tìm và quản lý file

- Gõ tên vào ô tìm kiếm để lọc danh sách.
- Chọn file để xem thời điểm sửa đổi, hạn chạy (nếu có), và các thao tác ở khung bên phải.
- **Hiện bản lưu trong Finder** mở vị trí bản sao nội bộ.
- **Bỏ khỏi danh mục** xóa bản sao nội bộ và mục tương ứng khỏi TrialShelf; file nguồn vẫn còn nguyên.
- Nút làm mới cập nhật lại thời điểm sửa đổi và trạng thái tồn tại của các bản sao.

### 4. Xuất folder thành ZIP

Bấm nút lưu trữ bên cạnh folder. ZIP sẽ chứa folder đã chọn cùng các file và folder con bên trong. Chọn nơi lưu và tên ZIP trong hộp thoại macOS. Folder cần có ít nhất một file.

### 5. Chạy script

Chọn file rồi bấm **Run** để chạy thủ công. TrialShelf hỗ trợ `.sh`, `.command`, `.py`, `.swift`, `.rb` và `.pl`; file được chạy bằng interpreter theo dòng shebang nếu có, nếu không thì dùng interpreter mặc định theo phần mở rộng. Kết quả, đầu ra và mã thoát hiện trong thông báo của ứng dụng.

Khi thêm file `.sh` (hoặc nhập folder có `.sh`), TrialShelf hỏi số ngày trước khi chạy. Nhập `0` để đặt đến hạn ngay. Đến hạn không có nghĩa là xóa file: script được tự chạy một lần khi ứng dụng đang hoạt động hoặc lần kế tiếp ứng dụng khởi chạy. Nếu chạy tự động thất bại, TrialShelf báo lỗi; chọn script và bấm **Run** để thử lại.

> Script chạy với quyền của tài khoản macOS hiện tại. Chỉ thêm và chạy script mà bạn tin cậy.

## Dữ liệu và quyền riêng tư

TrialShelf không tải file lên dịch vụ bên ngoài. Dữ liệu được lưu trong `~/Library/Application Support/TrialShelf/`:

- `catalog.json` và `packages.json`: danh mục file và cấu trúc folder.
- `Files/`: các bản sao được quản lý bởi TrialShelf.

Xóa folder trong ứng dụng sẽ xóa folder đó, các folder con và các bản sao bên trong khỏi kho TrialShelf. File gốc đã chọn từ Finder không bị xóa. ZIP xuất ra là file riêng do bạn chọn vị trí lưu.

## Build từ mã nguồn

Trên máy Mac Apple Silicon có Xcode Command Line Tools, chạy từ thư mục dự án:

```sh
./build.sh
```

Script tạo `build/TrialShelf.app` và gói `dist/TrialShelf-arm64.zip`. Gói được ký ad-hoc, chưa notarize; macOS có thể yêu cầu bạn cho phép mở app lần đầu.

## Cấu trúc mã nguồn

- `Sources/TrialShelfApp.swift`: giao diện, danh mục file, xuất ZIP, lịch chạy và thực thi script.
- `Resources/TrialShelf.iconset/`: các kích thước icon nguồn.
- `scripts/make-iconset.swift`: tiện ích tạo icon (build hiện tại dùng bộ icon trong `Resources`).
- `Info.plist`: tên app, bundle identifier và phiên bản macOS tối thiểu.
