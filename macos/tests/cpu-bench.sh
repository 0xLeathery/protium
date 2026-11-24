#!/bin/bash
#
# What the processor's work costs a game on this build, measured: the same small pieces of work
# as native arm64 code and as x86 code through FEX, side by side.
#
#   macos/tests/cpu-bench.sh [VAR=value ...]
#
# Builds cpu_tax.c for aarch64, x86_64 and i686 and native_tso.c for x86_64, runs them in
# check-wave5.sh's prefix as a game runs (fast synchronisation on) and prints one table of
# nanoseconds for each pass, with x86_64's cost as a multiple of native. Each VAR=value is set
# for the x86 runs only, to compare FEX's options, e.g.
#
#   macos/tests/cpu-bench.sh                       # as games run today
#   macos/tests/cpu-bench.sh FEX_HARDWARE_TSO=0    # software TSO
#
# It is a measurement, not a check: nothing passes or fails. It shows no window. Do not run it
# while a game is running: the numbers would be the game's, and it refuses when a wineserver is
# up. Results are kept in $EVIDENCE_DIR, one folder for each run.

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
BUILD_ROOT=${BUILD_ROOT:-$HOME/projects/proton-macos-build}
BUILD_DIR=${BUILD_DIR:-$BUILD_ROOT/wine-arm64ec}
TOOLCHAIN_DIR=${TOOLCHAIN_DIR:-$HOME/projects/proton-macos-toolchain/llvm-mingw-20261020-ucrt-macos-universal}
EVIDENCE_DIR=${EVIDENCE_DIR:-$BUILD_ROOT/evidence/perf}
PREFIX=${PREFIX:-$BUILD_ROOT/evidence/wave5/prefix}
RUN_TIMEOUT=${RUN_TIMEOUT:-300}
MINGW_BIN=$TOOLCHAIN_DIR/bin
INSTALL_DIR=$(sed -n 's/^prefix = //p' "$BUILD_DIR/Makefile" 2>/dev/null | head -1)
WINE=$INSTALL_DIR/bin/wine

[ -x "$WINE" ] || { echo "cpu-bench: no Wine at '$WINE' (BUILD_DIR=$BUILD_DIR)" >&2; exit 2; }
[ -d "$PREFIX" ] || { echo "cpu-bench: no prefix at $PREFIX; run check-wave5.sh once" >&2; exit 2; }
if pgrep -x wineserver >/dev/null; then
    echo "cpu-bench: a wineserver is running (a game?); the numbers would not be this build's" >&2
    exit 2
fi

run_timeout() {
    local t=$1; shift
    perl -e 'my $t = shift; my $pid = fork; die "fork: $!" unless defined $pid;
             if (!$pid) { exec @ARGV or die "exec: $!" }
             $SIG{ALRM} = sub { kill "KILL", $pid }; alarm $t; waitpid $pid, 0;
             exit((($? & 127) == 9) ? 142 : ($? & 127) ? 128 + ($? & 127) : $? >> 8)' "$t" "$@"
}

out=$EVIDENCE_DIR/cpu-bench-$(date +%Y%m%d-%H%M%S)
mkdir -p "$out"
for arch in aarch64 x86_64 i686; do
    "$MINGW_BIN/$arch-w64-mingw32-clang" -O2 -o "$out/cpu_tax_$arch.exe" "$SCRIPT_DIR/cpu_tax.c" -lntdll ||
        { echo "cpu-bench: cpu_tax.c did not build for $arch" >&2; exit 1; }
done
"$MINGW_BIN/x86_64-w64-mingw32-clang" -O2 -o "$out/native_tso.exe" "$SCRIPT_DIR/native_tso.c" -lntdll ||
    { echo "cpu-bench: native_tso.c did not build" >&2; exit 1; }

# run NAME exe: the program's lines to $out/NAME.txt; x86 programs get the options given to us
run() {
    local name=$1 exe=$2; shift 2
    ( cd "$out" || exit 1
      export WINEPREFIX="$PREFIX" WINEFSYNC=1 WINEDEBUG=-all
      export WINEDLLOVERRIDES="${WINEDLLOVERRIDES:-mscoree,mshtml=}"
      for v in "$@"; do export "$v"; done
      run_timeout "$RUN_TIMEOUT" "$WINE" "$exe" </dev/null >"$name.txt" 2>"$name.err" )
    [ -s "$out/$name.txt" ] || echo "cpu-bench: $exe printed nothing (see $out/$name.err)" >&2
}

echo "options for the x86 runs: ${*:-none}" | tee "$out/options.txt"
run aarch64 cpu_tax_aarch64.exe
run x86_64 cpu_tax_x86_64.exe "$@"
run i686 cpu_tax_i686.exe "$@"
run native_tso native_tso.exe "$@"

perl -e '
    my ($dir) = @ARGV; my (%v, @order);
    for my $a (qw(aarch64 x86_64 i686)) {
        open my $f, "<", "$dir/$a.txt" or next;
        while (<$f>) {
            next unless /^(.+?)\s+([\d.]+) ns/;
            push @order, $1 unless exists $v{$1};
            $v{$1}{$a} = $2;
        }
    }
    printf "%-14s %10s %10s %10s   %s\n", "ns each", "arm64", "x86_64", "i686", "x86_64/arm64";
    for my $k (@order) {
        my $r = $v{$k};
        printf "%-14s %10s %10s %10s", $k, map { defined $r->{$_} ? sprintf("%.2f", $r->{$_}) : "-" } qw(aarch64 x86_64 i686);
        printf "   %5.1fx", $r->{x86_64} / $r->{aarch64} if $r->{aarch64} && $r->{aarch64} > 0 && defined $r->{x86_64};
        print "\n";
    }' "$out" | tee "$out/table.txt"
echo "native code called from x86_64 code:" | tee -a "$out/table.txt"
sed 's/^/  /' "$out/native_tso.txt" | tee -a "$out/table.txt"
echo "kept in $out"
