#include <dos.h>
#include "SRC/GEN/GFXCTX.H"
#include "structs.h"
#include "SRC/GFX/DRIVER/VIDDRV.H"
#include "SRC/SYS/FARTHUNK.H"
#include "SRC/SYS/DOSMEM.H"
#include "SRC/STREAM/RESLOAD/IFFREAD.H"
#include "SRC/STREAM/CODEC/STREAM.H"
#include "SRC/GEN/RNDVTBL.H"

void huge *g_pVideoDriverTemplate = {0};
char g_szDrvSuffix_BAD[3] = {'B', 'A', 'D'};
unsigned short g_apVideoDriverChunkNames[13] = {0x003a,
                                                (unsigned short)g_szDrvSuffix_CGA,
                                                (unsigned short)g_szDrvSuffix_EGA,
                                                (unsigned short)g_szDrvSuffix_TAN,
                                                (unsigned short)g_szDrvSuffix_HER,
                                                (unsigned short)g_szDrvSuffix_MCG,
                                                (unsigned short)g_szDrvSuffix_BAD,
                                                (unsigned short)g_szDrvSuffix_EVA,
                                                (unsigned short)g_szDrvSuffix_VGA,
                                                (unsigned short)g_szDrvSuffix_EVG,
                                                (unsigned short)g_szDrvSuffix_HVG,
                                                (unsigned short)g_szDrvSuffix_HEG,
                                                (unsigned short)g_szDrvSuffix_NEW};
char g_szVideoChunkName[10] = "OVL:     ";
char g_szDrvSuffix_CGA[5] = "CGA:";
char g_szDrvSuffix_EGA[5] = "EGA:";
char g_szDrvSuffix_TAN[5] = "TAN:";
char g_szDrvSuffix_HER[5] = "HER:";
char g_szDrvSuffix_MCG[5] = "MCG:";
char g_szDrvSuffix_EVA[5] = "EVA:";
char g_szDrvSuffix_VGA[5] = "VGA:";
char g_szDrvSuffix_EVG[5] = "EVG:";
char g_szDrvSuffix_HVG[5] = "HVG:";
char g_szDrvSuffix_HEG[5] = "HEG:";
char g_szDrvSuffix_NEW[5] = "NEW:";

#define SVGA_DRIVER_MAX 0x4000

typedef void(far *SvgaCopyRectFn)(unsigned src_page, unsigned dst_page, int x, int y, int w,
                                  int h);
typedef void(far *SvgaSetOriginFn)(int x, int y);

int g_bSvgaDriver = 0;
int g_svgaOriginX = SVGA_UI_X;
int g_svgaOriginY = SVGA_UI_Y;

void far svga_copy_rect(unsigned src_page, unsigned dst_page, int x, int y, int w, int h) {
    (*(SvgaCopyRectFn)g_renderer_vtable.slot_41_unimplemented)(src_page, dst_page, x, y, w, h);
}

int g_svgaCurOriginX = SVGA_UI_X;
int g_svgaCurOriginY = SVGA_UI_Y;

void far svga_set_origin(int x, int y) {
    g_svgaCurOriginX = x;
    g_svgaCurOriginY = y;
    (*(SvgaSetOriginFn)g_renderer_vtable.slot_42_unimplemented)(x, y);
}

typedef void(far *SvgaCopyPageFn)(unsigned src_page, unsigned dst_page);

void far svga_copy_page(unsigned src_page, unsigned dst_page) {
    (*(SvgaCopyPageFn)g_renderer_vtable.slot_45_unimplemented)(src_page, dst_page);
}

typedef void(far *SvgaFillRectFn)(int x, int y, int w, int h, int colour);

/* whole 640x480 page to colour 0 (the logical clears only cover the UI box) */
void far svga_clear_page(unsigned page) {
    unsigned savedDst;
    int ox, oy;

    savedDst = g_graphics_context.wGfxBlitDstPage;
    ox = g_svgaCurOriginX;
    oy = g_svgaCurOriginY;
    g_graphics_context.wGfxBlitDstPage = page;
    svga_set_origin(0, 0);
    (*(SvgaFillRectFn)g_renderer_vtable.slot_44_unimplemented)(0, 0, 640, 480, 0);
    svga_set_origin(ox, oy);
    g_graphics_context.wGfxBlitDstPage = savedDst;
}

void far svga_set_ui_origin(int x, int y) {
    g_svgaOriginX = x;
    g_svgaOriginY = y;
    svga_set_origin(x, y);
}

static void far *svga_driver_load(void) {
    int fd;
    unsigned got;

    if (_dos_open("SVGA.DRV", 0, &fd) != 0) {
        return 0;
    }
    if (g_pVideoDriverTemplate != 0) {
        _freemem(g_pVideoDriverTemplate);
    }
    if ((g_pVideoDriverTemplate = alloc_far((long)SVGA_DRIVER_MAX, 0L)) == 0) {
        _dos_close(fd);
        return 0;
    }
    _dos_read(fd, (void far *)g_pVideoDriverTemplate, SVGA_DRIVER_MAX, &got);
    _dos_close(fd);
    return (void far *)g_pVideoDriverTemplate;
}

unsigned long far *video_driver_load(int mode, FileRef *file) {
    long size;
    int stream_id;
    int did_open;
    ResFile *handle;
    void far *svga;

    did_open = 0;

    g_bSvgaDriver = 0;
    if (mode == 8 && (svga = svga_driver_load()) != 0) {
        g_bSvgaDriver = 1;
        return (unsigned long far *)svga;
    }

    switch (mode) {
    case 12:
        mode = 0xb;
        g_wScreen_height = 0x15e;
        break;
    case 13:
        mode = 0xb;
        g_wScreen_height = 0x1e0;
        break;
    case 14:
        mode = 0xb;
        goto set_height_400;
    case 4:
        mode = 1;
        g_wScreen_width = 0x280;
    case 15:
        mode = 8;
    set_height_400:
        g_wScreen_height = 400;
        break;
    }

    if (is_file_cached(file) == 0) {
        did_open = 1;
        handle = cached_file_open(file);
    } else {
        handle = file;
    }
    if (handle == 0) {
        goto fail;
    }

    my_strcpy(g_szVideoChunkName + 4, (char *)g_apVideoDriverChunkNames[mode]);
    if (chunk_seek(handle, g_szVideoChunkName, 0) == -1L) {
        goto fail;
    }

    if ((stream_id = stream_open(-1, handle, "r", cached_file_chunk_size(handle))) < 0) {
        goto fail;
    }

    size = stream_size(stream_id);

    if (g_pVideoDriverTemplate != 0) {
        _freemem(g_pVideoDriverTemplate);
    }
    if ((g_pVideoDriverTemplate = alloc_far(size, 0L)) == 0) {
        goto fail;
    }

    stream_read(stream_id, (void far *)g_pVideoDriverTemplate, (unsigned int)size);
    stream_close(stream_id);

    if (did_open != 0) {
        cached_file_close(handle);
    }
    return (unsigned long far *)g_pVideoDriverTemplate;

fail:
    return 0;
}
