*&---------------------------------------------------------------------*
*& Include          ZGSP26_GROUP23_F08
*&---------------------------------------------------------------------*

*&---------------------------------------------------------------------*
*& Purpose
*&  Workspace sync between dynamic ALV (<GFS_DATA>), per-sheet GT_EXCEL_RAW
*&  in GT_MASTER_SHEETS, and plain-text GT_PREVIEW_LINES for CSV/TXT export.
*&---------------------------------------------------------------------*

*&---------------------------------------------------------------------*
*& Section: Dynamic grid <-> coordinate store (per sheet)
*&---------------------------------------------------------------------*

*&---------------------------------------------------------------------*
*& Form REVERSE_MAP_TO_RAW
*& Walk <gfs_data> and current sheet header_list: update or append cells in
*& <lfs_master>-excel_raw so raw coordinates match latest ALV edits (for log JSON).
*&---------------------------------------------------------------------*
FORM reverse_map_to_raw.

  DATA: ls_raw     TYPE gty_excel_cell,
        lv_tabix   TYPE i,
        lv_raw_idx TYPE i.

  FIELD-SYMBOLS: <lfs_master> TYPE gty_master_sheet,
                 <lfs_line>   TYPE any,
                 <lfs_value>  TYPE any.

  " Resolve master sheet row for the page currently shown on ALV (ASSIGNING = in-place edits).
  READ TABLE gt_master_sheets ASSIGNING <lfs_master>
       WITH KEY page_no = gv_current_page.

  IF sy-subrc <> 0.
    MESSAGE s039(zmsg_gr23) DISPLAY LIKE gc_displike_err.
    RETURN.
  ENDIF.

  IF <gfs_data> IS NOT ASSIGNED.
      MESSAGE s063(zmsg_gr23) DISPLAY LIKE gc_displike_err.
    RETURN.
  ENDIF.

  " Each row of the dynamic table (post-edit values).
  LOOP AT <gfs_data> ASSIGNING <lfs_line>.
    lv_tabix = sy-tabix.

    " Logical Excel row index (matches GT_EXCEL_RAW row coordinate).
    DATA(lv_real_row) = lv_tabix + gc_data_start - 1.

    " Each column from this sheet's header map (col_pos aligns with dynamic structure).
    LOOP AT <lfs_master>-header_list INTO DATA(ls_header).

      " Cell value by physical column index on the dynamic line.
      ASSIGN COMPONENT ls_header-col_pos OF STRUCTURE <lfs_line> TO <lfs_value>.

      IF sy-subrc = 0 AND <lfs_value> IS ASSIGNED.

        " Normalize to string for storage in coordinate table.
        DATA: lv_string_val TYPE string.
        lv_string_val = <lfs_value>.
        CONDENSE lv_string_val.

        " Look up existing raw cell on this sheet.
        READ TABLE <lfs_master>-excel_raw INTO ls_raw
             WITH KEY row = lv_real_row
                      col = ls_header-col_pos.
        lv_raw_idx = sy-tabix.

        IF sy-subrc = 0.
          " CASE A: cell exists -> MODIFY only when value changed.
          IF ls_raw-value <> lv_string_val.
            ls_raw-value = lv_string_val.
            MODIFY <lfs_master>-excel_raw FROM ls_raw INDEX lv_raw_idx.
          ENDIF.

        ELSE.
          " CASE B: no raw row yet -> APPEND when user filled a previously empty cell.
          IF lv_string_val IS NOT INITIAL.
            CLEAR ls_raw.
            ls_raw-row   = lv_real_row.
            ls_raw-col   = ls_header-col_pos.
            ls_raw-value = lv_string_val.
            APPEND ls_raw TO <lfs_master>-excel_raw.
          ENDIF.
        ENDIF.

      ENDIF.
    ENDLOOP.
  ENDLOOP.
ENDFORM.

*&---------------------------------------------------------------------*
*& Form FLUSH_WS_TO_MASTER
*& Persist workspace (<gfs_data> -> per-sheet excel_raw via reverse_map)
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
  READ TABLE gt_master_sheets INTO DATA(ls_sheet) WITH KEY page_no = pv_page_no BINARY SEARCH.
  IF sy-subrc <> 0.
    RETURN.
  ENDIF.

  " Expose sheet data to globals used by ALV / processing
  gv_current_page = ls_sheet-page_no.
  gt_header_list  = ls_sheet-header_list.
  gt_excel_raw    = ls_sheet-excel_raw.
  gt_error_log    = ls_sheet-error_log.
  gv_dref_table   = ls_sheet-dref_data.

  " Point the ALV field-symbol at this sheet's dynamic internal table
  IF gv_dref_table IS BOUND.
    ASSIGN gv_dref_table->* TO <gfs_data>.
  ELSE.
    UNASSIGN <gfs_data>.
  ENDIF.

ENDFORM.

*&---------------------------------------------------------------------*
*& Section: Plain-text preview rebuild from in-memory sheet
*&---------------------------------------------------------------------*

*&---------------------------------------------------------------------*
*& Form REBUILD_RAW_STRING_FROM_ALV
*& FLUSH current page; rebuild GT_PREVIEW_LINES (descr row, rule row, then
*& data rows from excel_raw with CSV/TXT delimiter and padding).
*&---------------------------------------------------------------------*
FORM rebuild_raw_string_from_alv USING pv_ftype TYPE char10.

  "First: flush current edits from the ALV into gt_master_sheets
  "so in-memory sheet state matches what the user sees on screen
  PERFORM flush_ws_to_master USING gv_current_page.

  DATA: lv_line      TYPE string,
        lv_separator TYPE char1,
        lv_cur_row   TYPE i.

  " Pick delimiter by file type (CSV vs plain text)
  IF pv_ftype = gc_ftype_csv.
    lv_separator = ','. " Could be ';' depending on locale / export rules
  ELSE.
    lv_separator = cl_abap_char_utilities=>horizontal_tab. " Tab for TXT
  ENDIF.

  CLEAR gt_preview_lines.

  " Read the active sheet from gt_master_sheets
  " (CSV/TXT flows often use a single sheet - still use current page)
  SORT gt_master_sheets BY page_no.
  READ TABLE gt_master_sheets INTO DATA(ls_master) WITH KEY page_no = gv_current_page BINARY SEARCH.
  IF sy-subrc <> 0.
    " Missing row - likely inconsistent state; fall back to first sheet
    READ TABLE gt_master_sheets INTO ls_master INDEX 1.
    IF sy-subrc <> 0.
      MESSAGE s054(zmsg_gr23) DISPLAY LIKE gc_displike_err.
      RETURN.
    ENDIF.
  ENDIF.

  " Headers must follow physical column order
  DATA(lt_header_sorted) = ls_master-header_list.
  SORT lt_header_sorted BY col_pos.

  " Build preview line 1: human-readable descriptions (DESCR)
  CLEAR lv_line.
  LOOP AT lt_header_sorted INTO DATA(ls_hdr).
    IF sy-tabix = 1.
      lv_line = ls_hdr-descr.
    ELSE.
      lv_line = |{ lv_line }{ lv_separator }{ ls_hdr-descr }|.
    ENDIF.
  ENDLOOP.
  APPEND lv_line TO gt_preview_lines.

  "Build preview line 2: rule string (TECH_NAME + *, +, [KEY], [RNG], [LIST])
  CLEAR lv_line.
  LOOP AT lt_header_sorted INTO ls_hdr.

    DATA(lv_rule) = ls_hdr-tech_name.

    " Re-append validation flags to the technical name
    IF ls_hdr-is_mand = abap_on.
      lv_rule = lv_rule && '*'.
    ENDIF.
    IF ls_hdr-is_pos = abap_on.
      lv_rule = lv_rule && '+'.
    ENDIF.
    IF ls_hdr-is_key = abap_on.
      lv_rule = lv_rule && '[KEY]'.
    ENDIF.
    IF ls_hdr-rng_low IS NOT INITIAL OR ls_hdr-rng_high IS NOT INITIAL.
      lv_rule = lv_rule && |[RNG:{ ls_hdr-rng_low }-{ ls_hdr-rng_high }]|.
    ENDIF.
    IF ls_hdr-val_list IS NOT INITIAL.
      lv_rule = lv_rule && |[LIST:{ ls_hdr-val_list }]|.
    ENDIF.

    IF sy-tabix = 1.
      lv_line = lv_rule.
    ELSE.
      lv_line = |{ lv_line }{ lv_separator }{ lv_rule }|.
    ENDIF.
  ENDLOOP.
  APPEND lv_line TO gt_preview_lines.

  " From row 3 onward: data lines from the sheet's coordinate table
  " Sort cells by row/column so we can emit one text line per Excel row
  DATA(lt_raw_sorted) = ls_master-excel_raw.
  SORT lt_raw_sorted BY row col.

  CLEAR: lv_cur_row, lv_line.

  LOOP AT lt_raw_sorted INTO DATA(ls_raw).
    " New physical row in the sheet
    IF lv_cur_row <> ls_raw-row.
      " Flush the previous row buffer (if any)
      IF lv_cur_row IS NOT INITIAL.
        APPEND lv_line TO gt_preview_lines.
      ENDIF.
      lv_cur_row = ls_raw-row.
      " Leading empty columns: pad with delimiters before first non-empty cell
      lv_line = repeat( val = lv_separator occ = ( ls_raw-col - 1 ) ).
      lv_line = lv_line && ls_raw-value.
    ELSE.
      " Same row: append next cell value
      lv_line = |{ lv_line }{ lv_separator }{ ls_raw-value }|.
    ENDIF.
  ENDLOOP.

  " Append the last buffered data row
  IF lv_cur_row IS NOT INITIAL.
    APPEND lv_line TO gt_preview_lines.
  ENDIF.
ENDFORM.
