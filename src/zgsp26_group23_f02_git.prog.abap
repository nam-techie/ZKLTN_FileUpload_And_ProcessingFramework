*&---------------------------------------------------------------------*
*& Include          ZGSP26_GROUP23_F02
*&---------------------------------------------------------------------*


*&---------------------------------------------------------------------*
*& Purpose
*&  Validation and error logging for dynamic upload data: rules
*&  from GT_HEADER_LIST against <GFS_DATA>, duplicate key detection,
*&  single-row revalidation, and detail-ALV edit sync back to master.
*&---------------------------------------------------------------------*

*&---------------------------------------------------------------------*
*& Form VALIDATE_DATA
*& Walk <gfs_data> x GT_HEADER_LIST: run check_one_cell per cell;
*& then duplicate key check at the end.
*&---------------------------------------------------------------------*

FORM validate_data.
  IF gv_error = abap_on.
    RETURN.
  ENDIF.

  IF <gfs_data> IS NOT ASSIGNED.
    MESSAGE s063 DISPLAY LIKE gc_displike_err.
    RETURN.
  ENDIF.

  DATA: ls_header TYPE gty_data_header,
        lv_tabix  TYPE i.

  FIELD-SYMBOLS: <lfs_line>  TYPE any,
                 <lfs_value> TYPE any.

  " Outer loop: each data row in the generic internal table.
  LOOP AT <gfs_data> ASSIGNING <lfs_line>.
    lv_tabix = sy-tabix.

    " Inner loop: each column rule from header metadata.
    LOOP AT gt_header_list INTO ls_header.

      ASSIGN COMPONENT ls_header-col_pos OF STRUCTURE <lfs_line> TO <lfs_value>.

      IF sy-subrc = 0.
        " Logical data row index (matches GT_ERROR_LOG / UI).
        DATA(lv_real_row) = lv_tabix + gc_data_start - 1.

        PERFORM check_one_cell USING <lfs_value>
                                     ls_header
                                     lv_real_row.
      ENDIF.
    ENDLOOP.
  ENDLOOP.
  PERFORM validate_duplicate_in_file USING 0.
ENDFORM.

*&---------------------------------------------------------------------*
*& Form ADD_ERROR
*& Append one row to GT_ERROR_LOG (type E) for a cell.
*&---------------------------------------------------------------------*
FORM add_error USING  pv_row_idx TYPE i
                      pv_col_pos TYPE i
                      pv_msg     TYPE string.

  DATA: ls_err TYPE gty_error_log.

  ls_err-row_index = pv_row_idx.
  ls_err-col_pos   = pv_col_pos.
  ls_err-message   = pv_msg.

  APPEND ls_err TO gt_error_log.

ENDFORM.

*&---------------------------------------------------------------------*
*& Form VALIDATE_DUPLICATE_IN_FILE
*& First occurrence of each key composite wins; later rows get errors on
*& all key columns. Message text must stay aligned with TEXT-044 cleanup.
*&---------------------------------------------------------------------*
FORM validate_duplicate_in_file USING pv_edited_row TYPE i.

  DATA: lt_key_cols TYPE TABLE OF gty_data_header.

  " 1. Extract Key Columns
  " Retrieve all columns defined as keys in the header
  LOOP AT gt_header_list INTO DATA(ls_header) WHERE is_key = abap_on.
    APPEND ls_header TO lt_key_cols.
  ENDLOOP.

  " If no key columns are defined, there is nothing to validate
  IF lt_key_cols IS INITIAL.
    RETURN.
  ENDIF.

  TYPES: BEGIN OF lty_tracked_key,
           key_value TYPE string,
           first_row TYPE i,
         END OF lty_tracked_key.

  DATA: lt_tracked TYPE HASHED TABLE OF lty_tracked_key WITH UNIQUE KEY key_value,
        ls_tracked TYPE lty_tracked_key.

  DATA: lv_composite_key TYPE string,
        lv_val_str       TYPE string.

  FIELD-SYMBOLS: <lfs_line>  TYPE any,
                 <lfs_value> TYPE any.

  IF <gfs_data> IS NOT ASSIGNED.
    RETURN.
  ENDIF.

  " 2. Determine Evaluation Order
  " To ensure the currently edited row is flagged as the duplicate (instead of the existing row),
  " we evaluate all other rows first, and push the edited row to the end of the evaluation order.
  DATA: lt_eval_order TYPE TABLE OF i.
  LOOP AT <gfs_data> ASSIGNING <lfs_line>.

    IF pv_edited_row > 0 AND sy-tabix = pv_edited_row.
      CONTINUE.
    ENDIF.
    APPEND sy-tabix TO lt_eval_order.
  ENDLOOP.


  " Append the edited row at the very end of the evaluation list
  IF  pv_edited_row > 0.
    DATA(lv_edited_tabix) = pv_edited_row.
    IF lv_edited_tabix > 0 AND lv_edited_tabix <= lines( <gfs_data> ).
      APPEND lv_edited_tabix TO lt_eval_order.
    ENDIF.
  ENDIF.

  " 3. Process each row based on the defined order
  LOOP AT lt_eval_order INTO DATA(lv_eval_tabix).
    READ TABLE <gfs_data> ASSIGNING <lfs_line> INDEX lv_eval_tabix.
    DATA(lv_real_row) = lv_eval_tabix + gc_data_start - 1.
    CLEAR lv_composite_key.

    " 3.1. Build a composite key by concatenating all key columns (e.g., '100-ABC')
    LOOP AT lt_key_cols INTO ls_header.
      ASSIGN COMPONENT ls_header-col_pos OF STRUCTURE <lfs_line> TO <lfs_value>.
      IF sy-subrc = 0.
        lv_val_str = |{ <lfs_value> }|.
*        CONDENSE lv_val_str. !OBSOLETE SYNTAX
        lv_val_str = condense( val = lv_val_str ).
        IF lv_composite_key IS INITIAL.
          lv_composite_key = lv_val_str.
        ELSE.
          lv_composite_key = lv_composite_key && '-' && lv_val_str.
        ENDIF.
      ENDIF.
    ENDLOOP.

    " Ignore completely empty composite keys
    DATA(lv_check_empty) = replace( val = lv_composite_key sub = '-' with = '' occ = 0 ).

    " 4. Track and check duplicates
    IF lv_check_empty IS NOT INITIAL.
      ls_tracked-key_value = lv_composite_key.
      ls_tracked-first_row = lv_real_row.

      " Try to insert into the Hashed Table.
      INSERT ls_tracked INTO TABLE lt_tracked.

      IF sy-subrc <> 0.
        " 5. Duplicate found: Log the error
        " Retrieve the original row that first introduced this key
        READ TABLE lt_tracked INTO DATA(ls_orig) WITH TABLE KEY key_value = lv_composite_key.

        LOOP AT lt_key_cols INTO ls_header.
          DATA(lv_err_msg) = replace( val = TEXT-106   sub = '&1' with = ls_header-descr ).
          lv_err_msg       = replace( val = lv_err_msg sub = '&2' with = lv_composite_key ).
          lv_err_msg       = replace( val = lv_err_msg sub = '&3' with = CONV string( ls_orig-first_row ) ).


          PERFORM add_error USING lv_real_row
                                  ls_header-col_pos
                                  lv_err_msg.
        ENDLOOP.
      ENDIF.
    ENDIF.
  ENDLOOP.
ENDFORM.


*&---------------------------------------------------------------------*
*& Section: Single-row revalidation (after edit or date F4)
*&---------------------------------------------------------------------*

*&---------------------------------------------------------------------*
*& Form REVALIDATE_SINGLE_ROW
*& Clear errors for pv_data_row; re-run check_one_cell on every
*& header column for that one row; refresh duplicate-key pass at end.
*&---------------------------------------------------------------------*
FORM revalidate_single_row USING pv_tabix TYPE i.

  FIELD-SYMBOLS: <lfs_line>  TYPE any,
                 <lfs_value> TYPE any.

  DELETE gt_error_log WHERE row_index = gv_selected_data_row.

  IF <gfs_data> IS NOT ASSIGNED.
    MESSAGE s063 DISPLAY LIKE gc_displike_err.
    RETURN.
  ENDIF.

  READ TABLE <gfs_data> ASSIGNING <lfs_line> INDEX pv_tabix.
  IF sy-subrc <> 0.
    RETURN.
  ENDIF.

  DATA: ls_header TYPE gty_data_header.

  LOOP AT gt_header_list INTO ls_header.
    ASSIGN COMPONENT ls_header-col_pos OF STRUCTURE <lfs_line> TO <lfs_value>.
    IF sy-subrc = 0 AND <lfs_value> IS ASSIGNED.

      PERFORM check_one_cell USING <lfs_value>
                                   ls_header
                                   gv_selected_data_row.
    ENDIF.
  ENDLOOP.
  DELETE gt_error_log WHERE message CS TEXT-044.
  PERFORM validate_duplicate_in_file USING pv_tabix.
ENDFORM.


*&---------------------------------------------------------------------*
*& Section: Shared cell-level validation kernel
*&---------------------------------------------------------------------*

*&---------------------------------------------------------------------*
*& Form check_one_cell
*& Apply all active header rules (mandatory, date, positive, range, list)
*& to a single field-symbol value and log any error via ADD_ERROR.
*& Called by both VALIDATE_DATA (full pass) and REVALIDATE_SINGLE_ROW.
*&---------------------------------------------------------------------*
FORM check_one_cell USING    pv_value  TYPE any
                                 ps_header   TYPE gty_data_header
                                 pv_data_row TYPE i.

  DATA: lv_err_msg   TYPE string,
        lv_num_check TYPE decfloat34,
        lo_type      TYPE REF TO cl_abap_typedescr.

  " --- 1. Mandatory check ------------------------------------------
  IF ps_header-is_mand = abap_on AND pv_value IS INITIAL.
    lv_err_msg = replace( val = TEXT-109 sub = '&1' with = ps_header-descr ).
    PERFORM add_error USING pv_data_row
                            ps_header-col_pos
                            lv_err_msg.
    RETURN.  " No further checks make sense on an empty mandatory cell.
  ENDIF.

  " Skip remaining rules if cell is empty (non-mandatory).
  IF pv_value IS INITIAL.
    RETURN.
  ENDIF.

  " --- 2. Date plausibility check ----------------------------------
  lo_type = cl_abap_typedescr=>describe_by_data( pv_value ).
  IF lo_type->type_kind = cl_abap_typedescr=>typekind_date.

    DATA: lv_date_check TYPE d.
    lv_date_check = condense( val = pv_value ).

    IF lv_date_check IS NOT INITIAL.

      IF strlen( lv_date_check ) <> 8 OR lv_date_check CN '0123456789'.
        lv_err_msg = replace( val = TEXT-110 sub = '&1' with = ps_header-descr ).
        PERFORM add_error USING pv_data_row
                                ps_header-col_pos
                                lv_err_msg.
        RETURN.
      ENDIF.

      CALL FUNCTION 'DATE_CHECK_PLAUSIBILITY'
        EXPORTING
          date                      = lv_date_check
        EXCEPTIONS
          plausibility_check_failed = 1
          OTHERS                    = 2.

      IF sy-subrc <> 0.
        lv_err_msg = replace( val = TEXT-111 sub = '&1' with = ps_header-descr ).
        PERFORM add_error USING pv_data_row
                                ps_header-col_pos
                                lv_err_msg.
        RETURN.
      ENDIF.

    ENDIF.
  ENDIF.

  " --- 3. Positive-only check (+) ----------------------------------
  IF ps_header-is_pos = abap_on.
    TRY.
        lv_num_check = pv_value.
        IF lv_num_check < 0.
          lv_err_msg = replace( val = TEXT-112 sub = '&1' with = ps_header-descr ).
          PERFORM add_error USING pv_data_row
                                  ps_header-col_pos
                                  lv_err_msg.
        ENDIF.
      CATCH cx_sy_conversion_no_number.
        lv_err_msg = replace( val = TEXT-112 sub = '&1' with = ps_header-descr ).
        PERFORM add_error USING pv_data_row
                                ps_header-col_pos
                                lv_err_msg.
        RETURN.
    ENDTRY.
  ENDIF.

  " --- 4. Numeric range [RNG:low-high] -----------------------------
  IF ps_header-rng_low IS NOT INITIAL OR ps_header-rng_high IS NOT INITIAL.
    TRY.
        lv_num_check = CONV string( pv_value ).

        IF ps_header-rng_low IS NOT INITIAL AND lv_num_check < ps_header-rng_low.
          lv_err_msg = replace( val  = replace( val  = TEXT-114
                                                sub  = '&1'
                                                with = ps_header-descr )
                                sub  = '&2'
                                with = CONV string( ps_header-rng_low ) ).
          PERFORM add_error USING pv_data_row
                                  ps_header-col_pos
                                  lv_err_msg.
        ENDIF.
        IF ps_header-rng_high IS NOT INITIAL AND lv_num_check > ps_header-rng_high.
          lv_err_msg = TEXT-115.
          lv_err_msg = replace( val  = replace( val  = TEXT-115
                                                sub  = '&1'
                                                with = ps_header-descr )
                                sub  = '&2'
                                with = CONV string( ps_header-rng_high ) ).
          PERFORM add_error USING pv_data_row
                                  ps_header-col_pos
                                  lv_err_msg.
        ENDIF.
      CATCH cx_sy_conversion_no_number.
        lv_err_msg =  replace( val  = TEXT-134
                               sub  = '&1'
                               with = ps_header-descr ).
        PERFORM add_error USING pv_data_row
                                ps_header-col_pos
                                lv_err_msg.
        RETURN.
    ENDTRY.
  ENDIF.

  " --- 5. Allowed value list [LIST:...] ---
  IF ps_header-val_list IS NOT INITIAL.
    DATA: lt_list_values TYPE TABLE OF string,
          lv_list_item   TYPE string,
          lv_is_valid    TYPE abap_bool,
          lo_dref        TYPE REF TO data.

    FIELD-SYMBOLS: <lfs_list_item_typed> TYPE any.

    SPLIT ps_header-val_list AT ';' INTO TABLE lt_list_values.

    " Create a typed helper variable that matches pv_value exactly.
    " Assigning each list entry to it lets ABAP handle padding/conversion
    " (e.g. '3' -> '03' for NUMC2) before the equality test.
    CREATE DATA lo_dref LIKE pv_value.
    ASSIGN lo_dref->* TO <lfs_list_item_typed>.
    lv_is_valid = abap_off.

    LOOP AT lt_list_values INTO lv_list_item.
      TRY.
          <lfs_list_item_typed> = lv_list_item.
          IF pv_value = <lfs_list_item_typed>.
            lv_is_valid = abap_on.
            EXIT.
          ENDIF.

        CATCH cx_sy_conversion_error.
          lv_err_msg =  replace( val = TEXT-080    sub  = '&1'   with = ps_header-descr ).
          lv_err_msg =  replace( val = lv_err_msg  sub  = '&2'   with = pv_value ).
          lv_err_msg =  replace( val = lv_err_msg  sub  = '&3'   with = pv_value ).
      ENDTRY.
    ENDLOOP.

    IF lv_is_valid = abap_off.
      lv_err_msg =  replace( val = TEXT-080    sub  = '&1'   with = ps_header-descr ).
      lv_err_msg =  replace( val = lv_err_msg  sub  = '&2'   with = pv_value ).
      lv_err_msg =  replace( val = lv_err_msg  sub  = '&3'   with = pv_value ).
      PERFORM add_error USING pv_data_row
                              ps_header-col_pos
                              lv_err_msg.
    ENDIF.
  ENDIF.

ENDFORM.

*&---------------------------------------------------------------------*
*& Section: Detail ALV edit pipeline
*&---------------------------------------------------------------------*

*&---------------------------------------------------------------------*
*& Form SYNC_AND_REVALIDATE
*& Apply MT_GOOD_CELLS from detail grid to <gfs_data>: date plausibility,
*& length overflow, NUMC digit check, conversion; then row revalidate +
*& refresh master/detail ALVs.
*&---------------------------------------------------------------------*
FORM sync_and_revalidate USING pv_data_changed TYPE REF TO cl_alv_changed_data_protocol.

  DATA: ls_mod_cell TYPE lvc_s_modi,
        lv_msgv1    TYPE string,
        lv_msgv2    TYPE string,
        lv_msgv3    TYPE string,
        lv_msgv4    TYPE string.

  DATA(lv_tabix) = gv_selected_data_row - gc_data_start + 1.

  IF <gfs_data> IS NOT ASSIGNED.
    MESSAGE s063 DISPLAY LIKE gc_displike_err.
    RETURN.
  ENDIF.

  READ TABLE <gfs_data> ASSIGNING FIELD-SYMBOL(<lfs_d_row>) INDEX lv_tabix.

  IF sy-subrc <> 0. RETURN. ENDIF.

  LOOP AT pv_data_changed->mt_good_cells INTO ls_mod_cell.
    READ TABLE gt_vertical_data INTO DATA(ls_vert) INDEX ls_mod_cell-row_id.

    IF sy-subrc = 0.
      ASSIGN COMPONENT ls_vert-row_index OF STRUCTURE <lfs_d_row> TO FIELD-SYMBOL(<lfs_field>).

      IF sy-subrc = 0.
        DATA: lv_old_value_str TYPE string.
        lv_old_value_str = |{ <lfs_field> }|.
*        CONDENSE lv_old_value_str. !OBSOLETE SYNTAX
        lv_old_value_str = condense( val = lv_old_value_str ).

        DESCRIBE FIELD <lfs_field> TYPE DATA(lv_type).
        IF lv_type = 'D'.

          DATA: lv_datbi TYPE d.

          lv_datbi = condense( val = ls_mod_cell-value ).
          IF strlen( lv_datbi ) <> 8 OR lv_datbi CN '0123456789'.

            lv_msgv1 = | { TEXT-085 } |.
            lv_msgv2 = | '{ ls_mod_cell-value }' |.
            lv_msgv3 = | { TEXT-090 } |.
            lv_msgv4 = ''.

            PERFORM trigger_alv_error USING    pv_data_changed
                                               lv_old_value_str
                                               ls_mod_cell
                                               lv_msgv1
                                               lv_msgv2
                                               lv_msgv3
                                               lv_msgv4.
            <lfs_field> = lv_old_value_str.
            EXIT.
          ELSE.
            <lfs_field> = lv_datbi.
          ENDIF.

        ELSE.

          DATA: lo_elem TYPE REF TO cl_abap_elemdescr.
          lo_elem ?= cl_abap_typedescr=>describe_by_data( <lfs_field> ).

          DATA(lv_max_len) = lo_elem->output_length.

          DATA: lv_input_str TYPE string.
          lv_input_str = ls_mod_cell-value.
*          CONDENSE lv_input_str.  !OBSOLETE SYNTAX
          lv_input_str = condense( val = lv_input_str ).

          DATA(lv_input_len) = strlen( lv_input_str ).

          IF lv_max_len > 0 AND lv_input_len > lv_max_len.

            lv_msgv1 = | { TEXT-123 } |.
            lv_msgv2 = | { TEXT-124 } |.
            lv_msgv3 = | { lv_max_len }) |.
            lv_msgv4 = ''.
            PERFORM trigger_alv_error USING    pv_data_changed
                                               lv_old_value_str
                                               ls_mod_cell
                                               lv_msgv1
                                               lv_msgv2
                                               lv_msgv3
                                               lv_msgv4.
            <lfs_field> = lv_old_value_str.
            EXIT.
          ENDIF.

          " NUMC: non-digits must be rejected explicitly.
          IF lv_type = cl_abap_typedescr=>typekind_num.
            IF ls_mod_cell-value CN '0123456789 '.

              lv_msgv1 = | { TEXT-085 } |.
              lv_msgv2 = | '{ ls_mod_cell-value }' |.
              lv_msgv3 = | { TEXT-086 } |.
              lv_msgv4 = | '{ ls_vert-descr }' |.

              PERFORM trigger_alv_error USING    pv_data_changed
                                                 lv_old_value_str
                                                 ls_mod_cell
                                                 lv_msgv1
                                                 lv_msgv2
                                                 lv_msgv3
                                                 lv_msgv4.
              <lfs_field> = lv_old_value_str.
              EXIT.
            ENDIF.
          ENDIF.

          TRY.

              <lfs_field> = ls_mod_cell-value.
            CATCH cx_sy_conversion_error.

              lv_msgv1 = | { TEXT-085 } |.
              lv_msgv2 = | '{ ls_mod_cell-value }' |.
              lv_msgv3 = | { TEXT-086 } |.
              lv_msgv4 = | '{ ls_vert-descr }' |.

              PERFORM trigger_alv_error USING    pv_data_changed
                                                 lv_old_value_str
                                                 ls_mod_cell
                                                 lv_msgv1
                                                 lv_msgv2
                                                 lv_msgv3
                                                 lv_msgv4.

              <lfs_field> = lv_old_value_str.

              EXIT.
          ENDTRY.
        ENDIF.
      ENDIF.
    ENDIF.
  ENDLOOP.

  IF pv_data_changed->mt_protocol IS NOT INITIAL.
    pv_data_changed->display_protocol( ).
    RETURN.
  ENDIF.

  IF lines( pv_data_changed->mt_good_cells ) > 0.
    gv_data_dirty = abap_on.
    INSERT VALUE #( page_no = gv_current_page data_row = gv_selected_data_row ) INTO TABLE gt_row_dirty.
  ENDIF.

  PERFORM revalidate_single_row USING lv_tabix.

  " Targeted refresh: update only the edited row in master + detail error cells.
  PERFORM prepare_master_alv_data.
  go_grid_master->refresh_table_display( is_stable = VALUE #( row = abap_on col = abap_on ) ).

  PERFORM refresh_single_detail_cells.
  go_grid_detail->refresh_table_display( is_stable = VALUE #( row = abap_on col = abap_on ) ).
ENDFORM.

*&---------------------------------------------------------------------*
*& Form REFRESH_SINGLE_DETAIL_CELLS
*& Update error_msg + cell colors in existing GT_VERTICAL_DATA rows
*& after revalidation. Value is already synced by mt_good_cells.
*& Delegates to compute_cell_error for shared error logic
*&---------------------------------------------------------------------*
FORM refresh_single_detail_cells.

  IF gv_selected_data_row <= 0.
    RETURN.
  ENDIF.

  DATA lv_has_error TYPE abap_bool VALUE abap_off.

  LOOP AT gt_vertical_data ASSIGNING FIELD-SYMBOL(<ls_vert>).

    READ TABLE gt_header_list INTO DATA(ls_hdr) INDEX <ls_vert>-row_index.
    IF sy-subrc <> 0. CONTINUE. ENDIF.

    PERFORM compute_cell_error USING    gv_selected_data_row
                                        ls_hdr-col_pos
                               CHANGING <ls_vert>-error_msg
                                        lv_has_error
                                        <ls_vert>-cell_col.
  ENDLOOP.

  PERFORM refresh_detail_grid USING lv_has_error.

ENDFORM.
