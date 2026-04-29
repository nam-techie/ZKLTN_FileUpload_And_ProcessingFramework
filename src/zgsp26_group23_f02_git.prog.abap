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
    MESSAGE s063(zmsg_gr23) DISPLAY LIKE gc_displike_err.
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

      IF sy-subrc = 0 AND <lfs_value> IS ASSIGNED.
        " Logical data row index (matches GT_ERROR_LOG / UI).
        DATA(lv_real_row) = lv_tabix + gc_data_start - 1.

        PERFORM check_one_cell USING    <lfs_value>
                                            ls_header
                                            lv_real_row.
      ENDIF.
    ENDLOOP.
  ENDLOOP.
  PERFORM validate_duplicate_in_file.
ENDFORM.

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
*& Clear errors for pv_data_row; re-run check_one_cell on every
*& header column for that one row; refresh duplicate-key pass at end.
*&---------------------------------------------------------------------*
FORM revalidate_single_row USING pv_tabix    TYPE i
                                 pv_data_row TYPE i.

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

  DATA: ls_header TYPE gty_data_header.

  LOOP AT gt_header_list INTO ls_header.
    ASSIGN COMPONENT ls_header-col_pos OF STRUCTURE <lfs_line> TO <lfs_value>.
    IF sy-subrc = 0 AND <lfs_value> IS ASSIGNED.

      PERFORM check_one_cell USING    <lfs_value>
                                          ls_header
                                          pv_data_row.
    ENDIF.
  ENDLOOP.
  PERFORM validate_duplicate_in_file.
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
*    MESSAGE e070(zmsg_gr23) WITH ps_header-descr INTO lv_err_msg.
    PERFORM add_error USING pv_data_row
                            ps_header-col_pos
                            ps_header-tech_name
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
*        MESSAGE e071(zmsg_gr23) WITH ps_header-descr INTO lv_err_msg.
        PERFORM add_error USING pv_data_row
                                ps_header-col_pos
                                ps_header-tech_name
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
*        MESSAGE e072(zmsg_gr23) WITH ps_header-descr INTO lv_err_msg.
        PERFORM add_error USING pv_data_row
                                ps_header-col_pos
                                ps_header-tech_name
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
*          MESSAGE e073(zmsg_gr23) WITH ps_header-descr INTO lv_err_msg.
          PERFORM add_error USING pv_data_row
                                  ps_header-col_pos
                                  ps_header-tech_name
                                  lv_err_msg.
        ENDIF.
      CATCH cx_sy_conversion_no_number.
        lv_err_msg = replace( val = TEXT-112 sub = '&1' with = ps_header-descr ).
*        MESSAGE e073(zmsg_gr23) WITH ps_header-descr INTO lv_err_msg.
        PERFORM add_error USING pv_data_row
                                ps_header-col_pos
                                ps_header-tech_name
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
*          MESSAGE e074(zmsg_gr23) WITH ps_header-descr ps_header-rng_low INTO lv_err_msg.
          PERFORM add_error USING pv_data_row
                                  ps_header-col_pos
                                  ps_header-tech_name
                                  lv_err_msg.
        ENDIF.
        IF ps_header-rng_high IS NOT INITIAL AND lv_num_check > ps_header-rng_high.
          lv_err_msg = TEXT-115.
          lv_err_msg = replace( val  = replace( val  = TEXT-115
                                                sub  = '&1'
                                                with = ps_header-descr )
                                sub  = '&2'
                                with = CONV string( ps_header-rng_low ) ).
*          MESSAGE e075(zmsg_gr23) WITH ps_header-descr ps_header-rng_high INTO lv_err_msg.
          PERFORM add_error USING pv_data_row
                                  ps_header-col_pos
                                  ps_header-tech_name
                                  lv_err_msg.
        ENDIF.
      CATCH cx_sy_conversion_no_number.
        lv_err_msg =  replace( val  = TEXT-134
                               sub  = '&1'
                               with = ps_header-descr ).
*        MESSAGE e076(zmsg_gr23) WITH ps_header-descr INTO lv_err_msg.
        PERFORM add_error USING pv_data_row
                                ps_header-col_pos
                                ps_header-tech_name
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
          lv_err_msg =  replace( val = lv_err_msg  sub  = '&1'   with = pv_value ).
          lv_err_msg =  replace( val = lv_err_msg  sub  = '&1'   with = pv_value ).
      ENDTRY.
    ENDLOOP.

    IF lv_is_valid = abap_off.
          lv_err_msg =  replace( val = TEXT-080    sub  = '&1'   with = ps_header-descr ).
          lv_err_msg =  replace( val = lv_err_msg  sub  = '&1'   with = pv_value ).
          lv_err_msg =  replace( val = lv_err_msg  sub  = '&1'   with = pv_value ).
      PERFORM add_error USING pv_data_row
                              ps_header-col_pos
                              ps_header-tech_name
                              lv_err_msg.
    ENDIF.
  ENDIF.

ENDFORM.



*&---------------------------------------------------------------------*
*& Section: Full-grid validation
*&---------------------------------------------------------------------*

**&---------------------------------------------------------------------*
**& Form VALIDATE_DATA
**& Walk <gfs_data> x GT_HEADER_LIST: mandatory, date, positive, range,
**& fixed list; skip cells already in GT_ERROR_LOG; then duplicate keys.
**&---------------------------------------------------------------------*
*
*FORM validate_data.
*  IF gv_error = abap_on.
*    RETURN.
*  ENDIF.
*
*  DATA: ls_header  TYPE gty_data_header,
*        lv_tabix   TYPE i,
*        lo_type    TYPE REF TO cl_abap_typedescr,
*        lv_err_msg TYPE string.
*
*  FIELD-SYMBOLS: <lfs_line>  TYPE any,
*                 <lfs_value> TYPE any.
*
*  " Outer loop: each data row in the generic internal table.
*  IF <gfs_data> IS NOT ASSIGNED.
*    MESSAGE s063(zmsg_gr23) DISPLAY LIKE gc_displike_err.
*    RETURN.
*  ENDIF.
*
*  DATA lv_num_check TYPE decfloat34.
*
*  LOOP AT <gfs_data> ASSIGNING <lfs_line>.
*    lv_tabix = sy-tabix.
*
*    " Inner loop: each column rule from header metadata.
*    LOOP AT gt_header_list INTO ls_header.
*
*      ASSIGN COMPONENT ls_header-col_pos OF STRUCTURE <lfs_line> TO <lfs_value>.
*
*      IF sy-subrc = 0 AND <lfs_value> IS ASSIGNED.
*        " Logical data row index (matches GT_ERROR_LOG / UI).
*        DATA(lv_real_row) = lv_tabix + gc_data_start - 1.
*
*        IF ls_header-is_mand = abap_on AND  <lfs_value> IS INITIAL.
*          MESSAGE e070(zmsg_gr23) WITH ls_header-descr INTO lv_err_msg.
*          PERFORM add_error USING lv_real_row
*                                  ls_header-col_pos
*                                  ls_header-tech_name
*                                  lv_err_msg.
*          CONTINUE.
*        ENDIF.
*
*        IF <lfs_value> IS INITIAL.
*          CONTINUE.
*        ENDIF.
*
*        lo_type = cl_abap_typedescr=>describe_by_data( <lfs_value> ).
*        IF lo_type->type_kind = cl_abap_typedescr=>typekind_date.
*          DATA: lv_date_check TYPE d,
*                lv_date_str   TYPE string.
*
*          lv_date_check = condense( val = <lfs_value> ).
*
*          IF lv_date_check IS NOT INITIAL.
*
*            IF strlen( lv_date_check ) <> 8 OR lv_date_check CN '0123456789'.
*              MESSAGE e071(zmsg_gr23) WITH ls_header-descr INTO lv_err_msg.
*              PERFORM add_error USING lv_real_row
*                                      ls_header-col_pos
*                                      ls_header-tech_name
*                                      lv_err_msg.
*              CONTINUE.
*            ENDIF.
*            CALL FUNCTION 'DATE_CHECK_PLAUSIBILITY'
*              EXPORTING
*                date                      = lv_date_check
*              EXCEPTIONS
*                plausibility_check_failed = 1
*                OTHERS                    = 2.
*
*            IF sy-subrc <> 0.
*              MESSAGE e072(zmsg_gr23) WITH ls_header-descr INTO lv_err_msg.
*              PERFORM add_error USING lv_real_row
*                                      ls_header-col_pos
*                                      ls_header-tech_name
*                                      lv_err_msg.
*              CONTINUE.
*            ENDIF.
*
*          ENDIF.
*        ENDIF.
*
*        " Positive-only columns (+ in tech row).
*        IF ls_header-is_pos = abap_on.
*
*          TRY.
*              lv_num_check = <lfs_value>.
*
*              IF lv_num_check < 0.
*                MESSAGE e073(zmsg_gr23) WITH ls_header-descr INTO lv_err_msg.
*                PERFORM add_error USING lv_real_row
*                                        ls_header-col_pos
*                                        ls_header-tech_name
*                                        lv_err_msg.
*              ENDIF.
*            CATCH cx_sy_conversion_no_number.
*              MESSAGE e073(zmsg_gr23) WITH ls_header-descr INTO lv_err_msg.
*              PERFORM add_error USING lv_real_row
*                                      ls_header-col_pos
*                                      ls_header-tech_name
*                                      lv_err_msg.
*              CONTINUE.
*          ENDTRY.
*        ENDIF.
*
*        " Numeric range [RNG:low-high] from header.
*        IF ls_header-rng_low IS NOT INITIAL OR ls_header-rng_high IS NOT INITIAL.
*          TRY.
*
*              lv_num_check = CONV string( <lfs_value> ).
*
*              IF ls_header-rng_low IS NOT INITIAL AND lv_num_check < ls_header-rng_low.
*                MESSAGE e074(zmsg_gr23) WITH ls_header-descr ls_header-rng_low INTO lv_err_msg.
*                PERFORM add_error USING lv_real_row
*                                        ls_header-col_pos
*                                        ls_header-tech_name
*                                        lv_err_msg.
*              ENDIF.
*              IF ls_header-rng_high IS NOT INITIAL AND lv_num_check > ls_header-rng_high.
*                MESSAGE e075(zmsg_gr23) WITH ls_header-descr ls_header-rng_high INTO lv_err_msg.
*                PERFORM add_error USING lv_real_row
*                                        ls_header-col_pos
*                                        ls_header-tech_name
*                                        lv_err_msg.
*              ENDIF.
*            CATCH cx_sy_conversion_no_number.
*              MESSAGE e076(zmsg_gr23) WITH ls_header-descr INTO lv_err_msg.
*              PERFORM add_error USING lv_real_row
*                                      ls_header-col_pos
*                                      ls_header-tech_name
*                                      lv_err_msg.
*              CONTINUE.
*          ENDTRY.
*        ENDIF.
*
*        " Allowed value list [LIST:...] from header.
*        IF ls_header-val_list IS NOT INITIAL.
*          DATA: lv_clean_list2 TYPE string,
*                lt_list_values TYPE TABLE OF string,
*                lv_list_item   TYPE string,
*                lv_is_valid    TYPE abap_bool,
*                lo_dref        TYPE REF TO data.
*
*          FIELD-SYMBOLS: <lfs_list_item_typed> TYPE any.
*
*          SPLIT ls_header-val_list AT ';' INTO TABLE lt_list_values.
*
*          " 3. Khởi tạo biến động có CÙNG TYPE với giá trị field hiện tại (<lfs_value>)
*          CREATE DATA lo_dref LIKE <lfs_value>.
*          ASSIGN lo_dref->* TO <lfs_list_item_typed>.
*          lv_is_valid = abap_off.
*          " 4. Kiểm tra từng giá trị trong list so với dữ liệu đầu vào
*          LOOP AT lt_list_values INTO lv_list_item.
*            TRY.
*                " Tại đây: Ép kiểu dữ liệu cấu hình ('3') thành định dạng của field ('03')
*                <lfs_list_item_typed> = lv_list_item.
*
*                " So sánh chính xác toán học & định dạng (vd: '03' = '03')
*                IF <lfs_value> = <lfs_list_item_typed>.
*                  lv_is_valid = abap_on.
*                  EXIT. " Giá trị hợp lệ -> Dừng vòng lặp check
*                ENDIF.
*
*              CATCH cx_sy_conversion_error.
*                MESSAGE e077(zmsg_gr23) WITH ls_header-descr CONV string( <lfs_value> ) ls_header-val_list INTO lv_err_msg.
*                PERFORM add_error USING lv_real_row
*                                        ls_header-col_pos
*                                        ls_header-tech_name
*                                        lv_err_msg.
*            ENDTRY.
*          ENDLOOP.
*          " 5. Thông báo lỗi nếu check hết list mà vẫn không có giá trị nào khớp
*          IF lv_is_valid = abap_off.
*            MESSAGE e077(zmsg_gr23) WITH ls_header-descr CONV string( <lfs_value> ) ls_header-val_list INTO lv_err_msg.
*            PERFORM add_error USING lv_real_row
*                                    ls_header-col_pos
*                                    ls_header-tech_name
*                                    lv_err_msg.
*          ENDIF.
**          DATA: lv_clean_list  TYPE string,
**                lv_search_list TYPE string,
**                lv_search_val  TYPE string.
**
**          lv_clean_list = replace( val = ls_header-val_list sub = '[LIST:' with = '' ).
**          lv_clean_list = replace( val = lv_clean_list      sub = ']'      with = '' ).
***          CONDENSE lv_clean_list NO-GAPS. !OBSOLETE SYNTAX
**          lv_clean_list = condense(
**                   val = lv_clean_list
**                   del = '' ).
**
**          lv_search_list = |;{ lv_clean_list };|.
**          lv_search_val  = |;{ condense( val = |{ <lfs_value> }| ) };|.
**
**          IF NOT lv_search_list CS lv_search_val.
**            lv_err_msg = |{ TEXT-087 }'{ ls_header-descr }'{ TEXT-103 }{ <lfs_value> }{ TEXT-104 }{ lv_clean_list }{ TEXT-105 }|.
**            PERFORM add_error USING lv_real_row
**                                    ls_header-col_pos
**                                    ls_header-tech_name
**                                    lv_err_msg.
**          ENDIF.
*
*        ENDIF.
*      ENDIF.
*    ENDLOOP.
*  ENDLOOP.
*  DELETE gt_error_log WHERE message CS TEXT-044.
*  PERFORM validate_duplicate_in_file.
*ENDFORM.


*
**&---------------------------------------------------------------------*
**& Section: Single-row revalidation (after edit or date F4)
**&---------------------------------------------------------------------*
*
**&---------------------------------------------------------------------*
**& Form REVALIDATE_SINGLE_ROW
**& Clear errors for pv_data_row; re-run header rules on one <gfs_data> row;
**& remap tech names for ASSIGN; refresh duplicate-key pass at end.
**&---------------------------------------------------------------------*
*FORM revalidate_single_row USING pv_tabix    TYPE i
*                                 pv_data_row TYPE i.
*
*  DATA: ls_header    TYPE gty_data_header,
*        lo_type      TYPE REF TO cl_abap_typedescr,
*        lv_err_msg   TYPE string,
*        lv_num_check TYPE decfloat34.
*
*  FIELD-SYMBOLS: <lfs_line>  TYPE any,
*                 <lfs_value> TYPE any.
*
*  DELETE gt_error_log WHERE row_index = pv_data_row.
*
*  IF <gfs_data> IS NOT ASSIGNED.
*    MESSAGE s063(zmsg_gr23) DISPLAY LIKE gc_displike_err.
*    RETURN.
*  ENDIF.
*
*  READ TABLE <gfs_data> ASSIGNING <lfs_line> INDEX pv_tabix.
*  IF sy-subrc <> 0.
*    RETURN.
*  ENDIF.
*
*  LOOP AT gt_header_list INTO ls_header.
*
*    ASSIGN COMPONENT ls_header-col_pos OF STRUCTURE <lfs_line> TO <lfs_value>.
*    IF sy-subrc = 0 AND <lfs_value> IS ASSIGNED.
*
*      IF ls_header-is_mand = abap_on AND <lfs_value> IS INITIAL.
*        MESSAGE e070(zmsg_gr23) WITH ls_header-descr INTO lv_err_msg.
*        PERFORM add_error USING pv_data_row
*                                ls_header-col_pos
*                                ls_header-tech_name
*                                lv_err_msg.
*        CONTINUE.
*      ENDIF.
*
*      IF <lfs_value> IS INITIAL. CONTINUE. ENDIF.
*
*      lo_type = cl_abap_typedescr=>describe_by_data( <lfs_value> ).
*      IF lo_type->type_kind = cl_abap_typedescr=>typekind_date.
*        DATA: lv_date_check TYPE d,
*              lv_date_str   TYPE string.
*
*        lv_date_check = condense( val = <lfs_value> ).
*
*        IF lv_date_check IS NOT INITIAL.
*
*          IF strlen( lv_date_check ) <> 8 OR lv_date_check CN '0123456789'.
*            MESSAGE e071(zmsg_gr23) WITH ls_header-descr INTO lv_err_msg.
*            PERFORM add_error USING pv_data_row
*                                    ls_header-col_pos
*                                    ls_header-tech_name
*                                    lv_err_msg.
*            CONTINUE.
*          ENDIF.
*          CALL FUNCTION 'DATE_CHECK_PLAUSIBILITY'
*            EXPORTING
*              date                      = lv_date_check
*            EXCEPTIONS
*              plausibility_check_failed = 1
*              OTHERS                    = 2.
*
*          IF sy-subrc <> 0.
*            MESSAGE e072(zmsg_gr23) WITH ls_header-descr INTO lv_err_msg.
*            PERFORM add_error USING pv_data_row
*                                    ls_header-col_pos
*                                    ls_header-tech_name
*                                    lv_err_msg.
*            CONTINUE.
*          ENDIF.
*
*        ENDIF.
*      ENDIF.
*
*      IF ls_header-is_pos = abap_on.
*        TRY.
*            lv_num_check = <lfs_value>.
*            IF lv_num_check < 0.
*              MESSAGE e073(zmsg_gr23) WITH ls_header-descr INTO lv_err_msg.
*              PERFORM add_error USING pv_data_row
*                                      ls_header-col_pos
*                                      ls_header-tech_name
*                                      lv_err_msg.
*            ENDIF.
*          CATCH cx_sy_conversion_no_number.
*            MESSAGE e073(zmsg_gr23) WITH ls_header-descr INTO lv_err_msg.
*            PERFORM add_error USING pv_data_row
*                                    ls_header-col_pos
*                                    ls_header-tech_name
*                                    lv_err_msg.
*            CONTINUE.
*        ENDTRY.
*      ENDIF.
*
*      IF ls_header-rng_low IS NOT INITIAL OR ls_header-rng_high IS NOT INITIAL.
*        TRY.
*
*            lv_num_check = CONV string( <lfs_value> ).
*
*            IF ls_header-rng_low IS NOT INITIAL AND lv_num_check < ls_header-rng_low.
*              MESSAGE e074(zmsg_gr23) WITH ls_header-descr ls_header-rng_low INTO lv_err_msg.
*              PERFORM add_error USING pv_data_row
*                                      ls_header-col_pos
*                                      ls_header-tech_name
*                                      lv_err_msg.
*            ENDIF.
*            IF ls_header-rng_high IS NOT INITIAL AND lv_num_check > ls_header-rng_high.
*              MESSAGE e075(zmsg_gr23) WITH ls_header-descr ls_header-rng_high INTO lv_err_msg.
*              PERFORM add_error USING pv_data_row
*                                      ls_header-col_pos
*                                      ls_header-tech_name
*                                      lv_err_msg.
*            ENDIF.
*          CATCH cx_sy_conversion_no_number.
*            MESSAGE e076(zmsg_gr23) WITH ls_header-descr INTO lv_err_msg.
*
*            PERFORM add_error USING pv_data_row
*                                    ls_header-col_pos
*                                    ls_header-tech_name
*                                    lv_err_msg.
*            CONTINUE.
*        ENDTRY.
*      ENDIF.
*
*      IF ls_header-val_list IS NOT INITIAL.
*
*        DATA: lv_clean_list2 TYPE string,
*              lt_list_values TYPE TABLE OF string,
*              lv_list_item   TYPE string,
*              lv_is_valid    TYPE abap_bool,
*              lo_dref        TYPE REF TO data.
*
*        FIELD-SYMBOLS: <lfs_list_item_typed> TYPE any.
*
*        SPLIT ls_header-val_list AT ';' INTO TABLE lt_list_values.
*
*        " 3. Khởi tạo biến động có CÙNG TYPE với giá trị field hiện tại (<lfs_value>)
*        CREATE DATA lo_dref LIKE <lfs_value>.
*        ASSIGN lo_dref->* TO <lfs_list_item_typed>.
*        lv_is_valid = abap_off.
*        " 4. Kiểm tra từng giá trị trong list so với dữ liệu đầu vào
*        LOOP AT lt_list_values INTO lv_list_item.
*          TRY.
*              " Tại đây: Ép kiểu dữ liệu cấu hình ('3') thành định dạng của field ('03')
*              <lfs_list_item_typed> = lv_list_item.
*
*              " So sánh chính xác toán học & định dạng (vd: '03' = '03')
*              IF <lfs_value> = <lfs_list_item_typed>.
*                lv_is_valid = abap_on.
*                EXIT. " Giá trị hợp lệ -> Dừng vòng lặp check
*              ENDIF.
*
*            CATCH cx_sy_conversion_error.
*              " Bỏ qua âm thầm nếu phần tử cấu hình trong list không ép kiểu được
*              MESSAGE e077(zmsg_gr23) WITH ls_header-descr <lfs_value> ls_header-val_list INTO lv_err_msg.
*              PERFORM add_error USING pv_data_row
*                                      ls_header-col_pos
*                                      ls_header-tech_name
*                                      lv_err_msg.
*          ENDTRY.
*        ENDLOOP.
*        " 5. Thông báo lỗi nếu check hết list mà vẫn không có giá trị nào khớp
*        IF lv_is_valid = abap_off.
*          MESSAGE e077(zmsg_gr23) WITH ls_header-descr <lfs_value> ls_header-val_list INTO lv_err_msg.
*          PERFORM add_error USING pv_data_row
*                                  ls_header-col_pos
*                                  ls_header-tech_name
*                                  lv_err_msg.
*        ENDIF.
*      ENDIF.
*    ENDIF.
*
*  ENDLOOP.
*  DELETE gt_error_log WHERE message CS TEXT-044.
*  PERFORM validate_duplicate_in_file.
*ENDFORM.

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
    MESSAGE s063(zmsg_gr23) DISPLAY LIKE gc_displike_err.
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
*
*          CALL FUNCTION 'DATE_CHECK_PLAUSIBILITY'
*            EXPORTING
*              date                      = lv_datbi
*            EXCEPTIONS
*              plausibility_check_failed = 1
*              OTHERS                    = 2.

          lv_datbi = condense( val = ls_mod_cell-value ).
          IF strlen( lv_datbi ) <> 8 OR lv_datbi CN '0123456789'.
*          ELSEIF sy-subrc <> 0.
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

  PERFORM revalidate_single_row USING lv_tabix gv_selected_data_row.

  PERFORM prepare_master_alv_data.

  go_grid_master->refresh_table_display( is_stable = VALUE #( row = abap_on col = abap_on ) ).
  PERFORM prepare_detail_alvs.
ENDFORM.
