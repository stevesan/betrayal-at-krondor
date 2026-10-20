#ifndef BAK_VIDDRV_H
#define BAK_VIDDRV_H

#include "structs.h"
#include "SRC/IO/RESOURCE.H"

extern void huge *g_pVideoDriverTemplate;
extern char g_szDrvSuffix_BAD[3];
extern unsigned short g_apVideoDriverChunkNames[13];
extern char g_szVideoChunkName[10];
extern char g_szDrvSuffix_CGA[5];
extern char g_szDrvSuffix_EGA[5];
extern char g_szDrvSuffix_TAN[5];
extern char g_szDrvSuffix_HER[5];
extern char g_szDrvSuffix_MCG[5];
extern char g_szDrvSuffix_EVA[5];
extern char g_szDrvSuffix_VGA[5];
extern char g_szDrvSuffix_EVG[5];
extern char g_szDrvSuffix_HVG[5];
extern char g_szDrvSuffix_HEG[5];
extern char g_szDrvSuffix_NEW[5];

#define SVGA_UI_X 160
#define SVGA_UI_Y 280
#define SVGA_VIEW_W 640
#define SVGA_VIEW_H 392
#define SVGA_VIEW_ZOOM 8

extern int g_bSvgaDriver;
extern int g_svgaOriginX;
extern int g_svgaOriginY;
extern int g_svgaCurOriginX;
extern int g_svgaCurOriginY;

extern unsigned long far *video_driver_load(int mode, FileRef *file);
extern void svga_copy_rect(unsigned src_page, unsigned dst_page, int x, int y, int w, int h);
extern void svga_set_origin(int x, int y);
extern void svga_copy_page(unsigned src_page, unsigned dst_page);
extern void svga_set_ui_origin(int x, int y);
extern void svga_clear_page(unsigned page);

#endif
