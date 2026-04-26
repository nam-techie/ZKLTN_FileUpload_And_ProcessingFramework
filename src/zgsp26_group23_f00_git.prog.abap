*&---------------------------------------------------------------------*
*& Include  ZGSP26_GROUP23_F00
*&---------------------------------------------------------------------*


*&---------------------------------------------------------------------*
*& Purpose  Subroutines for Group23 screen: splitter/containers, toolbar
*&          tabs, master/detail ALVs, plain-text preview, dynamic master
*&          structure, vertical detail grid, page switch, cleanup.
*&---------------------------------------------------------------------*


*&---------------------------------------------------------------------*
*& Section: Toolbar (worksheet tabs as toolbar buttons)
*&---------------------------------------------------------------------*

*&---------------------------------------------------------------------*
*& Form REFRESH_TABS_TOOLBAR
*& Rebuild tab buttons from GT_MASTER_SHEETS; register function_selected.
*&---------------------------------------------------------------------*
FORM refresh_tabs_toolbar.
  DATA: lt_events    TYPE cntl_simple_events,
        ls_event     TYPE cntl_simple_event,
        lv_fcode     TYPE ui_func,
        lv_text      TYPE text40,
        lv_quickinfo TYPE iconquick.

  go_toolbar_tabs->delete_all_buttons( ).

  LOOP AT gt_master_sheets INTO DATA(ls_sheet).

    IF ls_sheet-sheet_name IS NOT INITIAL.

      lv_fcode     = ls_sheet-page_no.
      lv_text      = ls_sheet-sheet_name.
      lv_quickinfo = ls_sheet-sheet_name.

      DATA(lv_checked) = COND abap_bool(
                           WHEN ls_sheet-page_no = gv_current_page
                           THEN abap_on
                           ELSE abap_off ).

      go_toolbar_tabs->add_button(
        fcode      = lv_fcode
        icon       = icon_xls
        butn_type  = cntb_btype_button
        is_checked = lv_checked
        text       = lv_text
        quickinfo  = lv_quickinfo ).

    ENDIF.

  ENDLOOP.

  ls_event-eventid    = cl_gui_toolbar=>m_id_function_selected.
  ls_event-appl_event = abap_on.
  APPEND ls_event TO lt_events.
  go_toolbar_tabs->set_registered_events( events = lt_events ).
ENDFORM.

*&---------------------------------------------------------------------*
*& Form TRIGGER_ALV_ERROR
*& Purpose: Log ALV protocol error (message 00/398) and revert the cell to
*&         the previous value on the dynamic table backing the grid.
*&---------------------------------------------------------------------*
FORM trigger_alv_error USING    lo_data_changed  TYPE REF TO cl_alv_changed_data_protocol
                                pv_old_value     TYPE string
                                ps_mod_cell      TYPE lvc_s_modi
                                pv_msgv1         TYPE string
                                pv_msgv2         TYPE string
                                pv_msgv3         TYPE string
                                pv_msgv4         TYPE string.


  " Message class '00' / no '398' must expand to & & & & so MSGV1–4 show on popup.
  lo_data_changed->add_protocol_entry(
    i_msgid     = '00'
    i_msgty     = 'E'
    i_msgno     = '398'

    i_msgv1     = pv_msgv1
    i_msgv2     = pv_msgv2
    i_msgv3     = pv_msgv3
    i_msgv4     = pv_msgv4
    i_fieldname = ps_mod_cell-fieldname
    i_row_id    = ps_mod_cell-row_id
  ).

  " Revert ALV cell display to old value.
  lo_data_changed->modify_cell(
    i_row_id    = ps_mod_cell-row_id
    i_fieldname = ps_mod_cell-fieldname
    i_value     = pv_old_value
  ).


ENDFORM.

*&---------------------------------------------------------------------*
*& Form SWITCH_ALV_MODE
*& Toggle edit vs display: detail VALUE column + ready_for_input, or
*& plain preview text editor read-only flag.
*&---------------------------------------------------------------------*
FORM switch_alv_mode.
  DATA: lt_fcat  TYPE lvc_t_fcat,
        lv_ready TYPE i,
        lv_locked TYPE abap_bool VALUE abap_off.

  IF gv_edit_mode = abap_on.

    PERFORM lock_data CHANGING lv_locked.
    IF lv_locked = abap_on.
      gv_edit_mode = abap_off.
    ENDIF.

    lv_ready = 1.
  ELSE.

    PERFORM unlock_data.
    lv_ready = 0.
  ENDIF.

  " Only the detail grid is editable in spreadsheet mode.
  IF go_grid_detail IS BOUND AND gv_plain_preview = abap_off.
    go_grid_detail->get_frontend_fieldcatalog( IMPORTING et_fieldcatalog = lt_fcat ).
    LOOP AT lt_fcat ASSIGNING FIELD-SYMBOL(<ls_fcat>) WHERE fieldname = 'VALUE'.
      <ls_fcat>-edit = gv_edit_mode.
    ENDLOOP.
    go_grid_detail->set_frontend_fieldcatalog( lt_fcat ).
    go_grid_detail->set_ready_for_input( lv_ready ).
    go_grid_detail->set_drop_down_table( it_drop_down = gt_drop_detail ).
    go_grid_detail->refresh_table_display( is_stable = VALUE #( row = abap_on col = abap_on ) ).
    IF go_grid_master IS BOUND.
      go_grid_master->refresh_table_display( is_stable = VALUE #( row = abap_on col = abap_on ) ).
    ENDIF.
    " CSV/TXT plain preview: lock/unlock GUI text control instead.
  ELSEIF go_text_edit IS BOUND AND gv_plain_preview = abap_on.
    IF gv_edit_mode = abap_on.
      go_text_edit->set_readonly_mode( cl_gui_textedit=>false ). " editable
    ELSE.
      go_text_edit->set_readonly_mode( cl_gui_textedit=>true ).  " view only
    ENDIF.
  ENDIF.
ENDFORM.


*&---------------------------------------------------------------------*
*& Section: Screen layout — containers, grids, event wiring
*&---------------------------------------------------------------------*

*&---------------------------------------------------------------------*
*& Form INIT_UI_COMPONENTS
*& One-shot: containers, grids/editor, ALV event registration.
*&---------------------------------------------------------------------*
FORM init_ui_components.
  IF go_cont_tabs IS BOUND. RETURN. ENDIF.

  PERFORM init_containers.
  PERFORM init_grids_and_editor.
  PERFORM register_alv_events.

ENDFORM.

*&---------------------------------------------------------------------*
*& Form INIT_CONTAINERS
*& Create custom controls: tab area, main area, splitter 65/35 columns.
*&---------------------------------------------------------------------*
FORM init_containers.

  CREATE OBJECT go_cont_tabs EXPORTING container_name = 'CC_TABS'.
  CREATE OBJECT go_cont_main EXPORTING container_name = 'CC_MAIN'.

  CREATE OBJECT go_toolbar_tabs EXPORTING parent = go_cont_tabs.

  CREATE OBJECT go_split_main EXPORTING parent = go_cont_main rows = 1 columns = 2.

  go_cont_left  = go_split_main->get_container( row = 1 column = 1 ).
  go_cont_right = go_split_main->get_container( row = 1 column = 2 ).

  go_split_main->set_column_mode( cl_gui_splitter_container=>mode_relative ).
  go_split_main->set_column_width( id = 1 width = 65 ).
  go_split_main->set_column_width( id = 2 width = 35 ).

  cl_gui_cfw=>flush( ).

ENDFORM.

*&---------------------------------------------------------------------*
*& Form INIT_GRIDS_AND_EDITOR
*& Master/detail ALV on splitter children; full-width textedit on CC_MAIN.
*&---------------------------------------------------------------------*
FORM init_grids_and_editor.

  CREATE OBJECT go_grid_master EXPORTING i_parent = go_cont_left.
  CREATE OBJECT go_grid_detail EXPORTING i_parent = go_cont_right.

  CREATE OBJECT go_text_edit
    EXPORTING
      parent                     = go_cont_main
      wordwrap_mode              = cl_gui_textedit=>wordwrap_at_fixed_position
      wordwrap_position          = 255
      wordwrap_to_linebreak_mode = cl_gui_textedit=>wordwrap_off.

  go_text_edit->set_readonly_mode( cl_gui_textedit=>true ).

ENDFORM.

*&---------------------------------------------------------------------*
*& Form REGISTER_ALV_EVENTS
*& Bind lcl_alv_events (include C00) to toolbar + both ALV grids.
*&---------------------------------------------------------------------*
FORM register_alv_events.

  IF go_alv_events IS NOT BOUND. CREATE OBJECT go_alv_events. ENDIF.

  SET HANDLER go_alv_events->on_tab_click FOR go_toolbar_tabs.
  SET HANDLER go_alv_events->on_master_double_click FOR go_grid_master.

  go_grid_detail->register_edit_event( cl_gui_alv_grid=>mc_evt_enter ).
  go_grid_detail->register_edit_event( cl_gui_alv_grid=>mc_evt_modified ).
  SET HANDLER go_alv_events->handle_data_changed FOR go_grid_detail.

  SET HANDLER go_alv_events->on_detail_hotspot_click FOR go_grid_detail.

ENDFORM.

*&---------------------------------------------------------------------*
*& Section: Plain-text preview (CSV/TXT) vs ALV layout
*&---------------------------------------------------------------------*

*&---------------------------------------------------------------------*
*& Form SHOW_RAW_PREVIEW_UI
*& Show GT_PREVIEW_LINES in GUI textedit; hide splitter + tab strip.
*&---------------------------------------------------------------------*
FORM show_raw_preview_ui.

  DATA: lv_full_str TYPE string,
        lv_crlf     TYPE string.

  IF go_text_edit IS NOT BOUND OR go_split_main IS NOT BOUND.
    RETURN.
  ENDIF.

  gt_preview_snapshot = gt_preview_lines.

  " Line break between rows in the stream.
  lv_crlf = cl_abap_char_utilities=>cr_lf.

  " Single string for the whole file body.
  CONCATENATE LINES OF gt_preview_lines INTO lv_full_str SEPARATED BY lv_crlf.

  " Avoid dump: use SET_TEXTSTREAM (string) instead of table-based setters.
  CALL METHOD go_text_edit->set_textstream
    EXPORTING
      text = lv_full_str.


  go_text_edit->set_toolbar_mode(
  EXPORTING
    toolbar_mode = cl_gui_textedit=>false
  ).

  " Visibility: full-width text, hide grid splitter and tabs.
  go_split_main->set_visible( EXPORTING visible = space ).
  go_text_edit->set_visible( EXPORTING visible = abap_on ).

  IF go_cont_tabs IS BOUND.
    go_cont_tabs->set_visible( EXPORTING visible = space ).
  ENDIF.

  " CSV/TXT plain preview: lock/unlock GUI text control instead.
  IF go_text_edit IS BOUND AND gv_plain_preview = abap_on.
    IF gv_edit_mode = abap_on.
      go_text_edit->set_readonly_mode( cl_gui_textedit=>false ). " editable
    ELSE.
      go_text_edit->set_readonly_mode( cl_gui_textedit=>true ).  " view only
    ENDIF.
  ENDIF.

  cl_gui_cfw=>flush( ).

ENDFORM.

*&---------------------------------------------------------------------*
*& Form HIDE_RAW_SHOW_ALV_UI
*& Restore splitter + tabs; hide text preview control.
*&---------------------------------------------------------------------*
FORM hide_raw_show_alv_ui.

  IF go_text_edit IS BOUND.
    go_text_edit->set_visible( EXPORTING visible = space ).
  ENDIF.
  IF go_split_main IS BOUND.
    go_split_main->set_visible( EXPORTING visible = abap_on ).
  ENDIF.
  IF go_cont_tabs IS BOUND.
    go_cont_tabs->set_visible( EXPORTING visible = abap_on ).
  ENDIF.

  cl_gui_cfw=>flush( ).

ENDFORM.

*&---------------------------------------------------------------------*
*& Section: Master ALV — dynamic structure and data
*&---------------------------------------------------------------------*

*&---------------------------------------------------------------------*
*& Form PREPARE_MASTER_ALV_DATA
*& Build dynamic master line type, fill <gfs_master>, snapshot originals.
*&---------------------------------------------------------------------*
FORM prepare_master_alv_data.

  DATA: lt_comp TYPE cl_abap_structdescr=>component_table.

  " 1) Dynamic structure: EXCEL_ROW, STATUS_ICON, data columns, ERR_COUNT.
  PERFORM build_master_struct CHANGING lt_comp.

  IF gv_error = abap_on.
    RETURN.
  ENDIF.

  " 2) Allocate master internal table once, bind field-symbol.
  DATA: lo_struct TYPE REF TO cl_abap_structdescr.
  lo_struct = cl_abap_structdescr=>create( lt_comp ).
  DATA(lo_table) = cl_abap_tabledescr=>create( p_line_type = lo_struct ).

  IF gv_dref_master IS NOT BOUND.
    CREATE DATA gv_dref_master TYPE HANDLE lo_table.
    ASSIGN gv_dref_master->* TO <gfs_master>.
  ENDIF.

  CLEAR <gfs_master>.

  " 3) Rows from <gfs_data> + status LED + error counts.
  PERFORM build_master_data USING lo_struct.

ENDFORM.

*&---------------------------------------------------------------------*
*& Form BUILD_MASTER_STRUCT
*& Component table: EXCEL_ROW, STATUS_ICON, typed columns from header
*& tech names (current sheet), then ERR_COUNT (integer).
*&---------------------------------------------------------------------*
FORM build_master_struct CHANGING pt_comp TYPE cl_abap_structdescr=>component_table.

  DATA: ls_comp      LIKE LINE OF pt_comp,
        lv_base_name TYPE string,
        lv_new_name  TYPE string.

  DATA: lo_type TYPE REF TO cl_abap_typedescr,
        lo_elem TYPE REF TO cl_abap_elemdescr.

  pt_comp = VALUE #( ( name = 'EXCEL_ROW' type = cl_abap_elemdescr=>get_i( ) )
                     ( name = 'STATUS_ICON' type = cl_abap_elemdescr=>get_c( 4 ) )
                     ).

  SORT gt_master_sheets BY page_no.
  READ TABLE gt_master_sheets INTO DATA(ls_master) WITH KEY page_no = gv_current_page BINARY SEARCH.

  IF sy-subrc <> 0.
    gv_error = abap_on.
    MESSAGE: s036(zmsg_gr23) WITH gv_current_page DISPLAY LIKE gc_displike_err.
    RETURN.
  ENDIF.

  DATA ls_hdr TYPE gty_excel_header.

  LOOP AT ls_master-header_list INTO ls_hdr.

    lv_base_name = ls_hdr-tech_name.

    CALL METHOD cl_abap_typedescr=>describe_by_name
      EXPORTING
        p_name         = lv_base_name
      RECEIVING
        p_descr_ref    = lo_type
      EXCEPTIONS
        type_not_found = 1
        OTHERS         = 2.

    IF sy-subrc = 0.
      TRY.
          lo_elem ?= lo_type.
          ls_comp-type = lo_elem.
        CATCH cx_sy_move_cast_error.
          MESSAGE s060(zmsg_gr23) DISPLAY LIKE gc_displike_err.
      ENDTRY.

      PERFORM handle_duplicated_tech_name USING lv_base_name
                                         pt_comp
                               CHANGING  lv_new_name.
      ls_comp-name = lv_new_name.
      APPEND ls_comp TO pt_comp.
    ENDIF.

  ENDLOOP.

  CLEAR ls_comp.
  ls_comp-name = 'ERR_COUNT'.
  ls_comp-type = cl_abap_elemdescr=>get_i( ).
  APPEND ls_comp TO pt_comp.

ENDFORM.


*&---------------------------------------------------------------------*
*& Form DISPLAY_MAIN_ALVS
*& Full master refresh: structure/data, fieldcat, first display, detail.
*&---------------------------------------------------------------------*
FORM display_main_alvs.

  PERFORM prepare_master_alv_data.

  DATA: lt_fcat    TYPE lvc_t_fcat,
        ls_layo    TYPE lvc_s_layo,
        lt_exclude TYPE ui_functions.

  PERFORM build_master_fcat CHANGING lt_fcat ls_layo lt_exclude.

  go_grid_master->set_table_for_first_display(
    EXPORTING is_layout            = ls_layo
              it_toolbar_excluding = lt_exclude
    CHANGING  it_outtab            = <gfs_master>
              it_fieldcatalog      = lt_fcat ).

  cl_gui_cfw=>flush( ).

  PERFORM refresh_detail_alvs.

ENDFORM.

*&---------------------------------------------------------------------*
*& Section: Detail ALV (vertical field list)
*&---------------------------------------------------------------------*

*&---------------------------------------------------------------------*
*& Form REFRESH_DETAIL_ALVS
*& Rebuild GT_VERTICAL_DATA; first display or lightweight grid refresh.
*&---------------------------------------------------------------------*
FORM refresh_detail_alvs.

  DATA: lv_has_error TYPE abap_bool.

  " 1) Vertical rows + dropdown + calendar icon + error text from log.
  PERFORM build_vertical_data CHANGING lv_has_error.

  " 2) Lazy init: first time uses set_table_for_first_display, else frontend FCAT.
  IF gv_detail_initialized = abap_off.
    PERFORM display_detail_first_time USING lv_has_error.
    gv_detail_initialized = abap_on.
  ELSE.
    PERFORM refresh_detail_grid USING lv_has_error.
  ENDIF.

  cl_gui_cfw=>flush( ).

ENDFORM.

*&---------------------------------------------------------------------*
*& Form BUILD_VERTICAL_DATA
*& For selected Excel row: scan headers, map values, DDIC list, date F4,
*& aggregate GT_ERROR_LOG lines into ERROR_MSG / cell colors.
*&---------------------------------------------------------------------*
FORM build_vertical_data CHANGING pv_has_error TYPE abap_bool.

  DATA: lt_values TYPE TABLE OF string,
        lv_val    TYPE string,
        lv_dh     TYPE int4,
        ls_vert   TYPE gty_vertical_data.

  DATA: lt_comp      TYPE cl_abap_structdescr=>component_table,
        ls_comp      LIKE LINE OF lt_comp,
        lv_base_name TYPE string,
        lv_new_name  TYPE string.

  CLEAR: gt_vertical_data, gt_drop_detail.
  CLEAR: lt_values, lv_val, lv_dh.
  pv_has_error = abap_off.

  IF gv_selected_excel_row > 0.
    DATA(lv_tabix) = gv_selected_excel_row - gc_data_start + 1.
    READ TABLE <gfs_master> ASSIGNING FIELD-SYMBOL(<lfs_d_row>) INDEX lv_tabix.

    IF sy-subrc = 0.
      LOOP AT gt_header_list INTO DATA(ls_hdr).

        lv_base_name = ls_hdr-tech_name.

        PERFORM handle_duplicated_tech_name USING lv_base_name
                                   lt_comp
                         CHANGING  lv_new_name.
        ls_comp-name = lv_new_name.
        APPEND ls_comp TO lt_comp.
        ls_hdr-tech_name = lv_new_name.

        ASSIGN COMPONENT ls_hdr-tech_name OF STRUCTURE <lfs_d_row> TO FIELD-SYMBOL(<lfs_val>).
        IF sy-subrc = 0.

          ls_vert = VALUE gty_vertical_data(
                            fieldname = ls_hdr-tech_name
                            descr     = ls_hdr-descr
                            value     = COND #( WHEN <lfs_val> IS INITIAL THEN space ELSE <lfs_val> )
                            row_pos   = sy-tabix ).

          " Fixed list from header (semicolon-separated) -> ALV dropdown handle.
          IF ls_hdr-val_list IS NOT INITIAL.
            lv_dh += 1.
            ls_vert-dd_hndl = lv_dh.
            CLEAR lt_values.
            SPLIT ls_hdr-val_list AT ';' INTO TABLE lt_values.
            LOOP AT lt_values INTO lv_val.
              IF lv_val IS NOT INITIAL.
                APPEND VALUE #( handle = lv_dh value = lv_val ) TO gt_drop_detail.
                IF lines( lt_values ) = 1.
                  APPEND VALUE #( handle = lv_dh value = lv_val ) TO gt_drop_detail.
                ENDIF.
              ENDIF.
            ENDLOOP.
          ENDIF.

          " Calendar hotspot icon for DATE-like components.
          DESCRIBE FIELD <lfs_val> TYPE DATA(lv_ftype).
          IF lv_ftype = cl_abap_typedescr=>typekind_date.
            ls_vert-f4_icon = '@1F@'.
          ENDIF.

          " Concatenate validation messages for this row/column.
          DATA: lv_full_error TYPE string.
          CLEAR lv_full_error.

          LOOP AT gt_error_log INTO DATA(ls_err)
               WHERE row_index = gv_selected_excel_row
                 AND col_pos   = ls_hdr-col_pos.
            IF lv_full_error IS INITIAL.
              lv_full_error = ls_err-message.
            ELSE.
              lv_full_error = lv_full_error && ', ' && ls_err-message.
            ENDIF.
          ENDLOOP.

          IF lv_full_error IS NOT INITIAL.
            ls_vert-error_msg = lv_full_error.
            pv_has_error      = abap_on.
            ls_vert-cell_col  = VALUE #( ( fname = 'VALUE'     color-col = 6 color-int = 1 color-inv = 0 )
                                         ( fname = 'ERROR_MSG' color-col = 6 color-int = 1 color-inv = 0 ) ).
          ENDIF.

          APPEND ls_vert TO gt_vertical_data.
        ENDIF.
      ENDLOOP.
    ENDIF.
  ENDIF.

ENDFORM.

*&---------------------------------------------------------------------*
*& Form DISPLAY_DETAIL_FIRST_TIME
*& Initial detail grid: layout, fieldcat (VALUE edit, F4 icon, ERROR_MSG).
*&---------------------------------------------------------------------*
FORM display_detail_first_time USING pv_has_error TYPE abap_bool.

  DATA: lt_fcat_dt TYPE lvc_t_fcat,
        ls_layo_dt TYPE lvc_s_layo,
        lt_exclude TYPE ui_functions.

  ls_layo_dt-cwidth_opt = abap_on.
  ls_layo_dt-ctab_fname = 'CELL_COL'.
  ls_layo_dt-grid_title = |{ TEXT-033 }|.

  lt_fcat_dt = VALUE #(
    ( fieldname = 'DESCR'     coltext = |{ TEXT-034 }| col_pos = 1 outputlen = 30 )
    ( fieldname = 'FIELDNAME' coltext = |{ TEXT-035 }| col_pos = 2 outputlen = 15 no_out = abap_on )
    ( fieldname = 'VALUE'     coltext = |{ TEXT-036 }| col_pos = 3 outputlen = 30 intlen = 100
      edit      = gv_edit_mode drdn_alias = abap_on drdn_field = 'DD_HNDL' )
    ( fieldname = 'DD_HNDL'   coltext = ''             col_pos = 4 outputlen = 30 no_out = abap_on tech = abap_on )
    ( fieldname = 'F4_ICON'   coltext = ''             col_pos = 5 outputlen = 3
      hotspot   = abap_on icon = abap_on just = 'C' )
    ( fieldname = 'ERROR_MSG' coltext = |{ TEXT-037 }| col_pos = 6 outputlen = 40
      no_out    = COND #( WHEN pv_has_error = abap_on THEN space ELSE abap_on )
      hotspot   = COND #( WHEN pv_has_error = abap_on THEN abap_on ELSE space ) )
  ).

  lt_exclude = VALUE #(
 ( cl_gui_alv_grid=>mc_fc_check )
 ( cl_gui_alv_grid=>mc_fc_refresh )
 ( cl_gui_alv_grid=>mc_fc_loc_cut )
 ( cl_gui_alv_grid=>mc_fc_loc_paste )
 ( cl_gui_alv_grid=>mc_fc_loc_paste_new_row )
 ( cl_gui_alv_grid=>mc_fc_loc_undo )
 ( cl_gui_alv_grid=>mc_fc_loc_paste )
 ( cl_gui_alv_grid=>mc_fc_loc_append_row )
 ( cl_gui_alv_grid=>mc_fc_loc_insert_row )
 ( cl_gui_alv_grid=>mc_fc_loc_delete_row )
 ( cl_gui_alv_grid=>mc_fc_loc_copy_row )
 ( cl_gui_alv_grid=>mc_fc_print )
 ( cl_gui_alv_grid=>mc_fc_print_prev )
 ( cl_gui_alv_grid=>mc_fc_view_grid )
 ( cl_gui_alv_grid=>mc_fc_view_excel )
 ( cl_gui_alv_grid=>mc_fc_view_crystal )
 ( cl_gui_alv_grid=>mc_fc_word_processor )
 ( cl_gui_alv_grid=>mc_fc_pc_file )
 ( cl_gui_alv_grid=>mc_fc_send )
 ( cl_gui_alv_grid=>mc_fc_to_office )
 ( cl_gui_alv_grid=>mc_fc_call_abc )
 ( cl_gui_alv_grid=>mc_fc_expcrdesig )
 ( cl_gui_alv_grid=>mc_fc_expcrtempl )
 ( cl_gui_alv_grid=>mc_fc_html )
 ( cl_gui_alv_grid=>mc_fc_url_copy_to_clipboard )
 ( cl_gui_alv_grid=>mc_fc_variant_admin )
 ( cl_gui_alv_grid=>mc_fc_graph )
 ( cl_gui_alv_grid=>mc_fc_info )
 ( cl_gui_alv_grid=>mc_fc_loc_copy )
 ( cl_gui_alv_grid=>mc_fc_detail )
 ( cl_gui_alv_grid=>mc_mb_sum )
 ( cl_gui_alv_grid=>mc_fc_subtot )
 ( cl_gui_alv_grid=>mc_fc_views )
 ( cl_gui_alv_grid=>mc_fc_sort )
 ( cl_gui_alv_grid=>mc_mb_export )
 ( cl_gui_alv_grid=>mc_mb_variant )
 ( cl_gui_alv_grid=>mc_mb_view )
 ).

  go_grid_detail->set_drop_down_table( it_drop_down = gt_drop_detail ).
  go_grid_detail->set_table_for_first_display(
    EXPORTING is_layout       = ls_layo_dt
              it_toolbar_excluding   = lt_exclude
    CHANGING  it_outtab       = gt_vertical_data
              it_fieldcatalog = lt_fcat_dt ).

ENDFORM.

*&---------------------------------------------------------------------*
*& Form REFRESH_DETAIL_GRID
*& Update grid title, ERROR_MSG visibility/hotspot, dropdown, refresh.
*&---------------------------------------------------------------------*
FORM refresh_detail_grid USING pv_has_error TYPE abap_bool.

  DATA: lt_fcat_dt TYPE lvc_t_fcat,
        ls_layo_dt TYPE lvc_s_layo.

  go_grid_detail->get_frontend_layout( IMPORTING es_layout = ls_layo_dt ).

  ls_layo_dt-grid_title = COND string(
    WHEN gv_selected_excel_row = 0
      THEN |{ TEXT-038 }|
    ELSE
      |{ TEXT-039 } { gv_selected_excel_row }|
  ).

  go_grid_detail->set_frontend_layout( ls_layo_dt ).
  go_grid_detail->get_frontend_fieldcatalog( IMPORTING et_fieldcatalog = lt_fcat_dt ).

  LOOP AT lt_fcat_dt ASSIGNING FIELD-SYMBOL(<ls_fcat_err>) WHERE fieldname = 'ERROR_MSG'.
    <ls_fcat_err>-no_out = COND #( WHEN pv_has_error = abap_on THEN space ELSE abap_on ).
    IF <ls_fcat_err>-no_out IS INITIAL.
      <ls_fcat_err>-hotspot = abap_on.
    ELSE.
      CLEAR <ls_fcat_err>-hotspot.
    ENDIF.
  ENDLOOP.

  go_grid_detail->set_frontend_fieldcatalog( lt_fcat_dt ).
  go_grid_detail->set_drop_down_table( it_drop_down = gt_drop_detail ).
  go_grid_detail->refresh_table_display( is_stable = VALUE #( row = abap_on col = abap_on ) ).

ENDFORM.


*&---------------------------------------------------------------------*
*& Section: Worksheet tab change (toolbar)
*&---------------------------------------------------------------------*

*&---------------------------------------------------------------------*
*& Form CHANGE_PAGE_LOGIC
*& Load new page into workspace, rebuild toolbar + master + detail.
*&---------------------------------------------------------------------*
FORM change_page_logic.

  LOOP AT gt_master_sheets ASSIGNING FIELD-SYMBOL(<ls_sheet>)
       WHERE page_no <> gv_current_page.
  ENDLOOP.

  DATA(lv_page) = gv_current_page.

  PERFORM load_page_to_workspace USING lv_page.
  PERFORM refresh_tabs_toolbar.

  gv_selected_excel_row = 0.

  IF gv_dref_master IS BOUND.
    FREE gv_dref_master.
  ENDIF.
  UNASSIGN <gfs_master>.

  PERFORM prepare_master_alv_data.

  " Shared master fieldcat builder (same as initial display).
  DATA: lt_fcat    TYPE lvc_t_fcat,
        ls_layo    TYPE lvc_s_layo,
        lt_exclude TYPE ui_functions.

  PERFORM build_master_fcat CHANGING lt_fcat ls_layo lt_exclude.

  ls_layo-grid_title = |{ TEXT-040 }|.

  go_grid_master->set_table_for_first_display(
    EXPORTING is_layout            = ls_layo
              it_toolbar_excluding = lt_exclude
    CHANGING  it_outtab            = <gfs_master>
              it_fieldcatalog      = lt_fcat ).

  cl_gui_cfw=>flush( ).

  PERFORM refresh_detail_alvs.

ENDFORM.

*&---------------------------------------------------------------------*
*& Form BUILD_MASTER_FCAT
*& Master ALV columns: keys, LEDs, dynamic data cols, ERR_COUNT; toolbar
*& excludes insert/delete row.
*&---------------------------------------------------------------------*
FORM build_master_fcat CHANGING pt_fcat    TYPE lvc_t_fcat
                                ps_layo    TYPE lvc_s_layo
                                pt_exclude TYPE ui_functions.

  DATA: lt_comp      TYPE cl_abap_structdescr=>component_table,
        ls_comp      LIKE LINE OF lt_comp,
        lv_base_name TYPE string,
        lv_new_name  TYPE string.

  ps_layo-cwidth_opt = abap_on.
  ps_layo-zebra      = abap_on.
  ps_layo-sel_mode   = 'A'.
  ps_layo-grid_title = TEXT-026.

  pt_fcat = VALUE #(
    ( fieldname = 'EXCEL_ROW'
      coltext   = TEXT-027
      col_pos   = 1
*      hotspot   = abap_on
*      key       = abap_on
      just      = 'C' )

    ( fieldname = 'STATUS_ICON'
      coltext   = TEXT-028
      col_pos   = 2
      icon      = abap_on
      just      = 'C'
      outputlen = 4
      scrtext_s = TEXT-028
      scrtext_m = TEXT-028
      scrtext_l = TEXT-028 )
  ).

  DATA(lv_pos) = 2.

  LOOP AT gt_header_list INTO DATA(ls_hdr).

    lv_base_name = ls_hdr-tech_name.

    PERFORM handle_duplicated_tech_name USING lv_base_name
                                   lt_comp
                         CHANGING  lv_new_name.
    ls_comp-name = lv_new_name.
    APPEND ls_comp TO lt_comp.

    lv_pos += 1.
    APPEND VALUE #(
      fieldname = lv_new_name
      coltext   = ls_hdr-descr
      col_pos   = lv_pos
      key       = ls_hdr-is_key
    ) TO pt_fcat.
  ENDLOOP.

  APPEND VALUE #(
    fieldname = 'ERR_COUNT'
    coltext   = TEXT-029
    col_pos   = lv_pos + 1
    just      = 'C'
  ) TO pt_fcat.

  pt_exclude = VALUE #(
    ( cl_gui_alv_grid=>mc_fc_check )
    ( cl_gui_alv_grid=>mc_fc_refresh )
    ( cl_gui_alv_grid=>mc_fc_loc_cut )
    ( cl_gui_alv_grid=>mc_fc_loc_paste )
    ( cl_gui_alv_grid=>mc_fc_loc_paste_new_row )
    ( cl_gui_alv_grid=>mc_fc_loc_undo )
    ( cl_gui_alv_grid=>mc_fc_loc_paste )
    ( cl_gui_alv_grid=>mc_fc_loc_append_row )
    ( cl_gui_alv_grid=>mc_fc_loc_insert_row )
    ( cl_gui_alv_grid=>mc_fc_loc_delete_row )
    ( cl_gui_alv_grid=>mc_fc_loc_copy_row )
    ( cl_gui_alv_grid=>mc_fc_print )
    ( cl_gui_alv_grid=>mc_fc_print_prev )
    ( cl_gui_alv_grid=>mc_fc_view_grid )
    ( cl_gui_alv_grid=>mc_fc_view_excel )
    ( cl_gui_alv_grid=>mc_fc_view_crystal )
    ( cl_gui_alv_grid=>mc_fc_word_processor )
    ( cl_gui_alv_grid=>mc_fc_pc_file )
    ( cl_gui_alv_grid=>mc_fc_send )
    ( cl_gui_alv_grid=>mc_fc_to_office )
    ( cl_gui_alv_grid=>mc_fc_call_abc )
    ( cl_gui_alv_grid=>mc_fc_expcrdesig )
    ( cl_gui_alv_grid=>mc_fc_expcrtempl )
    ( cl_gui_alv_grid=>mc_fc_html )
    ( cl_gui_alv_grid=>mc_fc_url_copy_to_clipboard )
    ( cl_gui_alv_grid=>mc_fc_variant_admin )
    ( cl_gui_alv_grid=>mc_fc_graph )
    ( cl_gui_alv_grid=>mc_fc_info )
    ( cl_gui_alv_grid=>mc_fc_loc_copy )
    ( cl_gui_alv_grid=>mc_fc_detail )
    ( cl_gui_alv_grid=>mc_mb_sum )
    ( cl_gui_alv_grid=>mc_fc_subtot )
    ( cl_gui_alv_grid=>mc_fc_views )
    ( cl_gui_alv_grid=>mc_fc_sort )
    ( cl_gui_alv_grid=>mc_mb_export )
    ( cl_gui_alv_grid=>mc_mb_variant )
    ( cl_gui_alv_grid=>mc_mb_view )
    ).

ENDFORM.


*&---------------------------------------------------------------------*
*& Section: Cleanup
*&---------------------------------------------------------------------*

*&---------------------------------------------------------------------*
*& Form FREE_ALV_OBJECTS
*& Free GUI controls and data references on leave / rebuild.
*&---------------------------------------------------------------------*
FORM free_alv_objects.
  IF go_text_edit IS BOUND. go_text_edit->free( ). FREE go_text_edit. ENDIF.

  IF go_grid_master IS BOUND. go_grid_master->free( ). FREE go_grid_master. ENDIF.
  IF go_grid_detail IS BOUND. go_grid_detail->free( ). FREE go_grid_detail. ENDIF.

  IF go_cont_left  IS BOUND. go_cont_left->free( ).  FREE go_cont_left.  ENDIF.
  IF go_cont_right IS BOUND. go_cont_right->free( ). FREE go_cont_right. ENDIF.

  IF go_split_main  IS BOUND. go_split_main->free( ).  FREE go_split_main.  ENDIF.

  IF go_toolbar_tabs IS BOUND. go_toolbar_tabs->free( ). FREE go_toolbar_tabs. ENDIF.
  IF go_cont_tabs    IS BOUND. go_cont_tabs->free( ).    FREE go_cont_tabs.    ENDIF.
  IF go_cont_main    IS BOUND. go_cont_main->free( ).    FREE go_cont_main.    ENDIF.

  FREE go_alv_events.

  IF gv_dref_master IS BOUND.
    FREE gv_dref_master.
  ENDIF.
  UNASSIGN <gfs_master>.

ENDFORM.

*&---------------------------------------------------------------------*
*& Form BUILD_MASTER_DATA
*& Single pass over <gfs_data>: MOVE-CORRESPONDING into master line shape,
*& then fill EXCEL_ROW, ERR_COUNT, STATUS_ICON (red/yellow/green).
*&---------------------------------------------------------------------*
FORM build_master_data USING lo_struct TYPE REF TO cl_abap_structdescr.

  DATA: lv_dref_line TYPE REF TO data.

  CREATE DATA lv_dref_line TYPE HANDLE lo_struct.
  FIELD-SYMBOLS: <lfs_m_row> TYPE any,
                 <lfs_val>   TYPE any,
                 <lfs_stat>  TYPE any.
  ASSIGN lv_dref_line->* TO <lfs_m_row>.

  " One loop over data rows only (O(N)); no per-column inner loops here.

  IF <gfs_data> IS NOT ASSIGNED.
    MESSAGE s063(zmsg_gr23) DISPLAY LIKE gc_displike_err.
    RETURN.
  ENDIF.

  LOOP AT <gfs_data> ASSIGNING FIELD-SYMBOL(<lfs_d_row>).
    UNASSIGN <lfs_stat>.
    CLEAR <lfs_m_row>.
    DATA(lv_real_row) = sy-tabix + gc_data_start - 1.

    " Fast copy: identically named components from data row to master row;
    " custom columns (EXCEL_ROW, STATUS_ICON, ERR_COUNT) set explicitly below.
    MOVE-CORRESPONDING <lfs_d_row> TO <lfs_m_row>.
*    <lfs_d_row> = <lfs_m_row>.

    " Custom columns (once per output row).
    ASSIGN COMPONENT 'EXCEL_ROW' OF STRUCTURE <lfs_m_row> TO <lfs_val>.
    <lfs_val> = lv_real_row.

    " Error count for this logical spreadsheet row.
    DATA(lv_err_count) = 0.
    LOOP AT gt_error_log TRANSPORTING NO FIELDS WHERE row_index = lv_real_row.
      lv_err_count += 1.
    ENDLOOP.

    ASSIGN COMPONENT 'ERR_COUNT' OF STRUCTURE <lfs_m_row> TO <lfs_val>.
    <lfs_val> = lv_err_count.

    " Traffic light: errors / dirty / OK.
    ASSIGN COMPONENT 'STATUS_ICON' OF STRUCTURE <lfs_m_row> TO <lfs_stat>.
    IF <lfs_stat> IS ASSIGNED.
*      IF lv_err_count > 0.
*        <lfs_stat> = icon_led_red.
*      ELSEIF line_exists( gt_row_dirty[ page_no = gv_current_page excel_row = lv_real_row ] ).
*        <lfs_stat> = icon_led_yellow.
*      ELSE.
*        <lfs_stat> = icon_led_green.
*      ENDIF.

      IF line_exists( gt_row_dirty[ page_no = gv_current_page excel_row = lv_real_row ] ).
        <lfs_stat> = icon_led_yellow.
      ELSEIF lv_err_count > 0.
        <lfs_stat> = icon_led_red.
      ELSE.
        <lfs_stat> = icon_led_green.
      ENDIF.
    ENDIF.

    APPEND <lfs_m_row> TO <gfs_master>.
  ENDLOOP.

ENDFORM.

*&---------------------------------------------------------------------*
*& Form SHOW_DETAIL_ALV_ERROR_POPUP
*& Wrap long ERROR_MSG into fixed-width lines; POPUP_WITH_TABLE_DISPLAY.
*&---------------------------------------------------------------------*
FORM show_detail_alv_error_popup USING pv_error_msg TYPE string.

  CONSTANTS lc_line_max TYPE i VALUE 80.

  DATA: lt_popup_lines TYPE TABLE OF char100,
        lv_msg_len     TYPE i,
        lv_offset      TYPE i,
        lv_take        TYPE i,
        ls_popup_line  TYPE char100.

  lv_msg_len = strlen( pv_error_msg ).
  lv_offset = 0.

  WHILE lv_offset < lv_msg_len.
    lv_take = nmin( val1 = lv_msg_len - lv_offset
                    val2 = lc_line_max ).

    CLEAR ls_popup_line.
    ls_popup_line = substring(
      val = pv_error_msg
      off = lv_offset
      len = lv_take
    ).

    APPEND ls_popup_line TO lt_popup_lines.
    lv_offset = lv_offset + lv_take.
  ENDWHILE.

  CALL FUNCTION 'POPUP_WITH_TABLE_DISPLAY'
    EXPORTING
      startpos_col = 5
      startpos_row = 3
      endpos_col   = 90
      endpos_row   = 20
      titletext    = TEXT-037
    TABLES
      valuetab     = lt_popup_lines
    EXCEPTIONS
      break_off    = 1
      OTHERS       = 2.

ENDFORM.
