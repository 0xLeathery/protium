/*
 * Calls the C runtime's maths functions from x86_64 (or i386) code and checks the results, as a
 * program's own code would use them: under FEX the runtime (ucrtbase/msvcrt) is native ARM64EC
 * code reached through the ARM64EC entry thunks, which carry float and double arguments and
 * results between the x86 and the Arm registers.
 *
 *   crt_math_test.exe
 *
 * Prints every result that is off by more than a few ulps and a summary, e.g.
 *   crt math: 64 checks, 0 wrong
 * and exits 0 when none is wrong. No window is shown. The arguments go through volatile
 * variables so the compiler cannot fold the calls.
 *
 * Built for x86_64 or i686 with the mingw compiler (ucrt): -lm.
 */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int checks, wrong;

static void check_d( const char *what, double got, double want )
{
    double tol = fabs( want ) * 1e-12 + 1e-300;
    checks++;
    if (isnan( want ) ? !isnan( got ) : fabs( got - want ) > tol)
    {
        printf( "crt math: %s = %.17g, want %.17g\n", what, got, want );
        wrong++;
    }
}

static void check_f( const char *what, float got, float want )
{
    float tol = fabsf( want ) * 1e-5f + 1e-30f;
    checks++;
    if (isnan( want ) ? !isnan( got ) : fabsf( got - want ) > tol)
    {
        printf( "crt math: %s = %.9g, want %.9g\n", what, got, want );
        wrong++;
    }
}

int main( void )
{
    volatile double a = 0.5, b = 2.0, c = -1.25, d = 1e6, e = 3.0;
    volatile float fa = 0.5f, fb = 2.0f, fc = -1.25f, fd = 1e6f, fe = 3.0f;
    char buf[64];

    check_d( "sin(0.5)", sin( a ), 0.479425538604203 );
    check_d( "cos(0.5)", cos( a ), 0.8775825618903728 );
    check_d( "tan(0.5)", tan( a ), 0.5463024898437905 );
    check_d( "atan(2)", atan( b ), 1.1071487177940904 );
    check_d( "atan2(0.5,-1.25)", atan2( a, c ), 2.761086276477428 );
    check_d( "asin(0.5)", asin( a ), 0.5235987755982989 );
    check_d( "acos(0.5)", acos( a ), 1.0471975511965979 );
    check_d( "exp(2)", exp( b ), 7.38905609893065 );
    check_d( "log(1e6)", log( d ), 13.815510557964274 );
    check_d( "log10(1e6)", log10( d ), 6.0 );
    check_d( "log2(1e6)", log2( d ), 19.931568569324174 );
    check_d( "pow(2,3)", pow( b, e ), 8.0 );
    check_d( "pow(0.5,-1.25)", pow( a, c ), 2.378414230005442 );
    check_d( "sqrt(2)", sqrt( b ), 1.4142135623730951 );
    check_d( "cbrt(1e6)", cbrt( d ), 100.0 );
    check_d( "fmod(1e6,3)", fmod( d, e ), 1.0 );
    check_d( "floor(-1.25)", floor( c ), -2.0 );
    check_d( "ceil(-1.25)", ceil( c ), -1.0 );
    check_d( "round(-1.25)", round( c ), -1.0 );
    check_d( "trunc(-1.25)", trunc( c ), -1.0 );
    check_d( "fabs(-1.25)", fabs( c ), 1.25 );
    check_d( "hypot(2,3)", hypot( b, e ), 3.605551275463989 );
    check_d( "ldexp(0.5,3)", ldexp( a, 3 ), 4.0 );
    check_d( "sinh(0.5)", sinh( a ), 0.5210953054937474 );
    check_d( "cosh(0.5)", cosh( a ), 1.1276259652063807 );
    check_d( "tanh(0.5)", tanh( a ), 0.46211715726000974 );
    check_d( "exp2(3)", exp2( e ), 8.0 );
    check_d( "expm1(0.5)", expm1( a ), 0.6487212707001282 );
    check_d( "log1p(0.5)", log1p( a ), 0.4054651081081644 );
    check_d( "fma(0.5,2,3)", fma( a, b, e ), 4.0 );
    check_d( "copysign(2,-1.25)", copysign( b, c ), -2.0 );
    check_d( "remainder(1e6,3)", remainder( d, e ), 1.0 );

    check_f( "sinf(0.5)", sinf( fa ), 0.4794255386f );
    check_f( "cosf(0.5)", cosf( fa ), 0.8775825619f );
    check_f( "tanf(0.5)", tanf( fa ), 0.5463024898f );
    check_f( "atanf(2)", atanf( fb ), 1.1071487178f );
    check_f( "atan2f(0.5,-1.25)", atan2f( fa, fc ), 2.7610862765f );
    check_f( "asinf(0.5)", asinf( fa ), 0.5235987756f );
    check_f( "acosf(0.5)", acosf( fa ), 1.0471975512f );
    check_f( "expf(2)", expf( fb ), 7.3890560989f );
    check_f( "logf(1e6)", logf( fd ), 13.815510558f );
    check_f( "log10f(1e6)", log10f( fd ), 6.0f );
    check_f( "log2f(1e6)", log2f( fd ), 19.931568569f );
    check_f( "powf(2,3)", powf( fb, fe ), 8.0f );
    check_f( "powf(0.5,-1.25)", powf( fa, fc ), 2.3784142300f );
    check_f( "sqrtf(2)", sqrtf( fb ), 1.4142135624f );
    check_f( "cbrtf(1e6)", cbrtf( fd ), 100.0f );
    check_f( "fmodf(1e6,3)", fmodf( fd, fe ), 1.0f );
    check_f( "floorf(-1.25)", floorf( fc ), -2.0f );
    check_f( "ceilf(-1.25)", ceilf( fc ), -1.0f );
    check_f( "roundf(-1.25)", roundf( fc ), -1.0f );
    check_f( "truncf(-1.25)", truncf( fc ), -1.0f );
    check_f( "fabsf(-1.25)", fabsf( fc ), 1.25f );
    check_f( "hypotf(2,3)", hypotf( fb, fe ), 3.6055512755f );
    check_f( "ldexpf(0.5,3)", ldexpf( fa, 3 ), 4.0f );
    check_f( "sinhf(0.5)", sinhf( fa ), 0.5210953055f );
    check_f( "coshf(0.5)", coshf( fa ), 1.1276259652f );
    check_f( "tanhf(0.5)", tanhf( fa ), 0.4621171573f );
    check_f( "exp2f(3)", exp2f( fe ), 8.0f );
    check_f( "fmaf(0.5,2,3)", fmaf( fa, fb, fe ), 4.0f );
    check_f( "copysignf(2,-1.25)", copysignf( fb, fc ), -2.0f );

    check_d( "atof(\"-1.25e3\")", atof( "-1.25e3" ), -1250.0 );
    check_d( "strtod(\"0.1\")", strtod( "0.1", NULL ), 0.1 );
    check_f( "strtof(\"3.5\")", strtof( "3.5", NULL ), 3.5f );
    snprintf( buf, sizeof(buf), "%.3f %g", (double)c, (double)d );
    checks++;
    if (strcmp( buf, "-1.250 1e+06" )) { printf( "crt math: printf gave \"%s\", want \"-1.250 1e+06\"\n", buf ); wrong++; }

    printf( "crt math: %d checks, %d wrong\n", checks, wrong );
    return wrong ? 1 : 0;
}
