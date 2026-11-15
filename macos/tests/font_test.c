/*
 * Checks that Wine has TrueType fonts, which it only has when it finds the FreeType library at
 * run time. Asks for Tahoma, which Wine ships, draws a word into a bitmap and counts the fonts
 * the system lists.
 *
 * Prints one line, e.g.
 *   font: face Tahoma, truetype 1, outline 1, drawn pixels 412, truetype families 187
 * and exits 0 when the font is the TrueType Tahoma, a glyph outline can be had and the word
 * left pixels in the bitmap.
 *
 * Built for aarch64, ARM64EC or x86_64; it only uses kernel32, user32 and gdi32.
 */
#include <stdio.h>
#include <string.h>
#include <windows.h>

static int truetype_families;

static int CALLBACK enum_proc( const LOGFONTA *lf, const TEXTMETRICA *tm, DWORD type, LPARAM lparam )
{
    if (type & TRUETYPE_FONTTYPE) truetype_families++;
    return 1;
}

int main(void)
{
    static const MAT2 identity = { { 0, 1 }, { 0, 0 }, { 0, 0 }, { 0, 1 } };
    BITMAPINFO bmi = { { sizeof(BITMAPINFOHEADER), 256, -64, 1, 32, BI_RGB } };
    LOGFONTA all = { 0 };
    TEXTMETRICA tm = { 0 };
    GLYPHMETRICS gm;
    char face[LF_FACESIZE] = "";
    DWORD *bits = NULL, outline;
    HBITMAP bitmap;
    HFONT font;
    HDC dc;
    int i, drawn = 0, ok;

    dc = CreateCompatibleDC( 0 );
    bitmap = CreateDIBSection( dc, &bmi, DIB_RGB_COLORS, (void **)&bits, NULL, 0 );
    SelectObject( dc, bitmap );
    memset( bits, 0xff, 256 * 64 * 4 );

    font = CreateFontA( 40, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, DEFAULT_CHARSET, OUT_TT_ONLY_PRECIS,
                        CLIP_DEFAULT_PRECIS, ANTIALIASED_QUALITY, DEFAULT_PITCH, "Tahoma" );
    SelectObject( dc, font );
    GetTextFaceA( dc, sizeof(face), face );
    GetTextMetricsA( dc, &tm );
    outline = GetGlyphOutlineA( dc, 'W', GGO_METRICS, &gm, 0, NULL, &identity );

    SetBkMode( dc, TRANSPARENT );
    SetTextColor( dc, RGB( 0, 0, 0 ) );
    TextOutA( dc, 4, 4, "Wine", 4 );
    GdiFlush();
    for (i = 0; i < 256 * 64; i++) if ((bits[i] & 0xffffff) != 0xffffff) drawn++;

    all.lfCharSet = DEFAULT_CHARSET;
    EnumFontFamiliesExA( dc, &all, enum_proc, 0, 0 );

    ok = !strcmp( face, "Tahoma" ) && (tm.tmPitchAndFamily & TMPF_TRUETYPE) && outline != GDI_ERROR && drawn > 0;
    printf( "font: face %s, truetype %d, outline %d, drawn pixels %d, truetype families %d\n",
            face, (tm.tmPitchAndFamily & TMPF_TRUETYPE) != 0, outline != GDI_ERROR, drawn, truetype_families );
    return ok ? 0 : 1;
}
