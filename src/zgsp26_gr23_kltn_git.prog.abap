*&---------------------------------------------------------------------*
*& Report ZGSP26_GROUP23_KLTN
*&---------------------------------------------------------------------*
*&
*&---------------------------------------------------------------------*
REPORT zgsp26_gr23_kltn_git.

INCLUDE zgsp26_group23_t01_git. "Top Include

INCLUDE zgsp26_group23_s01_git. "Main Screen

INCLUDE zgsp26_group23_c00_git. "Class Definition

INCLUDE zgsp26_group23_f00_git. "ALV UI Management Routines

INCLUDE zgsp26_group23_f01_git. "File I/O Routines

INCLUDE zgsp26_group23_f02_git. "Validation Routines

INCLUDE zgsp26_group23_f03_git. "Main Process Flow

INCLUDE zgsp26_group23_f04_git. "History & Download Routines

INCLUDE zgsp26_group23_f05_git. "Database & Logging Routines

INCLUDE zgsp26_group23_f06_git. "Encoding & File Rebuild Routines

INCLUDE zgsp26_group23_f07_git. "Utility Routines

INCLUDE zgsp26_group23_f08_git. "Data Processing & Sheet Management

INCLUDE zgsp26_group23_i01_git. "Process After Input

INCLUDE zgsp26_group23_o01_git. "Process Before Output

START-OF-SELECTION.
  PERFORM main_process.
