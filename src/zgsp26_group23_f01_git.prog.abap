*&---------------------------------------------------------------------*
*& Include          ZGSP26_GROUP23_F01
*&---------------------------------------------------------------------*


*&---------------------------------------------------------------------*
*& Purpose
*&  File I/O and parsing for Group23: XLSX from PC or application server,
*&  CSV/TXT lines to GT_HEADER_LIST / GT_data_RAW, header rule parsing,
*&  F4 paths for server/client selection.
*&---------------------------------------------------------------------*

*&---------------------------------------------------------------------*
*& Section: Client / server file pickers
*&---------------------------------------------------------------------*

*&---------------------------------------------------------------------*
*& Form BROWSE_FILE
*& Frontend F4: single XLSX selection into PV_FILE.
*&---------------------------------------------------------------------*
FORM browse_file CHANGING pv_file TYPE rlgrap-filename.

  DATA: lt_file_table TYPE filetable,
        ls_file_table TYPE file_table,
        lv_rc         TYPE i,
        lv_action     TYPE i,
        lv_ext        TYPE string,
        lv_filter     TYPE string.

  " Dynamic filter based on selection screen file type.
  CASE p_ftype.
    WHEN gc_ftype_xlsx.
      lv_ext    = gc_ftype_xlsx.
      lv_filter = |{ TEXT-148 }|.
    WHEN gc_ftype_csv.
      lv_ext    = gc_ftype_csv.
      lv_filter = |{ TEXT-149 }|.
    WHEN gc_ftype_txt.
      lv_ext    = gc_ftype_txt.
      lv_filter = |{ TEXT-150 }|.
    WHEN OTHERS.
      lv_ext    = gc_ftype_xlsx.
      lv_filter = |{ TEXT-043 }|.
  ENDCASE.

  CALL METHOD cl_gui_frontend_services=>file_open_dialog
    EXPORTING
      window_title            = |{ TEXT-042 }|
      default_extension       = lv_ext
      file_filter             = lv_filter
      multiselection          = abap_off      " just 1 file
    CHANGING
      file_table              = lt_file_table
      rc                      = lv_rc
      user_action             = lv_action
    EXCEPTIONS
      file_open_dialog_failed = 1
      cntl_error              = 2
      error_no_gui            = 3
      not_supported_by_gui    = 4
      OTHERS                  = 5.

  IF sy-subrc <> 0.
    RETURN.
  ENDIF.

  IF lv_action = cl_gui_frontend_services=>action_ok AND lv_rc > 0.
    READ TABLE lt_file_table INTO ls_file_table INDEX 1.
    IF sy-subrc = 0.
      pv_file = ls_file_table-filename.
    ENDIF.
  ENDIF.

ENDFORM.

*&---------------------------------------------------------------------*
*& Form BROWSE_SERVER_FILE
*& Pick path on application server.
*&---------------------------------------------------------------------*
FORM browse_server_file CHANGING pv_file TYPE rlgrap-filename.

  DATA: lv_server_file TYPE dxfields-longpath,
        lv_mask        TYPE dxfields-filemask.

  " Set up a dynamic file extension filter based on the chosen upload type
  CASE p_ftype.
    WHEN gc_ftype_xlsx.
      lv_mask = '*.xlsx'.
    WHEN gc_ftype_csv.
      lv_mask = '*.csv'.
    WHEN gc_ftype_txt.
      lv_mask = '*.txt'.
    WHEN OTHERS.
      lv_mask = '*.*'.
  ENDCASE.

  " Trigger the standard AL11 file browser popup.
  CALL FUNCTION '/SAPDMC/LSM_F4_SERVER_FILE'
    EXPORTING
      directory        = '/usr/sap/S40/D00/work/'
      filemask         = lv_mask
    IMPORTING
      serverfile       = lv_server_file
    EXCEPTIONS
      canceled_by_user = 1
      OTHERS           = 2.

  IF sy-subrc = 0 AND lv_server_file IS NOT INITIAL.
    pv_file = lv_server_file.
  ENDIF.
ENDFORM.

*&---------------------------------------------------------------------*
*& Section: XLSX - local (frontend upload) and server (AL11)
*&---------------------------------------------------------------------*

*&---------------------------------------------------------------------*
*& Form READ_EXCEL_LOCAL
*& Optional binary upload from PC; FDT spreadsheet per sheet; fill
*& GT_MASTER_SHEETS with parsed headers/raw/errors per valid sheet.
*&---------------------------------------------------------------------*
FORM read_excel_local USING pv_file TYPE rlgrap-filename
                            pv_data TYPE xstring.

  DATA(lv_file_string) = CONV string( pv_file ).

  DATA: lv_xstring TYPE xstring,
        lt_raw     TYPE solix_tab,
        lv_size    TYPE i.

  lv_xstring = pv_data.

  IF lv_xstring IS INITIAL.

    " GUI upload then convert SOLIX buffer to XSTRING.
    CALL METHOD cl_gui_frontend_services=>gui_upload
      EXPORTING
        filename   = lv_file_string
        filetype   = 'BIN'
      IMPORTING
        filelength = lv_size
      CHANGING
        data_tab   = lt_raw
      EXCEPTIONS
        OTHERS     = 1.
    IF sy-subrc <> 0.
      gv_error = abap_on.
      RETURN.
    ENDIF.

    CALL FUNCTION 'SCMS_BINARY_TO_XSTRING'
      EXPORTING
        input_length = lv_size
      IMPORTING
        buffer       = lv_xstring
      TABLES
        binary_tab   = lt_raw
      EXCEPTIONS
        OTHERS       = 1.
    IF sy-subrc <> 0.
      gv_error = abap_on.
      RETURN.
    ENDIF.

  ENDIF.
  " Open workbook; outer TRY catches corrupt / unreadable file.
  PERFORM process_excel_workbook USING lv_file_string
                                       lv_xstring.

ENDFORM.


*&---------------------------------------------------------------------*
*& Form process_excel_workbook
*&---------------------------------------------------------------------*
*& Shared kernel: open FDT workbook from XSTRING, loop worksheets via
*& Z_READ_EXCEL_SHEET_SAFE, scan grid (header/tech/data), build dynamic
*& table, validate, persist to GT_MASTER_SHEETS, show structure errors.
*&---------------------------------------------------------------------*
FORM process_excel_workbook  USING    pv_file_string TYPE string
                                      pv_xstring     TYPE xstring.


  DATA: lo_excel      TYPE REF TO cl_fdt_xl_spreadsheet,
        lt_worksheets TYPE if_fdt_doc_spreadsheet=>t_worksheet_names.

  FIELD-SYMBOLS: <lfs_excel_data> TYPE STANDARD TABLE.

  TRY.
      lo_excel = NEW cl_fdt_xl_spreadsheet( document_name = pv_file_string xdocument = pv_xstring ).
      lo_excel->if_fdt_doc_spreadsheet~get_worksheet_names( IMPORTING worksheet_names = lt_worksheets ).

      CLEAR gt_master_sheets.
      DATA(lv_real_page_count) = 0.

      DATA: lv_read_sheet_error TYPE abap_bool VALUE abap_off,
            lt_struct_errors    TYPE string_table,
            lt_hdr_rule_errs    TYPE string_table.

      LOOP AT lt_worksheets INTO DATA(lv_sheet_name).

        " Reset working area before each worksheet.
        CLEAR: gt_header_list, gt_data_raw, gt_error_log, gv_error.
        UNASSIGN <gfs_data>.
        TRY.
            DATA: lo_data TYPE REF TO data.

            CALL FUNCTION 'Z_READ_EXCEL_SHEET_SAFE'
              EXPORTING
                io_excel      = lo_excel
                iv_sheet_name = lv_sheet_name
              IMPORTING
                et_data       = lo_data
              EXCEPTIONS
                read_failed   = 1
                error_message = 2
                OTHERS        = 3.

            IF sy-subrc <> 0 OR lo_data IS NOT BOUND.

              DATA: lv_sheet_err_msg TYPE string.
              lv_sheet_err_msg = |{ TEXT-116 } '{ lv_sheet_name }' { TEXT-117 }|.

              CALL FUNCTION 'POPUP_TO_INFORM'
                EXPORTING
                  titel = TEXT-118
                  txt1  = lv_sheet_err_msg
                  txt2  = TEXT-119
                  txt3  = TEXT-120
                  txt4  = TEXT-121.
              lv_read_sheet_error = abap_on.
              CONTINUE.
            ENDIF.

            " Bind returned dynamic table.
            ASSIGN lo_data->* TO <lfs_excel_data>.

            " Skip completely empty sheets.
            IF <lfs_excel_data> IS NOT ASSIGNED OR lines( <lfs_excel_data> ) = 0.
              CONTINUE.
            ENDIF.

            " Scan grid: header row, tech row (rules), data cells -> GT_* .
            DATA: ls_header TYPE gty_data_header,
                  ls_cell   TYPE gty_data_cell.
            LOOP AT <lfs_excel_data> ASSIGNING FIELD-SYMBOL(<lfs_row>).
              DATA(lv_row_idx) = sy-tabix.
              DATA(lv_col_idx) = 1.

              DO.
                ASSIGN COMPONENT lv_col_idx OF STRUCTURE <lfs_row> TO FIELD-SYMBOL(<lfs_field>).
                IF sy-subrc <> 0. EXIT. ENDIF.

                DATA(lv_value) = condense( CONV string( <lfs_field> ) ).
                IF lv_row_idx = gc_header_row.
                  IF lv_value IS INITIAL.
                    lv_value = TEXT-151.
                  ENDIF.
                  ls_header = VALUE #( col_pos = lv_col_idx
                                       descr   = lv_value ).
                  APPEND ls_header TO gt_header_list.

                ELSEIF lv_row_idx = gc_tech_row.
                  READ TABLE gt_header_list ASSIGNING FIELD-SYMBOL(<lfs_hdr>) WITH KEY col_pos = lv_col_idx BINARY SEARCH.
                  IF sy-subrc = 0.
                    PERFORM parse_header_rule USING    lv_value
                                                       lv_sheet_name
                                              CHANGING <lfs_hdr>
                                                       lt_hdr_rule_errs.
                  ENDIF.

                ELSEIF lv_row_idx >= gc_data_start AND lv_value IS NOT INITIAL.
                  ls_cell = VALUE #( row   = lv_row_idx
                                     col   = lv_col_idx
                                     value = lv_value ).
                  APPEND ls_cell TO gt_data_raw.
                ENDIF.

                lv_col_idx += 1.
              ENDDO.
            ENDLOOP.

            " Need both header metadata and body cells before build/validate.
            IF gt_header_list IS INITIAL OR gt_data_raw IS INITIAL.
              CALL FUNCTION 'POPUP_TO_INFORM'
                EXPORTING
                  titel = TEXT-126
                  txt1  = replace( val = TEXT-127 sub = '&1' with = lv_sheet_name )
                  txt2  = ''.
              CONTINUE.
            ENDIF.

            PERFORM build_dynamic_data USING    lv_sheet_name
                                       CHANGING lt_struct_errors.
            PERFORM validate_data.

            " Count only sheets that passed validation pipeline.
            lv_real_page_count += 1.

            " Persist sheet package in global multi-sheet table.
            IF gv_dref_table IS NOT INITIAL.
              APPEND VALUE #( page_no     = lv_real_page_count
                              sheet_name  = lv_sheet_name
                              header_list = gt_header_list
                              data_raw    = gt_data_raw
                              dref_data   = gv_dref_table
                              error_log   = gt_error_log ) TO gt_master_sheets.
            ENDIF.

          CATCH cx_fdt_excel_core.
            lv_read_sheet_error = abap_on.
            CONTINUE.
        ENDTRY.
      ENDLOOP.

      PERFORM show_popup_struct_err USING lt_hdr_rule_errs
                                          'RULE'.

      PERFORM show_popup_struct_err USING lt_struct_errors
                                          'TECH'.

      IF gt_master_sheets IS INITIAL AND lv_read_sheet_error = abap_off.
        gv_error = abap_on.
        MESSAGE s003 DISPLAY LIKE gc_displike_err.
        RETURN.

      ELSEIF gt_master_sheets IS INITIAL AND lv_read_sheet_error = abap_on.
        gv_error = abap_on.
        MESSAGE s059 DISPLAY LIKE gc_displike_err.
        RETURN.
      ENDIF.

    CATCH cx_fdt_excel_core INTO DATA(lx_excel_err_master).
      gv_error = abap_on.
      MESSAGE s004 WITH lx_excel_err_master->get_text( ) DISPLAY LIKE gc_displike_err.
  ENDTRY.

ENDFORM.

*&---------------------------------------------------------------------*
*& Form parse_header_rule
*& Parse tech row tokens: [KEY], *, +, [RNG:low~high], [LIST:a;b] into
*& GTY_DATA_HEADER
*&---------------------------------------------------------------------*
FORM parse_header_rule USING    pv_raw_value     TYPE string
                                pv_sheet_name    TYPE string
                       CHANGING ps_header        TYPE gty_data_header
                                pt_hdr_rule_errs TYPE string_table.

  DATA: lv_clean      TYPE string,
        lv_count      TYPE i,
        lv_float_low  TYPE string,
        lv_float_high TYPE string,
        lv_dummy      TYPE string ##NEEDED,
        lv_err_msg    TYPE string.

  lv_clean = pv_raw_value.

  lv_clean = to_upper( replace( val = lv_clean sub = ` ` with = `` occ = 0 ) ).

  " 1. CHECK DUPLICATE RULES
  FIND ALL OCCURRENCES OF PCRE '\[RNG:' IN lv_clean MATCH COUNT lv_count.
  IF lv_count > 1.
    PERFORM build_header_rule_msg USING ps_header-col_pos
                                  TEXT-136
                                  CHANGING lv_err_msg.
    PERFORM add_header_error USING    lv_err_msg
                                      pv_sheet_name
                             CHANGING pt_hdr_rule_errs.
    RETURN.
  ENDIF.

  FIND ALL OCCURRENCES OF PCRE '\[LIST:' IN lv_clean MATCH COUNT lv_count.
  IF lv_count > 1.
    PERFORM build_header_rule_msg USING    ps_header-col_pos
                                           TEXT-137
                                  CHANGING lv_err_msg.

    PERFORM add_header_error USING     lv_err_msg
                                       pv_sheet_name
                              CHANGING pt_hdr_rule_errs.
    RETURN.
  ENDIF.

  " 2. CHECK RULE CONFLICTS
  IF ( lv_clean CS '[RNG:' ) AND ( lv_clean CS '[LIST:' ).
    PERFORM build_header_rule_msg USING    ps_header-col_pos
                                           TEXT-138
                                  CHANGING lv_err_msg.

    PERFORM add_header_error USING    lv_err_msg
                                      pv_sheet_name
                             CHANGING pt_hdr_rule_errs.
    RETURN.
  ENDIF.

  IF ( lv_clean CS '[KEY]' ) AND ( lv_clean CS '[LIST:' ).
    PERFORM build_header_rule_msg USING    ps_header-col_pos
                                           TEXT-139
                                  CHANGING lv_err_msg.

    PERFORM add_header_error USING    lv_err_msg
                                      pv_sheet_name
                             CHANGING pt_hdr_rule_errs.
    RETURN.
  ENDIF.

  IF ( lv_clean CS '[KEY]' ) AND ( lv_clean CS '[RNG:' ).
    PERFORM build_header_rule_msg USING    ps_header-col_pos
                                           TEXT-145
                                  CHANGING lv_err_msg.

    PERFORM add_header_error USING    lv_err_msg
                                      pv_sheet_name
                             CHANGING pt_hdr_rule_errs.
    RETURN.
  ENDIF.

  IF ( lv_clean CS '[KEY]' ) AND ( lv_clean CS '*' ).
    PERFORM build_header_rule_msg USING    ps_header-col_pos
                                           TEXT-146
                                  CHANGING lv_err_msg.
    PERFORM add_header_error USING    lv_err_msg
                                      pv_sheet_name
                             CHANGING pt_hdr_rule_errs.
    RETURN.
  ENDIF.

  IF ( lv_clean CS '[LIST:' ) AND ( lv_clean CS '+' ).
    PERFORM build_header_rule_msg USING    ps_header-col_pos
                                           TEXT-147
                                  CHANGING lv_err_msg.

    PERFORM add_header_error USING    lv_err_msg
                                      pv_sheet_name
                             CHANGING pt_hdr_rule_errs.
    RETURN.
  ENDIF.


  " 3. PARSE BASIC FLAGS
  IF lv_clean CS '[KEY]'.
    ps_header-is_key  = abap_on.
    ps_header-is_mand = abap_on.
    lv_clean = replace( val = lv_clean pcre = '\[KEY\]' with = '' occ = 0 ).
  ENDIF.

  IF lv_clean CS '*'.
    ps_header-is_mand = abap_on.
    lv_clean = replace( val = lv_clean pcre = '\*' with = '' occ = 0 ).
  ENDIF.

  IF lv_clean CS '+'.
    ps_header-is_pos = abap_on.
    lv_clean = replace( val = lv_clean pcre = '\+' with = '' occ = 0 ).
  ENDIF.

  " 4. PARSE RANGE RULE (Strict Regex Validation)
  IF lv_clean CS '[RNG:'.
    " Regex: [RNG:min~max] allowing decimals and negative numbers
    FIND PCRE TEXT-144 IN lv_clean
         SUBMATCHES lv_float_low lv_dummy
                    lv_float_high
                    lv_dummy.

    IF sy-subrc = 0.
      TRY.
          DATA lv_swap_temp TYPE decfloat34.
          ps_header-rng_low  = lv_float_low.
          ps_header-rng_high = lv_float_high.

          " Auto-swap if Min > Max
          IF  ps_header-rng_low  >  ps_header-rng_high.
            lv_swap_temp       = ps_header-rng_low.
            ps_header-rng_low  = ps_header-rng_high.
            ps_header-rng_high = lv_swap_temp.
          ENDIF.
        CATCH cx_sy_conversion_error.
          PERFORM build_header_rule_msg USING    ps_header-col_pos
                                                 TEXT-140
                                        CHANGING lv_err_msg.

          PERFORM add_header_error USING    lv_err_msg
                                            pv_sheet_name
                                   CHANGING pt_hdr_rule_errs.
          RETURN.
      ENDTRY.

      " Remove valid RNG tag
      lv_clean = replace( val = lv_clean pcre = TEXT-144 with = '' ).
    ELSE.
      PERFORM build_header_rule_msg USING    ps_header-col_pos
                                             TEXT-141
                                    CHANGING lv_err_msg.

      PERFORM add_header_error USING    lv_err_msg
                                        pv_sheet_name
                               CHANGING pt_hdr_rule_errs.
      RETURN.
    ENDIF.
  ENDIF.

  " 5. PARSE LIST RULE (Strict Regex Validation)
  IF lv_clean CS '[LIST:'.
    " Regex: [LIST:val1,val2]
    FIND PCRE '\[LIST:([^\[\]]+)\]' IN lv_clean SUBMATCHES ps_header-val_list.

    IF sy-subrc = 0.
      " Detect empty values or consecutive commas (e.g., A,,B or starting/ending with comma)
      IF ps_header-val_list CS ',,' OR
         ps_header-val_list(1) = ',' OR
         substring( val = ps_header-val_list off = strlen( ps_header-val_list ) - 1 ) = ','.

        PERFORM build_header_rule_msg USING    ps_header-col_pos
                                               TEXT-142
                                      CHANGING lv_err_msg.

        PERFORM add_header_error USING    lv_err_msg
                                          pv_sheet_name
                                 CHANGING pt_hdr_rule_errs.
        RETURN.
      ENDIF.

      " Remove valid LIST tag
      lv_clean = replace( val = lv_clean pcre = '\[LIST:[^\[\]]+\]' with = '' ).
    ELSE.
      PERFORM build_header_rule_msg USING    ps_header-col_pos
                                             TEXT-143
                                    CHANGING lv_err_msg.

      PERFORM add_header_error USING    lv_err_msg
                                        pv_sheet_name
                               CHANGING pt_hdr_rule_errs.
      RETURN.
    ENDIF.
  ENDIF.

  ps_header-tech_name = lv_clean.

ENDFORM.

*&---------------------------------------------------------------------*
*& Form READ_EXCEL_SERVER
*& Read XLSX binary from application server path; same coordinate logic
*& as local; returns Base64 copy of file buffer for persistence layer.
*&---------------------------------------------------------------------*
FORM read_excel_server USING     pv_file       TYPE rlgrap-filename
                       CHANGING pv_file_base64 TYPE string.

  DATA: lv_file_string TYPE string,
        lv_xstring     TYPE xstring,
        lv_buffer      TYPE xstring.

  lv_file_string =  pv_file.

  " Binary read by chunk until EOF.
  OPEN DATASET lv_file_string FOR INPUT IN BINARY MODE.

  IF sy-subrc <> 0.
    MESSAGE e005.
    RETURN.
  ENDIF.

  " Append each READ buffer to full XSTRING.
  DO.
    READ DATASET lv_file_string INTO lv_buffer.
    IF sy-subrc <> 0.
      " Last partial read: append then leave loop.
      CONCATENATE lv_xstring lv_buffer INTO lv_xstring IN BYTE MODE.
      EXIT.
    ENDIF.
    CONCATENATE lv_xstring lv_buffer INTO lv_xstring IN BYTE MODE.
  ENDDO.

  CLOSE DATASET lv_file_string.

  " Side output for DB / API consumers.
  PERFORM xstring_to_base64 USING    lv_xstring
                            CHANGING pv_file_base64.

  IF p_stor = abap_on.
    RETURN.
  ENDIF.

  " Open workbook; outer TRY catches corrupt / unreadable file.
  PERFORM process_excel_workbook USING lv_file_string
                                       lv_xstring.

ENDFORM.

*&---------------------------------------------------------------------*
*& Section: CSV/TXT — lines, preview, delimited parse
*&---------------------------------------------------------------------*

*&---------------------------------------------------------------------*
*& Form READ_TEXT_LOCAL
*& CSV/TXT from PC or from persisted XSTRING (UTF-8); GT_PREVIEW_LINES;
*& optional PARSE_STRING_TO_RAW when not stored-file mode.
*&---------------------------------------------------------------------*
FORM read_text_local USING pv_file TYPE rlgrap-filename
                           pv_type TYPE char10
                           pv_data TYPE xstring.

  DATA: lt_string_tab  TYPE string_table,
        lv_file_str    TYPE string,
        lv_full_string TYPE string.

  " Branch A: content already in memory (e.g. retry from DB).
  IF pv_data IS NOT INITIAL.

    " XSTRING -> string; UTF-8 (4110) for correct multi-byte text.
    TRY.
        DATA(lo_conv) = cl_abap_conv_in_ce=>create( encoding = 'UTF-8'
                                                    input    = pv_data ).

        lo_conv->read( IMPORTING data = lv_full_string ).

      CATCH cx_parameter_invalid_range cx_sy_codepage_converter_init cx_sy_conversion_codepage cx_parameter_invalid_type.
        gv_error = abap_on.
        MESSAGE s037 DISPLAY LIKE gc_displike_err.
        RETURN.
    ENDTRY.

    " Strip UTF-8 BOM if present (common for Excel/Notepad saves).
    IF lv_full_string(1) = cl_abap_char_utilities=>byte_order_mark_utf8.
      lv_full_string = lv_full_string+1.
    ENDIF.

    " Split body into lines (CRLF first; fallback to LF-only).
    SPLIT lv_full_string AT cl_abap_char_utilities=>cr_lf INTO TABLE lt_string_tab.

    IF lines( lt_string_tab ) <= 1.
      SPLIT lv_full_string AT cl_abap_char_utilities=>newline INTO TABLE lt_string_tab.
    ENDIF.

    " Branch B: read text lines from presentation layer upload.
  ELSEIF pv_file IS NOT INITIAL.
    lv_file_str = pv_file.

    CALL METHOD cl_gui_frontend_services=>gui_upload
      EXPORTING
        filename = lv_file_str
        filetype = 'ASC'  " text mode
        codepage = '4110' " UTF-8
      CHANGING
        data_tab = lt_string_tab
      EXCEPTIONS
        OTHERS   = 1.

    IF sy-subrc <> 0.
      gv_error = abap_on.
      MESSAGE e008.
      RETURN.
    ENDIF.

  ELSE.
    gv_error = abap_on.
    MESSAGE s034 DISPLAY LIKE gc_displike_err.
    RETURN.
  ENDIF.

  " Populate preview buffer; parse delimited file unless stored artifact.
  IF lt_string_tab IS NOT INITIAL.
    gt_preview_lines = lt_string_tab.

    IF p_ftype <> gc_stored_file.
      DATA: lt_struct_errors TYPE string_table.
      PERFORM parse_string_to_raw USING    lt_string_tab pv_type
                                  CHANGING lt_struct_errors.

    ENDIF.

  ELSE.
    gv_error = abap_on.
    MESSAGE s064 DISPLAY LIKE gc_displike_err.
  ENDIF.

ENDFORM.

*&---------------------------------------------------------------------*
*& Form READ_TEXT_SERVER
*& Read UTF-8 text file on server; Base64 export; same preview/parse path.
*&---------------------------------------------------------------------*
FORM read_text_server USING    pv_file        TYPE rlgrap-filename
                               pv_type        TYPE char10
                      CHANGING pv_file_base64 TYPE string.

  DATA: lt_string_tab TYPE string_table,
        lv_line       TYPE string,
        lv_file_str   TYPE string.

  lv_file_str = pv_file.

  OPEN DATASET lv_file_str FOR INPUT IN TEXT MODE ENCODING UTF-8.
  IF sy-subrc = 0.
    DO.
      READ DATASET lv_file_str INTO lv_line.
      IF sy-subrc <> 0.
        EXIT.
      ENDIF.

      " Strip out any trailing control characters (CR, LF, TAB, NULL, etc.) from the end of the string
      REPLACE PCRE '[[:cntrl:]]+$' IN lv_line WITH ''.

      " Clean up any leftover whitespaces
*      CONDENSE lv_line. !OBSOLETE SYNTAX
      lv_line = condense( val = lv_line ).  " Safely removes leading/trailing spaces and compresses inner spaces
      APPEND lv_line TO lt_string_tab.

    ENDDO.
    CLOSE DATASET lv_file_str.

    DATA: lv_xstring     TYPE xstring,
          lv_full_string TYPE string.

    CONCATENATE LINES OF lt_string_tab INTO lv_full_string
      SEPARATED BY cl_abap_char_utilities=>newline.

    DATA(lo_conv) = cl_abap_conv_out_ce=>create( encoding = 'UTF-8' ).

    lo_conv->convert(
      EXPORTING
        data   = lv_full_string
      IMPORTING
        buffer = lv_xstring ).

    PERFORM xstring_to_base64 USING    lv_xstring
                              CHANGING pv_file_base64.

    IF p_stor = abap_on.
      RETURN.
    ENDIF.

    IF lt_string_tab IS NOT INITIAL.
      gt_preview_lines = lt_string_tab.

      IF p_ftype <> gc_stored_file.
        DATA: lt_struct_errors TYPE string_table.
        PERFORM parse_string_to_raw USING    lt_string_tab pv_type
                                    CHANGING lt_struct_errors.
      ENDIF.

    ELSE.
      gv_error = abap_on.
      MESSAGE s064 DISPLAY LIKE gc_displike_err.
    ENDIF.


  ELSE.
    gv_error = abap_on.
    MESSAGE s009 DISPLAY LIKE gc_displike_err.
  ENDIF.
ENDFORM.

*&---------------------------------------------------------------------*
*& Form PARSE_STRING_TO_RAW
*& Core CSV/TXT path: split lines by separator -> GT_HEADER_LIST /
*& GT_EXCEL_RAW, then BUILD_DYNAMIC_DATA + VALIDATE + single GT_MASTER_SHEETS row.
*&---------------------------------------------------------------------*
FORM parse_string_to_raw USING    pt_string_tab    TYPE string_table
                                  pv_type          TYPE char10
                         CHANGING pt_struct_errors TYPE string_table.

  DATA: lt_cols          TYPE TABLE OF string,
        lv_val           TYPE string,
        ls_cell          TYPE gty_data_cell,
        ls_header        TYPE gty_data_header,
        lv_row           TYPE i,
        lv_col           TYPE i,
        lv_sep           TYPE char1,
        lt_hdr_rule_errs TYPE string_table.

  IF pv_type = gc_ftype_csv.
    lv_sep = ','.
  ELSEIF pv_type = gc_ftype_txt.
    lv_sep = cl_abap_char_utilities=>horizontal_tab. " tab-delimited TXT
  ENDIF.

  CLEAR: gt_header_list, gt_data_raw, gt_master_sheets, gt_error_log.

  LOOP AT pt_string_tab INTO DATA(lv_line).
    lv_row = sy-tabix.
    CLEAR lt_cols.

    REPLACE ALL OCCURRENCES OF cl_abap_char_utilities=>cr_lf+0(1) IN lv_line WITH ''.

    SPLIT lv_line AT lv_sep INTO TABLE lt_cols.

    lv_col = 1.
    LOOP AT lt_cols INTO lv_val.
*      CONDENSE lv_val.   !OBSOLETE SYNTAX
      lv_val = condense( val = lv_val ).

      IF lv_row = gc_header_row.
        IF lv_val IS INITIAL.
          lv_val = TEXT-151.
        ENDIF.
        ls_header-col_pos = lv_col.
        ls_header-descr   = lv_val.
        APPEND ls_header TO gt_header_list.

      ELSEIF lv_row = gc_tech_row.
        SORT gt_header_list BY col_pos.
        READ TABLE gt_header_list ASSIGNING FIELD-SYMBOL(<lfs_hdr>) WITH KEY col_pos = lv_col BINARY SEARCH.
        IF sy-subrc = 0.
          PERFORM parse_header_rule USING    lv_val
                                             ''
                                    CHANGING <lfs_hdr>
                                             lt_hdr_rule_errs.
        ENDIF.

      ELSEIF lv_row >= gc_data_start.
        IF lv_val IS NOT INITIAL.
          ls_cell-row   = lv_row.
          ls_cell-col   = lv_col.
          ls_cell-value = lv_val.
          APPEND ls_cell TO gt_data_raw.
        ENDIF.
      ENDIF.

      lv_col = lv_col + 1.
    ENDLOOP.
  ENDLOOP.

  IF gt_header_list IS NOT INITIAL.
    PERFORM build_dynamic_data USING    ''
                               CHANGING pt_struct_errors.

    PERFORM show_popup_struct_err USING lt_hdr_rule_errs
                                        'RULE'.

    PERFORM show_popup_struct_err USING pt_struct_errors
                                        'TECH'.

    IF gv_error = abap_on.
      RETURN.
    ENDIF.

    PERFORM validate_data.

    IF gt_data_raw IS INITIAL.
      MESSAGE s079 DISPLAY LIKE gc_displike_err.
      gv_error = abap_on.
      RETURN.
    ENDIF.

    APPEND VALUE #( page_no     = 1
                    sheet_name  = ''
                    header_list = gt_header_list
                    data_raw    = gt_data_raw
                    dref_data   = gv_dref_table
                    error_log   = gt_error_log ) TO gt_master_sheets.
  ELSE.
    MESSAGE s078 DISPLAY LIKE gc_displike_err.
    gv_error = abap_on.
    RETURN.
  ENDIF.

ENDFORM.
*&---------------------------------------------------------------------*
*& Form show_popup_struct_err
*&---------------------------------------------------------------------*
FORM show_popup_struct_err  USING pt_struct_errors TYPE string_table
                                  pv_err_type      TYPE char4.

  IF pt_struct_errors IS INITIAL.
    RETURN.
  ENDIF.

  " Build display table with full-length string column.
  TYPES: BEGIN OF ty_err_line,
           message TYPE string,
         END OF ty_err_line.

  DATA: lt_display TYPE TABLE OF ty_err_line,
        ls_display TYPE ty_err_line,
        lo_salv    TYPE REF TO cl_salv_table,
        lv_title   TYPE string.

  " Header line.
  ls_display-message = COND #( WHEN pv_err_type = 'TECH' THEN TEXT-045
                               WHEN pv_err_type = 'RULE' THEN TEXT-135 ).
  APPEND ls_display TO lt_display.

  " Error lines.
  LOOP AT pt_struct_errors INTO DATA(lv_err).
    ls_display-message = lv_err.
    APPEND ls_display TO lt_display.
  ENDLOOP.

  " Footer line.
  ls_display-message = TEXT-046.
  APPEND ls_display TO lt_display.

  " Title for popup.
  lv_title = ''.

  TRY.
      cl_salv_table=>factory(
        IMPORTING r_salv_table = lo_salv
        CHANGING  t_table      = lt_display ).

      " Popup mode with size.
      lo_salv->set_screen_popup(
        start_column = 5
        end_column   = 100
        start_line   = 3
        end_line     = 20 ).

      " Column settings: auto-width for full text.
      DATA(lo_cols) = lo_salv->get_columns( ).
      lo_cols->set_optimize( abap_on ).

      TRY.
          DATA(lo_col) = lo_cols->get_column( 'MESSAGE' ).
          lo_col->set_long_text( CONV #( lv_title ) ).
        CATCH cx_salv_not_found.                        "#EC NO_HANDLER
      ENDTRY.

      " Display header settings.
      DATA(lo_display) = lo_salv->get_display_settings( ).
      lo_display->set_list_header( CONV #( lv_title ) ).
      lo_display->set_striped_pattern( abap_on ).

      lo_salv->display( ).

    CATCH cx_salv_msg.                                  "#EC NO_HANDLER
  ENDTRY.

  gv_error = abap_on.
  MESSAGE s034 DISPLAY LIKE gc_displike_err.
ENDFORM.
