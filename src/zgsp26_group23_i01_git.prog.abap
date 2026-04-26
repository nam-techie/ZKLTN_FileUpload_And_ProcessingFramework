*&---------------------------------------------------------------------*
*& Include          ZGSP26_GROUP23_I01
*&---------------------------------------------------------------------*

*&---------------------------------------------------------------------*
*& Purpose
*&  PAI modules and FORM routines for dynpros 0100 (main) and 0200 (history):
*&  OK-code dispatch, save/display/raw preview, download, exit with confirm.
*&---------------------------------------------------------------------*

*&---------------------------------------------------------------------*
*& Section: Screen 0100 - PAI modules
*&---------------------------------------------------------------------*

*&---------------------------------------------------------------------*
*& Module  EXIT  INPUT
*& Map BACK to PROCESS_EXIT_SCREEN; EXIT / CANCEL leaves program; clear OK code.
*&---------------------------------------------------------------------*
MODULE exit INPUT.
  " Delegate BACK handling to shared exit FORM; EXIT command ends program.
  IF gv_okcode = gc_ucomm_back.
    PERFORM process_exit_screen.
  ELSEIF gv_okcode = gc_ucomm_exit.
    PERFORM unlock_data.
    LEAVE PROGRAM.
  ENDIF.
  CLEAR gv_okcode.
ENDMODULE.

*&---------------------------------------------------------------------*
*& Module  USER_COMMAND_0100  INPUT
*& CASE on GV_OKCODE: raw continue, view raw, save, edit, download, display, back.
*&---------------------------------------------------------------------*
MODULE user_command_0100 INPUT.

  CASE gv_okcode.
    WHEN gc_ucomm_raw_cont.
      "Check if raw file was changed?
      PERFORM is_raw_file_changed.
      PERFORM continue_from_raw_preview.

    WHEN gc_ucomm_view_raw.
      PERFORM process_view_raw.

    WHEN gc_ucomm_back OR gc_ucomm_exit.
      IF gv_okcode = gc_ucomm_back.
        PERFORM process_exit_screen.
      ELSE.
        LEAVE PROGRAM.
      ENDIF.

    WHEN gc_ucomm_save.
      PERFORM process_save.

    WHEN gc_ucomm_change.

      gv_edit_mode = abap_on.
      PERFORM switch_alv_mode.

    WHEN gc_ucomm_down.
      PERFORM process_btn_down_100.

    WHEN gc_ucomm_disp.
      PERFORM process_display.

  ENDCASE.

  CLEAR gv_okcode.
ENDMODULE.

*&---------------------------------------------------------------------*
*& Section: Screen 0100 - PAI subroutines
*&---------------------------------------------------------------------*

*&---------------------------------------------------------------------*
*& Form PROCESS_VIEW_RAW
*& Dirty confirm -> optional reload from DB; rebuild GT_PREVIEW_LINES from ALV;
*& show text preview and clear selection / dirty where applicable.
*&---------------------------------------------------------------------*
FORM process_view_raw.
  DATA: lv_ans_disp    TYPE char1,
        lv_parse_ftype TYPE char10.

  CLEAR lv_parse_ftype.
  IF gv_current_log_id IS NOT INITIAL.
    SELECT SINGLE file_type FROM zlog_header INTO @lv_parse_ftype
      WHERE log_id = @gv_current_log_id.
    IF sy-subrc = 0 AND lv_parse_ftype <> gc_ftype_csv AND lv_parse_ftype <> gc_ftype_txt.
      RETURN.
    ENDIF.
    IF sy-subrc <> 0 AND p_ftype <> gc_ftype_csv AND p_ftype <> gc_ftype_txt.
      RETURN.
    ENDIF.
  ELSE.
    IF p_ftype <> gc_ftype_csv AND p_ftype <> gc_ftype_txt.
      RETURN.
    ENDIF.
  ENDIF.

  IF gv_current_log_id IS INITIAL.
    MESSAGE s055(zmsg_gr23) DISPLAY LIKE gc_displike_err.
    RETURN.
  ENDIF.

  IF go_grid_detail IS BOUND. go_grid_detail->check_changed_data( ). ENDIF.

  IF gv_data_dirty = abap_true.
    PERFORM show_popup_confirm USING TEXT-056
                                     TEXT-057
                                     TEXT-058
                                     TEXT-059
                                     abap_true
                               CHANGING lv_ans_disp.
  ENDIF.

  IF lv_ans_disp = '2'.
    PERFORM reload_data_from_db USING gv_current_log_id.

    " Refresh full Master-Detail stack after reload from DB.
    PERFORM prepare_master_alv_data.
    PERFORM refresh_detail_alvs.

    IF go_grid_master IS BOUND. go_grid_master->refresh_table_display( is_stable = VALUE #( row = abap_on col = abap_on ) ). ENDIF.
    IF go_grid_detail IS BOUND. go_grid_detail->refresh_table_display( is_stable = VALUE #( row = abap_on col = abap_on ) ). ENDIF.

    gv_edit_mode = abap_off.
    PERFORM switch_alv_mode.
  ENDIF.
  gv_plain_preview = abap_on.
  gv_selected_excel_row = 0.
  " Rebuild plain-text lines from current sheet (F08) before showing editor.
  PERFORM rebuild_raw_string_from_alv USING lv_parse_ftype.
  PERFORM show_raw_preview_ui.


  CLEAR gv_data_dirty.

ENDFORM.

*&---------------------------------------------------------------------*
*& Form PROCESS_SAVE
*& Toolbar Save: flush detail / raw dirty checks; confirm; plain preview path
*& updates ZLOG_ITEM blob or continues parse; else PROCESS_SAVE_DATA.
*&---------------------------------------------------------------------*
FORM process_save.
  DATA: lv_ans_save TYPE char1,
        ls_header   TYPE zlog_header.

  " Push pending detail grid edits into protocol before checks.
  IF go_grid_detail IS BOUND. go_grid_detail->check_changed_data( ). ENDIF.
  "Check if raw file was changed?
  PERFORM is_raw_file_changed.

  IF gv_data_dirty = abap_false.
    MESSAGE s056(zmsg_gr23) DISPLAY LIKE gc_displike_warn.
    RETURN.
  ENDIF.

  SELECT SINGLE log_id, category, file_type FROM zlog_header INTO CORRESPONDING FIELDS OF @ls_header
  WHERE log_id = @gv_current_log_id.


  CLEAR lv_ans_save.
  PERFORM show_popup_confirm USING TEXT-060
                                   TEXT-061
                                   TEXT-058
                                   TEXT-021
                                   abap_false
                             CHANGING lv_ans_save.
  IF lv_ans_save = '1'.

    IF gv_plain_preview = abap_on.

      PERFORM get_text_from_editor.

      DATA lt_struct_errors TYPE string_table.

      PERFORM parse_string_to_raw USING    gt_preview_lines
                                           ls_header-file_type
                                  CHANGING lt_struct_errors.

      PERFORM show_popup_struct_err USING lt_struct_errors.

      go_text_edit->set_textmodified_status(
         status = 0
         ).

      cl_gui_cfw=>flush( ).

    ENDIF.

    PERFORM process_save_data.
*    IF gv_plain_preview = abap_on.
*
*      IF gv_current_log_id IS NOT INITIAL.
*
*        SELECT SINGLE log_id, category, file_type FROM zlog_header INTO CORRESPONDING FIELDS OF @ls_header
*          WHERE log_id = @gv_current_log_id.
*
*        SELECT SINGLE log_id, raw_data FROM zlog_item INTO CORRESPONDING FIELDS OF @ls_item
*          WHERE log_id = @gv_current_log_id
*            AND item_no = 0.
*
*        PERFORM get_text_from_editor.
*
*        PERFORM string_table_to_base64 USING gt_preview_lines
*                                             ls_header-file_type
*                                       CHANGING ls_item-raw_data.
*
*        MODIFY zlog_item FROM ls_item.
*
*        gv_edit_mode = abap_off.
*        go_text_edit->set_readonly_mode( cl_gui_textedit=>true ).
*
*        IF ls_header-category <> gc_stored_file.
*          CLEAR gt_row_dirty.
*          PERFORM continue_from_raw_preview.
*          CLEAR gv_data_dirty.
*        ENDIF.
*
*        IF gv_current_log_id IS INITIAL.
*          MESSAGE s055(zmsg_gr23) DISPLAY LIKE gc_displike_err.
*          RETURN.
*        ENDIF.
*      ENDIF.
*    ELSE.
*      PERFORM process_save_data.
*    ENDIF.
  ENDIF.
ENDFORM.

*&---------------------------------------------------------------------*
*& Form PROCESS_BTN_DOWN_100
*& Download current log file from DB (requires GV_CURRENT_LOG_ID).
*&---------------------------------------------------------------------*
FORM process_btn_down_100.
  IF gv_current_log_id IS INITIAL.
    MESSAGE s057(zmsg_gr23) DISPLAY LIKE gc_displike_err.
    RETURN.
  ENDIF.

  PERFORM download_file USING gv_current_log_id.
ENDFORM.

*&---------------------------------------------------------------------*
*& Form PROCESS_DISPLAY
*& Display mode: flush detail; if dirty, confirm then save blob / continue ALV
*& or reload; cancel path restores raw preview or reloads from DB.
*&---------------------------------------------------------------------*
FORM process_display.
  DATA: lv_ans_disp TYPE char1,
        ls_header   TYPE zlog_header.

  " Flush pending detail edits before dirty checks.
  IF go_grid_detail IS BOUND. go_grid_detail->check_changed_data( ). ENDIF.

  "Check if raw file was changed?
  PERFORM is_raw_file_changed.

  IF gv_data_dirty = abap_false.
    gv_edit_mode = abap_false.
    PERFORM switch_alv_mode.

  ELSE.
    SELECT SINGLE log_id, category, file_type FROM zlog_header INTO CORRESPONDING FIELDS OF @ls_header
      WHERE log_id = @gv_current_log_id.

    CLEAR lv_ans_disp.

*    IF ls_header-category <> gc_stored_file.
*    IF ls_header-category <> gc_stored_file AND gv_plain_preview = abap_off.
*    IF ls_header-category = gc_stored_file OR ls_header-file_type = gc_ftype_xlsx.
    PERFORM show_popup_confirm USING TEXT-056
                                     TEXT-062
                                     TEXT-058
                                     TEXT-059
                                     abap_true
                           CHANGING lv_ans_disp.
*    ELSEIF ls_header-category <> gc_stored_file AND gv_plain_preview = abap_on.
*      gv_edit_mode = abap_off.
*      PERFORM switch_alv_mode.
*    ENDIF.

    IF lv_ans_disp = '1'.

      IF gv_plain_preview = abap_on.

        PERFORM get_text_from_editor.

        DATA lt_struct_errors TYPE string_table.

        PERFORM parse_string_to_raw USING    gt_preview_lines
                                             ls_header-file_type
                                    CHANGING lt_struct_errors.

        PERFORM show_popup_struct_err USING lt_struct_errors.

        go_text_edit->set_textmodified_status(
           status = 0
           ).

        cl_gui_cfw=>flush( ).

      ENDIF.

      PERFORM process_save_data.

    ELSEIF lv_ans_disp = '2'.
      IF gv_plain_preview = abap_on.
        PERFORM show_raw_preview_ui.
        gv_edit_mode = abap_false.
        PERFORM switch_alv_mode.
        CLEAR gv_data_dirty.
      ELSE.
        PERFORM reload_data_from_db USING gv_current_log_id.

        PERFORM prepare_master_alv_data.
        PERFORM refresh_detail_alvs.

        gv_edit_mode = abap_false.
        PERFORM switch_alv_mode.
        CLEAR: gv_data_dirty, gt_row_dirty.
      ENDIF.

    ENDIF.
  ENDIF.
ENDFORM.

*&---------------------------------------------------------------------*
*& Form PROCESS_EXIT_SCREEN
*& If dirty in edit mode, confirm; then FREE GUI objects, clear globals, LEAVE TO SCREEN 0.
*&---------------------------------------------------------------------*
FORM process_exit_screen.

  DATA lv_ans_exit TYPE char1.

  IF gv_edit_mode = abap_true AND gv_data_dirty = abap_true.
    CLEAR lv_ans_exit.
    PERFORM show_popup_confirm USING TEXT-063
                                     TEXT-064
                                     TEXT-065
                                     TEXT-066
                                     abap_false
                               CHANGING lv_ans_exit.

    " Stay on screen when user chooses No / Cancel
    IF lv_ans_exit = '2' OR lv_ans_exit = 'A'.
      RETURN.
    ENDIF.
  ENDIF.

  PERFORM unlock_data.

  " Display mode or user confirmed leave: tear down ALV and return to selection.
  gv_detail_initialized = abap_off.

  PERFORM free_alv_objects.

  CLEAR: gv_plain_preview, gt_preview_lines, gv_data_dirty, gv_selected_excel_row, gv_current_log_id,
         gv_current_page, gt_master_sheets, gt_header_list, gt_excel_raw, gt_error_log.
  LEAVE TO SCREEN 0.
ENDFORM.


*&---------------------------------------------------------------------*
*& Section: Screen 0200 (history) - PAI
*&---------------------------------------------------------------------*

*&---------------------------------------------------------------------*
*& Module  USER_COMMAND_0200  INPUT
*& BACK/EXIT -> PROCESS_EXIT_HISTORY_SCREEN; download -> PROCESS_DOWNLOAD_BULK.
*&---------------------------------------------------------------------*
MODULE user_command_0200 INPUT.

  CASE gv_okcode.
      " History screen 0200: back/exit handling.
    WHEN gc_ucomm_back OR gc_ucomm_exit.
      PERFORM process_exit_history_screen USING gv_okcode.

    WHEN gc_ucomm_down.
      PERFORM process_download_bulk.

    WHEN gc_ucomm_del.
      PERFORM process_delete_bulk.
  ENDCASE.

  CLEAR gv_okcode.
ENDMODULE.

*&---------------------------------------------------------------------*
*& Form PROCESS_EXIT_HISTORY_SCREEN
*& BACK: free history grid + container then LEAVE TO SCREEN 0; else LEAVE PROGRAM.
*&---------------------------------------------------------------------*
FORM process_exit_history_screen USING pv_okcode TYPE sy-ucomm.

  IF pv_okcode = gc_ucomm_back.
    " Release history ALV controls before leaving dynpro 0200.
    IF go_grid_hist IS BOUND. go_grid_hist->free( ). FREE go_grid_hist. ENDIF.
    IF go_cont_hist IS BOUND. go_cont_hist->free( ). FREE go_cont_hist. ENDIF.
    LEAVE TO SCREEN 0.
  ELSE.
    LEAVE PROGRAM.
  ENDIF.
ENDFORM.
