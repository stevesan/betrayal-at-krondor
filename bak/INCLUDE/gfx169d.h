#ifndef GFX169D_H
#define GFX169D_H

extern unsigned char far g_abCursorPaletteLut[256];

extern unsigned char far g_abFogRemapTable[2560];

#define FOG_REMAP_TAB_OFF ((unsigned)(unsigned long)(void far *)g_abFogRemapTable)
#define CURSOR_REMAP_TAB_OFF ((unsigned)(unsigned long)(void far *)g_abCursorPaletteLut)

#endif
