REPORT ztest_abaplint.

DATA lv_name TYPE string.
DATA lv_count TYPE i.
DATA lv_unused TYPE string.

lv_name = 'Mundo'.
lv_count = 42.

IF lv_count > 10.
  WRITE: / 'Hola', lv_name.
ELSE.
  WRITE: / 'Adios'.
ENDIF.
