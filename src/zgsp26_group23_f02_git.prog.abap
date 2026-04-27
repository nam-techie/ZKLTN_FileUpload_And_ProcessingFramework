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
*& Section: Full-grid validation
*&---------------------------------------------------------------------*

*&---------------------------------------------------------------------*
*& Form VALIDATE_DATA
*& Walk <gfs_data> x GT_HEADER_LIST: mandatory, date, positive, range,
*& fixed list; skip cells already in GT_ERROR_LOG; then duplicate keys.
*&---------------------------------------------------------------------*

FORM validate_data.
  IF gv_error = abap_on.
    RETURN.
  ENDIF.

  DATA: ls_header  TYPE gty_data_header,
        lv_tabix   TYPE i,
        lo_type    TYPE REF TO cl_abap_typedescr,
        lv_err_msg TYPE string.

  FIELD-SYMBOLS: <lfs_line>  TYPE any,
                 <lfs_value> TYPE any.

  " Outer loop: each data row in the generic internal table.
  IF <gfs_data> IS NOT ASSIGNED.
    MESSAGE s063(zmsg_gr23) DISPLAY LIKE gc_displike_err.
    RETURN.
  ENDIF.

  DATA lv_num_check TYPE decfloat34.

  LOOP AT <gfs_data> ASSIGNING <lfs_line>.
    lv_tabix = sy-tabix.

    " Inner loop: each column rule from header metadata.
    LOOP AT gt_header_list INTO ls_header.

      ASSIGN COMPONENT ls_header-col_pos OF STRUCTURE <lfs_line> TO <lfs_value>.

      IF sy-subrc = 0 AND <lfs_value> IS ASSIGNED.

        " Logical data row index (matches GT_ERROR_LOG / UI).
        DATA(lv_real_row) = lv_tabix + gc_data_start - 1.

        SORT gt_error_log BY row_index col_pos.
        READ TABLE gt_error_log TRANSPORTING NO FIELDS
          WITH KEY row_index = lv_real_row
                   col_pos = ls_header-col_pos BINARY SEARCH.

        IF sy-subrc = 0.
          CONTINUE.
        ENDIF.

        IF ls_header-is_mand = abap_on.
          IF <lfs_value> IS INITIAL.
            lv_err_msg = |{ TEXT-087 } '{ ls_header-descr }'{ TEXT-088 }|.
            PERFORM add_error USING lv_real_row
                                    ls_header-col_pos
                                    ls_header-tech_name
                                    lv_err_msg.
            CONTINUE.
          ENDIF.
        ENDIF.

        IF <lfs_value> IS INITIAL.
          CONTINUE.
        ENDIF.

        " Date components: SAP plausibility check.
        lo_type = cl_abap_typedescr=>describe_by_data( <lfs_value> ).

        IF lo_type->type_kind = cl_abap_typedescr=>typekind_date.
          CALL FUNCTION 'DATE_CHECK_PLAUSIBILITY'
            EXPORTING
              date                      = <lfs_value>
            EXCEPTIONS
              plausibility_check_failed = 1
              OTHERS                    = 2.

          IF sy-subrc <> 0.
            lv_err_msg = |{ TEXT-087 }'{ ls_header-descr }'{ TEXT-090 }|.
            PERFORM add_error USING lv_real_row
                                    ls_header-col_pos
                                    ls_header-tech_name
                                    lv_err_msg.
            CONTINUE.
          ENDIF.
        ENDIF.

        " Positive-only columns (+ in tech row).
        IF ls_header-is_pos = abap_on.

          TRY.
              lv_num_check = <lfs_value>.

              IF lv_num_check < 0.
                lv_err_msg = |{ TEXT-087 }'{ ls_header-descr }'{ TEXT-092 }|.
                PERFORM add_error USING lv_real_row
                                        ls_header-col_pos
                                        ls_header-tech_name
                                        lv_err_msg.
              ENDIF.
            CATCH cx_sy_conversion_no_number.
              lv_err_msg = |{ TEXT-087 }'{ ls_header-descr }'{ TEXT-094 }|.
              PERFORM add_error USING lv_real_row
                                      ls_header-col_pos
                                      ls_header-tech_name
                                      lv_err_msg.
              CONTINUE.
            CATCH cx_sy_conversion_error.
              CONTINUE.
          ENDTRY.
        ENDIF.

        " Numeric range [RNG:low-high] from header.
        IF ls_header-rng_low IS NOT INITIAL OR ls_header-rng_high IS NOT INITIAL.
          TRY.

              lv_num_check = CONV string( <lfs_value> ).

              IF ls_header-rng_low IS NOT INITIAL AND lv_num_check < ls_header-rng_low.
                lv_err_msg = |{ TEXT-087 }'{ ls_header-descr }'{ TEXT-097 }{ ls_header-rng_low }{ TEXT-098 }|.
                PERFORM add_error USING lv_real_row
                                        ls_header-col_pos
                                        ls_header-tech_name
                                        lv_err_msg.
              ENDIF.

              IF ls_header-rng_high IS NOT INITIAL AND lv_num_check > ls_header-rng_high.
                lv_err_msg = |{ TEXT-087 }'{ ls_header-descr }'{ TEXT-100 }{ ls_header-rng_high }{ TEXT-101 }|.
                PERFORM add_error USING lv_real_row
                                        ls_header-col_pos
                                        ls_header-tech_name
                                        lv_err_msg.
              ENDIF.
            CATCH cx_sy_conversion_error.
              CONTINUE.
          ENDTRY.
        ENDIF.

        " Allowed value list [LIST:...] from header.
        IF ls_header-val_list IS NOT INITIAL.
          DATA: lv_clean_list  TYPE string,
                lv_search_list TYPE string,
                lv_search_val  TYPE string.

          lv_clean_list = replace( val = ls_header-val_list sub = '[LIST:' with = '' ).
          lv_clean_list = replace( val = lv_clean_list      sub = ']'      with = '' ).
*          CONDENSE lv_clean_list NO-GAPS. !OBSOLETE SYNTAX
          lv_clean_list = condense(
                   val = lv_clean_list
                   del = '' ).

          lv_search_list = |;{ lv_clean_list };|.
          lv_search_val  = |;{ condense( val = |{ <lfs_value> }| ) };|.

          IF NOT lv_search_list CS lv_search_val.
            lv_err_msg = |{ TEXT-087 }'{ ls_header-descr }'{ TEXT-103 }{ <lfs_value> }{ TEXT-104 }{ lv_clean_list }{ TEXT-105 }|.
            PERFORM add_error USING lv_real_row
                                    ls_header-col_pos
                                    ls_header-tech_name
                                    lv_err_msg.
          ENDIF.
        ENDIF.

      ENDIF.
    ENDLOOP.
  ENDLOOP.
  DELETE gt_error_log WHERE message CS TEXT-044.
  PERFORM validate_duplicate_in_file.
ENDFORM.

*&---------------------------------------------------------------------*
*& Section: Error log helpers
*&---------------------------------------------------------------------*

*&---------------------------------------------------------------------*
*& Form ADD_ERROR
*& Append one row to GT_ERROR_LOG (type E) for a cell.
*&---------------------------------------------------------------------*
FORM add_error USING  pv_row_idx TYPE i
                      pv_col_pos TYPE i
                      pv_field   TYPE string
                      pv_msg     TYPE string.

  DATA: ls_err TYPE gty_error_log.

  ls_err-row_index = pv_row_idx.
  ls_err-col_pos   = pv_col_pos.
  ls_err-fieldname = pv_field.
  ls_err-msg_type  = 'E'.
  ls_err-message   = pv_msg.

  APPEND ls_err TO gt_error_log.

ENDFORM.

*&---------------------------------------------------------------------*
*& Section: Duplicate composite keys ([KEY] columns)
*&---------------------------------------------------------------------*

*&---------------------------------------------------------------------*
*& Form VALIDATE_DUPLICATE_IN_FILE
*& First occurrence of each key composite wins; later rows get errors on
*& all key columns. Message text must stay aligned with TEXT-044 cleanup.
*&---------------------------------------------------------------------*
FORM validate_duplicate_in_file.

  DATA: lt_key_cols TYPE TABLE OF gty_data_header.

  LOOP AT gt_header_list INTO DATA(ls_header) WHERE is_key = abap_on.
    APPEND ls_header TO lt_key_cols.
  ENDLOOP.

  IF lt_key_cols IS INITIAL.
    RETURN.
  ENDIF.

  TYPES: BEGIN OF ty_tracked_key,
           key_value TYPE string,
           first_row TYPE i,
         END OF ty_tracked_key.

  DATA: lt_tracked TYPE HASHED TABLE OF ty_tracked_key WITH UNIQUE KEY key_value,
        ls_tracked TYPE ty_tracked_key.

  DATA: lv_composite_key TYPE string,
        lv_val_str       TYPE string.

  FIELD-SYMBOLS: <lfs_line>  TYPE any,
                 <lfs_value> TYPE any.

  IF <gfs_data> IS NOT ASSIGNED.
    RETURN.
  ENDIF.

  LOOP AT <gfs_data> ASSIGNING <lfs_line>.
    DATA(lv_real_row) = sy-tabix + gc_data_start - 1.
    CLEAR lv_composite_key.

    " Build composite key from all [KEY] columns (multi-column supported).
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

    DATA(lv_check_empty) = replace( val = lv_composite_key sub = '-' with = '' occ = 0 ).

    IF lv_check_empty IS NOT INITIAL.

      ls_tracked-key_value = lv_composite_key.
      ls_tracked-first_row = lv_real_row.

      INSERT ls_tracked INTO TABLE lt_tracked.

      IF sy-subrc <> 0.
        READ TABLE lt_tracked INTO DATA(ls_orig) WITH TABLE KEY key_value = lv_composite_key.

        LOOP AT lt_key_cols INTO ls_header.
          " Wording tied to DELETE ... WHERE message CS TEXT-044 in revalidate path.
          DATA(lv_err_msg) = |{ TEXT-106 }{ lv_composite_key }{ TEXT-107 }{ ls_orig-first_row }{ TEXT-108 }|.

          PERFORM add_error USING lv_real_row
                                  ls_header-col_pos
                                  ls_header-tech_name
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
*& Clear errors for pv_data_row; re-run header rules on one <gfs_data> row;
*& remap tech names for ASSIGN; refresh duplicate-key pass at end.
*&---------------------------------------------------------------------*
FORM revalidate_single_row USING pv_tabix     TYPE i
                                 pv_data_row TYPE i.

  DATA: ls_header    TYPE gty_data_header,
        lo_type      TYPE REF TO cl_abap_typedescr,
        lv_err_msg   TYPE string,
        lv_num_check TYPE decfloat34.

  FIELD-SYMBOLS: <lfs_line>  TYPE any,
                 <lfs_value> TYPE any.

  DELETE gt_error_log WHERE row_index = pv_data_row.

  IF <gfs_data> IS NOT ASSIGNED.
    MESSAGE s063(zmsg_gr23) DISPLAY LIKE gc_displike_err.
    RETURN.
  ENDIF.

  READ TABLE <gfs_data> ASSIGNING <lfs_line> INDEX pv_tabix.
  IF sy-subrc <> 0.
    RETURN.
  ENDIF.

  DATA: lt_comp      TYPE cl_abap_structdescr=>component_table,
        ls_comp      LIKE LINE OF lt_comp,
        lv_base_name TYPE string,
        lv_new_name  TYPE string.

  LOOP AT gt_header_list INTO ls_header.

    lv_base_name = ls_header-tech_name.

    PERFORM handle_duplicated_tech_name USING lv_base_name
                                   lt_comp
                         CHANGING  lv_new_name.

    ls_comp-name = lv_new_name.

    APPEND ls_comp TO lt_comp.

    ASSIGN COMPONENT ls_header-col_pos OF STRUCTURE <lfs_line> TO <lfs_value>.
    IF sy-subrc = 0 AND <lfs_value> IS ASSIGNED.

      IF ls_header-is_mand = abap_on AND <lfs_value> IS INITIAL.
        lv_err_msg = replace( val = TEXT-109 sub = '&1' with = ls_header-descr ).
        PERFORM add_error USING pv_data_row ls_header-col_pos ls_header-tech_name lv_err_msg.
        CONTINUE.
      ENDIF.

      IF <lfs_value> IS INITIAL. CONTINUE. ENDIF.

      lo_type = cl_abap_typedescr=>describe_by_data( <lfs_value> ).
      IF lo_type->type_kind = cl_abap_typedescr=>typekind_date.
        DATA: lv_date_check TYPE d.
        TRY.
            lv_date_check = <lfs_value>.
            IF lv_date_check IS NOT INITIAL AND lv_date_check <> '00000000'.
              CALL FUNCTION 'DATE_CHECK_PLAUSIBILITY'
                EXPORTING
                  date                      = lv_date_check
                EXCEPTIONS
                  plausibility_check_failed = 1
                  OTHERS                    = 2.
              IF sy-subrc <> 0.
                lv_err_msg = replace( val = TEXT-110 sub = '&1' with = ls_header-descr ).
                PERFORM add_error USING pv_data_row ls_header-col_pos ls_header-tech_name lv_err_msg.
                CONTINUE.
              ENDIF.
            ENDIF.
          CATCH cx_sy_conversion_error.
            lv_err_msg = replace( val = TEXT-111 sub = '&1' with = ls_header-descr ).
            PERFORM add_error USING pv_data_row ls_header-col_pos ls_header-tech_name lv_err_msg.
            CONTINUE.
        ENDTRY.
      ENDIF.

      IF ls_header-is_pos = abap_on.
        TRY.
            lv_num_check = <lfs_value>.
            IF lv_num_check < 0.
              lv_err_msg = replace( val = TEXT-112 sub = '&1' with = ls_header-descr ).
              PERFORM add_error USING pv_data_row ls_header-col_pos ls_header-tech_name lv_err_msg.
            ENDIF.
          CATCH cx_sy_conversion_no_number.
            lv_err_msg = replace( val = TEXT-113 sub = '&1' with = ls_header-descr ).
            PERFORM add_error USING pv_data_row ls_header-col_pos ls_header-tech_name lv_err_msg.
            CONTINUE.
          CATCH cx_sy_conversion_error.
            CONTINUE.
        ENDTRY.
      ENDIF.

      IF ls_header-rng_low IS NOT INITIAL OR ls_header-rng_high IS NOT INITIAL.
        TRY.

            lv_num_check = CONV string( <lfs_value> ).

            IF ls_header-rng_low IS NOT INITIAL AND lv_num_check < ls_header-rng_low.
              lv_err_msg = replace( val  = replace( val  = TEXT-114
                                              sub  = '&1'
                                              with = |{ ls_header-descr }| )
                              sub  = '&2'
                              with = |{ ls_header-rng_low }| ).
              PERFORM add_error USING pv_data_row ls_header-col_pos ls_header-tech_name lv_err_msg.
            ENDIF.
            IF ls_header-rng_high IS NOT INITIAL AND lv_num_check > ls_header-rng_high.
              lv_err_msg = replace( val  = replace( val  = TEXT-115
                                              sub  = '&1'
                                              with = ls_header-descr )
                              sub  = '&2'
                              with = |{ ls_header-rng_high }| ).
              PERFORM add_error USING pv_data_row ls_header-col_pos ls_header-tech_name lv_err_msg.
            ENDIF.
          CATCH cx_sy_conversion_error.
            CONTINUE.
        ENDTRY.
      ENDIF.

      IF ls_header-val_list IS NOT INITIAL.
        DATA: lv_clean_list2  TYPE string,
              lv_search_list2 TYPE string,
              lv_search_val2  TYPE string.

        lv_clean_list2 = replace( val = ls_header-val_list sub = '[LIST:' with = '' ).
        lv_clean_list2 = replace( val = lv_clean_list2     sub = ']'      with = '' ).
*        CONDENSE lv_clean_list2 NO-GAPS. !OBSOLETE SYNTAX
        lv_clean_list2 = condense(
                   val = lv_clean_list2
                   del = '' ).

        lv_search_list2 = |;{ lv_clean_list2 };|.
        lv_search_val2  = |;{ condense( val = |{ <lfs_value> }| ) };|.

        IF NOT lv_search_list2 CS lv_search_val2.
          lv_err_msg = TEXT-080.
          REPLACE ALL OCCURRENCES OF '&1' IN lv_err_msg WITH ls_header-descr.
          REPLACE ALL OCCURRENCES OF '&2' IN lv_err_msg WITH <lfs_value>.
          REPLACE ALL OCCURRENCES OF '&3' IN lv_err_msg WITH lv_clean_list2.
          PERFORM add_error USING pv_data_row
                                  ls_header-col_pos
                                  ls_header-tech_name
                                  lv_err_msg.
        ENDIF.
      ENDIF.
    ENDIF.
  ENDLOOP.
  DELETE gt_error_log WHERE message CS TEXT-044.
  PERFORM validate_duplicate_in_file.
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
FORM sync_and_revalidate USING lo_data_changed TYPE REF TO cl_alv_changed_data_protocol.

  DATA: ls_mod_cell TYPE lvc_s_modi,
        lv_msgv1    TYPE string,
        lv_msgv2    TYPE string,
        lv_msgv3    TYPE string,
        lv_msgv4    TYPE string.

  DATA(lv_tabix) = gv_selected_data_row - gc_data_start + 1.

  IF <gfs_data> IS NOT ASSIGNED.
    MESSAGE s063(zmsg_gr23) DISPLAY LIKE gc_displike_err.
    RETURN.
  ENDIF.

  READ TABLE <gfs_data> ASSIGNING FIELD-SYMBOL(<lfs_d_row>) INDEX lv_tabix.

  IF sy-subrc <> 0. RETURN. ENDIF.

  LOOP AT lo_data_changed->mt_good_cells INTO ls_mod_cell.

    READ TABLE gt_vertical_data INTO DATA(ls_vert) INDEX ls_mod_cell-row_id.

    IF sy-subrc = 0.
      ASSIGN COMPONENT ls_vert-row_pos OF STRUCTURE <lfs_d_row> TO FIELD-SYMBOL(<lfs_field>).

      IF sy-subrc = 0.

        DATA: lv_old_value_str TYPE string.
        lv_old_value_str = |{ <lfs_field> }|.
*        CONDENSE lv_old_value_str. !OBSOLETE SYNTAX
        lv_old_value_str = condense( val = lv_old_value_str ).

        DESCRIBE FIELD <lfs_field> TYPE DATA(lv_type).

        IF lv_type = 'D'.

          DATA: lv_datbi      TYPE sy-datum.

          lv_datbi = ls_mod_cell-value.
          CALL FUNCTION 'DATE_CHECK_PLAUSIBILITY'
            EXPORTING
              date                      = lv_datbi
            EXCEPTIONS
              plausibility_check_failed = 1
              OTHERS                    = 2.

          IF sy-subrc <> 0.
            lv_msgv1 = | { TEXT-085 } |.
            lv_msgv2 = | '{ ls_mod_cell-value }' |.
            lv_msgv3 = | { TEXT-090 } |.
            lv_msgv4 = ''.

            PERFORM trigger_alv_error USING    lo_data_changed
                                               lv_old_value_str
                                               ls_mod_cell
                                               lv_msgv1
                                               lv_msgv2
                                               lv_msgv3
                                               lv_msgv4.

            <lfs_field> = lv_old_value_str.
            EXIT.
          ELSE.
            <lfs_field> = ls_mod_cell-value.
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

          IF lv_input_len > lv_max_len.

            lv_msgv1 = | { TEXT-123 } |.
            lv_msgv2 = | { TEXT-124 } |.
            lv_msgv3 = | { lv_max_len }) |.
            lv_msgv4 = ''.
            PERFORM trigger_alv_error USING    lo_data_changed
                                               lv_old_value_str
                                               ls_mod_cell
                                               lv_msgv1
                                               lv_msgv2
                                               lv_msgv3
                                               lv_msgv4.
            CONTINUE.
          ENDIF.

          " NUMC: non-digits must be rejected explicitly.
          IF lv_type = cl_abap_typedescr=>typekind_num.
            IF ls_mod_cell-value CN '0123456789 '.

              lv_msgv1 = | { TEXT-085 } |.
              lv_msgv2 = | '{ ls_mod_cell-value }' |.
              lv_msgv3 = | { TEXT-086 } |.
              lv_msgv4 = | '{ ls_vert-descr }' |.

              PERFORM trigger_alv_error USING    lo_data_changed
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

              PERFORM trigger_alv_error USING    lo_data_changed
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

  IF lo_data_changed->mt_protocol IS NOT INITIAL.
    lo_data_changed->display_protocol( ).
    RETURN.
  ENDIF.

  IF lines( lo_data_changed->mt_good_cells ) > 0.
    gv_data_dirty = abap_on.
    INSERT VALUE #( page_no = gv_current_page data_row = gv_selected_data_row ) INTO TABLE gt_row_dirty.
  ENDIF.

  PERFORM revalidate_single_row USING lv_tabix gv_selected_data_row.

  PERFORM prepare_master_alv_data.

  go_grid_master->refresh_table_display( is_stable = VALUE #( row = abap_on col = abap_on ) ).
  PERFORM refresh_detail_alvs.
ENDFORM.
