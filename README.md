# ZKLTN_FileUpload_And_ProcessingFramework

A comprehensive and dynamic ABAP framework designed for uploading, validating, and processing data files (Excel, CSV, TXT) within SAP.

## Tổng quan (Overview)
Framework `ZGSP26_GROUP23_KLTN` cung cấp một giải pháp hoàn chỉnh từ việc upload file (hỗ trợ nhiều định dạng và multi-sheet), tự động parse dữ liệu, validate động dựa trên cấu trúc kỹ thuật (Technical Header), cho đến việc hiển thị giao diện ALV tương tác để người dùng kiểm tra, chỉnh sửa lỗi trước khi lưu vào cơ sở dữ liệu SAP. 

## Các tính năng chính (Key Features)

- **Hỗ trợ đa định dạng (Multi-format Support):** Xử lý các định dạng phổ biến như `.xlsx`, `.csv`, `.txt`. Hỗ trợ xử lý nhiều sheet (Tab) trong cùng một file Excel.
- **Dynamic Validation (Xác thực dữ liệu động):** Tự động đọc cấu hình validation từ các dòng đầu tiên của file để kiểm tra tính hợp lệ của dữ liệu:
  - Bắt buộc nhập (Mandatory / is_mand)
  - Giá trị dương (Positive / is_pos)
  - Khóa chính (Key Field / is_key)
  - Ràng buộc khoảng giá trị (Range Low/High)
  - Danh sách giá trị cho phép (Value List)
- **Interactive UI (Giao diện ALV tương tác):** 
  - Kiến trúc Split Screen (Master-Detail ALV): Cửa sổ bên trái hiển thị toàn bộ dữ liệu file, cửa sổ bên phải hiển thị chi tiết theo từng cột của dòng được chọn kèm theo thông báo lỗi.
  - Tích hợp màn hình TextEdit Preview cho định dạng text thô.
  - Hỗ trợ đổi tab linh hoạt giữa các Sheet dữ liệu.
- **Lưu trữ & Lịch sử (Database & Logging):** 
  - Ghi nhận lịch sử giao dịch (Transaction Logging).
  - Màn hình History (Screen 0200) cho phép tra cứu lại các phiên upload và download các file đã lưu.
- **Data Editing (Chỉnh sửa dữ liệu trực tiếp):** Hỗ trợ Edit Mode cho phép người dùng fix các bản ghi bị lỗi (Dirty records) trực tiếp trên ALV Grid mà không cần upload lại file nguồn.

## Cấu trúc File Source Code (Program Structure)

- **`zgsp26_gr23_kltn_git.prog.abap`**: Report chạy chính (Main Report)
- **`..._t01_git` (Top)**: Khai báo Data Types (`gty_master_sheet`, `gty_vertical_data`), hằng số, biến ALV và Field Symbols.
- **`..._s01_git` (Screen)**: Khai báo Selection Screen ban đầu.
- **`..._c00_git` (Class)**: Định nghĩa các Class cục bộ.
- **`..._f00_git` -> `..._f08_git` (Forms)**: Phân tách rõ ràng các xử lý logic:
  - `f00`: Quản lý giao diện ALV (UI).
  - `f01`: Các lệnh File I/O (Upload).
  - `f02`: Xử lý Validation logic.
  - `f03`: Flow xử lý chính.
  - `f04`: Chức năng History & Download.
  - `f05`: Tương tác Database (Lưu dữ liệu, Logging).
  - `f06` & `f07` & `f08`: Xử lý Encoding, Utility và Quản lý dữ liệu đa Sheet.
- **`..._i01_git` / `..._o01_git`**: Xử lý logic PAI và PBO cho UI screens (Screen 0100, 0200).

## Luồng hoạt động cơ bản (Basic Workflow)
1. **Upload:** Người dùng chạy chương trình, chỉ định file cần import.
2. **Parse & Validate:** Hệ thống đọc dữ liệu, phân tách sheet, đọc Header definitions và validate từng ô (`gty_excel_cell`).
3. **Review:** Dữ liệu được đưa lên ALV. Các cell lỗi sẽ được highlight và hiển thị thông báo chi tiết bên Grid dọc (Vertical Grid).
4. **Correction:** Người dùng có thể tùy chỉnh trực tiếp các giá trị sai nếu có (qua Edit mode).
5. **Commit:** Bấm **Save** để hệ thống ghi dữ liệu chuẩn vào SAP DB và tạo Log History.
