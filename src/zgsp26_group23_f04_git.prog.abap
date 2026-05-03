*&---------------------------------------------------------------------*
*& Include          ZGSP26_GROUP23_F04
*&---------------------------------------------------------------------*

*&---------------------------------------------------------------------*
*& Purpose
*&  Upload history UI: query ZLOG_HEADER for current user, ALV on screen
*&  200, batch/single download from ZLOG_ITEM (Base64), reopen log into
*&  preview or full reload, SMW0 template ZIP download.
*&---------------------------------------------------------------------*

*&---------------------------------------------------------------------*
*& Section: History list (screen 200)
*&---------------------------------------------------------------------*

*&---------------------------------------------------------------------*
*& Form VIEW_HISTORY_SCREEN
*& Build date/type ranges from selection screen, SELECT ZLOG_HEADER, then
*& CALL SCREEN 0200 (empty list -> message and RETURN).
*&---------------------------------------------------------------------*
FORM view_history_screen.

  PERFORM load_history_data.

  CALL SCREEN 0200.

ENDFORM.

*&---------------------------------------------------------------------*
*& Form REFRESH_HISTORY_ALV
*& Re-run the same SELECT as VIEW_HISTORY_SCREEN, then update ALV title and
*& refresh_table_display with stable row/col (keeps scroll/selection).
*&---------------------------------------------------------------------*
FORM refresh_history_alv.

  PERFORM load_history_data.

  " Refresh existing history ALV (after returning from drill-down screen).
  IF go_grid_hist IS BOUND.
    DATA: ls_layout        TYPE lvc_s_layo,
          lv_grid_title    TYPE string,
          lv_history_count TYPE i.

    go_grid_hist->get_frontend_layout( IMPORTING es_layout = ls_layout ).
    lv_history_count = lines( gt_history_list ).
    PERFORM get_history_grid_title USING    p_date
                                            lv_history_count
                                   CHANGING lv_grid_title.

    ls_layout-grid_title = lv_grid_title.
    go_grid_hist->set_frontend_layout( ls_layout ).

    " Refresh grid (keep scroll position and current row selection).
    go_grid_hist->refresh_table_display( is_stable = VALUE #( row = abap_on col = abap_on ) ).
  ENDIF.

ENDFORM.

*&---------------------------------------------------------------------*
*& Form BUILD_HISTORY_ALV_GRID
*& One-time: CC_HISTORY + grid, layout (sel_mode D = multi-select), FCAT,
*& toolbar excludes, double-click handler; else only refresh display.
*&---------------------------------------------------------------------*
FORM build_history_alv_grid.

  DATA: ls_layout        TYPE lvc_s_layo,
        lt_fcat          TYPE lvc_t_fcat,
        lt_exclude       TYPE ui_functions,
        lv_grid_title    TYPE string,
        lv_history_count TYPE i.

  " Initialize container + grid only once per session.
  IF go_cont_hist IS NOT BOUND.

    go_cont_hist = NEW #(
      container_name = 'CC_HISTORY'
    ).

    go_grid_hist = NEW #(
      i_parent = go_cont_hist
    ).

    " Layout: sel_mode 'D' allows Ctrl+click multi row selection (batch download).
    ls_layout-zebra      = abap_on.
    ls_layout-cwidth_opt = abap_on.
    ls_layout-sel_mode   = 'D'.
    ls_layout-ctab_fname = 'CELL_COL'.

    lv_history_count = lines( gt_history_list ).
    PERFORM get_history_grid_title USING    p_date
                                            lv_history_count
                                   CHANGING lv_grid_title.
    ls_layout-grid_title = lv_grid_title.

    " Field catalog for history columns.
    lt_fcat = VALUE #(
      ( fieldname = 'LOG_ID'      coltext = TEXT-008 key  = abap_on outputlen = 32 )
      ( fieldname = 'FILE_TYPE'   coltext = TEXT-009 just = 'C' )
      ( fieldname = 'FILE_NAME'   coltext = TEXT-125 just = 'C' )
      ( fieldname = 'CATEGORY'    coltext = TEXT-010 just = 'C' emphasize = 'C500' )
      ( fieldname = 'TOTAL_SHEET' coltext = TEXT-013 just = 'R' )
      ( fieldname = 'TOTAL_REC'   coltext = TEXT-011 just = 'R' )
      ( fieldname = 'SUCC_REC'    coltext = TEXT-012 just = 'R' )
      ( fieldname = 'ERR_REC'     coltext = TEXT-014 just = 'R' )
      ( fieldname = 'ERDAT'       coltext = TEXT-015 just = 'C' )
      ( fieldname = 'ERZET'       coltext = TEXT-016 just = 'C' )
      ( fieldname = 'ERNAM'       coltext = TEXT-017 just = 'C' )
    ).

    " Hide standard ALV toolbar functions not needed on this list.
    PERFORM get_alv_exclude_tb_func CHANGING lt_exclude.

    " Register double-click on history grid (open log / download path in C00).
    IF go_alv_events IS NOT BOUND.
      go_alv_events = NEW #( ).
    ENDIF.
    SET HANDLER go_alv_events->on_hist_grid_double_click FOR go_grid_hist.

    " First display of GT_HISTORY_LIST on the grid.
    go_grid_hist->set_table_for_first_display(
      EXPORTING
        is_layout            = ls_layout
        it_toolbar_excluding = lt_exclude
      CHANGING
        it_outtab            = gt_hist_alv
        it_fieldcatalog      = lt_fcat ).
    cl_gui_cfw=>flush( ).

  ELSE.
    go_grid_hist->refresh_table_display( is_stable = VALUE #( row = abap_on col = abap_on ) ).
  ENDIF.

ENDFORM.


*&---------------------------------------------------------------------*
*& Section: Download from history (single / ZIP batch)
*&---------------------------------------------------------------------*

*&---------------------------------------------------------------------*
*& Form PROCESS_DOWNLOAD_batch
*& Read ALV multi-selection; one row -> DOWNLOAD_SINGLE_FILE, else ZIP path.
*&---------------------------------------------------------------------*
FORM process_download_batch.

  DATA: lt_rows  TYPE lvc_t_row,
        ls_row   TYPE lvc_s_row,
        ls_hist  TYPE zlog_header,
        lv_count TYPE i.

  IF go_grid_hist IS BOUND.
    go_grid_hist->get_selected_rows( IMPORTING et_index_rows = lt_rows ).
  ENDIF.

  lv_count = lines( lt_rows ).

  IF lv_count = 0.
    MESSAGE s029 DISPLAY LIKE gc_displike_err.
    RETURN.
  ENDIF.

  IF lv_count = 1.

    READ TABLE lt_rows INTO ls_row INDEX 1.
    IF sy-subrc <> 0.
      RETURN.
    ENDIF.

    READ TABLE gt_history_list INTO ls_hist INDEX ls_row-index.
    IF sy-subrc <> 0.
      MESSAGE s047 DISPLAY LIKE gc_displike_err.
      RETURN.
    ENDIF.

    PERFORM download_log_file USING ls_hist.

  ELSE.
    PERFORM download_multiple_files_zip USING lt_rows lv_count.
  ENDIF.

ENDFORM.

*&---------------------------------------------------------------------*
*& Form DOWNLOAD_MULTIPLE_FILES_ZIP
*& Archives multiple selected files into a single ZIP and downloads it
*& Notice: The "SELECT inside loop" has been fixed here.
*&---------------------------------------------------------------------*
FORM download_multiple_files_zip USING pt_rows  TYPE lvc_t_row
                                       pv_count TYPE i.

  DATA: lv_ans      TYPE char1,
        lv_path     TYPE string,
        lv_fullpath TYPE string,
        lv_action   TYPE i,
        lv_filename TYPE string.

  " Confirm with the user before proceeding
  DATA(lv_confirm_txt) = |{ TEXT-018 } { pv_count } { TEXT-022 }|.

  PERFORM show_popup_confirm USING  TEXT-019 lv_confirm_txt
                                    TEXT-020
                                    TEXT-021 abap_off
                                    CHANGING lv_ans.

  IF lv_ans <> '1'. RETURN. ENDIF.

  " Prompt for the ZIP file save location
  cl_gui_frontend_services=>file_save_dialog(
    EXPORTING
       window_title      = |{ TEXT-030 }|
       default_extension = 'zip'
       default_file_name = |{ TEXT-032 }_{ sy-datum }_{ sy-uzeit }.zip|
       file_filter       = |{ TEXT-031 }|
    CHANGING
      filename           = lv_filename
      path               = lv_path
      fullpath           = lv_fullpath
      user_action        = lv_action ).

  IF lv_action <> cl_gui_frontend_services=>action_ok.
    MESSAGE s048 DISPLAY LIKE gc_displike_err.
    RETURN.
  ENDIF.

  TYPES: BEGIN OF lty_log_key,
           log_id TYPE zlog_item-log_id,
         END OF lty_log_key.

  TYPES: BEGIN OF lty_log_data,
           log_id   TYPE zlog_item-log_id,
           raw_data TYPE zlog_item-raw_data,
         END OF lty_log_data.

  DATA: lt_log_keys TYPE STANDARD TABLE OF lty_log_key WITH KEY log_id,
        lt_log_data TYPE SORTED TABLE OF lty_log_data WITH UNIQUE KEY log_id.

  " Collect all log IDs from the selected rows
  LOOP AT pt_rows INTO DATA(ls_row).
    READ TABLE gt_history_list INTO DATA(ls_hist) INDEX ls_row-index.
    IF sy-subrc = 0.
      APPEND VALUE #( log_id = ls_hist-log_id ) TO lt_log_keys.
    ENDIF.
  ENDLOOP.

  " Fetch all required base64 strings in a single DB trip avoiding FAE warning
  IF lt_log_keys IS NOT INITIAL.
    SELECT db~log_id, db~raw_data
      FROM zlog_item AS db
      INNER JOIN @lt_log_keys AS keys
        ON db~log_id = keys~log_id
      INTO TABLE @lt_log_data.
  ENDIF.

  " Build the ZIP archive in memory
  DATA(lo_zip) = NEW cl_abap_zip( ).
  DATA: lv_success_count TYPE i VALUE 0.

  LOOP AT pt_rows INTO ls_row.
    READ TABLE gt_history_list INTO ls_hist INDEX ls_row-index.
    IF sy-subrc <> 0. CONTINUE. ENDIF.

    " Read from our pre-fetched internal table instead of the database
    READ TABLE lt_log_data INTO DATA(ls_data) WITH TABLE KEY log_id = ls_hist-log_id.
    IF sy-subrc <> 0 OR ls_data-raw_data IS INITIAL. CONTINUE. ENDIF.

    TRY.
        DATA(lv_file_xstring) = cl_http_utility=>if_http_utility~decode_x_base64( ls_data-raw_data ).
        DATA(lv_inner_name)   = |{ TEXT-084 }_{ ls_hist-erdat }_{ ls_hist-erzet }_{ ls_hist-log_id }.{ to_lower( ls_hist-file_type ) }|.

        lo_zip->add( name = lv_inner_name content = lv_file_xstring ).
        lv_success_count += 1.

      CATCH cx_root.
        " Safely ignore corrupted base64 strings and move on to the next
        CONTINUE.
    ENDTRY.
  ENDLOOP.

  " Stop if we couldn't parse any files to zip
  IF lv_success_count = 0.
    MESSAGE s031 DISPLAY LIKE gc_displike_err.
    RETURN.
  ENDIF.

  " Finalize the ZIP and trigger the download
  DATA(lv_final_zip_xstring) = lo_zip->save( ).
  DATA: lt_binary_zip TYPE solix_tab.
  DATA(lv_zip_size) = xstrlen( lv_final_zip_xstring ).

  cl_bcs_convert=>xstring_to_solix( EXPORTING iv_xstring = lv_final_zip_xstring RECEIVING et_solix = lt_binary_zip ).

  cl_gui_frontend_services=>gui_download(
    EXPORTING
      bin_filesize            = lv_zip_size
      filename                = lv_fullpath
      filetype                = 'BIN'
    CHANGING
      data_tab                = lt_binary_zip
    EXCEPTIONS
      OTHERS                  = 1 ).

  IF sy-subrc = 0.
    MESSAGE s032 WITH lv_success_count lv_filename.
  ENDIF.

ENDFORM.

*&---------------------------------------------------------------------*
*& Section: Open log from history (preview vs full reload)
*&---------------------------------------------------------------------*

*&---------------------------------------------------------------------*
*& Form PROCESS_HISTORY_SELECTED
*& CSV/TXT: load lines from log into GT_PREVIEW_LINES, plain preview like validate.
*& Other types (e.g. XLSX): RELOAD_DATA_FROM_DB then CALL SCREEN 100 (Data ALV flow).
*&---------------------------------------------------------------------*
FORM process_history_selected USING pv_logid TYPE zlog_header-log_id.

  DATA lv_ftype TYPE zlog_header-file_type.

  gv_edit_mode = abap_off.

  SELECT SINGLE file_type FROM zlog_header INTO @lv_ftype
    WHERE log_id     = @pv_logid
      AND is_deleted = @abap_off.
  IF sy-subrc <> 0.
    MESSAGE s080 DISPLAY LIKE gc_displike_err.
    "Refresh Hitory list if some data was not found.
    PERFORM refresh_history_alv.
    RETURN.
  ENDIF.

  CLEAR gv_error.
  PERFORM reload_data_from_db USING pv_logid.

  IF gv_error = abap_on.
    RETURN.
  ENDIF.

  CLEAR gv_data_dirty.
  CLEAR gt_row_dirty.

  IF lv_ftype = gc_ftype_csv OR lv_ftype = gc_ftype_txt.
    gv_plain_preview = abap_on.
    CALL SCREEN 100.
    CLEAR gv_plain_preview.

  ELSE.
    CALL SCREEN 100.
  ENDIF.

  PERFORM refresh_history_alv.

ENDFORM.

*&---------------------------------------------------------------------*
*& Section: Single-file download by LOG_ID (toolbar / menu)
*&---------------------------------------------------------------------*

*&---------------------------------------------------------------------*
*& Form DOWNLOAD_FILE
*& Decode Base64 blob from ZLOG_ITEM (item 0) for PV_LOG_ID; save dialog + BIN download.
*& (Same pattern as DOWNLOAD_SINGLE_FILE but keyed by log id, not ALV selection.)
*&---------------------------------------------------------------------*
FORM download_file USING pv_log_id TYPE zlog_header-log_id.

  DATA ls_hist TYPE zlog_header.

  SELECT SINGLE
       log_id,
       file_type,
       file_name
    FROM zlog_header
    WHERE log_id = @pv_log_id
      AND ( is_deleted = @abap_off OR is_deleted IS INITIAL )
    INTO CORRESPONDING FIELDS OF @ls_hist.

  IF sy-subrc <> 0.
    MESSAGE s080 DISPLAY LIKE gc_displike_err.
    RETURN.
  ENDIF.

  PERFORM download_log_file USING ls_hist.

ENDFORM.

*&---------------------------------------------------------------------*
*& Section: SMW0 template asset
*&---------------------------------------------------------------------*

*&---------------------------------------------------------------------*
*& Form DOWNLOAD_TEMPLATE_ZIP
*& Download packaged ZIP from SMW0 (MIME MI object Z_UPLOAD_TEMPLATES_AND_HEADER_RULES).
*&---------------------------------------------------------------------*
FORM download_template_zip.

  DATA: ls_wwwdata TYPE wwwdatatab,
        lv_path    TYPE string,
        lv_full    TYPE string,
        lv_action  TYPE i.

  " Look up WWWDATA row for the SMW0 MIME object (template archive).
  SELECT SINGLE
            relid,
            objid,
            checkout,
            checknew,
            chname,
            tdate,
            ttime,
            text
     FROM wwwdata INTO CORRESPONDING FIELDS OF @ls_wwwdata
    WHERE relid = 'MI'
      AND objid = 'Z_UPLOAD_TEMPLATES_AND_HEADER_RULES'
      AND srtf2 = 0.

  IF sy-subrc <> 0.
    MESSAGE s020 DISPLAY LIKE gc_displike_err.
    RETURN.
  ENDIF.

  " File save dialog: where to store the .zip on the front end.
  cl_gui_frontend_services=>file_save_dialog(
    EXPORTING
      window_title      = |{ TEXT-053 }|
      default_extension = 'zip'
      default_file_name = |{ TEXT-054 }.zip|
      file_filter       = |{ TEXT-055 }|
    CHANGING
      filename          = lv_full
      path              = lv_path
      fullpath          = lv_full
      user_action       = lv_action ).

  IF lv_action = cl_gui_frontend_services=>action_ok.

    " Push binary from SMW0 to the path chosen by the user
    CALL FUNCTION 'DOWNLOAD_WEB_OBJECT'
      EXPORTING
        key         = ls_wwwdata
        destination = CONV localfile( lv_full )
      EXCEPTIONS
        OTHERS      = 1.

    IF sy-subrc = 0.
      MESSAGE s021.
    ELSE.
      MESSAGE e022.
    ENDIF.
  ENDIF.
ENDFORM.
*&---------------------------------------------------------------------*
*& Form process_delete_batch
*&---------------------------------------------------------------------*
FORM process_delete_batch.
  DATA: lt_rows        TYPE lvc_t_row,
        lv_count       TYPE i,
        lv_ans         TYPE char1,
        lv_deleted_cnt TYPE i.
  .

  IF go_grid_hist IS BOUND.
    go_grid_hist->get_selected_rows( IMPORTING et_index_rows = lt_rows ).
  ENDIF.

  lv_count = lines( lt_rows ).

  IF lv_count = 0.
    MESSAGE s065 DISPLAY LIKE gc_displike_warn.
    RETURN.
  ENDIF.

  DATA(lv_txt) = |{ TEXT-128 } { lv_count } { TEXT-129 }|.
  PERFORM show_popup_confirm USING TEXT-130
                                   lv_txt
                                   TEXT-131
                                   TEXT-132
                                   abap_off
                             CHANGING lv_ans.

  IF lv_ans <> '1'. RETURN. ENDIF.

  CLEAR lv_deleted_cnt.

  LOOP AT lt_rows INTO DATA(ls_row).
    READ TABLE gt_history_list INTO DATA(ls_hist) INDEX ls_row-index.
    IF sy-subrc = 0.
      UPDATE zlog_header SET is_deleted = abap_on
        WHERE log_id = ls_hist-log_id.

      IF sy-subrc = 0.
        lv_deleted_cnt = lv_deleted_cnt + 1.
      ENDIF.
    ENDIF.
  ENDLOOP.

  COMMIT WORK AND WAIT.
  PERFORM refresh_history_alv.

  IF lv_deleted_cnt = 1.
    MESSAGE s066.
  ELSE.
    MESSAGE s067 WITH lv_deleted_cnt DISPLAY LIKE gc_displike_suc.
  ENDIF.

ENDFORM.

*&---------------------------------------------------------------------*
*& Form load_history_data
*&---------------------------------------------------------------------*
FORM load_history_data.

  DATA: lt_r_date TYPE RANGE OF datum,
        lt_r_prog TYPE RANGE OF zlog_header-file_type.

  CLEAR gt_history_list.

  IF p_date IS NOT INITIAL.
    lt_r_date = VALUE #( ( sign = 'I' option = 'EQ' low = p_date ) ).
  ENDIF.

  IF p_ftype2 <> '*'.
    DATA(lv_prog_val) = COND zlog_header-file_type(
                          WHEN p_ftype2 = gc_ftype_xlsx THEN gc_ftype_xlsx
                          WHEN p_ftype2 = gc_ftype_csv  THEN gc_ftype_csv
                          WHEN p_ftype2 = gc_ftype_txt  THEN gc_ftype_txt
                          ELSE p_ftype2 ).

    lt_r_prog = VALUE #( ( sign = 'I' option = 'EQ' low = lv_prog_val ) ).
  ENDIF.

  SELECT mandt,
         log_id,
         file_type,
         file_name,
         total_rec,
         succ_rec,
         total_sheet,
         err_rec,
         category,
         erdat,
         erzet,
         ernam,
         aedat,
         aezet,
         aenam,
         is_deleted
    FROM zlog_header
    WHERE ernam = @sy-uname
      AND erdat IN @lt_r_date
      AND file_type IN @lt_r_prog
      AND ( is_deleted = @abap_off OR is_deleted IS INITIAL )
    ORDER BY erdat DESCENDING, erzet DESCENDING
    INTO CORRESPONDING FIELDS OF TABLE @gt_history_list.

  gt_hist_alv = CORRESPONDING #( gt_history_list ).

  LOOP AT gt_hist_alv ASSIGNING FIELD-SYMBOL(<ls_hist_alv>).

    CLEAR <ls_hist_alv>-cell_col.

    IF <ls_hist_alv>-err_rec > 0.
      APPEND VALUE #( fname = 'ERR_REC'
                      color = VALUE #( col = 6 int = 1 ) )
        TO <ls_hist_alv>-cell_col.
    ENDIF.

  ENDLOOP.

  " No rows -> warning and stay on selection screen.
  IF sy-subrc <> 0.
    MESSAGE s001 DISPLAY LIKE gc_displike_warn. " No data for selection
    RETURN.
  ENDIF.

ENDFORM.

*&---------------------------------------------------------------------*
*& Form get_history_grid_title
*&---------------------------------------------------------------------*
FORM get_history_grid_title USING    pv_date  TYPE datum
                                     pv_count TYPE i
                            CHANGING pv_title TYPE string.

  DATA(lv_title_date) = COND string(
    WHEN pv_date IS INITIAL THEN TEXT-004
    ELSE |{ TEXT-005 } { pv_date }| ).

  pv_title = |{ TEXT-006 } ({ lv_title_date }) - { TEXT-007 } { pv_count }|.

ENDFORM.

*&---------------------------------------------------------------------*
*& Form download_log_file
*&---------------------------------------------------------------------*
FORM download_log_file USING ps_hist TYPE zlog_header.

  DATA: lv_path         TYPE string,
        lv_fullpath     TYPE string,
        lv_filename     TYPE string,
        lv_action       TYPE i,
        lv_dialog_title TYPE string,
        lv_default_name TYPE string,
        lv_file_filter  TYPE string,
        lt_binary       TYPE solix_tab.

  DATA(lv_ext) = to_lower( ps_hist-file_type ).

  lv_dialog_title = TEXT-023.
  lv_default_name = |{ sy-datum }_{ ps_hist-file_name }|.
  lv_file_filter  = |{ TEXT-025 } (*.{ lv_ext })\|*.{ lv_ext }|.

  cl_gui_frontend_services=>file_save_dialog(
    EXPORTING
      window_title      = lv_dialog_title
      default_extension = lv_ext
      default_file_name = lv_default_name
      file_filter       = lv_file_filter
    CHANGING
      filename          = lv_filename
      path              = lv_path
      fullpath          = lv_fullpath
      user_action       = lv_action
    EXCEPTIONS
      OTHERS            = 1 ).

  IF lv_action <> cl_gui_frontend_services=>action_ok OR sy-subrc <> 0.
    MESSAGE s048 DISPLAY LIKE gc_displike_err.
    RETURN.
  ENDIF.

  SELECT SINGLE raw_data
    FROM zlog_item
    INTO @DATA(lv_base64)
    WHERE log_id  = @ps_hist-log_id.

  IF lv_base64 IS INITIAL.
    MESSAGE s047 DISPLAY LIKE gc_displike_err.
    RETURN.
  ENDIF.

  DATA(lv_xstring) = cl_http_utility=>if_http_utility~decode_x_base64( lv_base64 ).

  cl_bcs_convert=>xstring_to_solix(
    EXPORTING
      iv_xstring = lv_xstring
    RECEIVING
      et_solix   = lt_binary ).

  cl_gui_frontend_services=>gui_download(
    EXPORTING
      bin_filesize = xstrlen( lv_xstring )
      filename     = lv_fullpath
      filetype     = 'BIN'
    CHANGING
      data_tab     = lt_binary
    EXCEPTIONS
      OTHERS       = 1 ).

  IF sy-subrc = 0.
    MESSAGE s050 WITH lv_filename.
  ELSE.
    MESSAGE s051 DISPLAY LIKE gc_displike_err.
  ENDIF.

ENDFORM.
