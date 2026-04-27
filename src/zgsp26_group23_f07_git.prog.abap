*&---------------------------------------------------------------------*
*& Include          ZGSP26_GROUP23_F07
*&---------------------------------------------------------------------*

*&---------------------------------------------------------------------*
*& Purpose
*&  Plain-text preview continuation: editor -> GT_PREVIEW_LINES, parse to
*&  ALV pipeline, dirty-row diff vs snapshot, GUI helpers (confirm popup,
*&  textedit modified flag).
*&---------------------------------------------------------------------*

*&---------------------------------------------------------------------*
*& Section: Raw preview -> spreadsheet ALV
*&---------------------------------------------------------------------*

*&---------------------------------------------------------------------*
*& Form CONTINUE_FROM_RAW_PREVIEW - RAW_CONT (parse text -> ALV)
*& Call save_log only when gv_current_log_id is initial (new CSV/TXT upload cleared in KLTN).
*& Opened from history: log_id set in C00 -> skip re-logging / no duplicate save messaging.
*&---------------------------------------------------------------------*
FORM continue_from_raw_preview.

  DATA: lv_ftype_db      TYPE zlog_header-file_type,
        lv_ftype4        TYPE char10,
        lt_struct_errors TYPE string_table.

  CHECK gv_plain_preview = abap_on AND gt_preview_lines IS NOT INITIAL.

  IF gv_current_log_id IS NOT INITIAL.
    SELECT SINGLE file_type FROM zlog_header INTO @lv_ftype_db
      WHERE log_id = @gv_current_log_id.
    IF sy-subrc = 0.
      lv_ftype4 = lv_ftype_db.
    ELSE.
      lv_ftype4 = p_ftype.
    ENDIF.
  ELSE.
    lv_ftype4 = p_ftype.
  ENDIF.
  " Pull latest text from the GUI editor into the backend before parsing
  PERFORM get_text_from_editor.

  CLEAR gv_error.

  PERFORM parse_string_to_raw USING    gt_preview_lines lv_ftype4
                              CHANGING lt_struct_errors.

  IF gv_error = abap_on.
    IF lt_struct_errors IS NOT INITIAL.
      DATA: lt_err_display TYPE TABLE OF char200,
            ls_err_line    TYPE char200.

      CLEAR lt_err_display.
      ls_err_line = TEXT-045.
      APPEND ls_err_line TO lt_err_display.
      LOOP AT lt_struct_errors INTO DATA(lv_struct_err).
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
      IF sy-subrc <> 0.                                   "#EC CI_SUBRC
      ENDIF.
    ELSE.
      MESSAGE s034(zmsg_gr23) DISPLAY LIKE gc_displike_err.
    ENDIF.
    RETURN.
  ENDIF.


  IF <gfs_data> IS NOT ASSIGNED OR lines( <gfs_data> ) = 0.
    MESSAGE s035(zmsg_gr23) DISPLAY LIKE gc_displike_err.
    RETURN.
  ENDIF.


  " Diff preview vs snapshot -> gt_row_dirty (only when baseline exists)
  IF gt_preview_snapshot IS NOT INITIAL.
    DATA: lv_snp1 TYPE string,
          lv_snp2 TYPE string,
          lv_cur1 TYPE string,
          lv_cur2 TYPE string.

    CLEAR: lv_snp1, lv_snp2, lv_cur1, lv_cur2.
    READ TABLE gt_preview_snapshot INDEX 1 INTO lv_snp1.
    READ TABLE gt_preview_snapshot INDEX 2 INTO lv_snp2.
    READ TABLE gt_preview_lines    INDEX 1 INTO lv_cur1.
    READ TABLE gt_preview_lines    INDEX 2 INTO lv_cur2.

    CLEAR gt_row_dirty.

    IF lv_cur1 <> lv_snp1 OR lv_cur2 <> lv_snp2.
      " Header lines changed -> treat every data row as modified (yellow)
      DATA: lv_d_idx TYPE i.
      lv_d_idx = gc_data_start.
      WHILE lv_d_idx <= lines( gt_preview_lines ).
        INSERT VALUE gty_dirty_line( page_no = 1 data_row = lv_d_idx ) INTO TABLE gt_row_dirty.
        lv_d_idx = lv_d_idx + 1.
      ENDWHILE.
    ELSE.
      " Header unchanged -> mark only data rows that differ line by line
      DATA: lv_max_lines TYPE i,
            lv_snap_line TYPE string,
            lv_curr_line TYPE string,
            lv_row       TYPE i.

      lv_max_lines = nmax( val1 = lines( gt_preview_lines )
                           val2 = lines( gt_preview_snapshot ) ).

      lv_row = gc_data_start.
      WHILE lv_row <= lv_max_lines.
        CLEAR: lv_snap_line, lv_curr_line.
        READ TABLE gt_preview_snapshot INDEX lv_row INTO lv_snap_line.
        READ TABLE gt_preview_lines    INDEX lv_row INTO lv_curr_line.

        IF lv_curr_line <> lv_snap_line.
          INSERT VALUE gty_dirty_line( page_no = 1 data_row = lv_row ) INTO TABLE gt_row_dirty.
          gv_data_dirty = abap_on.
        ENDIF.
        lv_row = lv_row + 1.
      ENDWHILE.
    ENDIF.
  ENDIF.

  PERFORM load_page_to_workspace USING 1.

  CLEAR gv_plain_preview.
  gv_detail_initialized = abap_off.
  gv_current_page       = 1.

  PERFORM hide_raw_show_alv_ui.
  PERFORM refresh_tabs_toolbar.

  IF gv_dref_master IS BOUND.
    FREE gv_dref_master.
  ENDIF.
  UNASSIGN <gfs_master>.

  PERFORM display_main_alvs.
ENDFORM.

*&---------------------------------------------------------------------*
*& Section: GUI textedit
*&---------------------------------------------------------------------*

*&---------------------------------------------------------------------*
*& Form GET_TEXT_FROM_EDITOR
*& GET_TEXTSTREAM + FLUSH; split CRLF (fallback LF) into GT_PREVIEW_LINES for parsers.
*&---------------------------------------------------------------------*
FORM get_text_from_editor.

  DATA: lv_full_text TYPE string,
        lv_crlf      TYPE string.

  IF go_text_edit IS BOUND.

    "  Use the native API that returns one string (textstream)
    "    Avoid table-based getters that can raise unsupported_table_type
    CALL METHOD go_text_edit->get_textstream
      IMPORTING
        text = lv_full_text.


    " Force SAP GUI to push pending edits from screen to app server (required)
    cl_gui_cfw=>flush( ).

    " Empty editor -> clear preview and exit
    IF lv_full_text IS INITIAL.
      CLEAR gt_preview_lines.
      RETURN.
    ENDIF.

    " Split on real Windows line breaks (CRLF)
    lv_crlf = cl_abap_char_utilities=>cr_lf.

    CLEAR gt_preview_lines.

    " Break the single buffer into one string_table line per row
    SPLIT lv_full_text AT lv_crlf INTO TABLE gt_preview_lines.

    " Fallback for LF-only sources (Linux exports, some Web GUI paths)
    "    If CRLF split left a single long line, retry with plain LF
    IF lines( gt_preview_lines ) <= 1.
      DATA: lv_lf TYPE string.
      lv_lf = cl_abap_char_utilities=>newline.
      SPLIT lv_full_text AT lv_lf INTO TABLE gt_preview_lines.
    ENDIF.
  ENDIF.
ENDFORM.

*&---------------------------------------------------------------------*
*& Section: Shared popups / dirty detection
*&---------------------------------------------------------------------*

*&---------------------------------------------------------------------*
*& Form SHOW_POPUP_CONFIRM
*& POPUP_TO_CONFIRM: title, question, two buttons, optional cancel; answer in PV_ANSWER.
*&---------------------------------------------------------------------*
FORM show_popup_confirm USING    pv_title  TYPE clike
                                 pv_text   TYPE clike
                                 pv_btn1   TYPE clike
                                 pv_btn2   TYPE clike
                                 pv_cancel TYPE abap_bool
                        CHANGING pv_answer TYPE char1.

  CALL FUNCTION 'POPUP_TO_CONFIRM'
    EXPORTING
      titlebar              = CONV string( pv_title )
      text_question         = CONV string( pv_text )
      text_button_1         = CONV char15( pv_btn1 )
      icon_button_1         = 'ICON_OKAY'
      text_button_2         = CONV char15( pv_btn2 )
      icon_button_2         = 'ICON_CANCEL'
      display_cancel_button = pv_cancel
    IMPORTING
      answer                = pv_answer.

ENDFORM.

*&---------------------------------------------------------------------*
*& Form IS_RAW_FILE_CHANGED
*& Ask the textedit control whether the user changed the raw preview.
*& Sets gv_data_dirty when the editor reports modified = true.
*&---------------------------------------------------------------------*
FORM is_raw_file_changed .
  IF go_text_edit IS BOUND.
    DATA: lv_is_modified TYPE i.

    "  Query TextEdit modified flag from the control
    go_text_edit->get_textmodified_status( IMPORTING status = lv_is_modified ).
    cl_gui_cfw=>flush( ). " Always flush after GUI reads

    "  Mirror that into the global dirty flag
    IF lv_is_modified = 1.
      gv_data_dirty = abap_on.
    ENDIF.
  ENDIF.
ENDFORM.
