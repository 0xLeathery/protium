/* Which of the families that Windows programs take for granted DirectWrite's system font
 * collection has. Prints "dwrite: <n> families; Tahoma 1, Arial 1, ..." and exits 0 when it has
 * all of them. */
#define COBJMACROS
#define INITGUID
#include <windows.h>
#include <dwrite.h>
#include <stdio.h>

/* b859ee5a-d838-4b5b-a2e8-1adc7d93db48, which the mingw import libraries do not carry */
DEFINE_GUID(IID_IDWriteFactory_, 0xb859ee5a, 0xd838, 0x4b5b, 0xa2, 0xe8, 0x1a, 0xdc, 0x7d, 0x93, 0xdb, 0x48);

int main(void)
{
    static const WCHAR *names[] = { L"Tahoma", L"Arial", L"Times New Roman", L"Courier New", L"Microsoft Sans Serif" };
    IDWriteFontCollection *collection;
    IDWriteFactory *factory;
    unsigned int i, missing = 0;

    if (FAILED(DWriteCreateFactory( DWRITE_FACTORY_TYPE_SHARED, &IID_IDWriteFactory_, (IUnknown **)&factory )) ||
        FAILED(IDWriteFactory_GetSystemFontCollection( factory, &collection, FALSE )))
    {
        printf( "dwrite: no system font collection\n" );
        return 2;
    }
    printf( "dwrite: %u families;", (unsigned int)IDWriteFontCollection_GetFontFamilyCount( collection ) );
    for (i = 0; i < sizeof(names) / sizeof(names[0]); i++)
    {
        BOOL exists = FALSE;
        UINT32 index;

        IDWriteFontCollection_FindFamilyName( collection, names[i], &index, &exists );
        printf( "%s %ls %d", i ? "," : "", names[i], exists );
        if (!exists) missing++;
    }
    printf( "\n" );
    return missing ? 1 : 0;
}
