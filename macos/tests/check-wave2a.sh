#!/bin/bash
#
# Wave 2a acceptance check for the native arm64 macOS Wine build: Wine maps nothing below 4 GB,
# KUSER_SHARED_DATA lives at a fixed address above 4 GB, and wineboot gets past
# virtual_alloc_first_teb to the first PE code.
#
#   macos/tests/check-wave2a.sh
#
# Items (pass/fail unless marked INFO):
#   1  no definition compiled for aarch64 hard-codes 0x7ffe0000; resolved value per target;
#      PE code generation unchanged for a configuration without the macOS define (Linux)
#   2  incremental macos/build-wine.sh
#   3  WINEDEBUG=+virtual and a syscall-level probe: no mapping request or result below 4 GB,
#      shared user data mapped at the configured address
#   4  wineboot -u gets past virtual_alloc_first_teb (ntdll.dll mapped); next failure summarised
#   5  Wave 1 regression: check-wave1.sh items 1-4 and 6
#   6  diff scope (wine files touched by this wave, superproject only macos/)
# Logs go to $EVIDENCE_DIR.

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PROTON_DIR=$(cd "$SCRIPT_DIR/../.." && pwd)
WINE_DIR=$PROTON_DIR/wine
BUILD_ROOT=${BUILD_ROOT:-/Users/annon/projects/proton-macos-build}
BUILD_DIR=${BUILD_DIR:-$BUILD_ROOT/wine-aarch64}
SRC_DIR=${SRC_DIR:-$BUILD_ROOT/wine-src}
TOOLCHAIN_DIR=${TOOLCHAIN_DIR:-/Users/annon/projects/proton-macos-toolchain/llvm-mingw-20261020-ucrt-macos-universal}
EVIDENCE_DIR=${EVIDENCE_DIR:-$BUILD_ROOT/evidence/wave2a}
WAVE1_EVIDENCE_DIR=${WAVE1_EVIDENCE_DIR:-$BUILD_ROOT/evidence/wave1}
# wine commit this wave starts from (tip of macos-arm64 after Wave 1) and the superproject equivalent
WINE_WAVE_BASE=${WINE_WAVE_BASE:-4dd560606138bd6cfcdd5c140efa3134ea7d70bb}
SUPER_WAVE_BASE=${SUPER_WAVE_BASE:-81346fed2c54ee8eada400b03c168e6e5c8f1c9f}
WINEBOOT_TIMEOUT=${WINEBOOT_TIMEOUT:-120}
# Wine files this wave may change, plus those of later waves (Wave 2b: TEB in a TSD slot instead
# of x18, see check-wave2b.sh item 7; Wave 3a: x18 opt-in and W^X page flipping, see check-wave3a.sh item 9;
# Wave 3b: the loader in an app bundle and the ARM64 ID registers, see check-wave3b.sh item 6;
# Wave 4: winemac.drv's table for DXMT, see check-wave4.sh item 7).
WAVE_FILES="configure.ac include/ddk/wdm.h dlls/ntdll/unix/virtual.c dlls/ntdll/thread.c dlls/kernelbase/sync.c dlls/kernel32/process.c dlls/kernel32/sync.c dlls/win32u/message.c include/winnt.h dlls/ntdll/signal_arm64.c dlls/ntdll/unix/signal_arm64.c include/minwindef.h dlls/ntdll/unix/unix_private.h dlls/ntdll/unix/file.c dlls/ntdll/unix/loader.c dlls/ntdll/unix/server.c loader/main.c dlls/ntdll/unix/system.c dlls/winemac.drv/macdrv.h dlls/winemac.drv/window.c dlls/uiautomationcore/uia_client.c dlls/winegstreamer/media-converter/media-converter.h dlls/winebus.sys/bus_iohid.c"
# Wine files that later waves change, which check-wave5.sh checks the guards of (PE code, guarded
# by configure's WINE_MACOS_AARCH64, and configure.ac itself)
LATER_WAVE_FILES="dlls/mfreadwrite/reader.c configure.ac dlls/winegstreamer/video_decoder.c dlls/winegstreamer/video_processor.c dlls/winemac.drv/cocoa_display.m programs/tabtip/tabtip.c dlls/win32u/font.c dlls/kernelbase/process.c dlls/win32u/vulkan.c dlls/winemac.drv/cocoa_app.m dlls/winemac.drv/cocoa_event.m dlls/winemac.drv/macdrv_cocoa.h dlls/winemac.drv/mouse.c dlls/ntdll/signal_arm64ec.c dlls/ntdll/unix/fsync.c server/fsync.c server/inproc_sync.c dlls/ntdll/unix/thread.c dlls/ntdll/unwind.c"
WAVE1_FILES="configure.ac dlls/ntdll/unix/fsync.c dlls/ntdll/unix/loader.c dlls/ntdll/unix/sync.c dlls/win32u/opengl.c server/fsync.c server/inproc_sync.c dlls/ntdll/unix/system.c"
# Definition sites of the shared user data address compiled for aarch64: object -> source
DEF_SITES="dlls/ntdll/aarch64-windows/thread.o:dlls/ntdll/thread.c
dlls/kernelbase/aarch64-windows/sync.o:dlls/kernelbase/sync.c
dlls/kernel32/aarch64-windows/process.o:dlls/kernel32/process.c
dlls/kernel32/aarch64-windows/sync.o:dlls/kernel32/sync.c
dlls/ntdll/unix/virtual.o:dlls/ntdll/unix/virtual.c
dlls/win32u/message.o:dlls/win32u/message.c"
# Remaining 0x7ffe0000 literals that are not compiled for aarch64 (file|regex|reason)
ALLOWED_LITERALS="include/ddk/wdm.h|define WINE_USER_SHARED_DATA_ADDR 0x7ffe0000|the Windows default the macro falls back to
dlls/ntdll/unix/virtual.c|char \*user_space_limit = \(char \*\)0x7ffe0000;|inside #ifndef _WIN64 in mmap_init (32-bit hosts only)
dlls/ntdll/unix/virtual.c|free_reserved_memory\( 0, \(char \*\)0x7ffe0000 \);|inside #ifndef __APPLE__ in virtual_set_large_address_space
dlls/ntoskrnl.exe/instr.c|wine_user_shared_data = \(BYTE \*\)0x7ffe0000;|inside #elif defined(__x86_64__) (x86_64 instruction emulation)
dlls/ntdll/unix/virtual.c|mmap_is_in_reserved_area\( \(void \*\)0x7ffe0000, page_size \)|the second mapping of the page, at its Windows address, made only where the loader could reserve the low 4 GB
dlls/ntdll/unix/virtual.c|void \*low = \(void \*\)0x7ffe0000;|the same second mapping
dlls/ntdll/unix/virtual.c|A second mapping of the page at its Windows address, 0x7ffe0000,|the comment on that second mapping"
# The second mapping is the one place where aarch64 macOS code names the Windows address: with
# the cross-architecture entitlement the low 4 GB can be mapped, and programs and Wine's 32-bit
# code read the page there. The definitions that Wine's own 64-bit code is built with stay
# relocated, which is what this item is about. So virtual.o may hold these two uses and no more.
ALLOWED_PREPROCESSED_VIRTUAL=2

mkdir -p "$EVIDENCE_DIR"
RESULTS=()
FAILED=0
# CHECK_ITEMS limits the run to some items (the build in item 2 is skipped unless listed).
CHECK_ITEMS=${CHECK_ITEMS:-"1 2 3 4 5 6"}
want() { case " $CHECK_ITEMS " in *" $1 "*) return 0 ;; esac; return 1; }
pass() { RESULTS+=("PASS  item $1: $2"); echo "PASS  item $1: $2"; }
fail() { RESULTS+=("FAIL  item $1: $2"); echo "FAIL  item $1: $2"; FAILED=1; }
info() { RESULTS+=("INFO  item $1: $2"); echo "INFO  item $1: $2"; }
run_timeout() { local t=$1; shift; perl -e 'alarm shift; exec @ARGV or die "exec: $!"' "$t" "$@"; }

WORK=$EVIDENCE_DIR/work
rm -rf "$WORK"; mkdir -p "$WORK"
MINGW_BIN=$TOOLCHAIN_DIR/bin
OBJDUMP=$MINGW_BIN/llvm-objdump
WINE=$BUILD_DIR/wine
SERVER=$BUILD_DIR/server/wineserver

# compile_cmd OBJ SRC: the build's own compile command for OBJ, on one line
compile_cmd() {
    (cd "$BUILD_DIR" && make -n -W "$SRC_DIR/$2" "$1" 2>/dev/null) \
        | sed -e ':a' -e '/\\$/N; s/\\\n//; ta' | grep -F -- "-c -o $1 " | head -1
}
# configured address (empty when configure didn't relocate it)
configured_addr() {
    sed -n 's/.*-DWINE_USER_SHARED_DATA_ADDR=\(0x[0-9a-fA-F]*\).*/\1/p' "$BUILD_DIR/Makefile" 2>/dev/null | head -1
}

########################################################################
# Item 2 first: the other items need a build.
########################################################################
if want 2; then
echo "== item 2: macos/build-wine.sh (incremental)"
blog=$EVIDENCE_DIR/build-incremental.log
df -h "$HOME" | tail -1 >"$EVIDENCE_DIR/disk-before.txt"
start=$(date +%s)
"$PROTON_DIR/macos/build-wine.sh" >"$blog" 2>&1
bstatus=$?
end=$(date +%s)
df -h "$HOME" | tail -1 >"$EVIDENCE_DIR/disk-after.txt"
echo "exit=$bstatus wall_seconds=$((end - start)) log=$blog" >"$EVIDENCE_DIR/build-incremental-result.txt"
if [ $bstatus = 0 ]; then
    pass 2 "build-wine.sh exit 0 in $((end - start))s ($blog)"
else
    fail 2 "build-wine.sh exited $bstatus ($blog)"
fi
fi  # item 2

USD=$(configured_addr)

########################################################################
# Item 1: no aarch64 definition hard-codes 0x7ffe0000; per-target value; Linux codegen unchanged
########################################################################
if want 1; then
echo "== item 1: shared user data address definitions"
slog=$EVIDENCE_DIR/item1-static.log
ok=yes
{
    echo "\$ grep -rn 0x7ffe0000 wine/dlls wine/include wine/loader wine/server (excluding tests/)"
    (cd "$WINE_DIR" && grep -rnIw '0x7ffe0000' dlls include loader server | grep -v '/tests/')
} >"$slog" 2>&1
while IFS= read -r hit; do
    file=${hit%%:*}
    allowed=no
    while IFS='|' read -r afile are areason; do
        if [ "$file" = "$afile" ] && echo "$hit" | grep -Eq "$are"; then allowed=yes; echo "allowed: $hit   -- $areason" >>"$slog"; fi
    done <<<"$ALLOWED_LITERALS"
    [ $allowed = yes ] || { ok=no; echo "NOT ALLOWED: $hit" >>"$slog"; }
done < <(cd "$WINE_DIR" && grep -rnIw '0x7ffe0000' dlls include loader server | grep -v '/tests/')
while IFS=: read -r obj src; do
    if grep -Eq 'user_shared_data *= *\(.*\) *WINE_USER_SHARED_DATA_ADDR' "$WINE_DIR/$src"; then
        echo "uses macro: $src: $(grep -E 'user_shared_data *= *\(' "$WINE_DIR/$src")" >>"$slog"
    else
        ok=no; echo "DOES NOT USE MACRO: $src" >>"$slog"
    fi
done <<<"$DEF_SITES"

# Preprocess every aarch64 definition site with the build's real command: the resolved value,
# and no 0x7ffe0000 anywhere in the preprocessed output.
plog=$EVIDENCE_DIR/item1-preprocessed.log
: >"$plog"
[ -n "$USD" ] || { ok=no; echo "no -DWINE_USER_SHARED_DATA_ADDR in $BUILD_DIR/Makefile" >>"$plog"; }
{ echo "configured address: ${USD:-<none>}"; echo "Makefile flags:"; grep -n 'WINE_USER_SHARED_DATA_ADDR' "$BUILD_DIR/Makefile" | grep -E '^[0-9]+:(EXTRACFLAGS|[a-z0-9_]+_EXTRACFLAGS) ='; } >>"$plog"
for site in $DEF_SITES "dlls/ntoskrnl.exe/aarch64-windows/instr.o:dlls/ntoskrnl.exe/instr.c"; do
    obj=${site%%:*}; src=${site#*:}
    cmd=$(compile_cmd "$obj" "$src")
    if [ -z "$cmd" ]; then ok=no; echo "$obj: no compile command found" >>"$plog"; continue; fi
    out=$WORK/$(echo "$obj" | tr / _).i
    (cd "$BUILD_DIR" && eval "${cmd/-c -o $obj /-E -o $out }") >>"$plog" 2>&1 || { ok=no; echo "$obj: preprocessing failed" >>"$plog"; continue; }
    def=$(grep -E 'user_shared_data *= *\(' "$out" | head -1 | sed 's/^ *//')
    n=$(grep -cw '0x7ffe0000' "$out")
    nallowed=0; [ "$obj" = dlls/ntdll/unix/virtual.o ] && nallowed=$ALLOWED_PREPROCESSED_VIRTUAL
    echo "aarch64-darwin $obj: ${def:-<no definition>} | 0x7ffe0000 occurrences: $n (allowed: $nallowed)" >>"$plog"
    [ "$n" = "$nallowed" ] || ok=no
    case $src in
        dlls/ntoskrnl.exe/*) ;;
        *) echo "$def" | grep -qi "${USD:-none}" || ok=no ;;
    esac
done

# Without the configure define (what a Linux or x86_64 macOS configure produces): the same PE
# commands resolve to 0x7ffe0000, and generate the same object code before and after this wave.
clog=$EVIDENCE_DIR/item1-linux-equivalent.log
: >"$clog"
BASE_TREE=$WORK/base; NEW_TREE=$WORK/new
# Object code comparisons pin __LINE__: assert() embeds line numbers, which any edit above it shifts.
SAME_LINES="-Wno-builtin-macro-redefined -D__LINE__=0"
mkdir -p "$BASE_TREE/include/ddk" "$NEW_TREE/include/ddk"
git -C "$WINE_DIR" show "$WINE_WAVE_BASE:include/ddk/wdm.h" >"$BASE_TREE/include/ddk/wdm.h"
cp "$WINE_DIR/include/ddk/wdm.h" "$NEW_TREE/include/ddk/wdm.h"
for site in $DEF_SITES; do
    obj=${site%%:*}; src=${site#*:}
    case $obj in */aarch64-windows/*) ;; *) continue ;; esac
    cmd=$(compile_cmd "$obj" "$src")
    [ -n "$cmd" ] || { ok=no; echo "$obj: no compile command" >>"$clog"; continue; }
    cmd=$(echo "$cmd" | sed -E 's/ -DWINE_USER_SHARED_DATA_ADDR=[^ ]*//')
    for tgt in aarch64 x86_64; do
        tcmd=${cmd/$MINGW_BIN\/aarch64-w64-mingw32-clang/$MINGW_BIN/$tgt-w64-mingw32-clang}
        tag=$(echo "$obj" | tr / _)-$tgt
        # resolved value from the real source
        (cd "$BUILD_DIR" && eval "${tcmd/-c -o $obj /-E -o $WORK/$tag.linux.i }") >>"$clog" 2>&1
        def=$(grep -E 'user_shared_data *= *\(' "$WORK/$tag.linux.i" 2>/dev/null | head -1 | sed 's/^ *//')
        echo "$tgt-windows (no define) $src: ${def:-<none>}" >>"$clog"
        echo "$def" | grep -qw '0x7ffe0000' || ok=no
        # object code: wave base source + base wdm.h vs current source + current wdm.h
        for v in base new; do
            tree=$WORK/$v
            mkdir -p "$tree/$(dirname "$src")"
            if [ $v = base ]; then git -C "$WINE_DIR" show "$WINE_WAVE_BASE:$src" >"$tree/$src"; else cp "$WINE_DIR/$src" "$tree/$src"; fi
            vcmd=${tcmd/ $SRC_DIR\/$src / $tree/$src }
            vcmd=${vcmd/-c -o $obj /-c -o $WORK/$tag.$v.o -I$tree/include -I$SRC_DIR/$(dirname "$src") }
            (cd "$BUILD_DIR" && eval "$vcmd -g0 -fmacro-prefix-map=$tree=/wine $SAME_LINES") >>"$clog" 2>&1 \
                || { ok=no; echo "$tag $v: compile failed" >>"$clog"; }
            "$OBJDUMP" -d -r -s "$WORK/$tag.$v.o" | sed 1,2d >"$WORK/$tag.$v.dis" 2>&1
        done
        if cmp -s "$WORK/$tag.base.dis" "$WORK/$tag.new.dis" && [ -s "$WORK/$tag.new.dis" ]; then
            echo "$tgt-windows (no define) $src: object code identical to $WINE_WAVE_BASE ($(wc -l <"$WORK/$tag.new.dis") lines of objdump -d -r -s)" >>"$clog"
        else
            ok=no; echo "$tgt-windows (no define) $src: OBJECT CODE DIFFERS from $WINE_WAVE_BASE" >>"$clog"
            diff "$WORK/$tag.base.dis" "$WORK/$tag.new.dis" | head -20 >>"$clog"
        fi
    done
done
# Unix side: the header default seen by Linux and x86_64 macOS unix code (no define).
# Linux libc headers aren't available here: ctype.h/string.h are empty stubs, enough to preprocess.
mkdir -p "$WORK/stubs"; : >"$WORK/stubs/ctype.h"; : >"$WORK/stubs/string.h"
printf '#include <stdarg.h>\n#include "windef.h"\n#include "winternl.h"\n#include "ddk/wdm.h"\nstatic const void *usd_probe = (void *)WINE_USER_SHARED_DATA_ADDR;\n' >"$WORK/usd_probe.c"
for tgt in x86_64-linux-gnu aarch64-linux-gnu x86_64-apple-macos11 arm64-apple-macos11; do
    for def in "" "-DWINE_USER_SHARED_DATA_ADDR=$USD"; do
        [ -n "$def" ] && [ -z "$USD" ] && continue
        res=$(clang --target=$tgt -E -nostdinc -isystem "$(clang -print-resource-dir)/include" -isystem "$WORK/stubs" \
              -D__WINESRC__ -DWINE_UNIX_LIB $def -I"$BUILD_DIR/include" -I"$WINE_DIR/include" "$WORK/usd_probe.c" 2>/dev/null | grep "usd_probe =")
        echo "unix $tgt ${def:-(no define)}: ${res:-<preprocessing failed>}" >>"$clog"
        if [ -z "$def" ]; then echo "$res" | grep -q '(void \*)0x7ffe0000;' || ok=no; fi
    done
done
# Unix sites compiled for x86_64 macOS (the guarded aarch64 code must not leak): same object code.
for site in "dlls/ntdll/unix/virtual.o:dlls/ntdll/unix/virtual.c" "dlls/win32u/message.o:dlls/win32u/message.c"; do
    obj=${site%%:*}; src=${site#*:}
    cmd=$(compile_cmd "$obj" "$src" | sed -E 's/ -DWINE_USER_SHARED_DATA_ADDR=[^ ]*//')
    tag=$(echo "$obj" | tr / _)-x86_64-macos
    for v in base new; do
        tree=$WORK/$v
        mkdir -p "$tree/$(dirname "$src")"
        if [ $v = base ]; then git -C "$WINE_DIR" show "$WINE_WAVE_BASE:$src" >"$tree/$src"; else cp "$WINE_DIR/$src" "$tree/$src"; fi
        vcmd=${cmd/ $SRC_DIR\/$src / $tree/$src }
        vcmd=${vcmd/-c -o $obj /-c -o $WORK/$tag.$v.o -I$tree/include -I$SRC_DIR/$(dirname "$src") }
        (cd "$BUILD_DIR" && eval "$vcmd -target x86_64-apple-macos11 -g0 -fmacro-prefix-map=$tree=/wine $SAME_LINES") >"$WORK/$tag.$v.err" 2>&1
        objdump -d -r -s "$WORK/$tag.$v.o" 2>/dev/null | sed 1,2d >"$WORK/$tag.$v.dis"
    done
    if [ -s "$WORK/$tag.new.dis" ] && cmp -s "$WORK/$tag.base.dis" "$WORK/$tag.new.dis"; then
        echo "x86_64-apple-macos (no define) $src: object code identical to $WINE_WAVE_BASE" >>"$clog"
    elif [ ! -s "$WORK/$tag.new.dis" ]; then
        echo "x86_64-apple-macos $src: could not compile with this host's config.h (not checked): $(head -3 "$WORK/$tag.new.err" | tr '\n' ' ')" >>"$clog"
    else
        ok=no; echo "x86_64-apple-macos (no define) $src: OBJECT CODE DIFFERS from $WINE_WAVE_BASE" >>"$clog"
        diff "$WORK/$tag.base.dis" "$WORK/$tag.new.dis" | head -20 >>"$clog"
    fi
done
if [ $ok = yes ]; then
    pass 1 "aarch64 sites use WINE_USER_SHARED_DATA_ADDR=$USD, no 0x7ffe0000 in their preprocessed output but the second mapping in virtual.o; without the define every target resolves to 0x7ffe0000 and PE code is unchanged ($slog, $plog, $clog)"
else
    fail 1 "see $slog, $plog, $clog"
fi
fi  # item 1

########################################################################
# Syscall-level probe used by item 3: logs every mmap / mach_vm_map / mach_vm_allocate whose
# requested or resulting address is below 4 GB (LOW), or that touches the shared user data (USD).
########################################################################
PROBE_SRC=$WORK/lowmem_probe.c
PROBE=$WORK/lowmem_probe.dylib
cat >"$PROBE_SRC" <<'EOF'
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <mach-o/dyld.h>

#define FOUR_GB 0x100000000ULL
static int log_fd = -1;
static uint64_t watch;

static void out( const char *fmt, ... )
{
    char buf[512];
    va_list ap;
    int len;
    if (log_fd < 0)
    {
        const char *p = getenv( "LOWMEM_PROBE_LOG" );
        log_fd = p ? open( p, O_WRONLY | O_APPEND | O_CREAT, 0644 ) : 2;
    }
    len = snprintf( buf, sizeof(buf), "[%d] ", getpid() );
    va_start( ap, fmt );
    len += vsnprintf( buf + len, sizeof(buf) - len, fmt, ap );
    va_end( ap );
    if (len > (int)sizeof(buf)) len = sizeof(buf);
    write( log_fd, buf, len );
}

static const char *tag( uint64_t req, uint64_t res, uint64_t size )
{
    if ((req && req < FOUR_GB) || (res && res < FOUR_GB)) return "LOW";
    if (watch && ((req >= watch && req < watch + 0x10000) || (res >= watch && res < watch + 0x10000) ||
                  (req < watch && req + size > watch))) return "USD";
    return NULL;
}

__attribute__((constructor)) static void init( void )
{
    const char *w = getenv( "LOWMEM_PROBE_WATCH" );
    if (w) watch = strtoull( w, NULL, 16 );
    out( "probe loaded, watching %#llx\n", (unsigned long long)watch );
    /* the process's address floor: __PAGEZERO ends at the slid main executable header */
    out( "floor %p\n", (const void *)_dyld_get_image_header( 0 ) );
}

static void *probe_mmap( void *addr, size_t len, int prot, int flags, int fd, off_t off )
{
    void *ret = mmap( addr, len, prot, flags, fd, off );
    const char *t = tag( (uintptr_t)addr, ret == MAP_FAILED ? 0 : (uintptr_t)ret, len );
    if (t) out( "%s mmap(%p, %#zx, prot %d, flags %#x%s, fd %d) -> %p\n", t, addr, len, prot, flags,
                (flags & MAP_FIXED) ? " FIXED" : "", fd, ret );
    return ret;
}

static kern_return_t probe_mach_vm_map( vm_map_t task, mach_vm_address_t *addr, mach_vm_size_t size,
                                        mach_vm_offset_t mask, int flags, mem_entry_name_port_t obj,
                                        memory_object_offset_t off, boolean_t copy, vm_prot_t cur,
                                        vm_prot_t max, vm_inherit_t inh )
{
    uint64_t req = (flags & VM_FLAGS_ANYWHERE) ? 0 : *addr;
    kern_return_t kr = mach_vm_map( task, addr, size, mask, flags, obj, off, copy, cur, max, inh );
    const char *t = tag( req, kr ? 0 : *addr, size );
    if (t) out( "%s mach_vm_map(%#llx, %#llx, flags %#x) -> %d %#llx\n", t, (unsigned long long)req,
                (unsigned long long)size, flags, kr, (unsigned long long)*addr );
    return kr;
}

static kern_return_t probe_mach_vm_allocate( vm_map_t task, mach_vm_address_t *addr, mach_vm_size_t size, int flags )
{
    uint64_t req = (flags & VM_FLAGS_ANYWHERE) ? 0 : *addr;
    kern_return_t kr = mach_vm_allocate( task, addr, size, flags );
    const char *t = tag( req, kr ? 0 : *addr, size );
    if (t) out( "%s mach_vm_allocate(%#llx, %#llx, flags %#x) -> %d %#llx\n", t, (unsigned long long)req,
                (unsigned long long)size, flags, kr, (unsigned long long)*addr );
    return kr;
}

#define INTERPOSE(repl, orig) \
    __attribute__((used)) static const struct { const void *r; const void *o; } interpose_##orig \
    __attribute__((section("__DATA,__interpose"))) = { (const void *)repl, (const void *)orig }
INTERPOSE( probe_mmap, mmap );
INTERPOSE( probe_mach_vm_map, mach_vm_map );
INTERPOSE( probe_mach_vm_allocate, mach_vm_allocate );
EOF
cc -dynamiclib -O1 -o "$PROBE" "$PROBE_SRC" >"$WORK/lowmem_probe.build.log" 2>&1 || echo "probe build failed" >>"$WORK/lowmem_probe.build.log"

# check_virtual_log LOG: print virtual: lines naming an address below 4 GB
# (sizes, masks, protections, search limits and NULL "anywhere" requests are not addresses)
check_virtual_log() {
    perl -ne '
        next unless /(?:^|:)(?:trace|err|warn|fixme):virtual:/;
        next if /:virtual:(NtQueryVirtualMemory|NtProtectVirtualMemory|NtReadVirtualMemory|NtFreeVirtualMemory|virtual_handle_fault|get_vprot_range|virtual_check_buffer)/;
        my $l = $_;
        $l =~ s/\blimit 0x[0-9a-f]+-0x[0-9a-f]+//gi;
        $l =~ s/\b(size|mask|top_down|unix_prot|status|align|zero_bits|handle|process|access|alloc_type|off|offset|protect|type|flags)[ =]+0x[0-9a-f]+//gi;
        for my $t ($l =~ /\b0x([0-9a-fA-F]+)\b/g) { my $v = hex($t); if ($v && $v < 0x100000000) { print "$.: $_"; last } }
    ' "$1"
}

# floor_errors LOG FLOOR: err:virtual lines naming an address below FLOOR (the host's real floor;
# unix_prot values are protections, not addresses)
floor_errors() {
    perl -ne 'BEGIN { $f = hex(shift) } next unless /(?:^|:)err:virtual:/; s/\bunix_prot 0x[0-9a-f]+//;
        for my $t (/\b0x([0-9a-fA-F]+)\b/g) { my $v = hex($t); if ($v && $v < $f) { print "$.: $_"; last } }' "$2" "$1"
}
# behind_usd LOG USD: views starting in the 16 MB right behind the 64K shared user data reservation
# (a bottom-up allocation that skipped the whole range between the floor and the shared user data)
behind_usd() {
    perl -ne 'BEGIN { $u = hex(shift) } print "$.: $_" if /View: 0x([0-9a-f]+) - / && hex($1) >= $u + 0x10000 && hex($1) < $u + 0x10000 + 0x1000000' "$2" "$1"
}
# low_vallocs LOG FLOOR: anonymous views starting between FLOOR and the exe image base 0x140000000
low_vallocs() {
    perl -ne 'BEGIN { $f = hex(shift) } print "$.: $_" if /View: 0x([0-9a-f]+) - .*\(valloc\)/ && hex($1) >= $f && hex($1) < 0x140000000' "$2" "$1"
}

# classify_addr LOG ADDR: the "(image)" view of LOG containing ADDR, if any
classify_addr() {
    perl -e '
        my ($log, $addr) = @ARGV; my $a = hex($addr); my @v;
        open my $f, "<", $log or exit;
        while (<$f>) { push @v, [hex($1), hex($2), $1, $2] if /View: 0x([0-9a-f]+) - 0x([0-9a-f]+) .*\((?:builtin )?image\)/ }
        for (@v) { if ($a >= $_->[0] && $a <= $_->[1]) { print "in PE image view 0x$_->[2]-0x$_->[3]\n"; exit } }
    ' "$1" "$2"
}
# classify_faults LOG: each exception Wine reports, with the PE image view its address is in
classify_faults() {
    grep -E 'virtual_setup_exception|seh:.*(code|addr)=' "$1" | while IFS= read -r line; do
        a=$(echo "$line" | sed -n 's/.* addr[= ]\(0x[0-9a-f]*\).*/\1/p')
        w=$(classify_addr "$1" "${a:-0}")
        echo "$line  -> ${w:-not in a PE image}"
    done
}

########################################################################
# Item 3: +virtual run under the probe: nothing below 4 GB, USD at the configured address
########################################################################
if want 3; then
echo "== item 3: no memory below 4 GB, shared user data above it"
# Since Wave 3b the loader asks once per process for 16K at 0x10000, which only the
# cross-architecture entitlement allows, to find out whether it has it. Without the entitlement
# the request fails and the loader goes on as before. That one failed request is not a use of
# low memory; any other request below 4 GB, and any that succeeds, still fails this item.
ENTITLEMENT_PROBE=' LOW mmap\(0x10000, 0x4000, prot 0, flags 0x[0-9a-f]+ FIXED, fd -1\) -> 0xffffffffffffffff$'
vlog=$EVIDENCE_DIR/item3-virtual.log
plog3=$EVIDENCE_DIR/item3-probe.log
alog=$EVIDENCE_DIR/item3-analysis.log
PREFIX=$BUILD_DIR/wave2a-prefix-virtual
: >"$plog3"
if [ ! -x "$WINE" ] || [ ! -f "$PROBE" ]; then
    fail 3 "wine not built or probe not built ($WORK/lowmem_probe.build.log)"
else
    rm -rf "$PREFIX"; mkdir -p "$PREFIX"
    echo "\$ DYLD_INSERT_LIBRARIES=$PROBE LOWMEM_PROBE_WATCH=${USD:-0} WINEPREFIX=$PREFIX WINEDEBUG=+virtual $WINE wineboot -u   (timeout ${WINEBOOT_TIMEOUT}s)" >"$vlog"
    # SIP strips DYLD_* when launching the system perl used for the timeout: set it inside perl.
    PROBE_DYLIB=$PROBE LOWMEM_PROBE_LOG=$plog3 LOWMEM_PROBE_WATCH=${USD:-0} WINEPREFIX=$PREFIX WINEDEBUG=+virtual \
        perl -e '$ENV{DYLD_INSERT_LIBRARIES} = $ENV{PROBE_DYLIB}; alarm shift; exec @ARGV or die "exec: $!"' \
        "$WINEBOOT_TIMEOUT" "$WINE" wineboot -u >>"$vlog" 2>&1
    echo "exit=$?" >>"$vlog"
    WINEPREFIX=$PREFIX run_timeout 30 "$SERVER" -k >/dev/null 2>&1
    WINEPREFIX=$PREFIX run_timeout 30 "$SERVER" -w >/dev/null 2>&1
    rm -rf "$PREFIX"
    ok=yes
    FLOOR=$(sed -n 's/.* floor \(0x[0-9a-f]*\)$/\1/p' "$plog3" | sort | tail -1)
    {
        echo "configured shared user data address: ${USD:-<none>}"
        if [ -n "$USD" ]; then
            a=$((USD))
            if [ $a -ge $((0x100000000)) ] && [ $((a & 0xffff)) = 0 ] && [ $((a + 0x10000)) -le $((0x7fffffff0000)) ] \
               && { [ $a -lt $((0x140000000)) ] || [ $a -ge $((0x7000000000)) ]; }; then
                echo "address constraints: >= 4 GB, 64K aligned, below 0x7fffffff0000, outside 0x140000000-0x7000000000 (image bases, dyld shared region, kernel guard): ok"
            else
                echo "address constraints: VIOLATED"; ok=no
            fi
        else
            ok=no
        fi
        echo "--- probe: loaded in processes"
        grep -c 'probe loaded' "$plog3"
        echo "--- probe: LOW (request or result below 4 GB), other than the loader's failed entitlement probe"
        grep ' LOW ' "$plog3" | grep -v -E "$ENTITLEMENT_PROBE"
        echo "--- probe: the loader's failed entitlement probe (at most one per process)"
        grep ' LOW ' "$plog3" | grep -c -E "$ENTITLEMENT_PROBE"
        echo "--- probe: USD (shared user data range)"
        grep ' USD ' "$plog3"
        echo "--- +virtual lines naming an address below 4 GB"
        check_virtual_log "$vlog"
        echo "--- +virtual lines at the shared user data address"
        [ -n "$USD" ] && grep -n -i "$(printf '%x' $((USD)))" "$vlog" | head -20
        echo "--- process floors (slid main executable header, from the probe); highest: ${FLOOR:-?}"
        grep ' floor ' "$plog3"
        echo "--- err:virtual lines below the highest floor (must be none)"
        floor_errors "$vlog" "${FLOOR:-0x100000000}"
        echo "--- views starting right behind the shared user data reservation (must be none)"
        [ -n "$USD" ] && behind_usd "$vlog" "$USD"
        echo "--- anonymous views between the floor and 0x140000000 (bottom-up allocations; must be some)"
        low_vallocs "$vlog" "${FLOOR:-0x100000000}" | head -10
        echo "--- errors ($(grep -c 'err:virtual' "$vlog") err:virtual lines)"
        grep -n -E 'err:virtual|failed to map the shared user data|failed to remap the process USD' "$vlog" | head -20
    } >"$alog" 2>&1
    grep -q 'probe loaded' "$plog3" || ok=no
    [ "$(grep ' LOW ' "$plog3" | grep -c -v -E "$ENTITLEMENT_PROBE")" = 0 ] || ok=no
    nprobe=$(grep ' LOW ' "$plog3" | grep -c -E "$ENTITLEMENT_PROBE")
    [ "$nprobe" -le "$(grep -c 'probe loaded' "$plog3")" ] || ok=no
    [ -n "$(check_virtual_log "$vlog")" ] && ok=no
    if [ -n "$USD" ]; then
        usdhex=$(printf '0x%x' $((USD)))
        # reserved, allocated (view dump) and remapped from the server's section, all at the address
        grep -Eq " USD mach_vm_map\($usdhex, .* -> 0 $usdhex" "$plog3" || ok=no
        grep -Eq "View: $usdhex - " "$vlog" || ok=no
        grep -Eq " USD mmap\($usdhex, .*FIXED, fd [0-9]+\) -> $usdhex" "$plog3" || ok=no
    fi
    grep -q 'failed to map the shared user data\|failed to remap the process USD' "$vlog" && ok=no
    # The address space must start at the host's real floor: no mapping errors below it, and
    # bottom-up allocations just above it rather than behind the shared user data.
    [ -n "$FLOOR" ] || ok=no
    [ -n "$(floor_errors "$vlog" "${FLOOR:-0x100000000}")" ] && ok=no
    [ -n "$USD" ] && [ -n "$(behind_usd "$vlog" "$USD")" ] && ok=no
    [ -n "$(low_vallocs "$vlog" "${FLOOR:-0x100000000}")" ] || ok=no
    if [ $ok = yes ]; then
        pass 3 "no mapping below 4 GB (probe + +virtual; the loader's entitlement probe failed $nprobe times and nothing else asked), no err:virtual below the floor ($FLOOR), bottom-up allocations above the floor, shared user data reserved, allocated and mapped at $USD ($alog)"
    else
        fail 3 "see $alog ($vlog, $plog3)"
    fi
fi
fi  # item 3

########################################################################
# Item 4: wineboot -u past virtual_alloc_first_teb, to the next failure
########################################################################
if want 4; then
echo "== item 4: wineboot -u"
wlog=$EVIDENCE_DIR/item4-wineboot.log
wsum=$EVIDENCE_DIR/item4-summary.txt
PREFIX=$BUILD_DIR/wave2a-prefix-boot
if [ ! -x "$WINE" ] || [ ! -x "$SERVER" ]; then
    fail 4 "wine/wineserver not built"
else
    rm -rf "$PREFIX"; mkdir -p "$PREFIX"
    echo "\$ WINEPREFIX=$PREFIX WINEDEBUG=+seh,+loaddll,+process,+virtual $WINE wineboot -u   (timeout ${WINEBOOT_TIMEOUT}s)" >"$wlog"
    WINEPREFIX=$PREFIX WINEDEBUG=+seh,+loaddll,+process,+virtual run_timeout "$WINEBOOT_TIMEOUT" "$WINE" wineboot -u >>"$wlog" 2>&1
    wstatus=$?
    echo "exit=$wstatus" >>"$wlog"
    WINEPREFIX=$PREFIX run_timeout 30 "$SERVER" -k >/dev/null 2>&1
    WINEPREFIX=$PREFIX run_timeout 30 "$SERVER" -w >/dev/null 2>&1
    rm -rf "$PREFIX"
    # PE code reached: an exception (or loaddll trace) whose address lies in a mapped PE image view
    pe_faults=$(classify_faults "$wlog")
    {
        echo "exit=$wstatus (142 = timed out)"
        echo "--- shared user data / first TEB"
        grep -n -E 'failed to map the shared user data|virtual_alloc_first_teb|failed to remap the process USD|View: '"${USD:-none}"' ' "$wlog"
        echo "--- PE images mapped (only after virtual_alloc_first_teb)"
        grep -n -E 'View: .*\((builtin )?image\)' "$wlog" | head -20
        echo "--- exceptions, by containing image view"
        classify_faults "$wlog"
        echo "--- seh / loaddll / error lines"
        grep -n -m 40 -E 'seh:|loaddll:|exception|Unhandled|err:|wine: ' "$wlog"
        echo "--- last 30 lines"
        tail -30 "$wlog"
    } >"$wsum" 2>&1
    if ! grep -q 'failed to map the shared user data' "$wlog" && \
       { echo "$pe_faults" | grep -q 'in PE image' || grep -q ':trace:loaddll:' "$wlog"; }; then
        pass 4 "past virtual_alloc_first_teb into PE code; wineboot exit=$wstatus; next failure: $(echo "$pe_faults" | grep -m1 'in PE image' | cut -c1-120) ($wsum, $wlog)"
    else
        fail 4 "did not reach PE code (exit=$wstatus; $wsum, $wlog)"
    fi

    # INFO: the first fault of the real front end under lldb (Wine's own handler hides it):
    # pc, x18 and the faulting instruction, matched against ntdll.dll.
    llog=$EVIDENCE_DIR/item4-lldb-first-fault.log
    if command -v lldb >/dev/null; then
        rm -rf "$PREFIX"; mkdir -p "$PREFIX"
        run_timeout "$WINEBOOT_TIMEOUT" lldb --batch \
            -o "process launch --environment WINEPREFIX=$PREFIX --environment WINEDEBUG=+virtual -- wineboot -u" \
            -o "continue" -o "continue" \
            -k "register read pc x18 sp lr" -k "memory read -s4 -fx -c1 \$pc" -k "process kill" \
            -- "$WINE" >"$llog" 2>&1
        WINEPREFIX=$PREFIX run_timeout 30 "$SERVER" -k >/dev/null 2>&1
        WINEPREFIX=$PREFIX run_timeout 30 "$SERVER" -w >/dev/null 2>&1
        rm -rf "$PREFIX"
        stop=$(grep -m1 'stop reason = EXC_' "$llog" | sed 's/.*stop reason = //')
        pc=$(sed -n 's/^ *pc = \(0x[0-9a-f]*\).*/\1/p' "$llog" | head -1)
        x18=$(sed -n 's/^ *x18 = \(0x[0-9a-f]*\).*/\1/p' "$llog" | head -1)
        insn=$(sed -n 's/^0x[0-9a-f]*: \(0x[0-9a-f]*\).*/\1/p' "$llog" | head -1)
        where=$(classify_addr "$llog" "$pc")
        sym=""
        if [ -n "$pc" ] && [ -n "$where" ]; then
            vstart=$(echo "$where" | sed -n 's/.*view \(0x[0-9a-f]*\)-.*/\1/p')
            ntdll=$BUILD_DIR/dlls/ntdll/aarch64-windows/ntdll.dll
            ibase=0x$("$OBJDUMP" -p "$ntdll" | sed -n 's/^ImageBase *//p')
            addr=$((ibase + pc - vstart))
            fbytes=$("$OBJDUMP" -d --start-address=$addr --stop-address=$((addr + 4)) "$ntdll" | sed -n 's/^ *[0-9a-f]*: \([0-9a-f]\{8\}\) .*/\1/p' | head -1)
            [ "0x$fbytes" = "$insn" ] && sym="ntdll.dll $(printf '%#x' $addr) $("$MINGW_BIN/llvm-symbolizer" --obj="$ntdll" $addr | tr '\n' ' ')"
        fi
        {
            echo "--- first fault of $WINE wineboot -u under lldb"
            echo "stop: ${stop:-<none>}"
            echo "pc=${pc:-?} x18=${x18:-?} instruction=${insn:-?}"
            echo "pc ${where:-not in a mapped PE image view}"
            echo "symbol: ${sym:-<instruction bytes did not match ntdll.dll>}"
        } | tee -a "$wsum" >"$WORK/item4-lldb.txt"
        info 4 "first fault under lldb: ${stop:-?} pc=${pc:-?} x18=${x18:-?} ${sym:-} ($llog)"
    fi
fi
fi  # item 4

########################################################################
# Item 5: Wave 1 regression (items 1-4 and 6)
########################################################################
if want 5; then
echo "== item 5: Wave 1 regression"
W1DIR=$EVIDENCE_DIR/wave1-regression
rm -rf "$W1DIR"; mkdir -p "$W1DIR"
# Wave 1 item 2 also requires its recorded clean build; reuse that record instead of a clean rebuild.
cp "$WAVE1_EVIDENCE_DIR/build-clean-result.txt" "$W1DIR/" 2>/dev/null
EVIDENCE_DIR=$W1DIR WINE_ALLOWED_FILES="$WAVE1_FILES $WAVE_FILES" \
    "$PROTON_DIR/macos/tests/check-wave1.sh" >"$W1DIR/check-wave1.out" 2>&1
w1ok=yes
for i in 1 2 3 4 6; do
    grep -q "^PASS  item $i:" "$W1DIR/check-summary.txt" 2>/dev/null || w1ok=no
done
if [ $w1ok = yes ]; then
    pass 5 "check-wave1.sh items 1-4 and 6 pass; item 5: $(grep '^INFO  item 5' "$W1DIR/check-summary.txt" | cut -c1-80)... ($W1DIR/check-summary.txt)"
else
    fail 5 "check-wave1.sh regressions ($W1DIR/check-summary.txt)"
fi
fi  # item 5

########################################################################
# Item 6: diff scope
########################################################################
if want 6; then
echo "== item 6: diff scope"
dlog=$EVIDENCE_DIR/item6-diff.log
{
    echo "\$ git -C wine diff --stat $WINE_WAVE_BASE"
    git -C "$WINE_DIR" diff --stat "$WINE_WAVE_BASE"
    echo "\$ git -C wine log --format='%h %s' $WINE_WAVE_BASE..HEAD"
    git -C "$WINE_DIR" log --format='%h %s' "$WINE_WAVE_BASE..HEAD"
    echo "\$ git -C wine diff -U0 $WINE_WAVE_BASE | grep '^@@\\|^+++'   (hunks)"
    git -C "$WINE_DIR" diff -U0 "$WINE_WAVE_BASE" | grep '^@@\|^+++'
    echo "\$ git diff --stat $SUPER_WAVE_BASE   (superproject)"
    git -C "$PROTON_DIR" diff --stat "$SUPER_WAVE_BASE"
    echo "\$ git diff --raw $SUPER_WAVE_BASE -- wine   (submodule pointer; working-tree 'M wine' is the uncommitted checkout)"
    git -C "$PROTON_DIR" diff --cached --raw "$SUPER_WAVE_BASE" -- wine
} >"$dlog" 2>&1
wbad=""
for f in $(git -C "$WINE_DIR" diff --name-only "$WINE_WAVE_BASE"); do
    case " $WAVE_FILES $LATER_WAVE_FILES " in *" $f "*) ;; *) wbad="$wbad $f" ;; esac
done
wuntracked=$(git -C "$WINE_DIR" status --porcelain --untracked-files=all | grep -v '^ M\|^M ' | head -5)
sbad=$(git -C "$PROTON_DIR" diff --name-only "$SUPER_WAVE_BASE" HEAD | grep -v '^macos/' | grep -v -x -F -e lsteamclient/unixlib.cpp -e lsteamclient/unix_steam_input_manual.cpp)
if [ -z "$wbad" ] && [ -z "$wuntracked" ] && [ -z "$sbad" ]; then
    pass 6 "wine changes only in: $(git -C "$WINE_DIR" diff --name-only "$WINE_WAVE_BASE" | tr '\n' ' ')superproject commits only under macos/ ($dlog)"
else
    fail 6 "wine unexpected:${wbad:- none} untracked: '${wuntracked}' superproject outside macos/: '$(echo $sbad)' ($dlog)"
fi
fi  # item 6

echo
echo "== summary"
printf '%s\n' "${RESULTS[@]}" | tee "$EVIDENCE_DIR/check-summary.txt"
exit $FAILED
