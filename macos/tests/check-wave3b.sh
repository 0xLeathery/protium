#!/bin/bash
#
# Wave 3b acceptance check for the native arm64 macOS Wine build: Wine runs from an install tree
# with its loader in wine.app (macos/bundle-wine.sh), the only place where a provisioning profile
# can give it the cross-architecture entitlement (4K pages, memory below 4 GB, hardware TSO).
#
#   macos/tests/check-wave3b.sh                                    # ad-hoc signed bundle
#   LOADER_PROFILE=/path/to/loader.provisionprofile macos/tests/check-wave3b.sh
#
# Items (pass/fail):
#   1  the bundle: wine.app/Contents/{MacOS/wine, Info.plist} next to ntdll.so, lib/wine/
#      aarch64-unix/wine and bin/wine are links into it, the signature verifies (--strict) and
#      carries exactly the x18 entitlement (with LOADER_PROFILE: the cross-architecture
#      entitlement too, and the profile is embedded); wineserver has no entitlements
#   2  the loader finds ntdll.so started through bin/wine, through the link next to ntdll.so and
#      by its path in the bundle (wine --version)
#   3  bin/wine hello.exe prints its line and exits 0, HELLO_RUNS runs (the first in a fresh prefix)
#   4  bin/wine wineboot -u in a fresh prefix, WINEBOOT_RUNS runs: exit 0, no fault, and every
#      process Wine starts is started by the loader's path inside wine.app, none through the link
#      (a process started through the link has no bundle)
#   5  regression: check-wave3a.sh passes (it runs check-wave1.sh, 2a and 2b itself)
#   6  other targets unchanged: every line of this wave in Wine is under __APPLE__ && __aarch64__
#      (with either undefined the files are the wave base text); diff scope
# The build (macos/build-wine.sh, macos/bundle-wine.sh) and the test programs come first ("build").
#
# NOT YET CHECKED, so this check passing does not make Wave 3b done: 4K pages, memory below 4 GB
# (shared user data back at 0x7ffe0000), MAP_JIT memory for a Unix JIT, hardware TSO and FEX. They
# need the profile. The summary lists them as TODO and the exit status is 3 while they are open
# and nothing failed (1 when an item failed, 0 only when all of it passed).
# Logs go to $EVIDENCE_DIR.

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PROTON_DIR=$(cd "$SCRIPT_DIR/../.." && pwd)
WINE_DIR=$PROTON_DIR/wine
BUILD_ROOT=${BUILD_ROOT:-/Users/annon/projects/proton-macos-build}
BUILD_DIR=${BUILD_DIR:-$BUILD_ROOT/wine-aarch64}
SRC_DIR=${SRC_DIR:-$BUILD_ROOT/wine-src}
TOOLCHAIN_DIR=${TOOLCHAIN_DIR:-/Users/annon/projects/proton-macos-toolchain/llvm-mingw-20261020-ucrt-macos-universal}
EVIDENCE_DIR=${EVIDENCE_DIR:-$BUILD_ROOT/evidence/wave3b}
LOADER_PROFILE=${LOADER_PROFILE:-}
# wine and superproject commits this wave starts from (the tips after Wave 3a)
WINE_WAVE_BASE=${WINE_WAVE_BASE:-47775ab13b6141ecf958fbb5fedc5fd5e7bc8604}
SUPER_WAVE_BASE=${SUPER_WAVE_BASE:-56a14d835ae96ab59e2753a21fb855c08ce913a5}
WINEBOOT_TIMEOUT=${WINEBOOT_TIMEOUT:-300}
RUN_TIMEOUT=${RUN_TIMEOUT:-120}
HELLO_RUNS=${HELLO_RUNS:-5}
WINEBOOT_RUNS=${WINEBOOT_RUNS:-3}
UNIX_DIR=aarch64-unix
X18_ENTITLEMENT=com.apple.security.custom-x18-abi-toggle
CROSS_ARCH_ENTITLEMENT=com.apple.developer.cross-architecture-support
# Wine files this wave may change: the loader in an app bundle.
WAVE_FILES="loader/main.c dlls/ntdll/unix/loader.c"
# The build scripts stop below 20 GB free by default; 10 GB is the limit agreed for this work.
export MIN_FREE_GB=${MIN_FREE_GB:-10}
# A new prefix would otherwise wait on the Mono and Gecko install dialogs.
export WINEDLLOVERRIDES=${WINEDLLOVERRIDES:-mscoree,mshtml=}

mkdir -p "$EVIDENCE_DIR"
RESULTS=()
FAILED=0
TODO=0
# CHECK_ITEMS limits the run to some items ("build" rebuilds Wine, the bundle and the test programs).
CHECK_ITEMS=${CHECK_ITEMS:-"build 1 2 3 4 5 6"}
want() { case " $CHECK_ITEMS " in *" $1 "*) return 0 ;; esac; return 1; }
pass() { RESULTS+=("PASS  item $1: $2"); echo "PASS  item $1: $2"; }
fail() { RESULTS+=("FAIL  item $1: $2"); echo "FAIL  item $1: $2"; FAILED=1; }
todo() { RESULTS+=("TODO  $1"); echo "TODO  $1"; TODO=1; }
run_timeout() { local t=$1; shift; perl -e 'alarm shift; exec @ARGV or die "exec: $!"' "$t" "$@"; }

WORK=$EVIDENCE_DIR/work
mkdir -p "$WORK"
MINGW_BIN=$TOOLCHAIN_DIR/bin
OBJDUMP=$MINGW_BIN/llvm-objdump
INSTALL_DIR=$(sed -n 's/^prefix = //p' "$BUILD_DIR/Makefile" 2>/dev/null | head -1)
INSTALL_DIR=$(cd "${INSTALL_DIR:-/nonexistent}" 2>/dev/null && pwd -P || echo "${INSTALL_DIR:-/nonexistent}")
VERSION=$(sed -n 's/^PACKAGE_VERSION = //p' "$BUILD_DIR/Makefile" 2>/dev/null | head -1)
UNIXLIB=$INSTALL_DIR/lib/wine/$UNIX_DIR
APP=$UNIXLIB/wine.app
BUNDLE_LOADER=$APP/Contents/MacOS/wine
WINE=$INSTALL_DIR/bin/wine
SERVER=$INSTALL_DIR/bin/wineserver
TESTS_OUT=$EVIDENCE_DIR/programs
mkdir -p "$TESTS_OUT"

cleanup_prefix() {
    WINEPREFIX=$1 run_timeout 30 "$SERVER" -k >/dev/null 2>&1
    WINEPREFIX=$1 run_timeout 60 "$SERVER" -w >/dev/null 2>&1
    rm -rf "$1"
}
# entitlement keys of a signed file or bundle, one per line
entitlement_keys() {
    codesign -d --entitlements - --xml "$1" 2>/dev/null | perl -ne 'print "$1\n" while /<key>([^<]*)<\/key>/g'
}

########################################################################
# Build: Wine, the bundle and the test programs
########################################################################
if want build; then
echo "== build: macos/build-wine.sh (incremental), macos/bundle-wine.sh and the test programs"
blog=$EVIDENCE_DIR/build.log
start=$(date +%s)
"$PROTON_DIR/macos/build-wine.sh" >"$blog" 2>&1
bstatus=$?
if [ $bstatus = 0 ]; then
    pass build "build-wine.sh (incremental) exit 0 in $(( $(date +%s) - start ))s ($blog)"
else
    fail build "build-wine.sh (incremental) exited $bstatus ($blog)"
fi
ulog=$EVIDENCE_DIR/bundle.log
LOADER_PROFILE=$LOADER_PROFILE "$PROTON_DIR/macos/bundle-wine.sh" >"$ulog" 2>&1
ustatus=$?
if [ $ustatus = 0 ]; then
    pass build "bundle-wine.sh exit 0, $([ -n "$LOADER_PROFILE" ] && echo "profile $LOADER_PROFILE" || echo "ad hoc") ($ulog)"
else
    fail build "bundle-wine.sh exited $ustatus: $(tail -1 "$ulog") ($ulog)"
fi
# hello.exe: the build's own winegcc for aarch64-windows, against Wine's CRT, as in check-wave3a.sh
hlog=$TESTS_OUT/hello.build.log
rm -f "$TESTS_OUT/hello.exe"
{
    echo "\$ winegcc -b aarch64-w64-mingw32 hello.c (Wine CRT)"
    PATH=$MINGW_BIN:$PATH "$BUILD_DIR/tools/winegcc/winegcc" -v --wine-objdir "$BUILD_DIR" -b aarch64-w64-mingw32 \
        -mconsole -O2 -Wall -D_UCRT -I"$SRC_DIR/include/msvcrt" -I"$SRC_DIR/include" \
        -o "$TESTS_OUT/hello.exe" "$SCRIPT_DIR/hello.c" \
        "$BUILD_DIR/dlls/winecrt0/aarch64-windows/libwinecrt0.a" "$BUILD_DIR/dlls/ucrtbase/aarch64-windows/libucrtbase.a" \
        "$BUILD_DIR/dlls/kernel32/aarch64-windows/libkernel32.a" "$BUILD_DIR/dlls/ntdll/aarch64-windows/libntdll.a"
    echo "exit=$?"
    "$OBJDUMP" -p "$TESTS_OUT/hello.exe" | grep 'DLL Name'
} >"$hlog" 2>&1
if [ -f "$TESTS_OUT/hello.exe" ]; then pass build "hello.exe built ($hlog)"; else fail build "hello.exe did not build ($hlog)"; fi
plog=$TESTS_OUT/proc_exec_path.build.log
rm -f "$TESTS_OUT/proc_exec_path"
clang -O1 -Wall -Werror -o "$TESTS_OUT/proc_exec_path" "$SCRIPT_DIR/proc_exec_path.c" >"$plog" 2>&1
if [ -x "$TESTS_OUT/proc_exec_path" ]; then pass build "proc_exec_path built ($plog)"; else fail build "proc_exec_path did not build ($plog)"; fi
fi  # build

########################################################################
# Item 1: the bundle and its signature
########################################################################
if want 1; then
echo "== item 1: the bundle and its signature"
clog=$EVIDENCE_DIR/item1-bundle.log
ok=yes
no() { ok=no; echo "WRONG: $*" >>"$clog"; }
{
    echo "\$ ls -l (bundle, links)"
    ls -l "$APP/Contents" "$APP/Contents/MacOS" "$UNIXLIB/wine" "$WINE" "$UNIXLIB/ntdll.so" 2>&1
    echo "\$ plutil -p $APP/Contents/Info.plist"
    plutil -p "$APP/Contents/Info.plist" 2>&1
    echo "\$ codesign -dvv $APP"
    codesign -dvv "$APP" 2>&1
    echo "\$ codesign -d --entitlements - --xml $APP"
    codesign -d --entitlements - --xml "$APP" 2>&1; echo
    echo "\$ codesign --verify --strict --verbose=2 $APP"
    codesign --verify --strict --verbose=2 "$APP" 2>&1
    echo "verify exit=$?"
} >"$clog"
[ -f "$BUNDLE_LOADER" ] && [ ! -L "$BUNDLE_LOADER" ] || no "no loader file at $BUNDLE_LOADER"
[ -f "$UNIXLIB/ntdll.so" ] || no "no ntdll.so next to wine.app"
[ "$(readlink "$UNIXLIB/wine")" = "wine.app/Contents/MacOS/wine" ] || no "$UNIXLIB/wine is not the link into wine.app"
[ "$(readlink "$WINE")" = "../lib/wine/$UNIX_DIR/wine.app/Contents/MacOS/wine" ] || no "bin/wine is not the link into wine.app"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist" 2>/dev/null)" = wine ] || no "CFBundleExecutable is not wine"
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null)
[ -n "$bundle_id" ] || no "no CFBundleIdentifier"
codesign --verify --strict "$APP" 2>/dev/null || no "the signature does not verify"
keys=$(entitlement_keys "$APP" | sort | paste -sd, -)
echo "entitlement keys: ${keys:-<none>}" >>"$clog"
if [ -n "$LOADER_PROFILE" ]; then
    kind="profile, $bundle_id"
    for k in "$X18_ENTITLEMENT" "$CROSS_ARCH_ENTITLEMENT"; do
        codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -q "<key>$k</key><true/>" || no "the signature does not set $k"
    done
    cmp -s "$LOADER_PROFILE" "$APP/Contents/embedded.provisionprofile" || no "embedded.provisionprofile is not $LOADER_PROFILE"
    codesign -dvv "$APP" 2>&1 | grep -q '^TeamIdentifier=not set' && no "signed without a team"
else
    kind="ad hoc, $bundle_id"
    [ "$keys" = "$X18_ENTITLEMENT" ] || no "entitlements are not exactly $X18_ENTITLEMENT"
    codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -q "<key>$X18_ENTITLEMENT</key><true/>" || no "$X18_ENTITLEMENT is not true"
    [ ! -e "$APP/Contents/embedded.provisionprofile" ] || no "a profile is embedded in an ad-hoc bundle"
fi
skeys=$(entitlement_keys "$SERVER" | paste -sd, -)
{ echo "=== $SERVER (must not carry entitlements)"; codesign -dv "$SERVER" 2>&1; echo "entitlement keys: ${skeys:-<none>}"; } >>"$clog"
[ -z "$skeys" ] || no "wineserver carries entitlements"
if [ $ok = yes ]; then
    pass 1 "wine.app ($kind) next to ntdll.so, both links point into it, signature verifies with ${keys}; wineserver has no entitlements ($clog)"
else
    fail 1 "$(grep -c '^WRONG' "$clog") things wrong with the bundle: $(grep '^WRONG' "$clog" | head -3 | cut -c8-90 | paste -sd';' -) ($clog)"
fi
fi  # item 1

########################################################################
# Item 2: the loader finds ntdll.so from each of its paths
########################################################################
if want 2; then
echo "== item 2: wine --version through each path of the loader"
vlog=$EVIDENCE_DIR/item2-version.log
: >"$vlog"
vpass=0
for w in "$WINE" "$UNIXLIB/wine" "$BUNDLE_LOADER"; do
    out=$(run_timeout 60 "$w" --version 2>&1); rc=$?
    { echo "\$ $w --version"; echo "$out"; echo "exit=$rc"; } >>"$vlog"
    [ "$rc" = 0 ] && [ "$out" = "wine-$VERSION" ] && vpass=$((vpass + 1))
done
if [ "$vpass" = 3 ]; then
    pass 2 "bin/wine, $UNIX_DIR/wine and wine.app/Contents/MacOS/wine all print wine-$VERSION ($vlog)"
else
    fail 2 "wine --version worked through $vpass/3 paths ($vlog)"
fi
fi  # item 2

########################################################################
# Item 3: bin/wine hello.exe, HELLO_RUNS runs
########################################################################
if want 3; then
echo "== item 3: bin/wine hello.exe x $HELLO_RUNS"
hdir=$EVIDENCE_DIR/item3-hello
rm -rf "$hdir"; mkdir -p "$hdir"
PREFIX=$BUILD_ROOT/wave3b-prefix-hello
rm -rf "$PREFIX"; mkdir -p "$PREFIX"
hpass=0
for i in $(seq 1 "$HELLO_RUNS"); do
    t=$RUN_TIMEOUT; [ $i = 1 ] && t=$WINEBOOT_TIMEOUT   # the first run sets the prefix up
    echo "\$ WINEPREFIX=$PREFIX WINEDLLOVERRIDES=$WINEDLLOVERRIDES $WINE $TESTS_OUT/hello.exe" >"$hdir/run$i.log"
    WINEPREFIX=$PREFIX run_timeout "$t" "$WINE" "$TESTS_OUT/hello.exe" >"$hdir/run$i.stdout" 2>"$hdir/run$i.stderr"
    rc=$?
    { echo "--- stdout"; cat "$hdir/run$i.stdout"; echo "--- stderr"; cat "$hdir/run$i.stderr"; echo "exit=$rc"; } >>"$hdir/run$i.log"
    line=no; tr -d '\r' <"$hdir/run$i.stdout" | grep -qx 'hello from Windows ARM64 code on macOS' && line=yes
    [ "$rc" = 0 ] && [ $line = yes ] && hpass=$((hpass + 1))
    echo "run $i: exit=$rc line=$line" >>"$hdir/summary.txt"
done
cleanup_prefix "$PREFIX"
if [ "$hpass" = "$HELLO_RUNS" ]; then
    pass 3 "hello.exe printed its line and exited 0 in $hpass/$HELLO_RUNS runs through bin/wine, the first in a fresh prefix ($hdir/summary.txt)"
else
    fail 3 "hello.exe passed $hpass/$HELLO_RUNS runs through bin/wine ($hdir/summary.txt)"
fi
fi  # item 3

########################################################################
# Item 4: wineboot -u, and how the processes are started
########################################################################
if want 4; then
echo "== item 4: bin/wine wineboot -u x $WINEBOOT_RUNS, paths the processes are started with"
bdir=$EVIDENCE_DIR/item4-wineboot
rm -rf "$bdir"; mkdir -p "$bdir"
PREFIX=$BUILD_ROOT/wave3b-prefix-boot
bpass=0
for i in $(seq 1 "$WINEBOOT_RUNS"); do
    rm -rf "$PREFIX"; mkdir -p "$PREFIX"
    blog=$bdir/run$i.log
    # PID, path of the exec and file of every process of the install tree, sampled during the run
    rm -f "$bdir/stop"
    ( while [ ! -f "$bdir/stop" ]; do "$TESTS_OUT/proc_exec_path" "$INSTALL_DIR"; perl -e 'select(undef, undef, undef, 0.05)'; done \
          | sort -u >"$bdir/run$i.processes.tsv" ) &
    sampler=$!
    echo "\$ WINEPREFIX=$PREFIX WINEDLLOVERRIDES=$WINEDLLOVERRIDES $WINE wineboot -u" >"$blog"
    start=$(date +%s)
    WINEPREFIX=$PREFIX run_timeout "$WINEBOOT_TIMEOUT" "$WINE" wineboot -u >>"$blog" 2>&1
    rc=$?
    WINEPREFIX=$PREFIX run_timeout 120 "$SERVER" -w >>"$blog" 2>&1
    wrc=$?
    end=$(date +%s)
    touch "$bdir/stop"; wait $sampler
    echo "exit=$rc wineserver_wait=$wrc seconds=$((end - start))" >>"$blog"
    cleanup_prefix "$PREFIX"
    nfault=$(grep -c -E 'page fault|Unhandled exception|c0000005' "$blog")
    # by path inside the bundle; through a name in bin (what the user starts); anything else is a link
    nbundle=$(awk -F'\t' -v l="$BUNDLE_LOADER" '$3 == l && $2 == l' "$bdir/run$i.processes.tsv" | wc -l | tr -d ' ')
    nbin=$(awk -F'\t' -v l="$BUNDLE_LOADER" -v b="$INSTALL_DIR/bin/" '$3 == l && index($2, b) == 1' "$bdir/run$i.processes.tsv" | wc -l | tr -d ' ')
    nlink=$(awk -F'\t' -v l="$BUNDLE_LOADER" -v b="$INSTALL_DIR/bin/" '$3 == l && $2 != l && index($2, b) != 1' "$bdir/run$i.processes.tsv" | wc -l | tr -d ' ')
    status=FAIL
    [ "$rc" = 0 ] && [ "$wrc" = 0 ] && [ "$nfault" = 0 ] && [ "$nbundle" -ge 3 ] && [ "$nlink" = 0 ] && { status=PASS; bpass=$((bpass + 1)); }
    echo "run $i: $status wineboot exit=$rc, faults: $nfault, loader processes started by the path in wine.app: $nbundle, through bin/: $nbin, through another link: $nlink, $((end - start))s" \
        | tee -a "$bdir/summary.txt"
done
rm -f "$bdir/stop"
if [ "$bpass" = "$WINEBOOT_RUNS" ]; then
    pass 4 "wineboot -u clean in $bpass/$WINEBOOT_RUNS fresh prefixes: exit 0, no fault, every process Wine started runs by the loader's path in wine.app ($bdir/summary.txt)"
else
    fail 4 "wineboot -u clean in $bpass/$WINEBOOT_RUNS runs ($bdir/summary.txt)"
fi
fi  # item 4

########################################################################
# Item 5: regression of Wave 3a (and through it Waves 1, 2a and 2b)
########################################################################
if want 5; then
echo "== item 5: Wave 3a regression"
R=$EVIDENCE_DIR/regression-wave3a
rm -rf "$R"; mkdir -p "$R"
EVIDENCE_DIR=$R "$PROTON_DIR/macos/tests/check-wave3a.sh" >"$R/check-wave3a.out" 2>&1
rrc=$?
if [ $rrc = 0 ] && [ -s "$R/check-summary.txt" ] && ! grep -q '^FAIL' "$R/check-summary.txt"; then
    pass 5 "check-wave3a.sh: exit 0, no FAIL ($R/check-summary.txt)"
else
    fail 5 "check-wave3a.sh exit $rrc: $(grep '^FAIL' "$R/check-summary.txt" 2>/dev/null | cut -c1-70 | paste -sd';' -) ($R)"
fi
fi  # item 5

########################################################################
# Item 6: other targets unchanged
########################################################################
if want 6; then
echo "== item 6: other targets unchanged"
glog=$EVIDENCE_DIR/item6-guards.log
ulog=$EVIDENCE_DIR/item6-unifdef.log
dlog=$EVIDENCE_DIR/item6-diff.log
: >"$ulog"
ok=yes
# every line added since the wave base, with the stack of #if conditions it is in
{
    echo "\$ git -C wine diff $WINE_WAVE_BASE HEAD -- $WAVE_FILES: every added line with its enclosing #if stack"
    for f in $WAVE_FILES; do
        git -C "$WINE_DIR" show "HEAD:$f" >"$WORK/guard.c"
        git -C "$WINE_DIR" diff -U0 "$WINE_WAVE_BASE" HEAD -- "$f" | sed -n 's/^@@ -[0-9,]* +\([0-9]*\),\{0,1\}\([0-9]*\) @@.*/\1 \2/p' >"$WORK/hunks"
        perl -e '
            my ($file, $hunks) = @ARGV; open my $fh, "<", $file or die; my @lines = <$fh>;
            open my $hh, "<", $hunks or die; my %added;
            while (<$hh>) { my ($s, $n) = split; $n = 1 if $n eq ""; $added{$_} = 1 for $s .. $s + $n - 1; }
            my @stack; my $i = 0;
            for my $l (@lines) {
                $i++;
                # the conditions the line is in; the #if and #endif lines of a guard count as inside it
                my @in = @stack;
                if ($l =~ /^\s*#\s*(if|ifdef|ifndef)\b(.*)/) { push @stack, "$1$2"; @in = @stack; }
                elsif ($l =~ /^\s*#\s*(elif)\b(.*)/) { $stack[-1] = "$1$2 (after $stack[-1])"; @in = @stack; }
                elsif ($l =~ /^\s*#\s*else\b/) { $stack[-1] = "else of $stack[-1]"; @in = @stack; }
                elsif ($l =~ /^\s*#\s*endif\b/) { pop @stack; }
                next unless $added{$i};
                my @g = grep { /^if defined\(__APPLE__\) && defined\(__aarch64__\)\s*$/ } @in;
                printf "%s %s:%d [%s] %s", (@g ? "guarded" : "UNGUARDED"), $ARGV[2], $i, join(" > ", map { s/\s+/ /gr } @in), $l;
            }' "$WORK/guard.c" "$WORK/hunks" "$f"
    done
} >"$glog" 2>&1
nadd=$(grep -c -E '^(guarded|UNGUARDED) ' "$glog")
nung=$(grep -c '^UNGUARDED ' "$glog")
[ "$nung" = 0 ] && [ "$nadd" -gt 0 ] || ok=no
echo "--- added lines: $nadd, outside a defined(__APPLE__) && defined(__aarch64__) guard: $nung" >>"$glog"
# Source level: for every other system (__APPLE__ undefined) and for x86_64 macOS (__aarch64__
# undefined) each file is the wave base text.
for f in $WAVE_FILES; do
    for flags in "-U__APPLE__" "-D__APPLE__ -U__aarch64__"; do
        git -C "$WINE_DIR" show "$WINE_WAVE_BASE:$f" | unifdef $flags | cat -s >"$WORK/unifdef.base" 2>/dev/null
        git -C "$WINE_DIR" show "HEAD:$f" | unifdef $flags | cat -s >"$WORK/unifdef.new" 2>/dev/null
        if [ -s "$WORK/unifdef.new" ] && cmp -s "$WORK/unifdef.base" "$WORK/unifdef.new"; then
            echo "unifdef $flags $f: identical to $WINE_WAVE_BASE" >>"$ulog"
        else
            ok=no; echo "unifdef $flags $f: DIFFERS from $WINE_WAVE_BASE" >>"$ulog"
            diff "$WORK/unifdef.base" "$WORK/unifdef.new" | head -20 >>"$ulog"
        fi
    done
done
{
    echo "\$ git -C wine diff --stat $WINE_WAVE_BASE HEAD"
    git -C "$WINE_DIR" diff --stat "$WINE_WAVE_BASE" HEAD
    echo "\$ git -C wine log --format='%h %s' $WINE_WAVE_BASE..HEAD"
    git -C "$WINE_DIR" log --format='%h %s' "$WINE_WAVE_BASE..HEAD"
    echo "\$ git -C wine status --porcelain"
    git -C "$WINE_DIR" status --porcelain
    echo "\$ git diff --stat $SUPER_WAVE_BASE HEAD   (superproject)"
    git -C "$PROTON_DIR" diff --stat "$SUPER_WAVE_BASE" HEAD
    echo "\$ git diff --raw $SUPER_WAVE_BASE HEAD -- wine   (submodule pointer must be unchanged)"
    git -C "$PROTON_DIR" diff --raw "$SUPER_WAVE_BASE" HEAD -- wine
} >"$dlog" 2>&1
wbad=""
for f in $(git -C "$WINE_DIR" diff --name-only "$WINE_WAVE_BASE" HEAD); do
    case " $WAVE_FILES " in *" $f "*) ;; *) wbad="$wbad $f" ;; esac
done
wdirty=$(git -C "$WINE_DIR" status --porcelain --untracked-files=all | head -5)
sbad=$(git -C "$PROTON_DIR" diff --name-only "$SUPER_WAVE_BASE" HEAD | grep -v '^macos/')
[ -n "$(git -C "$PROTON_DIR" diff --raw "$SUPER_WAVE_BASE" HEAD -- wine)" ] && sbad="$sbad wine(pointer)"
[ -z "$wbad" ] && [ -z "$wdirty" ] && [ -z "$sbad" ] || ok=no
if [ $ok = yes ]; then
    pass 6 "$nadd lines added since $WINE_WAVE_BASE in $(echo $WAVE_FILES), all under defined(__APPLE__) && defined(__aarch64__); the files are the wave base text with __APPLE__ or __aarch64__ undefined; superproject changes only in macos/ ($glog, $ulog, $dlog)"
else
    fail 6 "unguarded lines: $nung of $nadd; wine unexpected:${wbad:- none}; wine uncommitted: '$wdirty'; superproject: '$(echo $sbad)' ($glog, $ulog, $dlog)"
fi
fi  # item 6

todo "4K pages, memory below 4 GB, MAP_JIT memory, hardware TSO and FEX have no items yet (they need LOADER_PROFILE); Wave 3b is not done"

echo
echo "== summary"
printf '%s\n' "${RESULTS[@]}" | tee "$EVIDENCE_DIR/check-summary.txt"
[ $FAILED = 0 ] || exit 1
[ $TODO = 0 ] || exit 3
exit 0
