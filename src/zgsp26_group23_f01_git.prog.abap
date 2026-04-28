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
*& Section: XLSX - local (frontend upload) and server (AL11)
*&---------------------------------------------------------------------*

*&---------------------------------------------------------------------*
*& Form READ_EXCEL_LOCAL
*& Optional binary upload from PC; FDT spreadsheet per sheet; fill
*& GT_MASTER_SHEETS with parsed headers/raw/errors per valid sheet.
*&---------------------------------------------------------------------*
FORM read_excel_local USING pv_file    TYPE rlgrap-filename
                           pv_data          TYPE xstring.

  DATA(lv_file_string) = CONV string( pv_file ).

  DATA: lo_excel      TYPE REF TO cl_fdt_xl_spreadsheet,
        lv_xstring    TYPE xstring,
        lt_worksheets TYPE if_fdt_doc_spreadsheet=>t_worksheet_names,
        lt_raw        TYPE solix_tab,
        lv_size       TYPE i.

  FIELD-SYMBOLS: <lfs_excel_data> TYPE STANDARD TABLE.

  lv_xstring = pv_data.

  IF pv_data IS INITIAL.

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
    IF sy-subrc <> 0. gv_error = abap_on. RETURN. ENDIF.

    CALL FUNCTION 'SCMS_BINARY_TO_XSTRING'
      EXPORTING
        input_length = lv_size
      IMPORTING
        buffer       = lv_xstring
      TABLES
        binary_tab   = lt_raw
      EXCEPTIONS
        OTHERS       = 1.
    IF sy-subrc <> 0. gv_error = abap_on. RETURN. ENDIF.

  ENDIF.


  " Open workbook; outer TRY catches corrupt / unreadable file.
  TRY.
      lo_excel = NEW cl_fdt_xl_spreadsheet( document_name = lv_file_string xdocument = lv_xstring ).
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
              RAISE EXCEPTION TYPE cx_fdt_excel_core.
            ENDIF.

            " Bind returned dynamic table.
            ASSIGN lo_data->* TO <lfs_excel_data>.


            " Skip completely empty sheets.
            IF <lfs_excel_data> IS NOT ASSIGNED OR lines( <lfs_excel_data> ) = 0.
              CONTINUE.
            ENDIF.

            " Scan grid: header row, tech row (rules), data cells -> GT_* .
            DATA: ls_header TYPE gty_data_header, ls_cell TYPE gty_data_cell.
            LOOP AT <lfs_excel_data> ASSIGNING FIELD-SYMBOL(<lfs_row>).
              DATA(lv_row_idx) = sy-tabix.
              DATA(lv_col_idx) = 1.

              DO.
                ASSIGN COMPONENT lv_col_idx OF STRUCTURE <lfs_row> TO FIELD-SYMBOL(<lfs_field>).
                IF sy-subrc <> 0. EXIT. ENDIF.

                DATA(lv_value) = condense( CONV string( <lfs_field> ) ).

                IF lv_row_idx = gc_header_row AND lv_value IS NOT INITIAL.
                  ls_header = VALUE #( col_pos = lv_col_idx descr = lv_value ).
                  APPEND ls_header TO gt_header_list.
                ELSEIF lv_row_idx = gc_tech_row.
                  SORT gt_header_list BY col_pos.
                  READ TABLE gt_header_list ASSIGNING FIELD-SYMBOL(<lfs_hdr>) WITH KEY col_pos = lv_col_idx BINARY SEARCH.
                  IF sy-subrc = 0.
                    PERFORM f01_parse_header_rule USING    lv_value
                                                           lv_sheet_name
                                                  CHANGING <lfs_hdr>
                                                           lt_hdr_rule_errs.
                  ENDIF.
                ELSEIF lv_row_idx >= gc_data_start AND lv_value IS NOT INITIAL.
                  ls_cell = VALUE #( row = lv_row_idx col = lv_col_idx value = lv_value ).
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
                              error_log   = gt_error_log
                              is_parsed   = abap_on ) TO gt_master_sheets.
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

      gv_total_pages = lines( gt_master_sheets ).

      IF gv_total_pages = 0 AND lv_read_sheet_error = abap_off.
        gv_error = abap_on.
        MESSAGE s003(zmsg_gr23) DISPLAY LIKE gc_displike_err.
        RETURN.
      ELSEIF gv_total_pages = 0 AND lv_read_sheet_error = abap_on.
        gv_error = abap_on.
        MESSAGE s059(zmsg_gr23) DISPLAY LIKE gc_displike_err.
        RETURN.
      ENDIF.

    CATCH cx_fdt_excel_core INTO DATA(lx_excel_err_master).
      gv_error = abap_on.
      MESSAGE s004(zmsg_gr23) WITH lx_excel_err_master->get_text( ) DISPLAY LIKE gc_displike_err.
  ENDTRY.

ENDFORM.

*&---------------------------------------------------------------------*
*& Form READ_EXCEL_SERVER
*& Read XLSX binary from application server path; same coordinate logic
*& as local; returns Base64 copy of file buffer for persistence layer.
*&---------------------------------------------------------------------*
FORM read_excel_server USING pv_file TYPE rlgrap-filename
                       CHANGING pv_file_base64 TYPE string.

  DATA(lv_file_string) = CONV string( pv_file ).

  DATA: lv_xstring       TYPE xstring,
        lv_buffer        TYPE xstring,
        lo_excel         TYPE REF TO cl_fdt_xl_spreadsheet,
        lt_worksheets    TYPE if_fdt_doc_spreadsheet=>t_worksheet_names,
        lt_struct_errors TYPE string_table,
        lt_hdr_rule_errs TYPE string_table.

  FIELD-SYMBOLS: <lfs_excel_data> TYPE STANDARD TABLE.
  " Binary read by chunk until EOF.
  OPEN DATASET lv_file_string FOR INPUT IN BINARY MODE.

  IF sy-subrc <> 0.
    MESSAGE e005(zmsg_gr23).
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

  CHECK p_val = abap_on.

  TRY.
      lo_excel = NEW cl_fdt_xl_spreadsheet( document_name = lv_file_string xdocument = lv_xstring ).
      lo_excel->if_fdt_doc_spreadsheet~get_worksheet_names( IMPORTING worksheet_names = lt_worksheets ).

      CLEAR gt_master_sheets.
      DATA(lv_real_page_count) = 0.

      LOOP AT lt_worksheets INTO DATA(lv_sheet_name).

        IF gv_error = abap_on.
          EXIT.
        ENDIF.
        CLEAR: gt_header_list, gt_data_raw, gt_error_log.
        UNASSIGN <gfs_data>.

        TRY.
            DATA(lo_data) = lo_excel->if_fdt_doc_spreadsheet~get_itab_from_worksheet( lv_sheet_name ).
            ASSIGN lo_data->* TO <lfs_excel_data>.

            IF <lfs_excel_data> IS NOT ASSIGNED OR lines( <lfs_excel_data> ) = 0.
              CONTINUE.
            ENDIF.

            DATA: ls_header TYPE gty_data_header,
                  ls_cell   TYPE gty_data_cell.

            LOOP AT <lfs_excel_data> ASSIGNING FIELD-SYMBOL(<lfs_row>).
              DATA(lv_row_idx) = sy-tabix.
              DATA(lv_col_idx) = 1.

              DO.
                ASSIGN COMPONENT lv_col_idx OF STRUCTURE <lfs_row> TO FIELD-SYMBOL(<lfs_field>).
                IF sy-subrc <> 0. EXIT. ENDIF.

                DATA(lv_value) = condense( CONV string( <lfs_field> ) ).

                IF lv_row_idx = gc_header_row AND lv_value IS NOT INITIAL.
                  ls_header = VALUE #( col_pos = lv_col_idx descr = lv_value ).
                  APPEND ls_header TO gt_header_list.
                ELSEIF lv_row_idx = gc_tech_row.
                  SORT gt_header_list BY col_pos.
                  READ TABLE gt_header_list ASSIGNING FIELD-SYMBOL(<lfs_hdr>) WITH KEY col_pos = lv_col_idx BINARY SEARCH.
                  IF sy-subrc = 0.
                    PERFORM f01_parse_header_rule USING    lv_value
                                                           lv_sheet_name
                                                  CHANGING <lfs_hdr>
                                                           lt_hdr_rule_errs.
                  ENDIF.
                ELSEIF lv_row_idx >= gc_data_start AND lv_value IS NOT INITIAL.
                  ls_cell = VALUE #( row = lv_row_idx col = lv_col_idx value = lv_value ).
                  APPEND ls_cell TO gt_data_raw.
                ENDIF.

                lv_col_idx += 1.
              ENDDO.
            ENDLOOP.

            IF gt_header_list IS NOT INITIAL.

              PERFORM build_dynamic_data USING    lv_sheet_name
                                         CHANGING lt_struct_errors.
              PERFORM validate_data.

              lv_real_page_count += 1.

              APPEND VALUE #( page_no     = lv_real_page_count
                              sheet_name  = lv_sheet_name
                              header_list = gt_header_list
                              data_raw   = gt_data_raw
                              dref_data   = gv_dref_table
                              error_log   = gt_error_log
                              is_parsed   = abap_on ) TO gt_master_sheets.
            ENDIF.

          CATCH cx_fdt_excel_core.
            CONTINUE.
        ENDTRY.
      ENDLOOP.

      PERFORM show_popup_struct_err USING lt_hdr_rule_errs
                                          'RULE'.

      PERFORM show_popup_struct_err USING lt_struct_errors
                                          'TECH'.

    gv_total_pages = lines( gt_master_sheets ).

    IF gv_total_pages = 0.
      MESSAGE s003(zmsg_gr23) DISPLAY LIKE gc_displike_err.
      gv_error = abap_on.
      RETURN.
    ENDIF.

    PERFORM load_page_to_workspace USING 1.

  CATCH cx_fdt_excel_core INTO DATA(lx_excel_err_master).
    MESSAGE s004(zmsg_gr23) WITH lx_excel_err_master->get_text( ) DISPLAY LIKE gc_displike_err.
    gv_error = abap_on.
ENDTRY.

ENDFORM.

*&---------------------------------------------------------------------*
*& Section: Client / server file pickers
*&---------------------------------------------------------------------*

*&---------------------------------------------------------------------*
*& Form BROWSE_FILE
*& Frontend F4: single XLSX selection into PV_FILE.
*&---------------------------------------------------------------------*
FORM browse_file  CHANGING pv_file TYPE rlgrap-filename.

  DATA: lt_file_table TYPE filetable,
        ls_file_table TYPE file_table,
        lv_rc         TYPE i,
        lv_action     TYPE i.

  CALL METHOD cl_gui_frontend_services=>file_open_dialog
    EXPORTING
      window_title            = |{ TEXT-042 }|
      default_extension       = 'xlsx'
      file_filter             = |{ TEXT-043 }|
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
*& Form F01_PARSE_HEADER_RULE
*& Parse tech row tokens: [KEY], *, +, [RNG:low~high], [LIST:a;b] into
*& GTY_DATA_HEADER
*&---------------------------------------------------------------------*
FORM f01_parse_header_rule USING    pv_raw_value     TYPE string
                                    pv_sheet_name    TYPE string
                           CHANGING ps_header        TYPE gty_data_header
                                    pt_hdr_rule_errs TYPE string_table.

  DATA: lv_clean      TYPE string,
        lv_count      TYPE i,
        lv_float_low  TYPE string,
        lv_float_high TYPE string,
        lv_dummy      TYPE string,
        lv_err_msg    TYPE string.

*  ps_header-is_invalid = abap_false.
  lv_clean = pv_raw_value.

  " 1. CHECK DUPLICATE RULES
  FIND ALL OCCURRENCES OF PCRE '\[RNG:' IN lv_clean MATCH COUNT lv_count.
  IF lv_count > 1.
*    ps_header-is_invalid = abap_true.
    lv_err_msg = |Column { ps_header-col_pos }: Syntax Error: Multiple [RNG] tags found in one column.|.
    PERFORM add_header_error USING    lv_err_msg
                                      pv_sheet_name
                             CHANGING pt_hdr_rule_errs.
    RETURN.
  ENDIF.

  FIND ALL OCCURRENCES OF PCRE '\[LIST:' IN lv_clean MATCH COUNT lv_count.
  IF lv_count > 1.
*    ps_header-is_invalid = abap_true.
    lv_err_msg = |Column { ps_header-col_pos }: Syntax Error: Multiple [LIST] tags found in one column.|.
    PERFORM add_header_error USING    lv_err_msg
                                       pv_sheet_name
                              CHANGING pt_hdr_rule_errs.
    RETURN.
  ENDIF.

  " 2. CHECK RULE CONFLICTS
  IF ( lv_clean CS '[RNG:' ) AND ( lv_clean CS '[LIST:' ).
*    ps_header-is_invalid = abap_true.
    lv_err_msg = |Column { ps_header-col_pos }: Syntax Error: [RNG] and [LIST] cannot be used together.|.
    PERFORM add_header_error USING    lv_err_msg
                                       pv_sheet_name
                              CHANGING pt_hdr_rule_errs.
    RETURN.
  ENDIF.

  IF ( lv_clean CS '[KEY]' ) AND ( lv_clean CS '[LIST:' ).
*    ps_header-is_invalid = abap_true.
    lv_err_msg = |Column { ps_header-col_pos }: Logic Error: Primary Key [KEY] should not be restricted by [LIST].|.
    PERFORM add_header_error USING    lv_err_msg
                                         pv_sheet_name
                              CHANGING pt_hdr_rule_errs.
    RETURN.
  ENDIF.

  " 3. PARSE BASIC FLAGS
  IF lv_clean CS '[KEY]'.
    ps_header-is_key = abap_true.
    lv_clean = replace( val = lv_clean pcre = '\[KEY\]' with = '' occ = 0 ).
  ENDIF.

  IF lv_clean CS '*'.
    ps_header-is_mand = abap_true.
    lv_clean = replace( val = lv_clean pcre = '\*' with = '' occ = 0 ).
  ENDIF.

  IF lv_clean CS '+'.
    ps_header-is_pos = abap_true.
    lv_clean = replace( val = lv_clean pcre = '\+' with = '' occ = 0 ).
  ENDIF.

  " 4. PARSE RANGE RULE (Strict Regex Validation)
  IF lv_clean CS '[RNG:'.
    " Regex: [RNG:min~max] allowing decimals and negative numbers
    FIND PCRE '\[RNG:(-?\d+(\.\d+)?)\~(-?\d+(\.\d+)?)\]' IN lv_clean
         SUBMATCHES lv_float_low lv_dummy lv_float_high lv_dummy.

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
*          ps_header-is_invalid = abap_true.
          lv_err_msg = |Column { ps_header-col_pos }: Logic Error: Failed to convert [RNG] values to numbers.|.
          PERFORM add_header_error USING    lv_err_msg
                                            pv_sheet_name
                                   CHANGING pt_hdr_rule_errs.
          RETURN.
      ENDTRY.

      " Remove valid RNG tag
      lv_clean = replace( val = lv_clean pcre = '\[RNG:-?\d+(\.\d+)?\~-?\d+(\.\d+)?\]' with = '' ).
    ELSE.
*      ps_header-is_invalid = abap_true.
      lv_err_msg = |Column { ps_header-col_pos }: Syntax Error: Invalid [RNG] format. Expected: [RNG:min~max] without extra characters.|.
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

*        ps_header-is_invalid = abap_true.
        lv_err_msg = |Column { ps_header-col_pos }: Syntax Error: [LIST] contains consecutive or dangling commas.|.
        PERFORM add_header_error USING    lv_err_msg
                                          pv_sheet_name
                                 CHANGING pt_hdr_rule_errs.
        RETURN.
      ENDIF.

      " Remove valid LIST tag
      lv_clean = replace( val = lv_clean pcre = '\[LIST:[^\[\]]+\]' with = '' ).
    ELSE.
*      ps_header-is_invalid = abap_true.
      lv_err_msg = |Column { ps_header-col_pos }: Syntax Error: Invalid [LIST] format. Nested brackets are not allowed.|.
      PERFORM add_header_error USING    lv_err_msg
                                        pv_sheet_name
                               CHANGING pt_hdr_rule_errs.
      RETURN.
    ENDIF.
  ENDIF.

ENDFORM.
*FORM f01_parse_header_rule  USING    pv_value TYPE string
*                            CHANGING ps_header TYPE gty_data_header.
*
*  DATA: lv_temp       TYPE string ##NEEDED,
*        lv_rule       TYPE string,
*        lv_clean      TYPE string,
*        lv_remove_str TYPE string.
*
*  " Start from full raw token string.
*  lv_clean = pv_value.
*
*  IF lv_clean CS '+'.
*    ps_header-is_pos = abap_on.
*    REPLACE ALL OCCURRENCES OF '+' IN lv_clean WITH ''. " remove positive-only marker
*  ENDIF.
*
*  IF lv_clean CS '[KEY]'.
*    ps_header-is_key = abap_on.
*    REPLACE ALL OCCURRENCES OF '[KEY]' IN lv_clean WITH ''.
*  ENDIF.
*
*  IF lv_clean CS '*'.
*    ps_header-is_mand = abap_on.
*    REPLACE ALL OCCURRENCES OF '*' IN lv_clean WITH ''. " remove mandatory marker
*  ENDIF.
*
*  IF lv_clean CS '[RNG:'.
*
*    DATA: lv_float_low  TYPE string,
*          lv_float_high TYPE string.
*
*    SPLIT lv_clean  AT '[RNG:' INTO lv_temp lv_rule.
*    SPLIT lv_rule   AT ']'     INTO lv_rule lv_temp.
*    SPLIT lv_rule   AT '~'     INTO lv_float_low lv_float_high.
*
*    IF lv_float_high IS NOT INITIAL AND lv_float_low IS NOT INITIAL.
*      TRY.
*
*          DATA:lv_swap_temp  TYPE decfloat34.
*
*          ps_header-rng_low  = lv_float_low.
*          ps_header-rng_high = lv_float_high.
*
*          IF ps_header-rng_low > ps_header-rng_high.
*            lv_swap_temp       = ps_header-rng_low.
*            ps_header-rng_low  = ps_header-rng_high.
*            ps_header-rng_high = lv_swap_temp.
*          ENDIF.
*
*        CATCH cx_sy_conversion_error.
*          CLEAR: ps_header-rng_low, ps_header-rng_high.
*      ENDTRY.
*    ENDIF.
*
*    CONCATENATE '[RNG:' lv_rule ']' INTO lv_remove_str.
*    REPLACE ALL OCCURRENCES OF lv_remove_str IN lv_clean WITH ''.
*  ENDIF.
*
*  IF lv_clean CS '[LIST:'.
*    SPLIT lv_clean AT '[LIST:' INTO lv_temp lv_rule.
*    SPLIT lv_rule  AT ']'      INTO ps_header-val_list lv_temp.
*    CONCATENATE '[LIST:' ps_header-val_list ']' INTO lv_remove_str.
*    REPLACE ALL OCCURRENCES OF lv_remove_str IN lv_clean WITH ''.
*  ENDIF.
*
*  lv_clean = to_upper( replace( val = lv_clean sub = ` ` with = `` occ = 0 ) ).
*
*  ps_header-tech_name = lv_clean.
*
*ENDFORM.

*&---------------------------------------------------------------------*
*& Section: CSV/TXT — lines, preview, delimited parse
*&---------------------------------------------------------------------*

*&---------------------------------------------------------------------*
*& Form READ_TEXT_LOCAL
*& CSV/TXT from PC or from persisted XSTRING (UTF-8); GT_PREVIEW_LINES;
*& optional PARSE_STRING_TO_RAW when not stored-file mode.
*&---------------------------------------------------------------------*
FORM read_text_local USING pv_file          TYPE rlgrap-filename
                           pv_type          TYPE char10
                           pv_data          TYPE xstring.

  DATA: lt_string_tab  TYPE string_table,
        lv_file_str    TYPE string,
        lv_full_string TYPE string.

  " Branch A: content already in memory (e.g. retry from DB).
  IF pv_data IS NOT INITIAL.

    " XSTRING -> string; UTF-8 (4110) for correct multi-byte text.
    TRY.
        DATA(lo_conv) = cl_abap_conv_in_ce=>create(
                          encoding = 'UTF-8'
                          input    = pv_data ).

        lo_conv->read( IMPORTING data = lv_full_string ).

      CATCH cx_parameter_invalid_range cx_sy_codepage_converter_init cx_sy_conversion_codepage cx_parameter_invalid_type.
        gv_error = abap_on.
        MESSAGE s037(zmsg_gr23) DISPLAY LIKE gc_displike_err.
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
      MESSAGE e008(zmsg_gr23).
      RETURN.
    ENDIF.

  ELSE.
    gv_error = abap_on.
    MESSAGE s034(zmsg_gr23) DISPLAY LIKE gc_displike_err.
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
    MESSAGE s064(zmsg_gr23) DISPLAY LIKE gc_displike_err.
  ENDIF.

ENDFORM.

*&---------------------------------------------------------------------*
*& Form READ_TEXT_SERVER
*& Read UTF-8 text file on server; Base64 export; same preview/parse path.
*&---------------------------------------------------------------------*
FORM read_text_server USING    pv_file          TYPE rlgrap-filename
                               pv_type          TYPE char10
                      CHANGING pv_file_base64   TYPE string.

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

    CHECK p_val = abap_on.

    IF lt_string_tab IS NOT INITIAL.
      gt_preview_lines = lt_string_tab.

      IF p_ftype <> gc_stored_file.
        DATA: lt_struct_errors TYPE string_table.
        PERFORM parse_string_to_raw USING    lt_string_tab pv_type
                                    CHANGING lt_struct_errors.
      ENDIF.

    ELSE.
      gv_error = abap_on.
      MESSAGE s064(zmsg_gr23) DISPLAY LIKE gc_displike_err.
    ENDIF.


  ELSE.
    gv_error = abap_on.
    MESSAGE s009(zmsg_gr23) DISPLAY LIKE gc_displike_err.
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

  CLEAR: gt_header_list, gt_data_raw, gt_master_sheets.

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
        IF lv_val IS NOT INITIAL.
          ls_header-col_pos = lv_col.
          ls_header-descr   = lv_val.
          APPEND ls_header TO gt_header_list.
        ENDIF.

      ELSEIF lv_row = gc_tech_row.
        SORT gt_header_list BY col_pos.
        READ TABLE gt_header_list ASSIGNING FIELD-SYMBOL(<lfs_hdr>) WITH KEY col_pos = lv_col BINARY SEARCH.
        IF sy-subrc = 0.
          PERFORM f01_parse_header_rule USING    lv_val
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

    CHECK gv_error = abap_off.

    PERFORM validate_data.

    APPEND VALUE #( page_no     = 1
                    sheet_name  = ''
                    header_list = gt_header_list
                    data_raw    = gt_data_raw
                    dref_data   = gv_dref_table
                    error_log   = gt_error_log
                    is_parsed   = abap_on ) TO gt_master_sheets.
  ENDIF.

ENDFORM.
*&---------------------------------------------------------------------*
*& Form show_popup_struct_err
*&---------------------------------------------------------------------*
*& text
*&---------------------------------------------------------------------*
*&      --> LT_STRUCT_ERRORS
*&---------------------------------------------------------------------*
FORM show_popup_struct_err  USING    pt_struct_errors TYPE string_table
                                     pv_err_type      TYPE char4.
  IF pt_struct_errors IS NOT INITIAL.
    DATA: lt_err_display TYPE TABLE OF char200,
          ls_err_line    TYPE char200.

    CLEAR lt_err_display.
    ls_err_line = COND #( WHEN pv_err_type = 'TECH' THEN TEXT-045
                          WHEN pv_err_type = 'RULE' THEN TEXT-135 ).
    APPEND ls_err_line TO lt_err_display.
    LOOP AT pt_struct_errors INTO DATA(lv_struct_err).
      ls_err_line = |{ lv_struct_err }|.
      APPEND ls_err_line TO lt_err_display.
    ENDLOOP.
    ls_err_line = TEXT-046.
    APPEND ls_err_line TO lt_err_display.

    CALL FUNCTION 'POPUP_WITH_TABLE_DISPLAY'
      EXPORTING
        endpos_col   = 100
        endpos_row   = 20
        startpos_col = 5
        startpos_row = 3
        titletext    = TEXT-045
      TABLES
        valuetab     = lt_err_display
      EXCEPTIONS
        break_off    = 1
        OTHERS       = 2.
    IF sy-subrc <> 0.                                     "#EC CI_SUBRC
    ENDIF.

    gv_error = abap_on.
    MESSAGE s034(zmsg_gr23) DISPLAY LIKE gc_displike_err.
    RETURN.
  ENDIF.
ENDFORM.
