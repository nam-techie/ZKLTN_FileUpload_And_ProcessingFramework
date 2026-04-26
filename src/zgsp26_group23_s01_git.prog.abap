*&---------------------------------------------------------------------*
*& Include          ZGSP26_GROUP23_S01
*&---------------------------------------------------------------------*

TABLES sscrfields ##NEEDED.
TYPE-POOLS vrm.

*----------------------------------------------------------------------*
* MAIN SCREEN DEFINITION
*----------------------------------------------------------------------*

" --- Block 1: processing mode ---
SELECTION-SCREEN BEGIN OF BLOCK b1 WITH FRAME TITLE TEXT-001.
  PARAMETERS: p_val  RADIOBUTTON GROUP act DEFAULT 'X' USER-COMMAND u_act, " Validate and save
              p_stor RADIOBUTTON GROUP act,                                " Store only (no validation run)
              p_hist RADIOBUTTON GROUP act.                                " View upload history
SELECTION-SCREEN END OF BLOCK b1.

" --- Block 2: new file upload ---
SELECTION-SCREEN BEGIN OF BLOCK b2 WITH FRAME TITLE TEXT-002.

  " Where the file comes from: local PC or application server (e.g. AL11)

  SELECTION-SCREEN BEGIN OF LINE.

    " Label "File source:" (text symbol s01)
    SELECTION-SCREEN COMMENT 1(12) TEXT-s01 MODIF ID m1.

    " Radio option 1 + its label
    SELECTION-SCREEN COMMENT 19(12) TEXT-s02 FOR FIELD p_local MODIF ID m1.
    PARAMETERS: p_local  RADIOBUTTON GROUP src DEFAULT 'X' MODIF ID m1 USER-COMMAND u2.


    " Radio option 2 + its label
    SELECTION-SCREEN COMMENT 35(20) TEXT-s03 FOR FIELD p_server MODIF ID m1.
    PARAMETERS: p_server RADIOBUTTON GROUP src MODIF ID m1.

  SELECTION-SCREEN END OF LINE.

  " File type (listbox)
  PARAMETERS: p_ftype TYPE char10 AS LISTBOX VISIBLE LENGTH 15 DEFAULT gc_ftype_xlsx OBLIGATORY MODIF ID m1 USER-COMMAND fty.

  " Full file path / logical file name
  PARAMETERS: p_file TYPE rlgrap-filename MODIF ID m1 VISIBLE LENGTH 60.

SELECTION-SCREEN END OF BLOCK b2.

" --- Block 3: history filters ---
SELECTION-SCREEN BEGIN OF BLOCK b3 WITH FRAME TITLE TEXT-003.
  PARAMETERS: p_date  TYPE datum MODIF ID m2.

  PARAMETERS: p_ftype2 TYPE char10 AS LISTBOX VISIBLE LENGTH 15 DEFAULT '*' MODIF ID m2 USER-COMMAND fty2.
SELECTION-SCREEN END OF BLOCK b3.

SELECTION-SCREEN FUNCTION KEY 1.

*----------------------------------------------------------------------*
* INITIALIZATION (fill listbox values, toolbar texts)
*----------------------------------------------------------------------*
INITIALIZATION.
  PERFORM init_selection_screen.

*----------------------------------------------------------------------*
*  PBO - PROCESS BEFORE OUTPUT (show / hide fields by mode)
*----------------------------------------------------------------------*
AT SELECTION-SCREEN OUTPUT.
  PERFORM pbo_selection_screen.

*----------------------------------------------------------------------*
* PAI - F4 HELP (file browse)
*----------------------------------------------------------------------*
AT SELECTION-SCREEN ON VALUE-REQUEST FOR p_file.
  PERFORM f4_help_p_file.

*----------------------------------------------------------------------*
*  PAI - VALIDATION (checks before leaving selection screen)
*----------------------------------------------------------------------*
AT SELECTION-SCREEN.
  PERFORM pai_selection_screen.

*&---------------------------------------------------------------------*
*& Form INIT_SELECTION_SCREEN
*&---------------------------------------------------------------------*
FORM init_selection_screen.

  DATA: lt_values_new  TYPE vrm_values,
        lt_values_hist TYPE vrm_values,
        ls_value       LIKE LINE OF lt_values_new,
        ls_functxt     TYPE smp_dyntxt.

  ls_value-key = gc_ftype_xlsx. ls_value-text = TEXT-072.
  APPEND ls_value TO lt_values_new.

  ls_value-key = gc_ftype_csv.  ls_value-text = TEXT-073.
  APPEND ls_value TO lt_values_new.

  ls_value-key = gc_ftype_txt.  ls_value-text = TEXT-074.
  APPEND ls_value TO lt_values_new.

  CALL FUNCTION 'VRM_SET_VALUES'
    EXPORTING
      id     = 'P_FTYPE'
      values = lt_values_new
    EXCEPTIONS
      OTHERS = 2.
  IF sy-subrc <> 0.
    MESSAGE ID sy-msgid TYPE 'S' NUMBER sy-msgno
            WITH sy-msgv1 sy-msgv2 sy-msgv3 sy-msgv4
            DISPLAY LIKE gc_displike_err.
  ENDIF.

  lt_values_hist = lt_values_new.

  CLEAR ls_value.
  ls_value-key  = '*'.
  ls_value-text = TEXT-075.
  INSERT ls_value INTO lt_values_hist INDEX 1.

  CALL FUNCTION 'VRM_SET_VALUES'
    EXPORTING
      id     = 'P_FTYPE2'
      values = lt_values_hist
    EXCEPTIONS
      OTHERS = 2.
  IF sy-subrc <> 0.
    MESSAGE ID sy-msgid TYPE 'S' NUMBER sy-msgno
            WITH sy-msgv1 sy-msgv2 sy-msgv3 sy-msgv4
            DISPLAY LIKE gc_displike_err.
  ENDIF.

  ls_functxt-text        = TEXT-076.
  ls_functxt-icon_id     = icon_export.
  ls_functxt-icon_text   = TEXT-077.
  ls_functxt-quickinfo   = TEXT-078.
  sscrfields-functxt_01  = ls_functxt.

ENDFORM.

*&---------------------------------------------------------------------*
*& Form PBO_SELECTION_SCREEN
*&---------------------------------------------------------------------*
FORM pbo_selection_screen.

  LOOP AT SCREEN.
    IF p_val = abap_on OR p_stor = abap_on.

      IF screen-group1 = 'M2'.
        screen-active = 0.
      ENDIF.

    ELSE.

      IF screen-group1 = 'M1'.
        screen-active = 0.
      ENDIF.

    ENDIF.
    MODIFY SCREEN.
  ENDLOOP.

ENDFORM.

*&---------------------------------------------------------------------*
*& Form f4_help_p_file
*&---------------------------------------------------------------------*
FORM f4_help_p_file.

  IF p_val = abap_on OR p_stor = abap_on.
    IF p_local = abap_on.
      PERFORM browse_file CHANGING p_file.
    ELSE.
      PERFORM browse_server_file CHANGING p_file.
    ENDIF.
  ENDIF.

ENDFORM.

*&---------------------------------------------------------------------*
*& Form PAI_SELECTION_SCREEN
*&---------------------------------------------------------------------*
FORM pai_selection_screen.

  DATA: lv_ext       TYPE string,
        lv_full_path TYPE string,
        lv_reversed  TYPE string,
        lv_dummy     TYPE string ##NEEDED.

  IF sy-ucomm = 'ONLI'.
    IF p_val = abap_on OR p_stor = abap_on.
      IF p_file IS INITIAL.
        MESSAGE e026(zmsg_gr23).
      ENDIF.

      lv_full_path = p_file.
      lv_reversed = reverse( lv_full_path ).
      SPLIT lv_reversed AT '.' INTO lv_ext lv_dummy.
      lv_ext = reverse( lv_ext ).
      TRANSLATE lv_ext TO UPPER CASE.

      IF lv_ext <> p_ftype.
        MESSAGE w027(zmsg_gr23) WITH lv_ext p_ftype.
      ENDIF.
    ENDIF.
  ENDIF.

  IF sy-ucomm = 'FC01'.
    PERFORM download_template_zip.
  ENDIF.

ENDFORM.
