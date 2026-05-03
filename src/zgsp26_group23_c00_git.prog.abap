*----------------------------------------------------------------------*
* Include  ZGSP26_GROUP23_C00
*----------------------------------------------------------------------*

*----------------------------------------------------------------------*
* Role     Local event-handler class for ALV grids in program          *
*           (master left, detail right, history, toolbar).
* Contents lcl_alv_events: tab page switch, master double-click,
*           detail data_changed, history double-click, date hotspot.
*----------------------------------------------------------------------*

*======================================================================*
* 1. CLASS DEFINITION
*======================================================================*
CLASS lcl_alv_events DEFINITION.
  PUBLIC SECTION.
    " Toolbar: user picked another tab (FCODE encodes target page number).
    METHODS: on_tab_click
      FOR EVENT function_selected OF cl_gui_toolbar
      IMPORTING fcode.

    " Master ALV (left): double-click selects spreadsheet row and loads detail.
    METHODS: on_master_double_click
      FOR EVENT double_click OF cl_gui_alv_grid
      IMPORTING e_row. " e_column.

    " Detail ALV (vertical layout): cell edit -> sync + validation pipeline.
    METHODS: handle_data_changed
      FOR EVENT data_changed OF cl_gui_alv_grid
      IMPORTING er_data_changed. " sender.

    " History ALV: open chosen log entry (with file-type guard for stored files).
    METHODS: on_hist_grid_double_click
      FOR EVENT double_click OF cl_gui_alv_grid
      IMPORTING e_row. " e_column.

    " Detail ALV: hotspot on F4_ICON opens calendar for editable date fields.
    METHODS: on_detail_hotspot_click
      FOR EVENT hotspot_click OF cl_gui_alv_grid
      IMPORTING e_column_id es_row_no.

ENDCLASS.

*======================================================================*
* 2. CLASS IMPLEMENTATION
*======================================================================*
CLASS lcl_alv_events IMPLEMENTATION.

  METHOD on_tab_click.
    " FCODE is the new page index (CHAR) matching gv_current_page semantics.
    DATA(lv_new_page) = CONV i( fcode ).
    IF lv_new_page <> gv_current_page.
      " Multi-sheet: persist the sheet user is leaving before switching page.
      PERFORM flush_ws_to_master USING gv_current_page.
      gv_current_page = lv_new_page.
      PERFORM change_page_logic.
    ENDIF.
  ENDMETHOD.

  METHOD on_master_double_click.
    FIELD-SYMBOLS: <lfs_master_row> TYPE any,
                   <lfs_data_row>   TYPE any.

    IF <gfs_master> IS NOT ASSIGNED.
      MESSAGE s063 DISPLAY LIKE gc_displike_err.
      RETURN.
    ENDIF.

    " Map grid row index to master row and read DATA_ROW (logical sheet row).
    READ TABLE <gfs_master> ASSIGNING <lfs_master_row> INDEX e_row-index.
    IF sy-subrc = 0.
      ASSIGN COMPONENT 'DATA_ROW' OF STRUCTURE <lfs_master_row> TO <lfs_data_row>.
      IF sy-subrc = 0.
        gv_selected_data_row = <lfs_data_row>.
        " Refresh both detail panels for the new selection.
        PERFORM prepare_detail_alvs.
      ENDIF.
    ENDIF.
  ENDMETHOD.

  METHOD handle_data_changed.
    " Merge grid deltas into backing structure and re-run validation.
    PERFORM sync_and_revalidate USING er_data_changed. "sender.
  ENDMETHOD.

  METHOD on_hist_grid_double_click.
    READ TABLE gt_history_list INTO DATA(ls_hist) INDEX e_row-index.
    IF sy-subrc = 0.
      IF ls_hist-category = gc_stored_file.
        MESSAGE s028 DISPLAY LIKE gc_displike_warn.
        RETURN.
      ENDIF.
      gv_current_log_id = ls_hist-log_id.
      PERFORM process_history_selected USING ls_hist-log_id.
    ENDIF.
  ENDMETHOD.

  METHOD on_detail_hotspot_click.

    DATA ls_vert_err TYPE gty_vertical_data.

    " Dedicated column: show full validation message in a popup.
    IF e_column_id-fieldname = 'ERROR_MSG'.
      READ TABLE gt_vertical_data INTO ls_vert_err INDEX es_row_no-row_id.
      IF sy-subrc = 0 AND ls_vert_err-error_msg IS NOT INITIAL.
        PERFORM show_detail_alv_error_popup USING ls_vert_err-error_msg.
      ENDIF.
      RETURN.
    ENDIF.

    " Calendar flow applies only to the F4/search icon column.
    IF e_column_id-fieldname <> 'F4_ICON'.
      RETURN.
    ENDIF.

    " Block date F4 while display-only (no edits allowed).
    IF gv_edit_mode = abap_off.
      RETURN.
    ENDIF.

    " Detail row key: ES_ROW_NO-ROW_ID (not E_ROW_ID / LVC_S_ROW without ROW_ID).
    READ TABLE gt_vertical_data INTO DATA(ls_vert) INDEX es_row_no-row_id.
    IF sy-subrc <> 0. RETURN. ENDIF.

    " Icon marks date-capable rows; ignore hotspot on blank icon.
    IF ls_vert-f4_icon IS INITIAL.
      RETURN.
    ENDIF.

    " Seed F4 initial month from cell value when plausible, else SY-DATUM.
    DATA: lv_date_sel TYPE sy-datum.
    IF ls_vert-value IS NOT INITIAL.
      CALL FUNCTION 'DATE_CHECK_PLAUSIBILITY'
        EXPORTING
          date                      = CONV dats( ls_vert-value )
        EXCEPTIONS
          plausibility_check_failed = 1
          OTHERS                    = 2.
      IF sy-subrc <> 0.
        lv_date_sel = sy-datum.
      ENDIF.
    ENDIF.

    " Standard SAP date picker.
    CALL FUNCTION 'F4_DATE'
      EXPORTING
        date_for_first_month = lv_date_sel
      IMPORTING
        select_date          = lv_date_sel
      EXCEPTIONS
        OTHERS               = 1.

    " Abort quietly on cancel / FM failure.
    IF sy-subrc <> 0 OR lv_date_sel IS INITIAL. RETURN. ENDIF.

    " Write chosen date into <gfs_data> row that feeds master ALV preparation.
    DATA(lv_tabix) = gv_selected_data_row - gc_data_start + 1.

    IF <gfs_data> IS NOT ASSIGNED.
      MESSAGE s063 DISPLAY LIKE gc_displike_err.
      RETURN.
    ENDIF.

    READ TABLE <gfs_data> ASSIGNING FIELD-SYMBOL(<lfs_d_row>) INDEX lv_tabix.
    IF sy-subrc <> 0. RETURN. ENDIF.

    ASSIGN COMPONENT ls_vert-fieldname OF STRUCTURE <lfs_d_row> TO FIELD-SYMBOL(<lfs_fld>).
    IF sy-subrc <> 0. RETURN. ENDIF.

    <lfs_fld> = lv_date_sel.
    gv_data_dirty = abap_on.
    INSERT VALUE #( page_no = gv_current_page data_row = gv_selected_data_row ) INTO TABLE gt_row_dirty.

    " Mirror manual edit path: row validation, master rebuild, grids refresh.
    PERFORM revalidate_single_row USING lv_tabix.

    PERFORM prepare_master_alv_data.

    IF go_grid_master IS BOUND.
      go_grid_master->refresh_table_display( is_stable = VALUE #( row = abap_on col = abap_on ) ).
    ENDIF.
    PERFORM prepare_detail_alvs.
  ENDMETHOD.

ENDCLASS.

*======================================================================*
* 3. GLOBAL OBJECT DECLARATION
*======================================================================*
" Single application-wide reference; instantiate where ALVs register events.
DATA: go_alv_events TYPE REF TO lcl_alv_events.
