*&---------------------------------------------------------------------*
*& Include          ZGSP26_GROUP23_F05
*&---------------------------------------------------------------------*

*&---------------------------------------------------------------------*
*& Purpose
*&  Persistence and round-trip for Group23: ZLOG_HEADER / ZLOG_ITEM,
*&  GT_PREVIEW_LINES from stored Base64, SAVE_LOG (insert/update),
*&  post-edit UPDATE_DATABASE_LOG, reload workbook from DB blob.
*&---------------------------------------------------------------------*

*&---------------------------------------------------------------------*
*& Section: Preview text from saved log
*&---------------------------------------------------------------------*

*&---------------------------------------------------------------------*
*& Form LOAD_PREVIEW_LINES_FROM_LOG
*& Load CSV/TXT body from ZLOG_ITEM (item 0 Base64), decode, delegate to
*& READ_TEXT_LOCAL so GT_PREVIEW_LINES is filled like a fresh upload.
*&---------------------------------------------------------------------*
FORM load_preview_lines_from_log USING pv_logid TYPE zlog_header-log_id.

  DATA: lv_base64  TYPE string,
        lv_xstring TYPE xstring,
        lv_ftype   TYPE char10.

  CLEAR gt_preview_lines.

  SELECT SINGLE raw_data FROM zlog_item INTO @lv_base64
    WHERE log_id = @pv_logid AND item_no = 0.
  IF sy-subrc <> 0 OR lv_base64 IS INITIAL.
    RETURN.
  ENDIF.

  SELECT SINGLE file_type FROM zlog_header INTO @lv_ftype
    WHERE log_id = @pv_logid.
  IF sy-subrc <> 0 OR ( lv_ftype <> gc_ftype_csv AND lv_ftype <> gc_ftype_txt ).
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
    RETURN.
  ENDIF.

  " Reuse F01 text pipeline (P_FILE may be empty when passing XSTRING only).
  PERFORM read_text_local USING p_file lv_ftype lv_xstring.

ENDFORM.

*&---------------------------------------------------------------------*
*& Section: Initial save / store-only (after upload or retry)
*&---------------------------------------------------------------------*

*&---------------------------------------------------------------------*
*& Form SAVE_LOG
*& Insert or update ZLOG_HEADER + item 0: new UUID unless GV_CURRENT_LOG_ID
*& already set (retry/update path); P_STOR -> stored category, else validated stats.
*&---------------------------------------------------------------------*
FORM save_log USING pv_ftype            TYPE char10
                    pv_file_base64      TYPE string.

  DATA: ls_log_head TYPE zlog_header,
        ls_log_item TYPE zlog_item,
        lt_log_item TYPE TABLE OF zlog_item.

  DATA: lv_uuid      TYPE sysuuid_c32,
        lv_do_update TYPE abap_bool,
        ls_head_old  TYPE zlog_header.

  " New UUID, or keep existing LOG_ID when continuing CSV/TXT (not store-only only).
  IF gv_current_log_id IS NOT INITIAL.
    lv_do_update = abap_on.
    lv_uuid = gv_current_log_id.
  ELSE.
    lv_do_update = abap_off.
    TRY.
        lv_uuid = cl_system_uuid=>create_uuid_c32_static( ).
        gv_current_log_id = lv_uuid.
      CATCH cx_uuid_error.
        MESSAGE e011(zmsg_gr23).
        RETURN.
    ENDTRY.
  ENDIF.

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


  IF p_stor = abap_on.

    ls_log_head-mandt       = sy-mandt.
    ls_log_head-log_id      = lv_uuid.
    ls_log_head-file_type   = pv_ftype.
    ls_log_head-erdat       = sy-datum.
    ls_log_head-erzet       = sy-uzeit.
    ls_log_head-ernam       = sy-uname.
    ls_log_head-file_name   = lv_filename.
    ls_log_head-total_sheet = lines( gt_master_sheets ).
    ls_log_head-category    = gc_stored_file.

    lt_log_item = VALUE #( ( log_id      = lv_uuid
                             item_no     = 0
                             raw_data    = pv_file_base64 ) ).
*    ls_log_item-log_id      = lv_uuid.
*    ls_log_item-item_no     = 0.
*    ls_log_item-raw_data    = pv_file_base64.
*    APPEND ls_log_item TO lt_log_item.

  ELSE.

    " Header aggregates: roll up counts across all sheets in GT_MASTER_SHEETS.
    ls_log_head-mandt       = sy-mandt.
    ls_log_head-log_id      = lv_uuid.
    ls_log_head-file_type   = pv_ftype.
    ls_log_head-erdat       = sy-datum.
    ls_log_head-erzet       = sy-uzeit.
    ls_log_head-ernam       = sy-uname.
    ls_log_head-file_name   = lv_filename.
    ls_log_head-total_sheet = lines( gt_master_sheets ).
    ls_log_head-category    = gc_validated_file.

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

    " Main blob item (item 0): full file Base64 for retry / reopen.
    lt_log_item = VALUE #( ( log_id      = lv_uuid
                         item_no     = 0
                         raw_data    = pv_file_base64 ) ).
*    ls_log_item-log_id   = lv_uuid.
*    ls_log_item-item_no  = 0.
*    ls_log_item-raw_data = pv_file_base64.
*    APPEND ls_log_item TO lt_log_item.
  ENDIF.

  " INSERT new header/items, or UPDATE header + replace item rows when continuing same log.
  IF lv_do_update = abap_on.
    SELECT log_id,
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
           aenam
       FROM zlog_header INTO CORRESPONDING FIELDS OF @ls_head_old WHERE log_id = @lv_uuid.
    ENDSELECT.

    IF sy-subrc <> 0.
      MESSAGE e013(zmsg_gr23).
      RETURN.
    ENDIF.
    ls_log_head-erdat = ls_head_old-erdat.
    ls_log_head-erzet = ls_head_old-erzet.
    ls_log_head-ernam = ls_head_old-ernam.
    ls_log_head-aedat = sy-datum.
    ls_log_head-aezet = sy-uzeit.
    ls_log_head-aenam = sy-uname.
    UPDATE zlog_header FROM ls_log_head.
    IF sy-subrc <> 0.
      MESSAGE e013(zmsg_gr23).
      RETURN.
    ENDIF.
    DELETE FROM zlog_item WHERE log_id = lv_uuid.
    INSERT zlog_item FROM TABLE lt_log_item.
  ELSE.
    INSERT zlog_header FROM ls_log_head.
    INSERT zlog_item   FROM TABLE lt_log_item.
  ENDIF.

  IF sy-subrc = 0.
    COMMIT WORK AND WAIT.
    IF p_stor = abap_on.
      MESSAGE s061(zmsg_gr23).
    ELSE.
      MESSAGE s012(zmsg_gr23).
    ENDIF.

  ELSE.
    gv_error = abap_on.

    IF p_stor = abap_on.
      MESSAGE s062(zmsg_gr23) DISPLAY LIKE gc_displike_err.
    ELSE.
      MESSAGE s013(zmsg_gr23) DISPLAY LIKE gc_displike_err.
    ENDIF.
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

  DATA: lv_lines_ok TYPE i,
        lt_err_rows TYPE TABLE OF i.

  " Count OK lines: total dynamic rows minus distinct rows that appear in GT_ERROR_LOG.
  IF <gfs_data> IS ASSIGNED.

    " Collect all row_index values that have at least one error.
    LOOP AT gt_error_log INTO DATA(ls_err).
      APPEND ls_err-row_index TO lt_err_rows.
    ENDLOOP.

    " One logical row with multiple errors still counts as one bad row.
    SORT lt_err_rows.
    DELETE ADJACENT DUPLICATES FROM lt_err_rows.

    lv_lines_ok = lines( <gfs_data> ) - lines( lt_err_rows ).

  ELSE.
    lv_lines_ok = 0.
  ENDIF.

  " Block save when nothing is valid to persist.
  IF lv_lines_ok = 0.
    MESSAGE i014(zmsg_gr23) DISPLAY LIKE gc_displike_warn.
    RETURN.
  ENDIF.

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

  MESSAGE s016(zmsg_gr23).

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

  DATA: ls_zlog_header TYPE zlog_header,
        ls_zlog_item   TYPE zlog_item,
        lv_ftype       TYPE char10,
        lv_base64      TYPE string.

  " Rebuild full-file Base64 from current workbook state (XLSX vs text).
  SELECT SINGLE file_type FROM zlog_header INTO @lv_ftype WHERE log_id = @pv_log_id.

  IF lv_ftype = gc_ftype_xlsx.
    PERFORM rebuild_base64_file_content CHANGING lv_base64.
  ELSE.
    PERFORM rebuild_text_base64 USING    lv_ftype
                                CHANGING lv_base64.
  ENDIF.

  SORT gt_master_sheets BY page_no.
  READ TABLE gt_master_sheets ASSIGNING FIELD-SYMBOL(<ls_current>) WITH KEY page_no = gv_current_page BINARY SEARCH.
  IF sy-subrc = 0.
    <ls_current>-data_raw = gt_data_raw.
    <ls_current>-error_log = gt_error_log.
  ENDIF.

  SELECT SINGLE
          mandt,
          log_id,
          item_no,
*          raw_index,
*          fieldname,
*          message,
          raw_data
     FROM zlog_item INTO CORRESPONDING FIELDS OF @ls_zlog_item WHERE log_id = @pv_log_id AND item_no = 0.
  IF sy-subrc = 0.
    ls_zlog_item-raw_data = lv_base64.
    MODIFY zlog_item FROM ls_zlog_item.
  ENDIF.

  " Remove previous line-level error items; re-insert from current memory (clean slate).
  DELETE FROM zlog_item WHERE log_id = pv_log_id AND item_no > 0.

  DATA: ls_master    TYPE gty_master_sheet.
*        lt_new_items TYPE TABLE OF zlog_item,
*        lv_item_no   TYPE i VALUE 1,

*  LOOP AT gt_master_sheets INTO ls_master.
*    LOOP AT ls_master-error_log INTO DATA(ls_err).
*      CLEAR ls_zlog_item.
*      ls_zlog_item-mandt     = sy-mandt.
*      ls_zlog_item-log_id    = pv_log_id.
*      ls_zlog_item-item_no   = lv_item_no.
*      ls_zlog_item-row_index = ls_err-row_index.
*      ls_zlog_item-fieldname = ls_err-fieldname.
*      ls_zlog_item-message   = |[Sheet { ls_master-page_no }] { ls_err-message }|.
*      ls_zlog_item-aedat     = sy-datum.
*      ls_zlog_item-aezet     = sy-uzeit.
*      ls_zlog_item-aenam     = sy-uname.
*      APPEND ls_zlog_item TO lt_new_items.
*      lv_item_no = lv_item_no + 1.
*    ENDLOOP.
*  ENDLOOP.

*  IF lt_new_items IS NOT INITIAL.
*    INSERT zlog_item FROM TABLE lt_new_items.
*  ENDIF.

  " Recompute header TOTAL_REC / ERR_REC / SUCC_REC from all sheets.
  SELECT SINGLE mandt,
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
       aenam
   FROM zlog_header
   INTO CORRESPONDING FIELDS OF @ls_zlog_header WHERE log_id = @pv_log_id.
  IF sy-subrc = 0.
    ls_zlog_header-total_rec = 0.
    ls_zlog_header-err_rec   = 0.

    LOOP AT gt_master_sheets INTO ls_master.
      IF ls_master-dref_data IS BOUND.
        ASSIGN ls_master-dref_data->* TO FIELD-SYMBOL(<lfs_temp_data>).
        IF <lfs_temp_data> IS ASSIGNED.
          ls_zlog_header-total_rec = ls_zlog_header-total_rec + lines( <lfs_temp_data> ).
        ENDIF.
      ENDIF.

      DATA: lt_error_temp TYPE gty_t_error_log.
      lt_error_temp = ls_master-error_log.
      SORT lt_error_temp BY row_index.
      DELETE ADJACENT DUPLICATES FROM lt_error_temp COMPARING row_index.
      ls_zlog_header-err_rec = ls_zlog_header-err_rec + lines( lt_error_temp ).
    ENDLOOP.

    ls_zlog_header-succ_rec = ls_zlog_header-total_rec - ls_zlog_header-err_rec.
    ls_zlog_header-aedat    = sy-datum.
    ls_zlog_header-aezet    = sy-uzeit.
    ls_zlog_header-aenam    = sy-uname.

    UPDATE zlog_header FROM ls_zlog_header.
  ENDIF.

  COMMIT WORK AND WAIT.

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
    WHERE log_id  = @pv_logid
      AND item_no = 0.

  SELECT SINGLE file_type FROM zlog_header INTO @lv_ftype
    WHERE log_id = @pv_logid.

  IF sy-subrc <> 0 OR lv_base64 IS INITIAL.

    gv_error = abap_on.
    MESSAGE s024(zmsg_gr23) DISPLAY LIKE gc_displike_err.

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
    MESSAGE s052(zmsg_gr23) DISPLAY LIKE gc_displike_err.
    RETURN.
  ENDIF.

  CASE lv_ftype.
    WHEN gc_ftype_xlsx.
      PERFORM read_excel_local USING p_file
                               lv_xstring.
    WHEN OTHERS.
      PERFORM read_text_local USING p_file
                                    lv_ftype
                                    lv_xstring.
  ENDCASE.

  DATA lv_current_page TYPE i.

  lv_current_page = gv_current_page.

  " Bring page 1 (or last current page if set) into workspace after parse.
  IF gt_master_sheets IS NOT INITIAL.
    IF gv_current_page IS INITIAL.
      PERFORM load_page_to_workspace USING 1.
    ELSE.
      PERFORM load_page_to_workspace USING lv_current_page.
    ENDIF.
  ELSE.
    gv_error = abap_on.
    MESSAGE s025(zmsg_gr23) DISPLAY LIKE gc_displike_err.
  ENDIF.
ENDFORM.
