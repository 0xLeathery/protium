#!/bin/bash
#
# Records what a running game's threads do, without touching the game: one second of macOS's
# `sample` every few seconds, from the moment the game's process is there until it exits.
#
#   macos/tests/gamewatch.sh <part of the game's exe name> [output directory]
#
# e.g.  macos/tests/gamewatch.sh s2_sp64_ship
#
# Start it before or after the game; it waits up to an hour for the process. Nothing is
# attached to the game and none of its threads is suspended (a debugger or a sampler that
# suspends threads makes some games exit), and no window is opened.
#
# <output directory>/log.txt (default $BUILD_ROOT/evidence/gamewatch/<date-time>) gets, per sample:
#   12:03:13 #22 cpu 284.2 server 19.3 loader 55 video [normandy_load.bik]
#      Database 55%: jit 107, read<libsystem_kernel.dylib> 20, ...
# cpu and server are the per cent of a core the game and the wineserver use; loader is how busy
# the thread named Database is (Call of Duty's level loader; "-" when there is none); video
# lists the .bik files the game has open. The lines below name each thread that was busy for
# more than a fifth of the sample and where: "jit" is translated x86 code, "pe" code of a
# Windows module, anything else a function of Wine's Unix side or of macOS. Every fifth raw
# sample is kept as s<n>.txt for a closer look.
#
# The end prints the spans in which a video was open and, for each, when the loader went quiet
# after it: that is how long a level's load took, and whether it outlasted its video.

set -u
name=${1:?usage: gamewatch.sh <part of the exe name> [output directory]}
BUILD_ROOT=${BUILD_ROOT:-/Users/annon/projects/proton-macos-build}
out=${2:-$BUILD_ROOT/evidence/gamewatch/$(date +%Y%m%d-%H%M%S)}
mkdir -p "$out"
log=$out/log.txt
: >"$log"

# the game, not the steam.exe that started it: of the processes with the name, the largest
game_pid() {
    ps -eo pid=,rss=,command= | grep -F "$name" | grep -v -e 'steam\.exe' -e gamewatch -e 'grep' \
        | sort -k2 -n | tail -1 | awk '{print $1}'
}

pid=""
for _ in $(seq 1 1800); do
    pid=$(game_pid)
    [ -n "$pid" ] && break
    sleep 2
done
[ -n "$pid" ] || { echo "no process with '$name' in its name within an hour" | tee -a "$log"; exit 1; }
echo "watching pid $pid, log $log"

summarise() {
    python3 - "$1" <<'EOF'
import collections, re, sys
lines = open(sys.argv[1], errors='replace').read().split('\n')
threads = collections.OrderedDict()
cur = None
for l in lines:
    m = re.match(r'^    (\d+) (Thread_\S+.*)', l)
    if m:
        cur = (re.sub(r'Thread_\d+:? ?', '', m.group(2))[:28] or 'unnamed') + '#' + str(len(threads))
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
loader = '-'
out = []
for name, body in threads.items():
    leaf = collections.Counter()
    for i, l in enumerate(body):
        m = re.match(r'^([ +!:|]*)(\d+) (.*)', l)
        if not m: continue
        depth = len(m.group(1))
        nxt = re.match(r'^([ +!:|]*)(\d+) ', body[i + 1]) if i + 1 < len(body) else None
        if nxt and len(nxt.group(1)) > depth: continue
        leaf[where(m.group(3))] += int(m.group(2))
    total = sum(leaf.values())
    busy = sum(v for k, v in leaf.items() if not k.startswith(idle))
    if not total: continue
    if name.startswith('Database'): loader = str(100 * busy // total)
    if busy * 5 > total:
        out.append('   %s %d%%: %s' % (name, 100 * busy // total, ', '.join(
            '%s %d' % (k, v) for k, v in leaf.most_common(6) if not k.startswith(idle))))
print(loader)
print('\n'.join(out))
EOF
}

n=0
while kill -0 "$pid" 2>/dev/null; do
    n=$((n + 1))
    raw=$out/s$n.txt
    video=$(lsof -p "$pid" 2>/dev/null | awk '/\.bik$/ {print $NF}' | sed 's|.*/||' | tr '\n' ' ' | sed 's/ $//')
    cpu=$(ps -o pcpu= -p "$pid" | tr -d ' ')
    server=$(ps -o pcpu= -p "$(pgrep -x wineserver | head -1)" 2>/dev/null | tr -d ' ')
    sample "$pid" 1 -file "$raw" >/dev/null 2>&1
    summary=$(summarise "$raw" 2>/dev/null)
    echo "$(date +%T) #$n cpu ${cpu:--} server ${server:--} loader $(printf '%s\n' "$summary" | head -1) video [$video]" >>"$log"
    printf '%s\n' "$summary" | tail -n +2 >>"$log"
    [ $((n % 5)) -ne 0 ] && rm -f "$raw"
    [ "$n" -ge 3000 ] && break
    sleep 2
done
echo "$(date +%T) the game ended" >>"$log"

# each span with a video open, and when the loader was quiet (under 10%) for three samples in a
# row after the span began: the load's end, which may be before or after the video's
python3 - "$log" <<'EOF' | tee -a "$log"
import re, sys
rows = []
for l in open(sys.argv[1]):
    m = re.match(r'^(\d\d):(\d\d):(\d\d) #\d+ cpu \S+ server \S+ loader (\S+) video \[(.*)\]', l)
    if m:
        t = int(m.group(1)) * 3600 + int(m.group(2)) * 60 + int(m.group(3))
        rows.append((t, l[:8], 0 if m.group(4) == '-' else int(m.group(4)), m.group(5)))
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
