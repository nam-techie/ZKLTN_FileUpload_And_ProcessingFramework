*&---------------------------------------------------------------------*
*& Include          ZGSP26_GROUP23_T01
*&---------------------------------------------------------------------*

*----------------------------------------------------------------------*
* CONSTANTS
*----------------------------------------------------------------------*
CONSTANTS: gc_header_row     TYPE i        VALUE 1,
           gc_tech_row       TYPE i        VALUE 2,
           gc_data_start     TYPE i        VALUE 3,
           gc_stored_file    TYPE char4    VALUE 'STOR',
           gc_validated_file TYPE char4    VALUE 'VALD',
           gc_ucomm_raw_cont TYPE sy-ucomm VALUE 'RAW_CONT',
           gc_ucomm_view_raw TYPE sy-ucomm VALUE 'VIEW_RAW',
           gc_ucomm_save     TYPE sy-ucomm VALUE 'SAVE',
           gc_ucomm_back     TYPE sy-ucomm VALUE 'BACK',
           gc_ucomm_exit     TYPE sy-ucomm VALUE 'EXIT',
           gc_ucomm_change   TYPE sy-ucomm VALUE 'CHANGE',
           gc_ucomm_disp     TYPE sy-ucomm VALUE 'DISPLAY',
           gc_ucomm_down     TYPE sy-ucomm VALUE 'BTN_DOWN',
           gc_ucomm_del      TYPE sy-ucomm VALUE 'BTN_DEL',
           gc_ftype_xlsx     TYPE char10   VALUE 'XLSX',
           gc_ftype_csv      TYPE char10   VALUE 'CSV',
           gc_ftype_txt      TYPE char10   VALUE 'TXT',
           gc_ftype_excel    TYPE char10   VALUE 'EXCEL',
           gc_ttbar_t001     TYPE char10   VALUE 'T001',
           gc_ttbar_t002     TYPE char10   VALUE 'T002',
           gc_stt_disp       TYPE char20   VALUE 'SSTATUS_DISPLAY',
           gc_stt_change     TYPE char20   VALUE 'SSTATUS_CHANGE',
           gc_displike_err   TYPE char1    VALUE 'E',
           gc_displike_warn  TYPE char1    VALUE 'W',
           gc_displike_suc   TYPE char1    VALUE 'S'.

*----------------------------------------------------------------------*
* TYPES (Data Type Definitions)
*----------------------------------------------------------------------*
* Structure for data Header read
TYPES: BEGIN OF gty_data_header,
         col_pos   TYPE i,
         tech_name TYPE string,
         descr     TYPE string,
         is_mand   TYPE abap_bool,  " Mandatory field? (X = yes, blank = no)
         is_pos    TYPE abap_bool,  " Must be a positive number (+)
         is_key    TYPE abap_bool,  " Key field
         rng_low   TYPE decfloat34,     " Minimum allowed value (e.g. 10)
         rng_high  TYPE decfloat34,     " Maximum allowed value (e.g. 100)
         val_list  TYPE string,     " Allowed values list (e.g. FERT,HAWA)
       END OF gty_data_header.

* Table Type for Header
TYPES: gty_t_data_header TYPE STANDARD TABLE OF gty_data_header WITH EMPTY KEY.

* Structure for data Cell (Coordinates)
TYPES: BEGIN OF gty_data_cell,
         row   TYPE i,
         col   TYPE i,
         value TYPE string,
       END OF gty_data_cell.

* Table Type for data Cell
TYPES: gty_t_data_cell TYPE STANDARD TABLE OF gty_data_cell WITH EMPTY KEY.

* Structure for Error Log
TYPES: BEGIN OF gty_error_log,
         col_pos   TYPE i,
         row_index TYPE i,
         fieldname TYPE fieldname,
         msg_type  TYPE bapi_mtype,
         message   TYPE bapi_msg,
         raw_data  TYPE string,
       END OF gty_error_log.

* Table Type for Error Log
TYPES: gty_t_error_log TYPE STANDARD TABLE OF gty_error_log WITH EMPTY KEY.

* Structure of Mutiple Sheet
TYPES: BEGIN OF gty_master_sheet,
         page_no     TYPE i,                   " Sheet index (1, 2, 3...)
         sheet_name  TYPE string,              " Excel sheet name (e.g. Nhan_Vien, Luong)
         header_list TYPE gty_t_data_header,  " Slot 1: column definitions from header row
         data_raw    TYPE gty_t_data_cell,    " Slot 2: raw cells with row/column coordinates
         dref_data   TYPE REF TO data,         " Slot 3: reference to dynamic result table
         error_log   TYPE gty_t_error_log,     " Slot 4: validation / processing error log
         is_parsed   TYPE abap_bool,           " Flag: this sheet was already validated
       END OF gty_master_sheet.

*----------------------------------------------------------------------*
* DATA (Variable Declarations)
*----------------------------------------------------------------------*
* Since REF TO DATA is a reference variable, we use GV_ (Global Variable)
DATA: gv_dref_table TYPE REF TO data.

* Global Field Symbols (GFS_*)
FIELD-SYMBOLS: <gfs_data> TYPE STANDARD TABLE. " Reference to dynamic table

* Variable holding Header list
DATA: gt_header_list TYPE gty_t_data_header.

* Variable holding raw data cell
DATA: gt_data_raw TYPE gty_t_data_cell.

* Variable holding error log
DATA: gt_error_log TYPE gty_t_error_log.

* Variable holding current log id
DATA: gv_current_log_id TYPE zlog_header-log_id.

* Variable mutiple sheet
DATA: gt_master_sheets TYPE TABLE OF gty_master_sheet, " All loaded sheets (main workbook state)
      gv_current_page  TYPE i VALUE 1,                 " Currently displayed sheet index
      gv_total_pages   TYPE i.                         " Total number of sheets


*----------------------------------------------------------------------*
* DATA ALV
*----------------------------------------------------------------------*
DATA: gv_okcode             TYPE sy-ucomm,
      gv_edit_mode          TYPE abap_bool VALUE abap_off,
      gv_detail_initialized TYPE abap_bool VALUE abap_off,
      gv_data_dirty         TYPE abap_bool VALUE abap_off.

"  Row structure for the right-hand vertical (detail) ALV — includes ERROR_MSG
TYPES: BEGIN OF gty_vertical_data,
         row_pos   TYPE i,
         fieldname TYPE string,
         descr     TYPE string,
         value     TYPE string,
         error_msg TYPE string,
         cell_col  TYPE lvc_t_scol,
         dd_hndl   TYPE int4,
         f4_icon   TYPE c LENGTH 4,
       END OF gty_vertical_data.

"  Data for the two new ALV grids (old standalone error-table variables removed)
DATA: gv_dref_master   TYPE REF TO data,
      gt_vertical_data TYPE TABLE OF gty_vertical_data,
      gt_drop_detail   TYPE lvc_t_drop.

FIELD-SYMBOLS: <gfs_master> TYPE STANDARD TABLE.

"  GUI container / splitter / grid objects for the new screen layout
DATA: go_cont_tabs    TYPE REF TO cl_gui_custom_container,
      go_toolbar_tabs TYPE REF TO cl_gui_toolbar,

      go_cont_main    TYPE REF TO cl_gui_custom_container,
      go_split_main   TYPE REF TO cl_gui_splitter_container,

      go_cont_left    TYPE REF TO cl_gui_container,
      go_cont_right   TYPE REF TO cl_gui_container,

      go_grid_master  TYPE REF TO cl_gui_alv_grid,
      go_grid_detail  TYPE REF TO cl_gui_alv_grid,

      go_text_edit    TYPE REF TO cl_gui_textedit.

" data row index the user last selected in the master grid
DATA: gv_selected_data_row TYPE i.

*----------------------------------------------------------------------*
* PROGRAM ERROR AND LOGGING
*----------------------------------------------------------------------*

DATA: gv_error TYPE abap_bool VALUE abap_off.

* CSV/TXT: preview + parse use STRING_TABLE; CHAR255 lines are built in show_raw_preview_ui (F00) when filling TextEdit
DATA: gv_plain_preview    TYPE abap_bool VALUE abap_off,
      gt_preview_lines    TYPE string_table,
      gt_preview_snapshot TYPE string_table.

* Rows edited in ALV but not yet saved to DB (status column — yellow); key = sheet + data row number
TYPES: BEGIN OF gty_dirty_line,
         page_no  TYPE i,
         data_row TYPE i,
       END OF gty_dirty_line.
DATA gt_row_dirty TYPE HASHED TABLE OF gty_dirty_line WITH UNIQUE KEY page_no data_row.

*----------------------------------------------------------------------*
* DATA FOR HISTORY SCREEN
*----------------------------------------------------------------------*
DATA: gt_history_list TYPE TABLE OF zlog_header. " Loaded history header rows

* --- New history screen (screen 200) ---
DATA: go_cont_hist TYPE REF TO cl_gui_custom_container,
      go_grid_hist TYPE REF TO cl_gui_alv_grid.
