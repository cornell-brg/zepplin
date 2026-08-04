/*======================================================================*/
/* Zeppelin linker script for assembly tests                               */
/*======================================================================*/
/* Identical to app/scripts/zeppelin.ld except STARTUP references          */
/* crt0_test.o instead of crt0.o, keeping test builds fully independent */
/* of the app/ build tree.                                               */

ENTRY( _start )
STARTUP( crt0_test.o )

MEMORY
{
  mem (rwx)        : ORIGIN = 0x00000200, LENGTH = 0xF0000000
  io  (!r!w!x!a!i) : ORIGIN = 0xF0000000, LENGTH = 0x10000000
}

SECTIONS
{

  /*--------------------------------------------------------------------*/
  /* Code and read-only segment                                         */
  /*--------------------------------------------------------------------*/

  .text :
  {
    *(.text)
    *(.text.*)
  }

  .rodata :
  {
    *(.rdata)
    *(.rodata)
    *(.rodata.*)
  }

  /*--------------------------------------------------------------------*/
  /* Initialized data segment                                           */
  /*--------------------------------------------------------------------*/

  . = ALIGN(16);
  _fdata = .;

  .data :
  {
    *(.data)
    *(.data.*)
  }

  . = ALIGN(16);
  _gp = . + 0x800;

  .sdata :
  {
    *(.sdata)
    *(.sdata.*)
    *(.srodata.*)
  }

  /*--------------------------------------------------------------------*/
  /* Uninitialized data segment                                         */
  /*--------------------------------------------------------------------*/

  . = ALIGN(16);
  _fbss = .;

  .sbss :
  {
    *(.sbss)
    *(.sbss.*)
  }

  . = .;
  .bss :
  {
    *(.bss)
    *(.bss.*)
    *(COMMON)
  }

  _end = ALIGN(16);
}
