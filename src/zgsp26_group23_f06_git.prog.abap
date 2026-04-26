*&---------------------------------------------------------------------*
*& Include          ZGSP26_GROUP23_F06
*&---------------------------------------------------------------------*

*&---------------------------------------------------------------------*
*& Purpose
*&  Serialization helpers for Group23: plain preview lines -> Base64,
*&  rebuild workbook/text from in-memory structures for ZLOG_ITEM,
*&  frontend file path -> Base64, XSTRING -> Base64.
*&---------------------------------------------------------------------*

*&---------------------------------------------------------------------*
*& Section: Rebuild persisted file body (XLSX vs CSV/TXT)
*&---------------------------------------------------------------------*

*&---------------------------------------------------------------------*
*& Form REBUILD_BASE64_FILE_CONTENT
*& Rebuild XLSX from GT_MASTER_SHEETS: header row, tech rule row, GT_EXCEL_RAW
*& cells per sheet; ABAP2XLSX writer -> XSTRING -> SSFC_BASE64_ENCODE.
*&---------------------------------------------------------------------*
FORM rebuild_base64_file_content CHANGING pv_base64 TYPE string.

  DATA:lo_excel     TYPE REF TO zcl_excel,
       lo_worksheet TYPE REF TO zcl_excel_worksheet,
       lo_writer    TYPE REF TO zif_excel_writer,
       lv_xstring   TYPE xstring.

  DATA: ls_raw      TYPE gty_excel_cell,
        lv_rule_str TYPE string.

  " New ABAP2XLSX workbook instance.
  CREATE OBJECT lo_excel.

  " First sheet already exists on create; reuse it, then ADD_NEW_WORKSHEET for others.
  DATA: lv_is_first_sheet TYPE abap_bool VALUE abap_on.

  " Walk every in-memory sheet package.
  TRY.

      LOOP AT gt_master_sheets INTO DATA(ls_master).

        " Create or pick worksheet and set title from sheet name.
        IF lv_is_first_sheet = abap_on.
          lo_worksheet = lo_excel->get_active_worksheet( ).
          lo_worksheet->set_title( ip_title = CONV #( ls_master-sheet_name ) ).
          lv_is_first_sheet = abap_off.
        ELSE.
          TRY.
              lo_worksheet = lo_excel->add_new_worksheet( ).
              lo_worksheet->set_title( ip_title = CONV #( ls_master-sheet_name ) ).
            CATCH zcx_excel INTO DATA(lx_err).
              MESSAGE s040(zmsg_gr23) WITH ls_master-sheet_name lx_err->get_text( ).
              RETURN.
          ENDTRY.
        ENDIF.

        SORT ls_master-header_list BY col_pos.
        LOOP AT ls_master-header_list INTO DATA(ls_header).
          lo_worksheet->set_cell(
            ip_row    = gc_header_row
            ip_column = ls_header-col_pos
            ip_value  = ls_header-descr
          ).

          lv_rule_str = ls_header-tech_name.

          IF ls_header-is_mand = abap_on.
            lv_rule_str = lv_rule_str && '*'.
          ENDIF.
          IF ls_header-is_pos = abap_on.
            lv_rule_str = lv_rule_str && '+'.
          ENDIF.
          IF ls_header-rng_low IS NOT INITIAL OR ls_header-rng_high IS NOT INITIAL.
            lv_rule_str = lv_rule_str && |[RNG:{ ls_header-rng_low }-{ ls_header-rng_high }]|.
          ENDIF.
          IF ls_header-val_list IS NOT INITIAL.
            lv_rule_str = lv_rule_str && |[LIST:{ ls_header-val_list }]|.
          ENDIF.

          lo_worksheet->set_cell(
            ip_row    = gc_tech_row
            ip_column = ls_header-col_pos
            ip_value  = lv_rule_str
          ).
        ENDLOOP.
        LOOP AT ls_master-excel_raw INTO ls_raw.
          lo_worksheet->set_cell(
            ip_row    = ls_raw-row
            ip_column = ls_raw-col
            ip_value  = ls_raw-value
          ).
        ENDLOOP.
      ENDLOOP.

    CATCH zcx_excel INTO DATA(lo_err).
      " Library-level Excel error from ABAP2XLSX.
      MESSAGE s041(zmsg_gr23) WITH lo_err->get_text( ) DISPLAY LIKE gc_displike_err.
  ENDTRY.

  TRY.
      CREATE OBJECT lo_writer TYPE zcl_excel_writer_2007.
      lv_xstring = lo_writer->write_file( lo_excel ).

    CATCH zcx_excel INTO lx_err.
      MESSAGE s042(zmsg_gr23) WITH lx_err->get_text( ) DISPLAY LIKE gc_displike_err.
      RETURN.
  ENDTRY.

  IF lv_xstring IS NOT INITIAL.
    CALL FUNCTION 'SSFC_BASE64_ENCODE'
      EXPORTING
        bindata = lv_xstring
      IMPORTING
        b64data = pv_base64
      EXCEPTIONS
        OTHERS  = 1.

    IF sy-subrc <> 0.
      MESSAGE s043(zmsg_gr23) DISPLAY LIKE gc_displike_err.
    ENDIF.
  ELSE.
    MESSAGE s043(zmsg_gr23) DISPLAY LIKE gc_displike_err.
  ENDIF.
ENDFORM.

*&---------------------------------------------------------------------*
*& Form REBUILD_TEXT_BASE64
*& Build CSV/TXT line table: header labels, tech rule row, then each <GFS_DATA>
*& row via column index; optional UTF-8 BOM for CSV; STRING_TABLE_TO_BASE64.
*&---------------------------------------------------------------------*
FORM rebuild_text_base64 USING    pv_file_type TYPE char10
                         CHANGING pv_base64    TYPE string.

  DATA: lt_lines     TYPE string_table,
        lv_line      TYPE string,
        lv_val_str   TYPE string,
        lv_separator TYPE char1.

  FIELD-SYMBOLS: <lfs_line>  TYPE any,
                 <lfs_value> TYPE any.

  " Delimiter: comma vs tab.
  IF pv_file_type = gc_ftype_csv.
    lv_separator = ','.
  ELSE.
    lv_separator = cl_abap_char_utilities=>horizontal_tab.
  ENDIF.

  " Header row: descriptions in column order.
  SORT gt_header_list BY col_pos.

  CLEAR lv_line.
  LOOP AT gt_header_list INTO DATA(ls_header).
    IF sy-tabix = 1.
      lv_line = ls_header-descr.
    ELSE.
      lv_line = |{ lv_line }{ lv_separator }{ ls_header-descr }|.
    ENDIF.
  ENDLOOP.
  APPEND lv_line TO lt_lines.

  CLEAR lv_line.
  LOOP AT gt_header_list INTO ls_header.

    DATA(lv_rule_string) = ls_header-tech_name.

    IF ls_header-is_mand = abap_on.
      lv_rule_string = lv_rule_string && '*'.
    ENDIF.
    IF ls_header-is_pos = abap_on.
      lv_rule_string = lv_rule_string && '+'.
    ENDIF.
    IF ls_header-rng_low IS NOT INITIAL OR ls_header-rng_high IS NOT INITIAL.
      lv_rule_string = lv_rule_string && |[RNG:{ ls_header-rng_low }-{ ls_header-rng_high }]|.
    ENDIF.
    IF ls_header-val_list IS NOT INITIAL.
      lv_rule_string = lv_rule_string && |[LIST:{ ls_header-val_list }]|.
    ENDIF.

    IF sy-tabix = 1.
      lv_line = lv_rule_string.
    ELSE.
      lv_line = |{ lv_line }{ lv_separator }{ lv_rule_string }|.
    ENDIF.
  ENDLOOP.
  APPEND lv_line TO lt_lines.

  IF <gfs_data> IS NOT ASSIGNED.
    MESSAGE s063(zmsg_gr23) DISPLAY LIKE gc_displike_err.
    RETURN.
  ENDIF.

  LOOP AT <gfs_data> ASSIGNING <lfs_line>.
    CLEAR lv_line.

    LOOP AT gt_header_list INTO ls_header.
      ASSIGN COMPONENT ls_header-col_pos OF STRUCTURE <lfs_line> TO <lfs_value>.

      IF sy-subrc = 0 AND <lfs_value> IS ASSIGNED.
        lv_val_str = |{ <lfs_value> }|.
        CONDENSE lv_val_str.

        " RFC-style CSV: wrap field in double quotes when it contains the separator.
        IF pv_file_type = gc_ftype_csv AND lv_val_str CS lv_separator.
          lv_val_str = |"{ lv_val_str }"|.
        ENDIF.
      ELSE.
        lv_val_str = ''.
      ENDIF.

      IF sy-tabix = 1.
        lv_line = lv_val_str.
      ELSE.
        lv_line = |{ lv_line }{ lv_separator }{ lv_val_str }|.
      ENDIF.
    ENDLOOP.

    APPEND lv_line TO lt_lines.
  ENDLOOP.

  PERFORM string_table_to_base64 USING lt_lines
                                       pv_file_type
                                 CHANGING pv_base64.

ENDFORM.

*&---------------------------------------------------------------------*
*& Form STRING_TABLE_TO_BASE64
*& CRLF-join lines; UTF-8 BOM prefix for CSV; UTF-8 convert + SSFC_BASE64_ENCODE.
*&---------------------------------------------------------------------*

FORM string_table_to_base64 USING pt_lines TYPE string_table
                                  pv_file_type TYPE char10
                            CHANGING pv_base64 TYPE string.

  DATA: lv_full_string TYPE string,
        lv_xstring     TYPE xstring.

  CONCATENATE LINES OF pt_lines INTO lv_full_string
            SEPARATED BY cl_abap_char_utilities=>cr_lf.

  IF pv_file_type = gc_ftype_csv.
    lv_full_string = cl_abap_char_utilities=>byte_order_mark_utf8 && lv_full_string.
  ENDIF.

  " STRING -> XSTRING (UTF-8).
  TRY.
      DATA(lo_conv) = cl_abap_conv_out_ce=>create( encoding = 'UTF-8' ).
      lo_conv->convert( EXPORTING data = lv_full_string IMPORTING buffer = lv_xstring ).
    CATCH cx_root.
      MESSAGE s045(zmsg_gr23) DISPLAY LIKE gc_displike_err.
      RETURN.
  ENDTRY.

  " XSTRING -> Base64 text for DB / API.
  CALL FUNCTION 'SSFC_BASE64_ENCODE'
    EXPORTING
      bindata = lv_xstring
    IMPORTING
      b64data = pv_base64
    EXCEPTIONS
      OTHERS  = 1.
  IF sy-subrc <> 0.
    MESSAGE s046(zmsg_gr23) DISPLAY LIKE gc_displike_err.
    RETURN.
  ENDIF.

ENDFORM.

*&---------------------------------------------------------------------*
*& Section: Binary helpers (path / buffer)
*&---------------------------------------------------------------------*

*&---------------------------------------------------------------------*
*& Form CONVERT_FILE_TO_BASE64
*& GUI_UPLOAD BIN from PC path -> SCMS_BINARY_TO_XSTRING -> SSFC_BASE64_ENCODE;
*& sets GV_ERROR on failure.
*&---------------------------------------------------------------------*
FORM convert_file_to_base64  USING    pv_file_path   TYPE rlgrap-filename
                             CHANGING pv_file_base64 TYPE string.

  DATA: lt_binary_tab  TYPE TABLE OF x255,
        lv_file_length TYPE i.

  DATA: lv_xstring TYPE xstring.

  " Read local file as raw binary chunks (SOLIX-style table).
  CALL METHOD cl_gui_frontend_services=>gui_upload
    EXPORTING
      filename   = CONV string( pv_file_path )
      filetype   = 'BIN'
    IMPORTING
      filelength = lv_file_length
    CHANGING
      data_tab   = lt_binary_tab
    EXCEPTIONS
      OTHERS     = 1.

  IF sy-subrc = 0.

    " Merge binary table into one XSTRING buffer.
    CALL FUNCTION 'SCMS_BINARY_TO_XSTRING'
      EXPORTING
        input_length = lv_file_length
      IMPORTING
        buffer       = lv_xstring
      TABLES
        binary_tab   = lt_binary_tab
      EXCEPTIONS
        failed       = 1
        OTHERS       = 2.

    IF sy-subrc = 0.

      CALL FUNCTION 'SSFC_BASE64_ENCODE'
        EXPORTING
          bindata = lv_xstring
        IMPORTING
          b64data = pv_file_base64
        EXCEPTIONS
          OTHERS  = 1.

      IF sy-subrc <> 0.
        gv_error = abap_on.

        MESSAGE s046(zmsg_gr23) DISPLAY LIKE gc_displike_err.
      ENDIF.

    ELSE.
      gv_error = abap_on.
      MESSAGE s053(zmsg_gr23) DISPLAY LIKE gc_displike_err.
    ENDIF.
  ENDIF.
ENDFORM.

*&---------------------------------------------------------------------*
*& Form XSTRING_TO_BASE64
*& Thin wrapper: SSFC_BASE64_ENCODE on PV_XSTRING into PV_FILE_BASE64.
*&---------------------------------------------------------------------*
FORM xstring_to_base64 USING pv_xstring        TYPE xstring
                       CHANGING pv_file_base64 TYPE string.

  CALL FUNCTION 'SSFC_BASE64_ENCODE'
    EXPORTING
      bindata = pv_xstring
    IMPORTING
      b64data = pv_file_base64
    EXCEPTIONS
      OTHERS  = 1.
  IF sy-subrc <> 0.
    MESSAGE s046(zmsg_gr23) DISPLAY LIKE gc_displike_err.
  ENDIF.
ENDFORM.
