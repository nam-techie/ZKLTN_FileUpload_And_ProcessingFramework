*&---------------------------------------------------------------------*
*& Include          ZGSP26_GROUP23_O01
*&---------------------------------------------------------------------*

*&---------------------------------------------------------------------*
*& Purpose
*&  PBO for dynpros 0100 (main) and 0200 (history): PF-STATUS / TITLEBAR,
*&  first-time GUI init, plain preview vs ALV layout, history grid build.
*&---------------------------------------------------------------------*

*&---------------------------------------------------------------------*
*& Section: Screen 0100 - PBO
*&---------------------------------------------------------------------*

*&---------------------------------------------------------------------*
*& Module  STATUS_0100  OUTPUT
*& Refresh PF-STATUS / TITLEBAR for screen 100 via SET_STATUS_0100.
*&---------------------------------------------------------------------*
MODULE status_0100 OUTPUT.

  PERFORM set_status_0100.
ENDMODULE.

*&---------------------------------------------------------------------*
*& Module  INIT_0100  OUTPUT
*& One-shot UI: raw preview path vs full splitter + sheet 1 + master/detail ALVs;
*& then SWITCH_ALV_MODE when not in plain preview.
*&---------------------------------------------------------------------*
MODULE init_0100 OUTPUT.
  IF gv_error = abap_on AND gv_plain_preview = abap_off.
    RETURN.
  ENDIF.

  IF gv_plain_preview = abap_on.
    IF go_cont_main IS NOT BOUND.
      PERFORM init_ui_components.
      PERFORM show_raw_preview_ui.
      gv_selected_data_row = 0.
    ENDIF.
  ELSEIF go_cont_main IS NOT BOUND AND p_stor <> abap_on.

    CLEAR gv_data_dirty.

    PERFORM init_ui_components.
    PERFORM refresh_tabs_toolbar.

    " Always show first valid sheet after initial layout build.
    PERFORM load_page_to_workspace USING 1.
    PERFORM display_main_alvs.

    gv_selected_data_row = 0.
  ENDIF.

  IF gv_plain_preview = abap_off.
    PERFORM switch_alv_mode.
  ENDIF.

ENDMODULE.

*&---------------------------------------------------------------------*
*& Section: Screen 0100 - PF-STATUS helpers
*&---------------------------------------------------------------------*

*&---------------------------------------------------------------------*
*& Form SET_STATUS_0100
*& Plain preview vs ALV: exclude RAW_CONT / SAVE / VIEW_RAW by stored-file rules
*& and file type; SET PF-STATUS display vs change + titlebar texts.
*&---------------------------------------------------------------------*
FORM set_status_0100 .
  DATA lt_excl TYPE ui_functions.

  CLEAR lt_excl.

  IF gv_plain_preview = abap_on.
    IF gv_edit_mode = abap_off.
      APPEND gc_ucomm_view_raw TO lt_excl.
      SET PF-STATUS gc_stt_disp EXCLUDING lt_excl.
      SET TITLEBAR gc_ttbar_t001 WITH TEXT-067.
    ELSE.
      APPEND gc_ucomm_view_raw TO lt_excl.
      APPEND gc_ucomm_raw_cont TO lt_excl.
      SET PF-STATUS gc_stt_change EXCLUDING lt_excl.
      SET TITLEBAR gc_ttbar_t001 WITH TEXT-068.
    ENDIF.

  ELSEIF gv_plain_preview = abap_off.
    IF gv_edit_mode = abap_off.

      PERFORM build_exclude_view_raw CHANGING lt_excl.
      APPEND gc_ucomm_raw_cont TO lt_excl.
      SET PF-STATUS gc_stt_disp EXCLUDING lt_excl.
      SET TITLEBAR gc_ttbar_t001 WITH TEXT-069.
    ELSE.

      PERFORM build_exclude_view_raw CHANGING lt_excl.
      APPEND gc_ucomm_raw_cont TO lt_excl.
      APPEND gc_ucomm_view_raw TO lt_excl.
      SET PF-STATUS gc_stt_change EXCLUDING lt_excl.
      SET TITLEBAR gc_ttbar_t001 WITH TEXT-070.
    ENDIF.
  ENDIF.

ENDFORM.

*&---------------------------------------------------------------------*
*& Form BUILD_EXCLUDE_VIEW_RAW
*& Hide FCODE VIEW_RAW when current context is not CSV/TXT (selection or DB header).
*&---------------------------------------------------------------------*
FORM build_exclude_view_raw CHANGING pt_excl TYPE ui_functions.

  DATA lv_db_ftype TYPE zlog_header-file_type.

  CLEAR pt_excl.

  DATA(lv_show) = abap_off.

  IF gv_current_log_id IS NOT INITIAL.
    SELECT SINGLE file_type FROM zlog_header INTO @lv_db_ftype
      WHERE log_id = @gv_current_log_id.
    IF sy-subrc = 0.
      lv_show = xsdbool( lv_db_ftype = gc_ftype_csv OR lv_db_ftype = gc_ftype_txt ).
    ENDIF.
  ELSE.
    lv_show = xsdbool( p_ftype = gc_ftype_csv OR p_ftype = gc_ftype_txt ).
  ENDIF.

  IF lv_show = abap_off.
    APPEND gc_ucomm_view_raw TO pt_excl.
  ENDIF.

ENDFORM.


*&---------------------------------------------------------------------*
*& Section: Screen 0200 (history) - PBO
*&---------------------------------------------------------------------*

*&---------------------------------------------------------------------*
*& Module  STATUS_0200  OUTPUT
*& Fixed PF-STATUS S002 and title TEXT-071 for history list screen.
*&---------------------------------------------------------------------*
MODULE status_0200 OUTPUT.
  SET PF-STATUS 'S002'.
  SET TITLEBAR gc_ttbar_t002 WITH TEXT-071.

ENDMODULE.

*&---------------------------------------------------------------------*
*& Module  INIT_0200  OUTPUT
*& Skip when GV_ERROR; else build (or refresh) history ALV on first PBO pass.
*&---------------------------------------------------------------------*
MODULE init_0200 OUTPUT.
  IF gv_error = abap_on.
    RETURN.
  ENDIF.

  PERFORM build_history_alv_grid.
ENDMODULE.
