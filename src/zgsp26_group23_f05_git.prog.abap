*&---------------------------------------------------------------------*
*& Include          ZGSP26_GROUP23_F05
*&---------------------------------------------------------------------*
*& Purpose
*&  Persistence and round-trip for Group23: ZLOG_HEADER / ZLOG_ITEM,
*&  GT_PREVIEW_LINES from stored Base64, SAVE_LOG (insert/update),
*&  post-edit UPDATE_DATABASE_LOG, reload workbook from DB blob.
*&---------------------------------------------------------------------*

*&---------------------------------------------------------------------*
*& Section: Initial save / store-only (after upload or retry)
*&---------------------------------------------------------------------*

*&---------------------------------------------------------------------*
*& Form SAVE_LOG
*& Insert or update ZLOG_HEADER + item 0: new UUID unless GV_CURRENT_LOG_ID
*& already set (retry/update path); P_STOR -> stored category, else validated stats.
*&---------------------------------------------------------------------*
FORM save_log USING pv_ftype       TYPE char10
                    pv_file_base64 TYPE string.

  DATA: ls_log_head TYPE zlog_header,
        ls_log_item TYPE zlog_item,
        lv_uuid     TYPE sysuuid_c32.

  " New UUID.
  TRY.
      lv_uuid = cl_system_uuid=>create_uuid_c32_static( ).
      gv_current_log_id = lv_uuid.
    CATCH cx_uuid_error.
      MESSAGE e011.
      RETURN.
  ENDTRY.

  DATA: lv_filename  TYPE string,
        lv_full_path TYPE string.

  lv_full_path = p_file.

  REPLACE ALL OCCURRENCES OF '/' IN lv_full_path WITH '\'.

  " Split full path into file name for ZLOG_HEADER-FILE_NAME.
  CALL FUNCTION 'SO_SPLIT_FILE_AND_PATH'
    EXPORTING
      full_name     = lv_full_path
    IMPORTING
      stripped_name = lv_filename.

  ls_log_head = VALUE #( mandt       = sy-mandt
                         log_id      = lv_uuid
                         file_type   = pv_ftype
                         erdat       = sy-datum
                         erzet       = sy-uzeit
                         ernam       = sy-uname
                         file_name   = lv_filename
                         total_sheet = lines( gt_master_sheets )
                         category    = COND #( WHEN p_val  = abap_on THEN gc_validated_file
                                               ELSE gc_stored_file )  ).

  IF p_val = abap_on.

    DATA: lt_error_temp TYPE gty_t_error_log.

    " Sum data rows per sheet; count distinct error rows per sheet for ERR_REC.
    LOOP AT gt_master_sheets INTO DATA(ls_master).
      " Rough row count from dynamic table bound on each sheet.
      IF ls_master-dref_data IS BOUND.
        ASSIGN ls_master-dref_data->* TO FIELD-SYMBOL(<lfs_temp_data>).
        IF <lfs_temp_data> IS ASSIGNED.
          ls_log_head-total_rec = ls_log_head-total_rec + lines( <lfs_temp_data> ).
        ENDIF.
      ENDIF.

      " Unique error rows for this sheet (one row may have several cell errors).
      lt_error_temp = ls_master-error_log.
      SORT lt_error_temp BY row_index.
      DELETE ADJACENT DUPLICATES FROM lt_error_temp COMPARING row_index.
      ls_log_head-err_rec = ls_log_head-err_rec + lines( lt_error_temp ).
    ENDLOOP.

    ls_log_head-succ_rec = ls_log_head-total_rec - ls_log_head-err_rec.

  ENDIF.

  " Full file Base64 for retry / reopen.
  ls_log_item = VALUE #(  log_id    = lv_uuid
                           raw_data = pv_file_base64  ).

  " INSERT new header.
  INSERT zlog_header FROM ls_log_head.
  IF sy-subrc <> 0.
    ROLLBACK WORK.
    gv_error = abap_on.

    IF p_stor = abap_on.
      MESSAGE s062 DISPLAY LIKE gc_displike_err.
    ELSE.
      MESSAGE s013 DISPLAY LIKE gc_displike_err.
    ENDIF.
    RETURN.
  ENDIF.

  " INSERT new item.
  INSERT zlog_item FROM ls_log_item.
  IF sy-subrc <> 0.
    ROLLBACK WORK.
    gv_error = abap_on.

    IF p_stor = abap_on.
      MESSAGE s062 DISPLAY LIKE gc_displike_err.
    ELSE.
      MESSAGE s013 DISPLAY LIKE gc_displike_err.
    ENDIF.
    RETURN.
  ENDIF.

  COMMIT WORK.

  IF p_stor = abap_on.
    MESSAGE s061.
  ELSE.
    MESSAGE s012.
  ENDIF.

ENDFORM.

*&---------------------------------------------------------------------*
*& Section: User Save after edits on dynpro 100
*&---------------------------------------------------------------------*

*&---------------------------------------------------------------------*
*& Form PROCESS_SAVE_DATA
*& Count error-free rows; flush current sheet; UPDATE_DATABASE_LOG;
*& exit edit mode and refresh master ALV when not plain preview.
*&---------------------------------------------------------------------*
FORM process_save_data.

  DATA: lv_current_log_id TYPE zlog_header-log_id.
  lv_current_log_id = gv_current_log_id.

*  " Optional: sync ALV grid back to GT_data_RAW before persist (reverse map).
*  PERFORM reverse_map_to_raw.

  " Push current worksheet into GT_MASTER_SHEETS before DB write.
  IF gv_plain_preview = abap_off.
    PERFORM flush_ws_to_master USING gv_current_page.
  ENDIF.

  " Persist edited data + error lines + refreshed Base64 blob.
  PERFORM update_database_log USING lv_current_log_id.

  " Leave edit mode on detail (and master refresh below).
  gv_edit_mode = abap_off.
  PERFORM switch_alv_mode.

  CLEAR gv_data_dirty.
  CLEAR gt_row_dirty.

  IF gv_plain_preview = abap_off.

    PERFORM prepare_master_alv_data.
    IF go_grid_master IS BOUND.
      go_grid_master->refresh_table_display( is_stable = VALUE #( row = abap_on col = abap_on ) ).
    ENDIF.
  ENDIF.
ENDFORM.

*&---------------------------------------------------------------------*
*& Section: DB update after save (blob + per-cell error items)
*&---------------------------------------------------------------------*

*&---------------------------------------------------------------------*
*& Form UPDATE_DATABASE_LOG
*& Rebuild file Base64 from current in-memory sheets; update item 0; delete old
*& detail error items (item_no > 0) and re-insert from GT_MASTER_SHEETS error logs;
*& refresh ZLOG_HEADER counters.
*&---------------------------------------------------------------------*
FORM update_database_log USING pv_log_id TYPE zlog_header-log_id.

  DATA: ls_header TYPE zlog_header,
        ls_item   TYPE zlog_item,
        lv_ftype  TYPE char10,
        lv_base64 TYPE string.

  " Rebuild full-file Base64 from current workbook state (XLSX vs text).
  SELECT SINGLE file_type
    FROM zlog_header
    INTO @lv_ftype
    WHERE log_id     = @pv_log_id
      AND is_deleted = @abap_off.

  IF sy-subrc <> 0.
    MESSAGE s080 DISPLAY LIKE gc_displike_err.
    LEAVE TO SCREEN 0.
  ENDIF.

  IF lv_ftype = gc_ftype_xlsx.
    PERFORM rebuild_base64_file_content CHANGING lv_base64.
  ELSE.
    PERFORM rebuild_text_base64 USING    lv_ftype
                                CHANGING lv_base64.
  ENDIF.

  SORT gt_master_sheets BY page_no.
  READ TABLE gt_master_sheets ASSIGNING FIELD-SYMBOL(<ls_current>)
    WITH KEY page_no = gv_current_page
    BINARY SEARCH.

  IF sy-subrc = 0.
    <ls_current>-data_raw = gt_data_raw.
    <ls_current>-error_log = gt_error_log.
  ENDIF.

  SELECT SINGLE
          log_id,
          raw_data
     FROM zlog_item INTO CORRESPONDING FIELDS OF @ls_item WHERE log_id = @pv_log_id.
  IF sy-subrc = 0.
    ls_item-raw_data = lv_base64.
  ENDIF.

  " Recompute header TOTAL_REC / ERR_REC / SUCC_REC from all sheets.
  SELECT SINGLE
       log_id,
       total_rec,
       err_rec,
       succ_rec,
       aedat,
       aezet,
       aenam
   FROM zlog_header
   INTO CORRESPONDING FIELDS OF @ls_header WHERE log_id = @pv_log_id.
  IF sy-subrc = 0.
    ls_header-total_rec = 0.
    ls_header-err_rec   = 0.

    LOOP AT gt_master_sheets INTO DATA(ls_master).
      IF ls_master-dref_data IS BOUND.
        ASSIGN ls_master-dref_data->* TO FIELD-SYMBOL(<lfs_temp_data>).
        IF <lfs_temp_data> IS ASSIGNED.
          ls_header-total_rec = ls_header-total_rec + lines( <lfs_temp_data> ).
        ENDIF.
      ENDIF.

      DATA: lt_error_temp TYPE gty_t_error_log.
      lt_error_temp = ls_master-error_log.
      SORT lt_error_temp BY row_index.
      DELETE ADJACENT DUPLICATES FROM lt_error_temp COMPARING row_index.
      ls_header-err_rec = ls_header-err_rec + lines( lt_error_temp ).
    ENDLOOP.

    ls_header-succ_rec = ls_header-total_rec - ls_header-err_rec.
    ls_header-aedat    = sy-datum.
    ls_header-aezet    = sy-uzeit.
    ls_header-aenam    = sy-uname.

  ENDIF.

  MODIFY zlog_item FROM ls_item.
  IF sy-subrc <> 0.
    ROLLBACK WORK.
    MESSAGE s081 DISPLAY LIKE gc_displike_err.
    gv_error = abap_on.
    RETURN.
  ENDIF.

  UPDATE zlog_header FROM ls_header.
  IF sy-subrc <> 0.
    ROLLBACK WORK.
    MESSAGE s081 DISPLAY LIKE gc_displike_err.
    gv_error = abap_on.
    RETURN.
  ENDIF.

  COMMIT WORK.
  MESSAGE s016.

ENDFORM.

*&---------------------------------------------------------------------*
*& Section: Reload workbook from stored log (full parse)
*&---------------------------------------------------------------------*

*&---------------------------------------------------------------------*
*& Form RELOAD_DATA_FROM_DB
*& Decode item 0 Base64; branch READ_EXCEL_LOCAL vs READ_TEXT_LOCAL by file type;
*& LOAD_PAGE_TO_WORKSPACE restores sheet 1 or previous GV_CURRENT_PAGE when possible.
*&---------------------------------------------------------------------*
FORM reload_data_from_db USING pv_logid TYPE zlog_header-log_id.
  DATA: lv_base64  TYPE string,
        lv_xstring TYPE xstring,
        lv_ftype   TYPE char10.

  CLEAR gt_row_dirty.

  SELECT SINGLE raw_data FROM zlog_item INTO @lv_base64
    WHERE log_id  = @pv_logid.

  SELECT SINGLE file_type FROM zlog_header INTO @lv_ftype
    WHERE log_id     = @pv_logid
      AND is_deleted = @abap_off.

  IF sy-subrc <> 0 OR lv_base64 IS INITIAL.
    gv_error = abap_on.
    MESSAGE s024 DISPLAY LIKE gc_displike_err.
    RETURN.
  ENDIF.

  CALL FUNCTION 'SSFC_BASE64_DECODE'
    EXPORTING
      b64data = lv_base64
    IMPORTING
      bindata = lv_xstring
    EXCEPTIONS
      OTHERS  = 1.

  IF sy-subrc <> 0.
    MESSAGE s052 DISPLAY LIKE gc_displike_err.
    RETURN.
  ENDIF.

  CASE lv_ftype.
    WHEN gc_ftype_xlsx.
      PERFORM read_excel_local USING p_file
                               lv_xstring.

      DATA lv_current_page TYPE i.
      lv_current_page = gv_current_page.

      " Bring page 1 (or last current page if set) into workspace after parse
      IF gv_current_page IS INITIAL.
        PERFORM load_page_to_workspace USING 1.
      ELSE.
        PERFORM load_page_to_workspace USING lv_current_page.
      ENDIF.

    WHEN OTHERS.
      PERFORM read_text_local USING p_file
                                    lv_ftype
                                    lv_xstring.
  ENDCASE.
ENDFORM.
