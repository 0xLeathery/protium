#!/bin/bash
#
# Records how busy a running game's threads are, from the moment the game's process is there
# until it exits, without stopping the game.
#
#   macos/tests/gamewatch.sh <part of the game's exe name> [output directory]
#
# e.g.  macos/tests/gamewatch.sh s2_sp64_ship
#
# Start it before or after the game; it waits up to an hour for the process. It reads each
# thread's CPU time (macos/tests/threadcpu.c) and the list of open files, which stops nothing.
#
# STACKS=1 also takes one second of macOS's sample each round, which says where each busy
# thread is. THAT IS FELT IN THE GAME: sample stops the threads for every stack it reads. With
# it running, Call of Duty: WWII stuttered every few seconds and lost its sound, and without
# it the same build played smoothly. Use it to find out what a thread does, never while
# someone judges how the game plays, and tell them it is on.
#
# <output directory>/log.txt (default $BUILD_ROOT/evidence/gamewatch/<date-time>) gets, per round:
#   12:03:13 #22 cpu 284 server 19 loader 55 mem 7419 free 61 swap 812 video [normandy_load.bik]
#      Main 84, Server 80, Backend 54, ?#5 95, Database 55
# cpu and server are the per cent of a core the game and the wineserver use; loader is that
# of the thread named Database (Call of Duty's level loader; 0 when it is idle or absent);
# mem is the game's memory footprint in MB, free the per cent of the Mac's memory that is
# free, swap the MB of swap in use; video lists the .bik files the game has open; the second
# line is every thread over 3%. A game that slows down as it goes on shows here whether its
# memory grows and the Mac runs out of it. (Whether the Mac throttles for heat is not here:
# an Apple Silicon Mac only tells root, through powermetrics.)
# With STACKS=1 a third part names where each busy thread is ("jit" is translated x86 code,
# "pe" code of a Windows module, anything else a function of Wine's Unix side or of macOS),
# and every fifth raw sample is kept as s<n>.txt.
#
# The end prints each span in which a video was open and when the loader went quiet after it
# began: how long a level's load took, and whether it outlasted its video.

set -u
name=${1:?usage: gamewatch.sh <part of the exe name> [output directory]}
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
BUILD_ROOT=${BUILD_ROOT:-/Users/annon/projects/proton-macos-build}
STACKS=${STACKS:-}
out=${2:-$BUILD_ROOT/evidence/gamewatch/$(date +%Y%m%d-%H%M%S)}
mkdir -p "$out"
log=$out/log.txt
: >"$log"
cc -O2 -o "$out/threadcpu" "$SCRIPT_DIR/threadcpu.c" || { echo "threadcpu.c did not build"; exit 1; }

# the game, not the steam.exe that started it: of the processes with the name, the largest
game_pid() {
    ps -eo pid=,rss=,command= | grep -F "$name" | grep -v -e 'steam\.exe' -e 'gamewatch\.sh' -e 'grep' \
        | sort -k2 -n | tail -1 | awk '{print $1}'
}

pid=""
for _ in $(seq 1 1800); do
    pid=$(game_pid)
    [ -n "$pid" ] && break
    sleep 2
done
[ -n "$pid" ] || { echo "no process with '$name' in its name within an hour" | tee -a "$log"; exit 1; }
echo "watching pid $pid${STACKS:+ WITH STACKS (the game will stutter)}, log $log"

# where the busy threads of a raw sample are
stacks() {
    python3 - "$1" <<'EOF'
import collections, re, sys
lines = open(sys.argv[1], errors='replace').read().split('\n')
threads = collections.OrderedDict()
cur = None
for l in lines:
    m = re.match(r'^    (\d+) (Thread_\S+.*)', l)
    if m:
        cur = (re.sub(r'Thread_\d+:? ?', '', m.group(2))[:28] or '?') + '#' + str(len(threads))
        threads[cur] = []
        continue
    if l.startswith('Total number'): break
    if cur: threads[cur].append(l)
idle = ('__ulock_wait2', '__workq_kernreturn', 'mach_msg2_trap', 'kevent64', 'semaphore_wait',
        '__psynch_cvwait', 'start_wqthread', 'swtch_pri', '_pthread_wqthread')
def where(text):
    m = re.search(r'\?\?\?  \(in <unknown binary>\)\s+\[0x([0-9a-f]+)\]', text)
    if m: return 'jit' if int(m.group(1), 16) >= 0x700000000000 else 'pe'
    return re.sub(r'\s+\(in ([^)]*)\).*', r'<\1>', text)[:40]
for name, body in threads.items():
    leaf = collections.Counter()
    for i, l in enumerate(body):
        m = re.match(r'^([ +!:|]*)(\d+) (.*)', l)
        if not m: continue
        nxt = re.match(r'^([ +!:|]*)(\d+) ', body[i + 1]) if i + 1 < len(body) else None
        if nxt and len(nxt.group(1)) > len(m.group(1)): continue
        leaf[where(m.group(3))] += int(m.group(2))
    total = sum(leaf.values())
    busy = sum(v for k, v in leaf.items() if not k.startswith(idle))
    if total and busy * 5 > total:
        print('      %s %d%%: %s' % (name, 100 * busy // total, ', '.join(
            '%s %d' % (k, v) for k, v in leaf.most_common(6) if not k.startswith(idle))))
EOF
}

n=0
while kill -0 "$pid" 2>/dev/null; do
    n=$((n + 1))
    video=$(lsof -p "$pid" 2>/dev/null | awk '/\.bik$/ {print $NF}' | sed 's|.*/||' | tr '\n' ' ' | sed 's/ $//')
    cpu=$(ps -o pcpu= -p "$pid" | tr -d ' ')
    server=$(ps -o pcpu= -p "$(pgrep -x wineserver | head -1)" 2>/dev/null | tr -d ' ')
    threads=$("$out/threadcpu" "$pid" 1 2>/dev/null)
    loader=$(printf '%s' "$threads" | sed -n 's/.*Database \([0-9]*\).*/\1/p')
    mem=$(printf '%s' "$threads" | sed -n 's/^mem \([0-9]*\) .*/\1/p')
    swap=$(sysctl -n vm.swapusage | sed -n 's/.*used = \([0-9]*\).*/\1/p')
    echo "$(date +%T) #$n cpu ${cpu%.*} server ${server%.*} loader ${loader:-0} mem ${mem:--} free $(sysctl -n kern.memorystatus_level) swap ${swap:--} video [$video]" >>"$log"
    echo "   ${threads#mem * | }" >>"$log"
    if [ -n "$STACKS" ]; then
        raw=$out/s$n.txt
        sample "$pid" 1 -file "$raw" >/dev/null 2>&1
        stacks "$raw" >>"$log" 2>/dev/null
        [ $((n % 5)) -ne 0 ] && rm -f "$raw"
    fi
    [ "$n" -ge 5000 ] && break
    sleep 2
done
echo "$(date +%T) the game ended" >>"$log"

# each span with a video open, and when the loader was quiet (under 10%) for three rounds in a
# row after the span began: the load's end, which may be before or after the video's
python3 - "$log" <<'EOF' | tee -a "$log"
import re, sys
rows = []
for l in open(sys.argv[1]):
    m = re.match(r'^(\d\d):(\d\d):(\d\d) #\d+ cpu \S* server \S* loader (\d+) .*video \[(.*)\]', l)
    if m:
        t = int(m.group(1)) * 3600 + int(m.group(2)) * 60 + int(m.group(3))
        rows.append((t, l[:8], int(m.group(4)), m.group(5)))
i = 0
while i < len(rows):
    if not rows[i][3]: i += 1; continue
    j = i
    while j < len(rows) and rows[j][3]: j += 1
    quiet = None
    for k in range(i, len(rows) - 2):
        if all(rows[k + d][2] < 10 for d in range(3)): quiet = k; break
    span = 'video %s from %s for %d s (%s)' % (rows[i][3], rows[i][1], rows[j - 1][0] - rows[i][0],
                                             'still open at the end' if j == len(rows) else 'closed ' + rows[j][1])
    load = ('loader quiet at %s, %d s after the video began' % (rows[quiet][1], rows[quiet][0] - rows[i][0])
            if quiet is not None else 'loader never quiet before the game ended')
    print('== %s; %s' % (span, load))
    i = j
EOF
