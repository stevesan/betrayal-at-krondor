; ============================================================================
; SVGA.ASM -- 640x480x256 VESA linear-framebuffer video driver (mod).
;
; Drop-in replacement for the VMCODE.OVL "VGA:" chunk, loaded from SVGA.DRV.
; Same entry ABI and 50-slot vtable layout as the shipped drivers; the slot
; semantics follow the chunky MCGA driver (MCG.ASM) plus chunky versions of the
; VGA-only slots (19, 23, 24, 39, 40).
;
; Memory model: VBE mode 101h with a linear framebuffer, addressed through
; 32-bit flat offsets from real mode ("unreal mode": FS/ES/DS limits raised to
; 4 GiB at init). Every engine "page segment" (A000/A400/A800/AC00) is a page
; ID mapped to a 640x480 page in VRAM. The engine's row LUT holds the row
; number itself; slots turn (page, row, x) into a flat address, adding the
; origin offset that places the engine's 320x200 logical screen on the
; 640x480 display.
;
; Build: nasm -f bin SVGA.ASM -o SVGA.DRV
; ============================================================================

                cpu     386
                bits    16
                org     0

PITCH           equ     640
SCR_W           equ     640
SCR_H           equ     480
PAGE_SIZE       equ     PITCH*SCR_H
RETRACE_SPIN    equ     40000           ; bounded retrace polling

; --- GfxContext field offsets (GFXCTX.INC) ---
GC_FG           equ     000h
GC_BG           equ     001h
GC_STYLE        equ     002h
GC_CLIP_EN      equ     003h
GC_CLIP_X0      equ     004h
GC_CLIP_X1      equ     006h
GC_CLIP_Y0      equ     008h
GC_CLIP_Y1      equ     00Ah
GC_FILL_COLOR   equ     00Dh
GC_OUTLINE      equ     00Eh
GC_DITHER       equ     00Fh
GC_PAGE1        equ     010h
GC_PAGE2        equ     012h
GC_FRONT        equ     014h
GC_SRC          equ     016h
GC_DST          equ     018h
GC_ADAPTER      equ     01Dh
GC_RSTATE       equ     01Fh
GC_ACTMODE      equ     021h
GC_PALBUF       equ     19Eh
GC_TEXIDX       equ     6BCh
GC_SCR_W        equ     6EAh
GC_SCR_H        equ     6ECh
GC_ROWLUT       equ     6F2h
GC_AUTODET      equ     0AB4h

; ============================================================================
; Entry: init. Far call: [BP+6] = ctx offset (paragraph aligned, in caller DS),
; [BP+8]/[BP+0A] = far ptr to 19 host callbacks. Returns AL = 8,
; DX:SI = vtable.
; ============================================================================
svga_init:
                push    bp
                mov     bp, sp
                push    di
                push    ds
                push    di
                push    si
                mov     di, hostcb
                push    cs
                pop     es
                mov     si, [bp+8]
                mov     ds, [bp+0Ah]
                mov     cx, 26h
                cld
                rep     movsw
                pop     si
                pop     di
                pop     ds
                mov     ax, [bp+6]
                shr     ax, 4
                mov     bx, ds
                add     ax, bx
                mov     [cs:dseg], ax
                push    ds
                mov     ds, ax
                mov     byte [GC_ACTMODE], 0FFh
                inc     byte [GC_RSTATE]

                ; VBE mode info -> LFB physical base
                push    cs
                pop     es
                mov     ax, 4F01h
                mov     cx, 101h
                mov     di, modeinfo
                int     10h
                mov     eax, [cs:modeinfo+28h]
                mov     [cs:lfb], eax

                call    enter_unreal

                cmp     byte [GC_AUTODET], 0
                je      .no_modeset
                mov     ax, 4F02h
                mov     bx, 4101h
                int     10h
                call    enter_unreal
                ; clear four pages
                push    es
                xor     ax, ax
                mov     es, ax
                mov     edi, [cs:lfb]
                mov     ecx, PAGE_SIZE*4/4
                xor     eax, eax
                a32 rep stosd
                pop     es
                xor     bx, bx
                xor     cx, cx
                xor     dx, dx
                mov     ax, 4F07h
                int     10h
.no_modeset:
                mov     word [GC_FRONT], 0A000h
                mov     word [GC_PAGE2], 0A400h
                mov     word [GC_PAGE1], 0A800h

                ; row LUT: row number per row
                push    ds
                pop     es
                mov     di, GC_ROWLUT
                xor     ax, ax
                mov     cx, SCR_H
.lut:           stosw
                inc     ax
                loop    .lut

                mov     al, 8
                mov     [GC_ADAPTER], al
                pop     ds
                mov     dx, cs
                mov     si, vtable
                pop     di
                pop     bp
                retf

; Raise DS/ES/FS/GS limits to 4 GiB (unreal mode). DOSBox does not check
; real-mode limits, but real CPUs do.
enter_unreal:
                pushad
                push    ds
                push    es
                push    fs
                push    gs
                pushf
                cli
                xor     eax, eax
                mov     ax, cs
                shl     eax, 4
                add     eax, unreal_gdt
                mov     [cs:unreal_gdtr+2], eax
                lgdt    [cs:unreal_gdtr]
                mov     eax, cr0
                or      al, 1
                mov     cr0, eax
                jmp     short $+2
                mov     bx, 8
                mov     ds, bx
                mov     es, bx
                mov     fs, bx
                mov     gs, bx
                and     al, 0FEh
                mov     cr0, eax
                jmp     short $+2
                popf
                pop     gs
                pop     fs
                pop     es
                pop     ds
                popad
                ret

                align   4
dseg            dw      0
                dw      0
lfb             dd      0
org_x           dd      160
org_y           dd      280

; ============================================================================
; vtable (50 slots, offset:segment; the host patches the segment halves)
; ============================================================================
                align   4
vtable:
                dw      0, 0                    ; 0
                dw      s_glyph_row, 0          ; 1
                dw      s_draw_line, 0          ; 2
                dw      s_blit_sprite, 0        ; 3
                dw      s_present, 0            ; 4
                dw      s_save_rect, 0          ; 5
                dw      s_rect_size, 0          ; 6
                dw      s_paste_rect, 0         ; 7
                dw      s_flip, 0               ; 8
                dw      s_nop, 0                ; 9
                dw      s_fill_run_a, 0         ; 10
                dw      s_fill_run_b, 0         ; 11
                dw      s_nop, 0                ; 12
                dw      s_image_measure, 0      ; 13
                dw      s_image_install, 0      ; 14
                dw      s_image_pack_or, 0      ; 15
                dw      s_nop, 0                ; 16
                dw      s_nibble_blit, 0        ; 17
                dw      s_nibble_blit_or, 0     ; 18
                dw      s_tex_span_b, 0         ; 19
                dw      s_palette_set, 0        ; 20
                dw      s_getpixel, 0           ; 21
                dw      s_putpixel, 0           ; 22
                dw      s_rect_buffer, 0        ; 23
                dw      s_set_buffer_ofs, 0     ; 24
                dw      s_nop, 0                ; 25
                dw      s_nop, 0                ; 26
                dw      s_span_fill, 0          ; 27
                dw      s_nop, 0                ; 28
                dw      s_sprite_master, 0      ; 29
                dw      s_rect_blit, 0          ; 30
                dw      s_identity, 0           ; 31
                dw      s_nop, 0                ; 32
                dw      s_sprite_simple, 0      ; 33
                dw      s_palette_lerp, 0       ; 34
                dw      s_dac_write, 0          ; 35
                dw      s_rot_span, 0           ; 36
                dw      s_stretch_span, 0       ; 37
                dw      s_chunky_span, 0        ; 38
                dw      s_remap_spans, 0        ; 39
                dw      s_tex_span, 0           ; 40
                dw      s_copy_rect, 0          ; 41  (new) page->page rect copy
                dw      s_set_origin, 0         ; 42  (new) logical origin
                dw      s_flat_addr, 0          ; 43  (new) flat address of (page, x, y)
                dw      s_fill_rect, 0          ; 44  (new) solid rect fill on DstPage
                dw      s_copy_page, 0          ; 45  (new) whole-page copy (src, dst)
                dw      s_flat_addr_org, 0      ; 46  (new) flat address with explicit origin
                dw      s_nop, 0                ; 47
                dw      s_nop, 0                ; 48
                dw      0, 0                    ; 49

hostcb:         times   19*2 dw 0

s_nop:          retf

s_identity:
                push    bp
                mov     bp, sp
                mov     ax, [bp+6]
                pop     bp
                retf

; ============================================================================
; Helpers
; ============================================================================

; page_lin: AX = page id -> EAX = flat base of that page
page_lin:
                sub     ax, 0A000h
                shr     ax, 10
                and     eax, 3
                imul    eax, eax, PAGE_SIZE
                add     eax, [cs:lfb]
                ret

; pix_addr: AX = page id, BX = row (signed), DX = x (signed) -> EDI flat
; clobbers EAX
pix_addr:
                call    page_lin
                mov     edi, eax
                movsx   eax, bx
                add     eax, [cs:org_y]
                imul    eax, eax, PITCH
                add     edi, eax
                movsx   eax, dx
                add     eax, [cs:org_x]
                add     edi, eax
                ret

; far_lin: DX:AX = seg:off -> EAX flat linear address (clobbers EDX)
far_lin:
                movzx   edx, dx
                shl     edx, 4
                movzx   eax, ax
                add     eax, edx
                ret

%macro FLAT_FS 0
                push    word 0
                pop     fs
%endmacro

; ============================================================================
; slot 1 -- glyph row blit.
; ES:SI = glyph rows (1 byte/row), BX = width (<=8), CX = rows, DX = x, BP = y.
; ============================================================================
s_glyph_row:
                push    di
                push    bp
                push    ds
                push    es
                push    fs
                FLAT_FS
                mov     [cs:gl_w], bx
                mov     [cs:gl_h], cx
                mov     ds, [cs:dseg]
                mov     al, [GC_FG]
                mov     [cs:gl_fg], al
                mov     al, [GC_BG]
                mov     [cs:gl_bg], al
                mov     al, [GC_STYLE]
                mov     [cs:gl_style], al
                mov     ax, [GC_DST]
                mov     bx, bp
                call    pix_addr
                mov     ax, es
                mov     ds, ax
                cld
.row:
                lodsb
                mov     ah, al
                mov     cx, [cs:gl_w]
                push    edi
.bit:
                shl     ah, 1
                jnc     .zero
                mov     al, [cs:gl_fg]
                mov     [fs:edi], al
                jmp     short .next
.zero:
                cmp     byte [cs:gl_style], 0
                jne     .next
                mov     al, [cs:gl_bg]
                mov     [fs:edi], al
.next:
                inc     edi
                loop    .bit
                pop     edi
                add     edi, PITCH
                dec     word [cs:gl_h]
                jnz     .row
                pop     fs
                pop     es
                pop     ds
                pop     bp
                pop     di
                retf

gl_w            dw      0
gl_h            dw      0
gl_fg           db      0
gl_bg           db      0
gl_style        db      0
                db      0

; ============================================================================
; slot 2 -- line. BX=x0, CX=y0, DX=x1, SI=y1, ES = page; colour = outline.
; ============================================================================
s_draw_line:
                push    bp
                push    si
                push    di
                push    ds
                push    fs
                FLAT_FS
                mov     ds, [cs:dseg]
                mov     al, [GC_OUTLINE]
                mov     [cs:ln_col], al
                mov     [cs:ln_x1], dx
                mov     [cs:ln_y1], si
                mov     [cs:ln_x0], bx
                mov     [cs:ln_y0], cx
                ; dx = |x1-x0|, sx
                mov     ax, dx
                sub     ax, bx
                mov     word [cs:ln_sx], 1
                jge     .dxpos
                neg     ax
                mov     word [cs:ln_sx], -1
.dxpos:         mov     [cs:ln_dx], ax
                mov     ax, si
                sub     ax, cx
                mov     word [cs:ln_sy], PITCH
                jge     .dypos
                neg     ax
                mov     word [cs:ln_sy], -PITCH
.dypos:         mov     [cs:ln_dy], ax
                mov     ax, es
                mov     dx, bx
                mov     bx, cx
                call    pix_addr
                movsx   ebx, word [cs:ln_sx]
                movsx   ebp, word [cs:ln_sy]
                mov     al, [cs:ln_col]
                mov     cx, [cs:ln_dx]
                cmp     cx, [cs:ln_dy]
                jl      .ymajor
                ; x-major: cx+1 pixels, err = dx/2
                mov     si, cx
                shr     si, 1
                inc     cx
.xl:            mov     [fs:edi], al
                add     edi, ebx
                sub     si, [cs:ln_dy]
                jge     .xn
                add     edi, ebp
                add     si, [cs:ln_dx]
.xn:            loop    .xl
                jmp     short .done
.ymajor:
                mov     cx, [cs:ln_dy]
                mov     si, cx
                shr     si, 1
                inc     cx
.yl:            mov     [fs:edi], al
                add     edi, ebp
                sub     si, [cs:ln_dx]
                jge     .yn
                add     edi, ebx
                add     si, [cs:ln_dy]
.yn:            loop    .yl
.done:
                pop     fs
                pop     ds
                pop     di
                pop     si
                pop     bp
                retf

ln_col          db      0, 0
ln_x0           dw      0
ln_y0           dw      0
ln_x1           dw      0
ln_y1           dw      0
ln_dx           dw      0
ln_dy           dw      0
ln_sx           dw      0
ln_sy           dw      0

; ============================================================================
; Rect copy between flat addresses.
;   ESI = src flat, EDI = dst flat, CX = width, DX = rows,
;   EAX = src stride, EBX = dst stride
; ============================================================================
copy_rows:
                push    es
                push    ds
                push    word 0
                pop     es
                push    word 0
                pop     ds
                cld
                or      cx, cx
                jle     .out
                or      dx, dx
                jle     .out
.row:
                push    esi
                push    edi
                push    cx
                movzx   ecx, cx
                a32 rep movsb
                pop     cx
                pop     edi
                pop     esi
                add     esi, eax
                add     edi, ebx
                dec     dx
                jnz     .row
.out:
                pop     ds
                pop     es
                ret

; ============================================================================
; slot 4 -- present(x, y, w, h): SrcPage -> DstPage.
; ============================================================================
s_present:
                push    bp
                mov     bp, sp
                push    si
                push    di
                push    ds
                mov     ds, [cs:dseg]
                cmp     word [bp+6], 0
                jne     .rect
                cmp     word [bp+8], 0
                jne     .rect
                cmp     word [bp+0Ah], 320
                jne     .rect
                cmp     word [bp+0Ch], 200
                jne     .rect
                push    word [GC_DST]
                push    word [GC_SRC]
                push    cs
                call    s_copy_page
                add     sp, 4
                jmp     short .done
.rect:
                mov     ax, [GC_SRC]
                mov     bx, [bp+8]
                mov     dx, [bp+6]
                call    pix_addr
                mov     esi, edi
                mov     ax, [GC_DST]
                mov     bx, [bp+8]
                mov     dx, [bp+6]
                call    pix_addr
                mov     cx, [bp+0Ah]
                mov     dx, [bp+0Ch]
                mov     eax, PITCH
                mov     ebx, PITCH
                call    copy_rows
.done:
                pop     ds
                pop     di
                pop     si
                pop     bp
                retf

; ============================================================================
; slot 41 (new) -- copy_rect(src_page, dst_page, x, y, w, h)
; ============================================================================
s_copy_rect:
                push    bp
                mov     bp, sp
                push    si
                push    di
                mov     ax, [bp+6]
                mov     bx, [bp+0Ch]
                mov     dx, [bp+0Ah]
                call    pix_addr
                mov     esi, edi
                mov     ax, [bp+8]
                mov     bx, [bp+0Ch]
                mov     dx, [bp+0Ah]
                call    pix_addr
                mov     cx, [bp+0Eh]
                mov     dx, [bp+10h]
                mov     eax, PITCH
                mov     ebx, PITCH
                call    copy_rows
                pop     di
                pop     si
                pop     bp
                retf

; ============================================================================
; slot 46 (new) -- flat_addr_org(page, x, y, org_x, org_y) -> DX:AX
; ============================================================================
s_flat_addr_org:
                push    bp
                mov     bp, sp
                push    di
                mov     ax, [bp+6]
                call    page_lin
                mov     edi, eax
                movsx   eax, word [bp+0Ah]
                movsx   edx, word [bp+0Eh]
                add     eax, edx
                imul    eax, eax, PITCH
                add     edi, eax
                movsx   eax, word [bp+8]
                movsx   edx, word [bp+0Ch]
                add     eax, edx
                add     edi, eax
                mov     ax, di
                shr     edi, 16
                mov     dx, di
                pop     di
                pop     bp
                retf

; ============================================================================
; slot 45 (new) -- copy_page(src_page, dst_page): the whole 640x480 page
; ============================================================================
s_copy_page:
                push    bp
                mov     bp, sp
                push    si
                push    di
                push    ds
                push    es
                mov     ax, [bp+6]
                call    page_lin
                mov     esi, eax
                mov     ax, [bp+8]
                call    page_lin
                mov     edi, eax
                push    word 0
                pop     ds
                push    word 0
                pop     es
                cld
                mov     ecx, PAGE_SIZE/4
                a32 rep movsd
                pop     es
                pop     ds
                pop     di
                pop     si
                pop     bp
                retf

; ============================================================================
; slot 42 (new) -- set_origin(x, y)
; ============================================================================
s_set_origin:
                push    bp
                mov     bp, sp
                movsx   eax, word [bp+6]
                mov     [cs:org_x], eax
                movsx   eax, word [bp+8]
                mov     [cs:org_y], eax
                pop     bp
                retf

; ============================================================================
; slot 44 (new) -- fill_rect(x, y, w, h, colour) on DstPage
; ============================================================================
s_fill_rect:
                push    bp
                mov     bp, sp
                push    di
                push    ds
                push    es
                mov     ds, [cs:dseg]
                mov     ax, [GC_DST]
                mov     bx, [bp+8]
                mov     dx, [bp+6]
                call    pix_addr
                push    word 0
                pop     es
                cld
                mov     al, [bp+0Eh]
                mov     dx, [bp+0Ch]
                mov     cx, [bp+0Ah]
                or      cx, cx
                jle     .out
.row:           or      dx, dx
                jle     .out
                push    edi
                movzx   ecx, word [bp+0Ah]
                a32 rep stosb
                pop     edi
                add     edi, PITCH
                dec     dx
                jmp     short .row
.out:
                pop     es
                pop     ds
                pop     di
                pop     bp
                retf

; ============================================================================
; slot 43 (new) -- flat_addr(page, x, y) -> DX:AX = flat linear address
; ============================================================================
s_flat_addr:
                push    bp
                mov     bp, sp
                push    di
                mov     ax, [bp+6]
                mov     dx, [bp+8]
                mov     bx, [bp+0Ah]
                call    pix_addr
                mov     ax, di
                shr     edi, 16
                mov     dx, di
                pop     di
                pop     bp
                retf

; ============================================================================
; slot 5 -- save_rect(buf_off, buf_seg, x, y, w, h): SrcPage -> buffer
; ============================================================================
s_save_rect:
                push    bp
                mov     bp, sp
                push    si
                push    di
                push    ds
                mov     ds, [cs:dseg]
                mov     ax, [GC_SRC]
                mov     bx, [bp+0Ch]
                mov     dx, [bp+0Ah]
                call    pix_addr
                mov     esi, edi
                mov     ax, [bp+6]
                mov     dx, [bp+8]
                call    far_lin
                mov     edi, eax
                mov     cx, [bp+0Eh]
                mov     dx, [bp+10h]
                mov     eax, PITCH
                movzx   ebx, cx
                call    copy_rows
                pop     ds
                pop     di
                pop     si
                pop     bp
                retf

; ============================================================================
; slot 7 -- paste_rect(buf_off, buf_seg, x, y, w, h): buffer -> DstPage
; ============================================================================
s_paste_rect:
                push    bp
                mov     bp, sp
                push    si
                push    di
                push    ds
                mov     ds, [cs:dseg]
                mov     ax, [GC_DST]
                mov     bx, [bp+0Ch]
                mov     dx, [bp+0Ah]
                call    pix_addr
                mov     ax, [bp+6]
                mov     dx, [bp+8]
                call    far_lin
                mov     esi, eax
                mov     cx, [bp+0Eh]
                mov     dx, [bp+10h]
                movzx   eax, cx
                mov     ebx, PITCH
                call    copy_rows
                pop     ds
                pop     di
                pop     si
                pop     bp
                retf

; ============================================================================
; slot 6 -- rect byte size (w, h) -> DX:AX
; ============================================================================
s_rect_size:
                push    bp
                mov     bp, sp
                mov     ax, [bp+6]
                cwd
                mul     word [bp+8]
                pop     bp
                retf

; ============================================================================
; slot 8 -- flip(wait): swap front/back page IDs and show the new front.
; ============================================================================
s_flip:
                push    bp
                mov     bp, sp
                push    ds
                push    si
                push    di
                mov     ds, [cs:dseg]
                mov     ax, [GC_PAGE2]
                xchg    ax, [GC_FRONT]
                mov     [GC_PAGE2], ax
                ; Set the new display start first, then wait for the retrace
                ; that latches it: only after that is the old front page off
                ; screen and safe to draw into. Always wait (the game starts
                ; drawing into the old front as soon as this returns).
                mov     ax, [GC_FRONT]
                sub     ax, 0A000h
                shr     ax, 10
                and     ax, 3
                mov     dx, SCR_H
                mul     dx
                mov     dx, ax
                xor     cx, cx
                xor     bx, bx
                mov     ax, 4F07h
                int     10h
                ; Bounded: under DOSBox the retrace bit can stop toggling
                ; (seen during palette fades); never hang on it.
                mov     dx, 3DAh
                mov     ecx, RETRACE_SPIN
.w1:            in      al, dx
                test    al, 8
                jz      .w1done
                dec     ecx
                jnz     .w1
.w1done:
                mov     ecx, RETRACE_SPIN
.w2:            in      al, dx
                test    al, 8
                jnz     .w2done
                dec     ecx
                jnz     .w2
.w2done:
                pop     di
                pop     si
                pop     ds
                pop     bp
                retf

; ============================================================================
; slot 10 -- solid run. AL colour, AH !=0 -> dither (slot 11), BX x, CX count,
; DI row, ES page.
; ============================================================================
s_fill_run_a:
                or      cx, cx
                jle     .out
                or      ah, ah
                jnz     s_fill_run_b
                push    di
                push    fs
                FLAT_FS
                push    ax
                mov     ax, es
                mov     dx, bx
                mov     bx, di
                call    pix_addr
                pop     ax
.l:             mov     [fs:edi], al
                inc     edi
                loop    .l
                pop     fs
                pop     di
.out:           retf

; ============================================================================
; slot 11 -- dithered run. AL/AH colour pair, DX bit0 swap, BX x, CX count,
; DI row, ES page. Even x -> AH, odd x -> AL.
; ============================================================================
s_fill_run_b:
                or      cx, cx
                jle     .out
                test    dx, 1
                jz      .ns
                xchg    al, ah
.ns:
                push    di
                push    fs
                FLAT_FS
                push    ax
                test    bx, 1
                jz      .even
                xchg    al, ah
.even:
                mov     [cs:dith], ax
                mov     ax, es
                mov     dx, bx
                mov     bx, di
                call    pix_addr
                pop     ax
                mov     ax, [cs:dith]
.l:             mov     [fs:edi], ah
                inc     edi
                xchg    al, ah
                loop    .l
                pop     fs
                pop     di
.out:           retf

dith            dw      0

; ============================================================================
; slot 27 -- span fill. ES:SI = { y0, count, (x0, x1 inclusive)* }.
; Colour fill/dither from ctx; dst = ctx DstPage. Dither = checkerboard.
; ============================================================================
s_span_fill:
                push    bp
                push    si
                push    di
                push    ds
                push    fs
                FLAT_FS
                mov     ds, [cs:dseg]
                mov     al, [GC_FILL_COLOR]
                mov     ah, [GC_DITHER]
                mov     [cs:sf_col], ax
                mov     ax, [GC_DST]
                mov     [cs:sf_page], ax
                mov     ax, es
                mov     ds, ax
                cld
                lodsw
                mov     [cs:sf_y], ax
                lodsw
                mov     [cs:sf_n], ax
                or      ax, ax
                jle     .done
.row:
                lodsw
                mov     dx, ax
                lodsw
                mov     cx, ax
                sub     cx, dx
                jl      .next
                inc     cx
                push    dx
                mov     ax, [cs:sf_page]
                mov     bx, [cs:sf_y]
                call    pix_addr
                pop     dx
                mov     ax, [cs:sf_col]
                or      ah, ah
                jz      .solid
                add     dx, [cs:sf_y]
                test    dx, 1
                jz      .dl
                xchg    al, ah
.dl:            mov     [fs:edi], al
                inc     edi
                xchg    al, ah
                loop    .dl
                jmp     short .next
.solid:         mov     [fs:edi], al
                inc     edi
                loop    .solid
.next:
                inc     word [cs:sf_y]
                dec     word [cs:sf_n]
                jnz     .row
.done:
                pop     fs
                pop     ds
                pop     di
                pop     si
                pop     bp
                retf

sf_col          dw      0
sf_page         dw      0
sf_y            dw      0
sf_n            dw      0

; ============================================================================
; slot 39 -- remap spans. ES:SI = { y0, count, (x0, x1 exclusive)* };
; dst[x] = LUT[dst[x]], LUT at SS:[ctx.wTextureIdx]. dst = ctx DstPage.
; ============================================================================
s_remap_spans:
                push    bp
                push    si
                push    di
                push    ds
                push    fs
                FLAT_FS
                mov     ds, [cs:dseg]
                mov     ax, [GC_DST]
                mov     [cs:sf_page], ax
                mov     bp, [GC_TEXIDX]
                mov     ax, es
                mov     ds, ax
                cld
                lodsw
                mov     [cs:sf_y], ax
                lodsw
                mov     [cs:sf_n], ax
                or      ax, ax
                jle     .done
.row:
                lodsw
                mov     dx, ax
                lodsw
                mov     cx, ax
                sub     cx, dx
                jle     .next
                push    dx
                mov     ax, [cs:sf_page]
                mov     bx, [cs:sf_y]
                call    pix_addr
                pop     dx
                movzx   ebp, bp
.px:            movzx   ebx, byte [fs:edi]
                mov     al, [ss:ebp+ebx]
                mov     [fs:edi], al
                inc     edi
                loop    .px
.next:
                inc     word [cs:sf_y]
                dec     word [cs:sf_n]
                jnz     .row
.done:
                pop     fs
                pop     ds
                pop     di
                pop     si
                pop     bp
                retf

; ============================================================================
; slot 23 -- rect-buffer copy. ES:SI = { y0, count, (x0, x1 inclusive)* };
; dst(x,y) on DstPage = src(x+bx_ofs, y+by_ofs) on SrcPage.
; ============================================================================
s_rect_buffer:
                push    bp
                push    si
                push    di
                push    ds
                mov     ds, [cs:dseg]
                mov     ax, [GC_DST]
                mov     [cs:sf_page], ax
                mov     ax, [GC_SRC]
                mov     [cs:rb_src], ax
                mov     ax, es
                mov     ds, ax
                cld
                lodsw
                mov     [cs:sf_y], ax
                lodsw
                mov     [cs:sf_n], ax
                or      ax, ax
                jle     .done
.row:
                lodsw
                mov     dx, ax
                lodsw
                mov     cx, ax
                sub     cx, dx
                jl      .next
                inc     cx
                push    cx
                push    dx
                mov     ax, [cs:sf_page]
                mov     bx, [cs:sf_y]
                call    pix_addr
                pop     dx
                push    edi
                add     dx, [cs:rb_ox]
                mov     bx, [cs:sf_y]
                add     bx, [cs:rb_oy]
                mov     ax, [cs:rb_src]
                call    pix_addr
                mov     esi, edi
                pop     edi
                pop     cx
                push    si
                mov     dx, 1
                xor     eax, eax
                xor     ebx, ebx
                call    copy_rows
                pop     si
.next:
                inc     word [cs:sf_y]
                dec     word [cs:sf_n]
                jnz     .row
.done:
                pop     ds
                pop     di
                pop     si
                pop     bp
                retf

rb_src          dw      0
rb_ox           dw      0
rb_oy           dw      0

; slot 24 -- set_buffer_offset(x, y)
s_set_buffer_ofs:
                push    bp
                mov     bp, sp
                mov     ax, [bp+6]
                mov     [cs:rb_ox], ax
                mov     ax, [bp+8]
                mov     [cs:rb_oy], ax
                pop     bp
                retf

; ============================================================================
; slot 21 -- getpixel(x, y) from SrcPage; slot 22 -- putpixel(x, y, c) to Dst
; ============================================================================
s_getpixel:
                push    bp
                mov     bp, sp
                push    di
                push    ds
                push    fs
                FLAT_FS
                mov     ds, [cs:dseg]
                mov     ax, [GC_SRC]
                mov     bx, [bp+8]
                mov     dx, [bp+6]
                call    pix_addr
                movzx   ax, byte [fs:edi]
                pop     fs
                pop     ds
                pop     di
                pop     bp
                retf

s_putpixel:
                push    bp
                mov     bp, sp
                push    di
                push    ds
                push    fs
                FLAT_FS
                mov     ds, [cs:dseg]
                mov     ax, [GC_DST]
                mov     bx, [bp+8]
                mov     dx, [bp+6]
                call    pix_addr
                mov     al, [bp+0Ah]
                mov     [fs:edi], al
                pop     fs
                pop     ds
                pop     di
                pop     bp
                retf

; ============================================================================
; Sprite blit core. Record (10 bytes, near ptr in caller DS):
;   +0 src seg, +2 src off, +4 ?, +6 width, +8 height. Pixel 0 = transparent.
; sp_blit: [cs:sp_*] set up; flags bit0 = V flip, bit1 = H flip.
; ============================================================================
s_blit_sprite:
                push    bp
                mov     bp, sp
                xor     ax, ax
                push    ax
                push    word [bp+0Ah]
                push    word [bp+8]
                push    word [bp+6]
                push    cs
                call    s_sprite_master
                add     sp, 8
                pop     bp
                retf

s_sprite_simple:
                push    bp
                mov     bp, sp
                xor     ax, ax
                push    ax
                push    word [bp+0Ah]
                push    word [bp+8]
                push    word [bp+6]
                push    cs
                call    s_sprite_master
                add     sp, 8
                pop     bp
                retf

; slot 29 -- sprite_master(rec, x, y, flags)
s_sprite_master:
                push    bp
                mov     bp, sp
                push    si
                push    di
                push    ds
                push    es
                push    fs
                FLAT_FS
                mov     si, [bp+6]
                mov     ax, [si]
                mov     [cs:sp_seg], ax
                mov     ax, [si+2]
                mov     [cs:sp_off], ax
                mov     ax, [si+6]
                mov     [cs:sp_w], ax
                mov     ax, [si+8]
                mov     [cs:sp_h], ax
                mov     ax, [bp+8]
                mov     [cs:sp_x], ax
                mov     ax, [bp+0Ah]
                mov     [cs:sp_y], ax
                mov     ax, [bp+0Ch]
                mov     [cs:sp_flags], ax
                call    sprite_draw
                pop     fs
                pop     es
                pop     ds
                pop     di
                pop     si
                pop     bp
                retf

; sprite_draw: uses cs:sp_* ; dst = ctx DstPage; clip if ctx clip enabled
sprite_draw:
                mov     ds, [cs:dseg]
                ; visible column range [c0, c1), row range [r0, r1)
                mov     word [cs:sp_c0], 0
                mov     ax, [cs:sp_w]
                mov     [cs:sp_c1], ax
                mov     word [cs:sp_r0], 0
                mov     ax, [cs:sp_h]
                mov     [cs:sp_r1], ax
                cmp     byte [GC_CLIP_EN], 0
                je      .noclip
                ; left
                mov     ax, [GC_CLIP_X0]
                sub     ax, [cs:sp_x]
                jle     .cl1
                mov     [cs:sp_c0], ax
.cl1:           mov     ax, [GC_CLIP_X1]
                sub     ax, [cs:sp_x]
                inc     ax
                cmp     ax, [cs:sp_c1]
                jge     .cl2
                mov     [cs:sp_c1], ax
.cl2:           mov     ax, [GC_CLIP_Y0]
                sub     ax, [cs:sp_y]
                jle     .cl3
                mov     [cs:sp_r0], ax
.cl3:           mov     ax, [GC_CLIP_Y1]
                sub     ax, [cs:sp_y]
                inc     ax
                cmp     ax, [cs:sp_r1]
                jge     .noclip
                mov     [cs:sp_r1], ax
.noclip:
                ; hard clip to the physical screen
                mov     ax, [cs:org_x]
                neg     ax
                sub     ax, [cs:sp_x]
                cmp     ax, [cs:sp_c0]
                jle     .pc1
                mov     [cs:sp_c0], ax
.pc1:           mov     ax, SCR_W
                sub     ax, [cs:org_x]
                sub     ax, [cs:sp_x]
                cmp     ax, [cs:sp_c1]
                jge     .pc2
                mov     [cs:sp_c1], ax
.pc2:           mov     ax, [cs:org_y]
                neg     ax
                sub     ax, [cs:sp_y]
                cmp     ax, [cs:sp_r0]
                jle     .pc3
                mov     [cs:sp_r0], ax
.pc3:           mov     ax, SCR_H
                sub     ax, [cs:org_y]
                sub     ax, [cs:sp_y]
                cmp     ax, [cs:sp_r1]
                jge     .pc4
                mov     [cs:sp_r1], ax
.pc4:
                mov     ax, [cs:sp_c0]
                cmp     ax, [cs:sp_c1]
                jge     .out
                mov     ax, [cs:sp_r0]
                cmp     ax, [cs:sp_r1]
                jge     .out
                mov     ax, [GC_DST]
                mov     [cs:sp_page], ax
                ; src flat base
                mov     ax, [cs:sp_off]
                mov     dx, [cs:sp_seg]
                call    far_lin
                mov     [cs:sp_src], eax
                mov     bx, [cs:sp_r0]
.row:
                ; source row
                mov     ax, bx
                test    byte [cs:sp_flags], 1
                jz      .nv
                mov     ax, [cs:sp_h]
                dec     ax
                sub     ax, bx
.nv:            movzx   eax, ax
                movzx   ecx, word [cs:sp_w]
                imul    eax, ecx
                add     eax, [cs:sp_src]
                mov     esi, eax
                ; dst row address at column c0
                push    bx
                mov     ax, [cs:sp_page]
                add     bx, [cs:sp_y]
                mov     dx, [cs:sp_x]
                add     dx, [cs:sp_c0]
                call    pix_addr
                pop     bx
                mov     cx, [cs:sp_c1]
                sub     cx, [cs:sp_c0]
                test    byte [cs:sp_flags], 2
                jnz     .hflip
                movzx   eax, word [cs:sp_c0]
                add     esi, eax
.px:            mov     al, [fs:esi]
                inc     esi
                or      al, al
                jz      .s1
                mov     [fs:edi], al
.s1:            inc     edi
                loop    .px
                jmp     short .rnext
.hflip:
                movzx   eax, word [cs:sp_w]
                dec     eax
                movzx   edx, word [cs:sp_c0]
                sub     eax, edx
                add     esi, eax
.pxh:           mov     al, [fs:esi]
                dec     esi
                or      al, al
                jz      .s2
                mov     [fs:edi], al
.s2:            inc     edi
                loop    .pxh
.rnext:
                inc     bx
                cmp     bx, [cs:sp_r1]
                jl      .row
.out:
                ret

                align   4
sp_src          dd      0
sp_seg          dw      0
sp_off          dw      0
sp_w            dw      0
sp_h            dw      0
sp_x            dw      0
sp_y            dw      0
sp_flags        dw      0
sp_c0           dw      0
sp_c1           dw      0
sp_r0           dw      0
sp_r1           dw      0
sp_page         dw      0

; ============================================================================
; slot 30 -- opaque rect blit(rec, x, y): rec = {seg, off, ?, w, h} -> Dst
; ============================================================================
s_rect_blit:
                push    bp
                mov     bp, sp
                push    si
                push    di
                push    ds
                mov     ds, [cs:dseg]
                mov     ax, [GC_DST]
                mov     bx, [bp+0Ah]
                mov     dx, [bp+8]
                call    pix_addr
                pop     ds
                push    ds
                mov     si, [bp+6]
                mov     ax, [si+2]
                mov     dx, [si]
                push    word [si+6]
                push    word [si+8]
                call    far_lin
                mov     esi, eax
                pop     dx
                pop     cx
                movzx   eax, cx
                mov     ebx, PITCH
                call    copy_rows
                pop     ds
                pop     di
                pop     si
                pop     bp
                retf

; ============================================================================
; slot 36 -- indexed span. DX = x (signed; left-clipped), CX = count,
; DI = row, ES = page. Stack: [bp+6] = near ptr (SS) to {seg, off},
; [bp+8] = row base, [bp+0A] = column table (SS words).
; dst[x+i] = src[base + table[i]] unless 0.
; slot 40 -- same, but the source byte goes through the LUT at
; SS:[ctx.wTextureIdx] first (skip if the result is 0).
; ============================================================================
s_rot_span:
                mov     byte [cs:is_lut], 0
                jmp     short idx_span
s_tex_span:
                mov     byte [cs:is_lut], 1
idx_span:
                push    bp
                mov     bp, sp
                push    si
                push    di
                push    ds
                push    fs
                FLAT_FS
                or      dx, dx
                jns     .nonneg
                neg     dx
                sub     cx, dx
                jle     .out
                shl     dx, 1
                add     [bp+0Ah], dx
                xor     dx, dx
.nonneg:
                or      cx, cx
                jle     .out
                push    cx
                mov     ax, es
                mov     bx, di
                call    pix_addr
                pop     cx
                push    ds
                mov     ds, [cs:dseg]
                mov     ax, [GC_TEXIDX]
                mov     [cs:is_lutbase], ax
                pop     ds
                mov     bx, [bp+6]
                mov     ax, [ss:bx+2]
                add     ax, [bp+8]
                mov     [cs:is_base], ax
                mov     ds, [ss:bx]
                mov     bp, [bp+0Ah]
.px:
                mov     si, [ss:bp]
                add     bp, 2
                add     si, [cs:is_base]
                mov     al, [si]
                cmp     byte [cs:is_lut], 0
                je      .nolut
                movzx   bx, al
                add     bx, [cs:is_lutbase]
                mov     al, [ss:bx]
.nolut:
                or      al, al
                jz      .skip
                mov     [fs:edi], al
.skip:          inc     edi
                loop    .px
.out:
                pop     fs
                pop     ds
                pop     di
                pop     si
                pop     bp
                retf

is_lut          db      0, 0
is_base         dw      0
is_lutbase      dw      0

; ============================================================================
; slot 37 -- stretched span. DI = row, DX = x, CX = count, ES = page,
; DS:SI = source row base, BP = column table (SS words).
; slot 19 -- same with the LUT translate after the zero test.
; ============================================================================
s_stretch_span:
                mov     byte [cs:is_lut], 0
                jmp     short str_span
s_tex_span_b:
                mov     byte [cs:is_lut], 2
str_span:
                push    bp
                push    si
                push    di
                push    fs
                FLAT_FS
                or      cx, cx
                jle     .out
                push    cx
                push    ds
                mov     ds, [cs:dseg]
                mov     ax, [GC_TEXIDX]
                mov     [cs:is_lutbase], ax
                mov     ax, es
                mov     bx, di
                call    pix_addr
                pop     ds
                pop     cx
.px:
                mov     bx, [ss:bp]
                add     bp, 2
                mov     al, [bx+si]
                or      al, al
                jz      .skip
                cmp     byte [cs:is_lut], 0
                je      .w
                movzx   bx, al
                add     bx, [cs:is_lutbase]
                mov     al, [ss:bx]
.w:             mov     [fs:edi], al
.skip:          inc     edi
                loop    .px
.out:
                pop     fs
                pop     di
                pop     si
                pop     bp
                retf

; ============================================================================
; slot 38 -- chunky span copy. CF = reverse. CX = count, BX = x, DS:SI = src,
; DI = row, ES = page. Forward: dst[x..] = src. Reverse: dst[x], dst[x-1]...
; ============================================================================
s_chunky_span:
                push    bp
                push    si
                push    di
                push    fs
                mov     bp, 1
                jnc     .fwd
                mov     bp, -1
.fwd:
                FLAT_FS
                push    cx
                mov     ax, es
                mov     dx, bx
                mov     bx, di
                call    pix_addr
                pop     cx
                movsx   ebp, bp
                or      cx, cx
                jle     .out
.l:             mov     al, [si]
                inc     si
                mov     [fs:edi], al
                add     edi, ebp
                loop    .l
.out:
                pop     fs
                pop     di
                pop     si
                pop     bp
                retf

; ============================================================================
; slot 17 / 18 -- 4bpp nibble rows -> pixels (overwrite / OR high nibbles).
; (src_off, src_seg, x, y, width_pixels, rows) -> DstPage
; ============================================================================
s_nibble_blit:
                mov     byte [cs:nb_or], 0
                jmp     short nibble_blit
s_nibble_blit_or:
                mov     byte [cs:nb_or], 1
nibble_blit:
                push    bp
                mov     bp, sp
                push    si
                push    di
                push    ds
                push    fs
                FLAT_FS
                mov     ax, [bp+6]
                mov     dx, [bp+8]
                call    far_lin
                mov     esi, eax
                mov     ds, [cs:dseg]
                mov     ax, [GC_DST]
                mov     [cs:sp_page], ax
                mov     bx, [bp+0Ch]
.row:
                cmp     word [bp+10h], 0
                je      .out
                push    bx
                mov     ax, [cs:sp_page]
                mov     dx, [bp+0Ah]
                call    pix_addr
                pop     bx
                mov     cx, [bp+0Eh]
                shr     cx, 1
                jz      .rnext
.px:            mov     al, [fs:esi]
                inc     esi
                mov     ah, al
                shr     al, 4
                and     ah, 0Fh
                cmp     byte [cs:nb_or], 0
                jne     .or
                mov     [fs:edi], al
                mov     [fs:edi+1], ah
                jmp     short .pn
.or:            shl     al, 4
                shl     ah, 4
                or      [fs:edi], al
                or      [fs:edi+1], ah
.pn:            add     edi, 2
                loop    .px
.rnext:
                inc     bx
                dec     word [bp+10h]
                jmp     short .row
.out:
                pop     fs
                pop     ds
                pop     di
                pop     si
                pop     bp
                retf

nb_or           db      0, 0

; ============================================================================
; slot 13 -- image list measure (array of near ptrs, out_ptr) -> DX:AX
; ============================================================================
s_image_measure:
                push    bp
                mov     bp, sp
                push    si
                push    di
                mov     di, [bp+6]
                xor     bx, bx
                xor     dx, dx
.l:             mov     si, [di]
                or      si, si
                jz      .d
                push    dx
                xor     dx, dx
                mov     ax, [si+6]
                mul     word [si+8]
                pop     dx
                add     bx, ax
                adc     dx, 0
                add     di, 2
                jmp     short .l
.d:             mov     ax, bx
                mov     si, [bp+8]
                mov     word [si], 0
                pop     di
                pop     si
                pop     bp
                retf

; ============================================================================
; slot 14 -- image records install (port of mcg_image_records_install)
; (record_array, base_off, base_seg, src_count_lo, src_count_hi)
; ============================================================================
s_image_install:
                push    bp
                mov     bp, sp
                push    si
                push    di
                push    ds
                mov     di, [bp+8]
                mov     es, [bp+0Ah]
.rec:
                mov     si, [bp+6]
                mov     si, [si]
                or      si, si
                jz      .pack
                mov     dx, di
                mov     ax, es
                mov     cl, 4
                shr     dx, cl
                add     ax, dx
                mov     [si], ax
                mov     dx, di
                and     dx, 0Fh
                mov     [si+2], dx
                mov     ax, [si+6]
                xor     dx, dx
                mul     word [si+8]
                xor     cx, cx
                add     di, ax
                rcr     cx, 1
                shr     cx, 1
                shr     cx, 1
                shr     cx, 1
                mov     ax, es
                add     ax, cx
                mov     es, ax
                add     word [bp+6], 2
                jmp     short .rec
.pack:
                mov     si, [bp+8]
                mov     ax, [bp+0Ah]
                xor     cx, cx
                add     si, [bp+0Ch]
                rcr     cx, 1
                shr     cx, 1
                shr     cx, 1
                shr     cx, 1
                mov     bh, [bp+0Eh]
                xor     bl, bl
                shl     bx, 1
                shl     bx, 1
                shl     bx, 1
                shl     bx, 1
                add     bx, cx
                sub     si, 1
                jnc     .p1
                sub     ax, 1000h
.p1:
                add     ax, bx
                mov     ds, ax
                mov     di, [bp+8]
                mov     ax, [bp+0Ah]
                mov     dx, [bp+0Ch]
                mov     bh, [bp+0Eh]
                xor     bl, bl
                shl     bx, 1
                shl     bx, 1
                shl     bx, 1
                shl     bx, 1
                shl     bx, 1
                xor     cx, cx
                sub     dx, 1
                jnc     .p2
                sub     dx, 1000h
.p2:
                shl     dx, 1
                jnc     .p3
                add     bx, 1000h
.p3:
                add     di, dx
                rcr     cx, 1
                shr     cx, 1
                shr     cx, 1
                shr     cx, 1
                add     bx, cx
                add     ax, bx
                mov     es, ax
.ploop:
                mov     al, [si]
                xor     cx, cx
                mov     bx, ds
                sub     si, 1
                rcr     cx, 1
                shr     cx, 1
                shr     cx, 1
                shr     cx, 1
                sub     bx, cx
                mov     ds, bx
                mov     ah, al
                mov     cl, 4
                shr     al, cl
                and     ax, 0F0Fh
                mov     [es:di], ax
                xor     cx, cx
                mov     bx, es
                sub     di, 2
                rcr     cx, 1
                shr     cx, 1
                shr     cx, 1
                shr     cx, 1
                sub     bx, cx
                mov     es, bx
                sub     word [bp+0Ch], 1
                sbb     word [bp+0Eh], 0
                mov     ax, [bp+0Ch]
                or      ax, [bp+0Eh]
                jnz     .ploop
                pop     ds
                pop     di
                pop     si
                pop     bp
                retf

; ============================================================================
; slot 15 -- OR high nibbles (port of mcg_image_pack_nibble_or)
; (src_off, src_seg, dst_off, dst_seg, count)
; ============================================================================
s_image_pack_or:
                push    bp
                mov     bp, sp
                push    si
                push    di
                push    ds
                mov     si, [bp+6]
                mov     ds, [bp+8]
                mov     di, [bp+0Ah]
                mov     es, [bp+0Ch]
                mov     cx, [bp+0Eh]
.l:
                xor     dx, dx
                mov     al, [si]
                add     si, 1
                rcr     dx, 1
                shr     dx, 1
                shr     dx, 1
                shr     dx, 1
                mov     bx, ds
                add     bx, dx
                mov     ds, bx
                mov     ah, al
                shl     ah, 1
                shl     ah, 1
                shl     ah, 1
                shl     ah, 1
                and     ax, 0F0F0h
                or      [es:di], ax
                xor     dx, dx
                add     di, 2
                rcr     dx, 1
                shr     dx, 1
                shr     dx, 1
                shr     dx, 1
                mov     bx, es
                add     bx, dx
                mov     es, bx
                loop    .l
                pop     ds
                pop     di
                pop     si
                pop     bp
                retf

; ============================================================================
; slot 35 -- DAC write (rgb_near_off, start, count) with vsync gate
; ============================================================================
s_dac_write:
                push    bp
                mov     bp, sp
                push    si
                push    di
                mov     si, [bp+6]
                mov     cx, [bp+0Ah]
                mov     ax, cx
                shl     cx, 1
                add     cx, ax
                mov     bx, [bp+8]
                mov     dx, 3DAh
                push    ecx
                mov     ecx, RETRACE_SPIN
.vs:            in      al, dx
                test    al, 8
                jnz     .vsdone
                dec     ecx
                jnz     .vs
.vsdone:        pop     ecx
                mov     dx, 3C8h
                mov     ax, bx
                out     dx, al
                mov     dx, 3C9h
                cli
                jcxz    .e
.st:            lodsb
                out     dx, al
                loop    .st
.e:             sti
                pop     di
                pop     si
                pop     bp
                retf

; ============================================================================
; slot 20 -- palette set (pal_off, pal_seg)
; ============================================================================
s_palette_set:
                push    bp
                mov     bp, sp
                push    di
                push    si
                push    ds
                mov     ds, [cs:dseg]
                mov     di, [GC_PALBUF]
                mov     es, [GC_PALBUF+2]
                mov     si, [bp+6]
                mov     ax, [bp+8]
                mov     ds, ax
                or      ax, ax
                jz      .x
                mov     ax, 100h
                push    ax
                xor     ax, ax
                push    ax
                push    si
                push    cs
                call    s_dac_write
                add     sp, 6
                cld
                mov     cx, 180h
                mov     ax, cx
                rep     movsw
                sub     si, ax
                sub     si, ax
                mov     cx, ax
                rep     movsw
.x:
                pop     ds
                pop     si
                pop     di
                pop     bp
                retf

; ============================================================================
; slot 34 -- palette lerp (start, count, dst_idx, weight) (port of MCG)
; ============================================================================
s_palette_lerp:
                push    bp
                mov     bp, sp
                push    ds
                push    di
                push    si
                mov     ds, [cs:dseg]
                mov     ax, [bp+8]
                push    ax
                mov     cx, ax
                shl     ax, 1
                add     cx, ax
                mov     dl, [bp+0Ch]
                mov     dh, 3Fh
                mov     ds, [GC_PALBUF+2]
                mov     ax, [bp+6]
                push    ax
                mov     di, ax
                shl     ax, 1
                add     di, ax
                push    di
                mov     si, di
                add     si, 300h
                mov     ax, [bp+0Ah]
                mov     bp, 300h
                add     bp, ax
                shl     ax, 1
                add     bp, ax
                push    ds
                pop     es
                xor     bx, bx
                cld
.l:
                xor     ah, ah
                lodsb
                mul     dl
                div     dh
                mov     bh, al
                mov     al, dl
                mov     dl, dh
                sub     dl, al
                xor     ah, ah
                mov     al, [ds:bp]
                mul     dl
                div     dh
                add     al, bh
                stosb
                mov     al, dl
                mov     dl, dh
                sub     dl, al
                inc     bp
                inc     bl
                cmp     bl, 3
                jne     .nw
                xor     bx, bx
                sub     bp, 3
.nw:            loop    .l
                push    cs
                call    s_dac_write
                add     sp, 6
                pop     si
                pop     di
                pop     ds
                pop     bp
                retf

                align   4
modeinfo:       times   256 db 0
                align   8
unreal_gdt:     dq      0
                dw      0FFFFh, 0
                db      0, 92h, 0CFh, 0
unreal_gdtr:    dw      15
                dd      0
