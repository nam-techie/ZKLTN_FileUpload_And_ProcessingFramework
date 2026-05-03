*&---------------------------------------------------------------------*
*& Report ZGSP26_GROUP23_KLTN
*&---------------------------------------------------------------------*
*&
*&---------------------------------------------------------------------*
REPORT zgsp26_group23_kltn MESSAGE-ID ZMSG_GR23.

INCLUDE zgsp26_group23_t01. "Top Include

INCLUDE zgsp26_group23_s01. "Main Screen

INCLUDE zgsp26_group23_c00. "Class Definition

INCLUDE zgsp26_group23_f00. "ALV UI Management Routines

INCLUDE zgsp26_group23_f01. "File I/O Routines

INCLUDE zgsp26_group23_f02. "Validation Routines

INCLUDE zgsp26_group23_f03. "Main Process Flow

INCLUDE zgsp26_group23_f04. "History & Download Routines

INCLUDE zgsp26_group23_f05. "Database & Logging Routines

INCLUDE zgsp26_group23_f06. "Encoding & File Rebuild Routines

INCLUDE zgsp26_group23_f07. "Utility Routines

INCLUDE zgsp26_group23_f08. "Data Processing & Sheet Management

INCLUDE zgsp26_group23_i01. "Process After Input

INCLUDE zgsp26_group23_o01. "Process Before Output

START-OF-SELECTION.
  PERFORM main_process.
