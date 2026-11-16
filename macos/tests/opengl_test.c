/*
 * Creates an OpenGL context through WGL, clears and reads the colour back:
 *
 *   opengl_test.exe
 *
 * It draws into a framebuffer object, and the window is never shown, so no Mac window appears.
 * Prints one line, e.g.
 *   opengl: renderer "Apple M4 Pro", version "2.1 ...", pixel 3366cc
 * or the step that failed, and exits 0 when the pixel read back as the colour it was cleared to.
 *
 * Built for x86_64 or i686 with the mingw compiler: -lopengl32 -lgdi32 -luser32.
 */
#include <windows.h>
#include <GL/gl.h>
#include <stdio.h>

/* GL_EXT_framebuffer_object, so that the test draws into a texture rather than into the window,
 * which has no surface on macOS while it is hidden */
#define GL_FRAMEBUFFER_EXT          0x8D40
#define GL_COLOR_ATTACHMENT0_EXT    0x8CE0
#define GL_FRAMEBUFFER_COMPLETE_EXT 0x8CD5
typedef void (APIENTRY *gen_fbs)(GLsizei, GLuint *);
typedef void (APIENTRY *bind_fb)(GLenum, GLuint);
typedef void (APIENTRY *fb_tex2d)(GLenum, GLenum, GLenum, GLuint, GLint);
typedef GLenum (APIENTRY *check_fb)(GLenum);

int main( void )
{
    PIXELFORMATDESCRIPTOR pfd = { sizeof(pfd), 1, PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER,
                                  PFD_TYPE_RGBA, 32, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 24, 8 };
    unsigned char pixel[4] = { 0 };
    HGLRC context;
    int format;
    HWND hwnd;
    HDC hdc;

    hwnd = CreateWindowExA( 0, "static", "opengl_test", WS_OVERLAPPEDWINDOW, 0, 0, 64, 64, 0, 0, 0, NULL );
    hdc = GetDC( hwnd );
    if (!(format = ChoosePixelFormat( hdc, &pfd ))) { printf( "opengl: ChoosePixelFormat failed, error %lu\n", GetLastError() ); return 1; }
    if (!SetPixelFormat( hdc, format, &pfd )) { printf( "opengl: SetPixelFormat %d failed, error %lu\n", format, GetLastError() ); return 1; }
    if (!(context = wglCreateContext( hdc ))) { printf( "opengl: wglCreateContext failed, error %lu\n", GetLastError() ); return 1; }
    if (!wglMakeCurrent( hdc, context )) { printf( "opengl: wglMakeCurrent failed, error %lu\n", GetLastError() ); return 1; }

    {
        gen_fbs pglGenFramebuffersEXT = (gen_fbs)wglGetProcAddress( "glGenFramebuffersEXT" );
        bind_fb pglBindFramebufferEXT = (bind_fb)wglGetProcAddress( "glBindFramebufferEXT" );
        fb_tex2d pglFramebufferTexture2DEXT = (fb_tex2d)wglGetProcAddress( "glFramebufferTexture2DEXT" );
        check_fb pglCheckFramebufferStatusEXT = (check_fb)wglGetProcAddress( "glCheckFramebufferStatusEXT" );
        GLuint fbo, tex;

        if (!pglGenFramebuffersEXT || !pglBindFramebufferEXT || !pglFramebufferTexture2DEXT || !pglCheckFramebufferStatusEXT)
        {
            printf( "opengl: renderer \"%s\", no GL_EXT_framebuffer_object\n", (const char *)glGetString( GL_RENDERER ) );
            return 1;
        }
        glGenTextures( 1, &tex );
        glBindTexture( GL_TEXTURE_2D, tex );
        glTexImage2D( GL_TEXTURE_2D, 0, GL_RGBA8, 64, 64, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL );
        pglGenFramebuffersEXT( 1, &fbo );
        pglBindFramebufferEXT( GL_FRAMEBUFFER_EXT, fbo );
        pglFramebufferTexture2DEXT( GL_FRAMEBUFFER_EXT, GL_COLOR_ATTACHMENT0_EXT, GL_TEXTURE_2D, tex, 0 );
        if (pglCheckFramebufferStatusEXT( GL_FRAMEBUFFER_EXT ) != GL_FRAMEBUFFER_COMPLETE_EXT)
        {
            printf( "opengl: framebuffer incomplete\n" );
            return 1;
        }
    }
    glViewport( 0, 0, 64, 64 );
    glClearColor( 0x33 / 255.0f, 0x66 / 255.0f, 0xcc / 255.0f, 1.0f );
    glClear( GL_COLOR_BUFFER_BIT );
    glFinish();
    glReadPixels( 32, 32, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel );
    printf( "opengl: renderer \"%s\", version \"%s\", pixel %02x%02x%02x\n", (const char *)glGetString( GL_RENDERER ),
            (const char *)glGetString( GL_VERSION ), pixel[0], pixel[1], pixel[2] );
    wglMakeCurrent( NULL, NULL );
    wglDeleteContext( context );
    return pixel[0] == 0x33 && pixel[1] == 0x66 && pixel[2] == 0xcc ? 0 : 1;
}
