*&---------------------------------------------------------------------*
*& Objeto:   ZCLACA_LOG.ABAP
*& Paquete:  $Z001
*&---------------------------------------------------------------------*
CLASS ZCLACA_LOG.ABAP DEFINITION PUBLIC.
  PUBLIC SECTION.
    METHODS: constructor.
  PROTECTED SECTION.
  PRIVATE SECTION.
ENDCLASS.

CLASS ZCLACA_LOG.ABAP IMPLEMENTATION.
  METHOD constructor.
    super->constructor( ).
  ENDMETHOD.
ENDCLASS.
