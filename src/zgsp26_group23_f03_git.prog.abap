*&---------------------------------------------------------------------*
*& Include          ZGSP26_GROUP23_F03
*&---------------------------------------------------------------------*

*&---------------------------------------------------------------------*
*& Purpose
*&  Group23 report driver: entry event, MAIN_PROCESS routing, RTTI-based
*&  dynamic table from headers + raw cells, list reporting for header errors.
*&---------------------------------------------------------------------*

*&---------------------------------------------------------------------*
*& Section: Main orchestration
*&---------------------------------------------------------------------*

*&---------------------------------------------------------------------*
*& Form MAIN_PROCESS
*& Routes P_HIST / P_VAL / P_STOR: optional Base64 of path, local vs server
*& file read, preview flag, persist log, CALL SCREEN 100 when applicable.
*&---------------------------------------------------------------------*
FORM main_process .

  CLEAR: gv_current_log_id, gt_row_dirty, gv_error, gv_plain_preview.

  DATA: lv_file_base64 TYPE string,
        lv_xstring     TYPE xstring.

  IF p_file IS NOT INITIAL AND ( p_val = abap_on OR p_stor = abap_on ).
    " Encode selected path for DB / log payload when validate or store is on.
    PERFORM convert_file_to_base64 USING    p_file
                                   CHANGING lv_file_base64.
  ENDIF.

  IF p_hist = abap_on.
    " History mode: list / open prior uploads (separate from validate flow).
    PERFORM view_history_screen.
  ELSEIF p_val = abap_on.
    IF p_local = abap_on.
      IF p_ftype = gc_ftype_xlsx.
        " PC path: XLSX via FDT wrapper (Z_READ_EXCEL_SHEET_SAFE inside F01).
        PERFORM read_excel_local USING p_file lv_xstring.
      ELSE.
        " PC path: CSV/TXT lines (or XSTRING from DB on retry — see F01).
        PERFORM read_text_local USING p_file p_ftype lv_xstring.
      ENDIF.
    ELSE.
      IF p_ftype = gc_ftype_xlsx.
        " Application server path: binary read + same FDT sheet loop as local.
        PERFORM read_excel_server USING    p_file
                                  CHANGING lv_file_base64.
      ELSE.
        " Application server path: UTF-8 text + Base64 side output.
        PERFORM read_text_server USING    p_file p_ftype
                                 CHANGING lv_file_base64.
      ENDIF.
    ENDIF.

    IF gv_error = abap_off AND <gfs_data> IS ASSIGNED.
      IF gt_preview_lines IS NOT INITIAL.
        gv_plain_preview = abap_on.
      ELSE.
        MESSAGE s058 DISPLAY LIKE gc_displike_err.
      ENDIF.

      " Persist upload metadata (type + optional Base64) before dynpro.
      PERFORM save_log USING p_ftype
                             lv_file_base64.

      CALL SCREEN 100.

    ENDIF.
  ELSEIF p_stor = abap_on.

    IF p_server = abap_on.

      IF p_ftype = gc_ftype_xlsx.
        " Application server path: binary read + same FDT sheet loop as local.
        PERFORM read_excel_server USING    p_file
                                  CHANGING lv_file_base64.
      ELSE.
        " Application server path: UTF-8 text + Base64 side output.
        PERFORM read_text_server USING    p_file p_ftype
                                 CHANGING lv_file_base64.
      ENDIF.
    ENDIF.

    IF lv_file_base64 IS INITIAL.
      RETURN.
    ENDIF.

    PERFORM save_log USING p_ftype lv_file_base64.
  ENDIF.

ENDFORM.

*&---------------------------------------------------------------------*
*& Section: Dynamic internal table (RTTI pipeline)
*&---------------------------------------------------------------------*

*&---------------------------------------------------------------------*
*& Form BUILD_DYNAMIC_DATA
*& Orchestrates: component list + header errors, else allocate <GFS_DATA> and
*& fill from GT_DATA_RAW (see GET / GENERATE / FILL forms below).
*&---------------------------------------------------------------------*
FORM build_dynamic_data USING pv_sheet_name       TYPE string
                        CHANGING pt_header_errors TYPE string_table.

  " Bail out early if we already have an error flag
  IF gv_error = abap_on.
    RETURN.
  ENDIF.

  DATA: lt_comp         TYPE cl_abap_structdescr=>component_table,
        lo_struct       TYPE REF TO cl_abap_structdescr.

  " Gather components and check for structure errors
  PERFORM get_dynamic_components USING    pv_sheet_name
                                 CHANGING lt_comp
                                          pt_header_errors.

  " Create the dynamic internal table based on the components
  PERFORM generate_dynamic_table USING    lt_comp
                                 CHANGING lo_struct.

  IF gv_error = abap_on.
    RETURN.
  ENDIF.

  " Map the raw excel data into our newly created dynamic table
  PERFORM fill_dynamic_data USING lo_struct.

ENDFORM.

*&---------------------------------------------------------------------*
*& Form GET_DYNAMIC_COMPONENTS
*& Uses RTTI to build table components and handles duplicate names
*& (duplicate labels -> PT_HEADER_ERRORS; duplicate DDIC names -> suffix).
*&---------------------------------------------------------------------*
FORM get_dynamic_components USING    pv_sheet_prefix  TYPE string
                            CHANGING pt_comp          TYPE cl_abap_structdescr=>component_table
                                     pt_header_errors TYPE string_table.

  TYPES: BEGIN OF lty_seen_col,
           descr   TYPE string,
           col_pos TYPE i,
         END OF lty_seen_col.

  DATA: lt_seen_cols TYPE HASHED TABLE OF lty_seen_col WITH UNIQUE KEY descr,
        ls_seen      TYPE lty_seen_col.

  DATA: ls_comp      LIKE LINE OF pt_comp,
        lo_type      TYPE REF TO cl_abap_typedescr,
        lo_elem      TYPE REF TO cl_abap_elemdescr,
        lv_base_name TYPE string,
        lv_new_name  TYPE string,
        lv_err_msg   TYPE string.

  FIELD-SYMBOLS: <lfs_header> TYPE gty_data_header.

  " Loop through the header list to build the components.
  " Using ASSIGNING so we can update the technical name directly if needed.
  LOOP AT gt_header_list ASSIGNING <lfs_header>.

    IF <lfs_header>-tech_name IS INITIAL.

      lv_err_msg = TEXT-133.
      REPLACE '&1' IN lv_err_msg WITH |{ <lfs_header>-col_pos }|.

      PERFORM add_header_error USING    lv_err_msg
                                        pv_sheet_prefix
                               CHANGING pt_header_errors.
      CONTINUE.
    ENDIF.


    lv_base_name = <lfs_header>-tech_name.

    " Keep track of descriptions to prevent exact duplicates
    ls_seen-descr   = <lfs_header>-descr.
    ls_seen-col_pos = <lfs_header>-col_pos.

    " Try to insert into our tracking table
    INSERT ls_seen INTO TABLE lt_seen_cols.

    IF sy-subrc <> 0.
      " If it fails, this description already exists. Find the original one.
      READ TABLE lt_seen_cols INTO DATA(ls_orig)
        WITH TABLE KEY descr = <lfs_header>-descr.

      lv_err_msg = TEXT-081.
      REPLACE '&1' IN lv_err_msg WITH |{ <lfs_header>-col_pos }|.
      REPLACE '&2' IN lv_err_msg WITH |{ ls_orig-col_pos }|.
      REPLACE '&3' IN lv_err_msg WITH <lfs_header>-descr.

      PERFORM add_header_error USING lv_err_msg
                                     pv_sheet_prefix
                               CHANGING pt_header_errors.

      " Skip creating the component for this column and move on
      CONTINUE.
    ENDIF.

    " Resolve any duplicate technical names (e.g., KUNNR -> KUNNR1)
    PERFORM handle_duplicated_tech_name USING    lv_base_name
                                                 pt_comp
                                        CHANGING lv_new_name.

    ls_comp-name = lv_new_name.

    " Describe the data element to get its type properties
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
          " Cast down to elementary description
          lo_elem ?= lo_type.
          ls_comp-type = lo_elem.
          APPEND ls_comp TO pt_comp.

        CATCH cx_sy_move_cast_error.
          " Type exists but it's not an elementary type (e.g., it's a struct/table)
          lv_err_msg = TEXT-082.
          REPLACE '&1' IN lv_err_msg WITH |{ <lfs_header>-col_pos }|.
          REPLACE '&2' IN lv_err_msg WITH lv_base_name.

          PERFORM add_header_error USING lv_err_msg
                                         pv_sheet_prefix
                                   CHANGING pt_header_errors.

      ENDTRY.
    ELSE.
      " The data element or type doesn't exist in the system
      lv_err_msg = TEXT-083.
      REPLACE '&1' IN lv_err_msg WITH |{ <lfs_header>-col_pos }|.
      REPLACE '&2' IN lv_err_msg WITH lv_base_name.

      PERFORM add_header_error USING lv_err_msg
                                     pv_sheet_prefix
                               CHANGING pt_header_errors.

    ENDIF.

  ENDLOOP.

ENDFORM.

*&---------------------------------------------------------------------*
*& Form add_header_error
*&---------------------------------------------------------------------*
FORM add_header_error USING    pv_err_msg TYPE string
                               pv_sheet_prefix TYPE string
                      CHANGING pt_header_errors TYPE string_table.

  IF pv_sheet_prefix IS NOT INITIAL.

    DATA(lv_sheet_msg) = replace(
      val  = TEXT-152
      sub  = '&'
      with = pv_sheet_prefix
    ).

    READ TABLE pt_header_errors TRANSPORTING NO FIELDS
      WITH KEY table_line = lv_sheet_msg.

    IF sy-subrc <> 0.
      APPEND lv_sheet_msg TO pt_header_errors.
    ENDIF.

  ENDIF.


  APPEND |  { pv_err_msg }| TO pt_header_errors.
  gv_error = abap_on.

ENDFORM.

*&---------------------------------------------------------------------*
*& Form build_header_rule_msg
*&---------------------------------------------------------------------*
FORM build_header_rule_msg USING    pv_col_pos TYPE i
                                    pv_msg     TYPE string
                           CHANGING pv_result  TYPE string.

  pv_result = |{ TEXT-087 } { pv_col_pos }: { pv_msg }|.

ENDFORM.

*&---------------------------------------------------------------------*
*& Form GENERATE_DYNAMIC_TABLE
*& Defines the structure and allocates memory for the dynamic table
*& (CREATE DATA GV_DREF_TABLE, ASSIGN to <GFS_DATA> global field-symbol).
*&---------------------------------------------------------------------*
FORM generate_dynamic_table USING    pt_comp   TYPE cl_abap_structdescr=>component_table
                            CHANGING lo_struct TYPE REF TO cl_abap_structdescr.

  DATA: lo_table TYPE REF TO cl_abap_tabledescr.

  TRY.
      " Build the blueprints for the line and the table
      lo_struct = cl_abap_structdescr=>create( pt_comp ).
      lo_table  = cl_abap_tabledescr=>create( p_line_type = lo_struct ).

    CATCH cx_root.
      " This rarely happens unless the renaming logic above is flawed
      gv_error = abap_on.
      MESSAGE s010 DISPLAY LIKE gc_displike_err.
      RETURN.
  ENDTRY.

  " Allocate memory and assign it to our global field symbol
  CREATE DATA gv_dref_table TYPE HANDLE lo_table.
  ASSIGN gv_dref_table->* TO <gfs_data>.

ENDFORM.

*&---------------------------------------------------------------------*
*& Form FILL_DYNAMIC_DATA
*& Parses raw data cells and maps them into the dynamic table
*& (row boundary APPEND; ASSIGN by column index for renamed components).
*&---------------------------------------------------------------------*
FORM fill_dynamic_data USING pv_struct TYPE REF TO cl_abap_structdescr.

  DATA: ls_raw       TYPE gty_data_cell,
        lv_cur_row   TYPE i,
        lv_dref_line TYPE REF TO data,
        lv_error_msg TYPE string.

  FIELD-SYMBOLS: <lfs_line>   TYPE any,
                 <lfs_field>  TYPE any,
                 <lfs_header> TYPE gty_data_header.

  " Create a workspace for a single line
  CREATE DATA lv_dref_line TYPE HANDLE pv_struct.
  ASSIGN lv_dref_line->* TO <lfs_line>.

  " Make sure the data is processed sequentially by coordinates
  SORT gt_data_raw BY row col.
  CLEAR lv_cur_row.

  LOOP AT gt_data_raw INTO ls_raw.

    " Whenever the row index changes, append the completed line and start fresh
    IF lv_cur_row <> ls_raw-row.
      IF lv_cur_row IS NOT INITIAL.
        APPEND <lfs_line> TO <gfs_data>.
        CLEAR <lfs_line>.
      ENDIF.
      lv_cur_row = ls_raw-row.
    ENDIF.

    " Assign component by column index instead of field name.
    " This is much safer since technical names might have been altered (e.g. KUNNR1).
    ASSIGN COMPONENT ls_raw-col OF STRUCTURE <lfs_line> TO <lfs_field>.

    IF sy-subrc = 0.
      TRY.
          <lfs_field> = ls_raw-value.
        CATCH cx_sy_conversion_error INTO DATA(lx_error).
          " If type conversion fails, grab the column details for logging
          SORT gt_header_list BY col_pos.
          READ TABLE gt_header_list ASSIGNING <lfs_header> WITH KEY col_pos = ls_raw-col BINARY SEARCH.
          IF sy-subrc = 0.
            lv_error_msg = lx_error->get_text( ).

            PERFORM add_error USING ls_raw-row
                                    ls_raw-col
                                    lv_error_msg.
          ENDIF.
      ENDTRY.
    ENDIF.
  ENDLOOP.

  " Don't forget to append the very last parsed row
  IF lv_cur_row IS NOT INITIAL.
    APPEND <lfs_line> TO <gfs_data>.
  ENDIF.
ENDFORM.

*&---------------------------------------------------------------------*
*& Form HANDLE_DUPLICATED_TECH_NAME
*& Picks a free component name in PT_COMP by appending 1,2,... to PV_BASE_NAME
*& while LINE_EXISTS (used when several data columns map to same DDIC name).
*&---------------------------------------------------------------------*
FORM handle_duplicated_tech_name USING    pv_base_name TYPE string
                                          pt_comp      TYPE cl_abap_structdescr=>component_table
                                 CHANGING pv_new_name  TYPE string.

  DATA: lv_counter  TYPE i.

  pv_new_name  = pv_base_name.
  lv_counter   = 0.

  " Keep incrementing suffix until NAME is not already in the component table.
  WHILE line_exists( pt_comp[ name = pv_new_name ] ).
    lv_counter  = lv_counter + 1.
    pv_new_name = |{ pv_base_name }{ lv_counter }|.
  ENDWHILE.
ENDFORM.

*&---------------------------------------------------------------------*
*& Form unlock_data
*&---------------------------------------------------------------------*
FORM unlock_data .

  DATA lv_varkey TYPE rstable-varkey.

  " Build the lock key using client and current log ID.
  lv_varkey = sy-mandt && gv_current_log_id.

  " Release the exclusive lock on the current log header record.
  CALL FUNCTION 'DEQUEUE_E_TABLEE'
    EXPORTING
      mode_rstable = 'E'
      tabname      = 'ZLOG_HEADER'
      varkey       = lv_varkey.

ENDFORM.

*&---------------------------------------------------------------------*
*& Form lock_data
*&---------------------------------------------------------------------*
FORM lock_data CHANGING pv_locked TYPE abap_bool.

  DATA lv_varkey TYPE rstable-varkey.

  " Build the lock key using client and current log ID
  lv_varkey = sy-mandt && gv_current_log_id.

  " Request an exclusive edit lock before entering change mode.
  CALL FUNCTION 'ENQUEUE_E_TABLEE'
    EXPORTING
      mode_rstable   = 'E'
      tabname        = 'ZLOG_HEADER'
      varkey         = lv_varkey
    EXCEPTIONS
      foreign_lock   = 1
      system_failure = 2
      OTHERS         = 3.

  IF sy-subrc <> 0.
    " Reject edit mode immediately if the lock cannot be obtained.
    MESSAGE s068 WITH sy-uname gv_current_log_id DISPLAY LIKE gc_displike_err.
    pv_locked = abap_on.
  ENDIF.

ENDFORM.
