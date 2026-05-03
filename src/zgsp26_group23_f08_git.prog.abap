*&---------------------------------------------------------------------*
*& Include          ZGSP26_GROUP23_F08
*&---------------------------------------------------------------------*

*&---------------------------------------------------------------------*
*& Purpose
*&  Workspace sync between dynamic ALV (<GFS_DATA>), per-sheet GT_data_RAW
*&  in GT_MASTER_SHEETS, and plain-text GT_PREVIEW_LINES for CSV/TXT export.
*&---------------------------------------------------------------------*

*&---------------------------------------------------------------------*
*& Section: Dynamic grid <-> coordinate store (per sheet)
*&---------------------------------------------------------------------*

*&---------------------------------------------------------------------*
*& Form REVERSE_MAP_TO_RAW
*& Walk <gfs_data> and current sheet header_list: update or append cells in
*& <lfs_master>-data_raw so raw coordinates match latest ALV edits (for log base64).
*&---------------------------------------------------------------------*
FORM reverse_map_to_raw.

  DATA: ls_raw     TYPE gty_data_cell,
        lv_tabix   TYPE i,
        lv_raw_idx TYPE i.

  FIELD-SYMBOLS: <lfs_master> TYPE gty_master_sheet,
                 <lfs_line>   TYPE any,
                 <lfs_value>  TYPE any.

  " Resolve master sheet row for the page currently shown on ALV (ASSIGNING = in-place edits).
  SORT gt_master_sheets BY page_no.
  READ TABLE gt_master_sheets ASSIGNING <lfs_master>
       WITH KEY page_no = gv_current_page BINARY SEARCH.

  IF sy-subrc <> 0.
    MESSAGE s039 DISPLAY LIKE gc_displike_err.
    RETURN.
  ENDIF.

  IF <gfs_data> IS NOT ASSIGNED.
    MESSAGE s063 DISPLAY LIKE gc_displike_err.
    RETURN.
  ENDIF.

  " Each row of the dynamic table (post-edit values).
  LOOP AT <gfs_data> ASSIGNING <lfs_line>.
    lv_tabix = sy-tabix.

    " Logical data row index (matches GT_data_RAW row coordinate).
    DATA(lv_real_row) = lv_tabix + gc_data_start - 1.

    " Each column from this sheet's header map (col_pos aligns with dynamic structure).
    LOOP AT <lfs_master>-header_list INTO DATA(ls_header).

      " Cell value by physical column index on the dynamic line.
      ASSIGN COMPONENT ls_header-col_pos OF STRUCTURE <lfs_line> TO <lfs_value>.

      IF sy-subrc = 0 AND <lfs_value> IS ASSIGNED.
        " Normalize to string for storage in coordinate table.
        DATA: lv_string_val TYPE string.
        lv_string_val = <lfs_value>.
*        CONDENSE lv_string_val. !OBSOLETE SYNTAX
        lv_string_val = condense( val = lv_string_val ).

        " Look up existing raw cell on this sheet.
        READ TABLE <lfs_master>-data_raw INTO ls_raw
             WITH KEY row = lv_real_row
                      col = ls_header-col_pos.
        lv_raw_idx = sy-tabix.

        IF sy-subrc = 0.
          " CASE A: cell exists -> MODIFY only when value changed.
          IF ls_raw-value <> lv_string_val.
            ls_raw-value = lv_string_val.
            MODIFY <lfs_master>-data_raw FROM ls_raw INDEX lv_raw_idx.
          ENDIF.

        ELSE.
          " CASE B: no raw row yet -> APPEND when user filled a previously empty cell.
          IF lv_string_val IS NOT INITIAL.
            CLEAR ls_raw.
            ls_raw-row   = lv_real_row.
            ls_raw-col   = ls_header-col_pos.
            ls_raw-value = lv_string_val.
            APPEND ls_raw TO <lfs_master>-data_raw.
          ENDIF.
        ENDIF.

      ENDIF.
    ENDLOOP.
  ENDLOOP.
ENDFORM.

*&---------------------------------------------------------------------*
*& Form FLUSH_WS_TO_MASTER
*& Persist workspace (<gfs_data> -> per-sheet data_raw via reverse_map)
*& into gt_master_sheets. Call before switching tabs or on save.
*&---------------------------------------------------------------------*
FORM flush_ws_to_master USING pv_page_no TYPE i.
  IF pv_page_no <= 0.
    RETURN.
  ENDIF.
  IF <gfs_data> IS NOT ASSIGNED.
    RETURN.
  ENDIF.

  SORT gt_master_sheets BY page_no.
  READ TABLE gt_master_sheets ASSIGNING FIELD-SYMBOL(<ls_ms>) WITH KEY page_no = pv_page_no BINARY SEARCH.
  IF sy-subrc <> 0.
    RETURN.
  ENDIF.

  IF gv_dref_table IS NOT BOUND OR <ls_ms>-dref_data IS NOT BOUND.
    RETURN.
  ENDIF.
  IF gv_dref_table <> <ls_ms>-dref_data.
    RETURN.
  ENDIF.

  IF go_grid_detail IS BOUND AND gv_edit_mode = abap_on.
    go_grid_detail->check_changed_data( ).
  ENDIF.

  PERFORM reverse_map_to_raw.
  <ls_ms>-error_log = gt_error_log.
ENDFORM.

*&---------------------------------------------------------------------*
*& Form LOAD_PAGE_TO_WORKSPACE
*& Copy one sheet from gt_master_sheets into global workspace variables.
*& Rebinds <GFS_DATA> to that sheet's DREF when present.
*&---------------------------------------------------------------------*
FORM load_page_to_workspace USING pv_page_no TYPE i.

  " Load master row for this page index
  SORT gt_master_sheets BY page_no.

  READ TABLE gt_master_sheets
    INTO DATA(ls_sheet)
    WITH KEY page_no = pv_page_no
    BINARY SEARCH.

  IF sy-subrc <> 0.
    RETURN.
  ENDIF.

  " Expose sheet data to globals used by ALV / processing
  gv_current_page = ls_sheet-page_no.
  gt_header_list  = ls_sheet-header_list.
  gt_data_raw     = ls_sheet-data_raw.
  gt_error_log    = ls_sheet-error_log.
  gv_dref_table   = ls_sheet-dref_data.

  " Point the ALV field-symbol at this sheet's dynamic internal table
  IF gv_dref_table IS BOUND.
    ASSIGN gv_dref_table->* TO <gfs_data>.
  ELSE.
    UNASSIGN <gfs_data>.
  ENDIF.

ENDFORM.
