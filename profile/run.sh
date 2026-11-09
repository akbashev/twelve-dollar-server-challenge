#!/usr/bin/env bash
# profile/run.sh <submission>...: each submission in turn on CPU 0, in a cgroup of its own, with a fresh copy of the
# seed; mload on the other CPUs. Over a window of the hold: requests, the server's CPU (user and kernel) per request;
# then perf stat, a perf profile by DSO and by symbol, mallocs per request (uprobes on glibc's allocator, with their
# callers), and memory: the cgroup's peak and breakdown (what the board's RAM column is), and the process's RSS.
# TARGETS spreads users over loopback addresses (more connections than one address's ports); the server gets
# SERVER_NOFILE descriptors (the box's 65,535 by default, so past that it opens more rings); NOTRACK=1 takes loopback
# out of connection tracking (the box has none).
set -uo pipefail
cd "$(dirname "$0")/.."
OUT=profile/out; mkdir -p $OUT
USERS=${USERS:-20000} THINK=${THINK:-0.15} RAMP=${RAMP:-20} HOLD=${HOLD:-70} WINDOW=${WINDOW:-20} PERF=${PERF:-15}
TARGETS=${TARGETS:-127.0.0.1} SERVER_NOFILE=${SERVER_NOFILE:-65535} NOTRACK=${NOTRACK:-1} LABEL=${LABEL:-run}
sudo sysctl -q kernel.perf_event_paranoid=-1 kernel.kptr_restrict=0 net.ipv4.ip_local_port_range="1024 65535"
# Both ends of every connection are on this machine: room for their socket memory, so neither hits TCP memory pressure.
sudo sysctl -q net.ipv4.tcp_mem="2000000 3000000 4000000" net.core.somaxconn=65535 net.ipv4.tcp_max_syn_backlog=65535
sudo prlimit --pid $$ --nofile=1048576:1048576
if [ "$NOTRACK" = 1 ] && ! sudo iptables -t raw -C OUTPUT -o lo -j NOTRACK 2>/dev/null; then
  sudo iptables -t raw -I PREROUTING -i lo -j NOTRACK && sudo iptables -t raw -I OUTPUT -o lo -j NOTRACK
fi
grep -qw memory /sys/fs/cgroup/cgroup.subtree_control || echo +memory | sudo tee /sys/fs/cgroup/cgroup.subtree_control >/dev/null
LIBC=$(ldconfig -p | awk '/libc\.so\.6 .*x86-64/ { print $NF; exit }')
sudo perf probe -q -x "$LIBC" -a malloc -a calloc -a realloc -a posix_memalign -a aligned_alloc 2>/dev/null
ALLOCS=probe_libc:malloc,probe_libc:calloc,probe_libc:realloc,probe_libc:posix_memalign,probe_libc:aligned_alloc
TCK=$(getconf CLK_TCK)
LAST=$(($(nproc) - 1))
demangle() { if [ -x /opt/swift/usr/bin/swift-demangle ]; then /opt/swift/usr/bin/swift-demangle --simplified; else cat; fi; }
cputime() { awk -v t=$TCK '{ print $14 / t, $15 / t }' /proc/$1/stat; }   # user, system seconds (all threads)
# The mean of mload's per-second req/s over its log lines after the first $2, up to line $3.
rate() { grep '^t=' $1 | sed -n "$(($2 + 1)),$3p" | grep -o 'req/s=[0-9]*' | cut -d= -f2 | awk '{ s += $1; n++ } END { print n ? s / n : 0 }'; }
run=0
for sub in "$@"; do
  run=$((run + 1)); tag="$LABEL-$run-$sub"
  CG=/sys/fs/cgroup/prof-$tag
  sudo mkdir $CG
  rm -rf /tmp/db && mkdir /tmp/db && cp seed/feed.db /tmp/db/feed.db
  SQLITE_PATH=/tmp/db/feed.db JWT_SECRET=twelve-dollar-challenge HOST=0.0.0.0 PORT=3000 \
    taskset -c 0 bash -c "echo \$\$ | sudo tee $CG/cgroup.procs >/dev/null && ulimit -n $SERVER_NOFILE && exec bash submissions/$sub/start.sh" \
    > $OUT/$tag.server.log 2>&1 &
  PID=$!
  for _ in $(seq 120); do curl -sf http://127.0.0.1:3000/health >/dev/null && break; sleep 0.5; done
  taskset -c 1-$LAST profile/mload/mload -target $TARGETS -ports 3000 -users $USERS -ramp ${RAMP}s -hold ${HOLD}s \
    -think-scale $THINK -tokens seed/tokens.json > $OUT/$tag.load.log 2>&1 &
  LOAD=$!
  sleep $((RAMP + 10))
  # CPU per request over the window.
  read u0 s0 < <(cputime $PID); t0=$(date +%s.%N); w0=$(grep -c '^t=' $OUT/$tag.load.log)
  sleep $WINDOW
  read u1 s1 < <(cputime $PID); t1=$(date +%s.%N); w1=$(grep -c '^t=' $OUT/$tag.load.log)
  rps=$(rate $OUT/$tag.load.log $w0 $w1)
  { cat $CG/memory.stat; echo "current $(cat $CG/memory.current)"; grep -E '^(VmRSS|VmHWM|RssAnon|RssFile|RssShmem|Threads)' /proc/$PID/status
    cat /proc/net/sockstat; } > $OUT/$tag.mem-hold.txt
  sudo perf stat -e task-clock,context-switches,page-faults,cycles,instructions,branch-misses,cache-misses \
    -p $PID -- sleep 5 > $OUT/$tag.stat.txt 2>&1
  sudo perf record -q -F 1999 -p $PID -o $OUT/$tag.perf.data -- sleep $PERF > /dev/null 2>&1
  # Allocations per request: glibc's allocator entry points, counted over 5 s; then their callers over 3 s.
  a0=$(grep -c '^t=' $OUT/$tag.load.log)
  sudo perf stat -x, -e $ALLOCS -p $PID -- sleep 5 > $OUT/$tag.allocs.txt 2>&1
  a1=$(grep -c '^t=' $OUT/$tag.load.log)
  arps=$(rate $OUT/$tag.load.log $a0 $a1)
  sudo perf record -q -g -e $ALLOCS -p $PID -o $OUT/$tag.allocs.data -- sleep 3 > /dev/null 2>&1
  wait $LOAD
  { cat $CG/memory.stat; echo "peak $(cat $CG/memory.peak)"; grep -E '^(VmRSS|VmHWM|RssAnon|RssFile)' /proc/$PID/status; } > $OUT/$tag.mem-end.txt
  echo "server log tail:"; tail -3 $OUT/$tag.server.log
  kill $PID 2>/dev/null; wait $PID 2>/dev/null
  sleep 10
  echo "================ $tag"
  grep RESULT $OUT/$tag.load.log
  python3 - "$rps" "$u0" "$s0" "$u1" "$s1" "$t0" "$t1" <<'P'
import sys
rps, u0, s0, u1, s1, t0, t1 = map(float, sys.argv[1:8])
secs = t1 - t0
user, system = (u1 - u0) / secs, (s1 - s0) / secs
per = lambda c: c * 1e6 / rps if rps else 0
print(f"window {secs:.0f}s: {rps:.0f} req/s; server {100 * (user + system):.0f}% of a CPU "
      f"({100 * user:.0f}% user, {100 * system:.0f}% kernel) = {per(user + system):.1f} us/req "
      f"({per(user):.1f} user + {per(system):.1f} kernel)")
P
  grep -E 'task-clock|context-switches|cycles|instructions|branch-misses|cache-misses|not supported' $OUT/$tag.stat.txt | sed 's/^ */  /'
  echo "-- allocations (5 s at $arps req/s)"
  awk -F, -v r="$arps" '$3 ~ /probe_libc/ { n = $1 + 0; t += n; printf "  %-28s %9d  %.3f/req\n", $3, n, r ? n / (5 * r) : 0 }
    END { printf "  %-28s %9d  %.3f/req\n", "total", t, r ? t / (5 * r) : 0 }' $OUT/$tag.allocs.txt
  echo "-- allocation callers"
  sudo perf report -i $OUT/$tag.allocs.data --stdio --children --sort symbol 2>/dev/null | grep -E '^ +[0-9]' | head -25 | demangle | cut -c1-170
  echo "-- memory during the hold (cgroup) and its peak"
  python3 - $OUT/$tag.mem-hold.txt $OUT/$tag.mem-end.txt <<'P'
import sys
def read(p):
    d = {}
    for line in open(p):
        parts = line.split()
        if len(parts) >= 2 and parts[1].isdigit(): d[parts[0].rstrip(':')] = int(parts[1])
    return d
hold, end = read(sys.argv[1]), read(sys.argv[2])
for k in ["current", "anon", "file", "kernel", "sock", "slab", "slab_unreclaimable", "pagetables", "kernel_stack", "percpu", "shmem", "file_mapped", "file_dirty"]:
    if k in hold: print(f"  {k:20s} {hold[k] / 2**20:8.1f} MB")
print(f"  {'peak':20s} {end.get('peak', 0) / 2**20:8.1f} MB")
for k in ["VmRSS", "VmHWM", "RssAnon", "RssFile"]:
    if k in hold: print(f"  {k:20s} {hold[k] / 1024:8.1f} MB")
P
  grep -E '^TCP:' $OUT/$tag.mem-hold.txt | sed 's/^/  /'
  echo "-- by DSO"
  sudo perf report -i $OUT/$tag.perf.data --stdio --no-children --sort dso 2>/dev/null | grep -v '^#' | grep -v '^$' | head -8
  echo "-- by symbol (top 50)"
  sudo perf report -i $OUT/$tag.perf.data --stdio --no-children --sort dso,symbol 2>/dev/null | grep -v '^#' | grep -v '^$' \
    | head -50 | demangle | cut -c1-170
  sudo rmdir $CG 2>/dev/null
done
sudo chmod -R a+r $OUT
