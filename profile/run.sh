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
# DISK="wbps=... wiops=..." caps the server's cgroup's I/O (io.max) on the disk under /tmp, for a disk slower than the
# runner's; the cgroup's dirty pages are written back under the cap too.
if [ -n "${DISK:-}" ]; then
  grep -qw io /sys/fs/cgroup/cgroup.subtree_control || echo +io | sudo tee /sys/fs/cgroup/cgroup.subtree_control >/dev/null
  PART=$(findmnt -n -o SOURCE -T /tmp)
  PARENT=$(lsblk -no PKNAME "$PART" | head -1)
  MAJMIN=$(cat /sys/block/${PARENT:-$(basename "$PART")}/dev)
  echo "disk cap on $PART ($MAJMIN): $DISK"
fi
# PACKETS=1: count the packets to and from the server (each leaves through lo's OUTPUT once), all of them and those
# without data (60 bytes or less: a bare TCP header). On the box each costs the server's one CPU interrupt and protocol
# work; on loopback the receiving side's runs on the sender's CPU, so the profile alone can't see them.
if [ "${PACKETS:-0}" = 1 ]; then
  sudo iptables -t raw -F PROFILE 2>/dev/null || sudo iptables -t raw -N PROFILE
  for dir in "--sport 3000" "--dport 3000"; do
    sudo iptables -t raw -A PROFILE -p tcp $dir
    sudo iptables -t raw -A PROFILE -p tcp $dir -m length --length 0:60
  done
  sudo iptables -t raw -C OUTPUT -o lo -j PROFILE 2>/dev/null || sudo iptables -t raw -I OUTPUT 1 -o lo -j PROFILE
fi
# LO_MTU=1500: loopback with the box's MTU and no segmentation offload, so a response leaves as wire-sized packets
# and the client acknowledges them as it would over the network.
if [ -n "${LO_MTU:-}" ]; then
  sudo ip link set lo mtu $LO_MTU && sudo ethtool -K lo tso off gso off 2>/dev/null
  ip link show lo | head -1; ethtool -k lo 2>/dev/null | grep -E '^(tcp-segmentation|generic-segmentation)-offload'
fi
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
  [ -n "${DISK:-}" ] && echo "$MAJMIN $DISK" | sudo tee $CG/io.max > /dev/null
  # MEMMAX caps the server's cgroup (page cache and kernel memory included), as the box's 2 GB does at its user count.
  [ -n "${MEMMAX:-}" ] && echo "$MEMMAX" | sudo tee $CG/memory.max > /dev/null && echo 0 | sudo tee $CG/memory.swap.max > /dev/null
  rm -rf /tmp/db && mkdir /tmp/db && cp seed/feed.db /tmp/db/feed.db
  SQLITE_PATH=/tmp/db/feed.db JWT_SECRET=twelve-dollar-challenge HOST=0.0.0.0 PORT=3000 \
    taskset -c 0 bash -c "echo \$\$ | sudo tee $CG/cgroup.procs >/dev/null && ulimit -n $SERVER_NOFILE && exec bash submissions/$sub/start.sh" \
    > $OUT/$tag.server.log 2>&1 &
  PID=$!
  for _ in $(seq 120); do curl -sf http://127.0.0.1:3000/health >/dev/null && break; sleep 0.5; done
  # The WAL's size every second.
  ( while kill -0 $PID 2>/dev/null; do stat -c %s /tmp/db/feed.db-wal 2>/dev/null || echo 0; sleep 1; done ) > $OUT/$tag.wal.txt &
  taskset -c 1-$LAST profile/mload/mload -target $TARGETS -ports 3000 -users $USERS -ramp ${RAMP}s -hold ${HOLD}s \
    -think-scale $THINK -tokens seed/tokens.json > $OUT/$tag.load.log 2>&1 &
  LOAD=$!
  sleep $((RAMP + 10))
  # CPU per request over the window.
  [ "${PACKETS:-0}" = 1 ] && sudo iptables -t raw -Z PROFILE
  read u0 s0 < <(cputime $PID); t0=$(date +%s.%N); w0=$(grep -c '^t=' $OUT/$tag.load.log)
  sleep $WINDOW
  read u1 s1 < <(cputime $PID); t1=$(date +%s.%N); w1=$(grep -c '^t=' $OUT/$tag.load.log)
  [ "${PACKETS:-0}" = 1 ] && sudo iptables -t raw -L PROFILE -v -x -n > $OUT/$tag.packets.txt
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
  echo "WAL largest $(sort -n $OUT/$tag.wal.txt | tail -1 | awk '{ printf "%.0f MB", $1 / 1048576 }'), memory peak $(awk '/^peak/ { printf "%.0f MB", $2 / 1048576 }' $OUT/$tag.mem-end.txt)"
  grep -h -i -E 'checkpoint|hold' $OUT/$tag.server.log | grep -v -i 'listening' | tail -4 | sed 's/^/  log: /'
  echo "memory cap ${MEMMAX:-none}: $(awk '/^(pgmajfault|pgscan|pgsteal|workingset_refault_file|workingset_refault_anon) / { printf "%s %s  ", $1, $2 }' $OUT/$tag.mem-end.txt)oom $(sudo cat $CG/memory.events 2>/dev/null | awk '/^oom_kill/ { print $2 }')"
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
  if [ -f $OUT/$tag.packets.txt ]; then
    echo "-- packets per request over the window"
    python3 - $OUT/$tag.packets.txt "$rps" "$t0" "$t1" <<'P'
import sys
path, rps, t0, t1 = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), float(sys.argv[4])
requests = rps * (t1 - t0)
counts = {}
for line in open(path):
    f = line.split()
    if len(f) < 3 or not f[0].isdigit(): continue
    direction = "server -> client" if "spt:3000" in line else "client -> server"
    kind = "bare" if "length 0:60" in line else "all"
    counts[(direction, kind)] = (int(f[0]), int(f[1]))
for direction in ["server -> client", "client -> server"]:
    packets, octets = counts.get((direction, "all"), (0, 0))
    bare, _ = counts.get((direction, "bare"), (0, 0))
    if requests:
        print(f"  {direction}: {packets / requests:.3f} packets/req ({(packets - bare) / requests:.3f} with data, "
              f"{bare / requests:.3f} bare), {octets / requests:.0f} bytes/req")
P
  fi
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
  sudo perf report -i $OUT/$tag.perf.data --stdio --no-children --sort dso,symbol 2>/dev/null | grep -v '^#' | grep -v '^$' \
    | demangle > $OUT/$tag.symbols.txt
  echo "-- by symbol (top 40)"
  head -40 $OUT/$tag.symbols.txt | cut -c1-170
  # Samples cover the server's user and kernel time alike: a symbol's share of them times the CPU per request is its
  # time per request.
  echo "-- user space by symbol, ns per request (top 45)"
  python3 - $OUT/$tag.symbols.txt "$rps" "$u0" "$s0" "$u1" "$s1" "$t0" "$t1" <<'P'
import sys, re
path = sys.argv[1]
rps, u0, s0, u1, s1, t0, t1 = map(float, sys.argv[2:9])
ns = ((u1 - u0) + (s1 - s0)) / (t1 - t0) * 1e9 / rps if rps else 0
rows, user = [], 0.0
for line in open(path):
    m = re.match(r'\s*([\d.]+)%\s+(\S+)\s+\[(.)\]\s+(.*)', line)
    if not m or m.group(2) == '[kernel.kallsyms]': continue
    pct = float(m.group(1)); user += pct
    rows.append((pct, m.group(2), m.group(4).strip()))
print(f"  user space: {user:.1f}% of samples = {user / 100 * ns:.0f} ns/req")
for pct, dso, sym in rows[:45]:
    print(f"  {pct / 100 * ns:6.0f}  {dso[:12]:12s} {sym[:130]}")
P
  sudo rmdir $CG 2>/dev/null
done
sudo chmod -R a+r $OUT
