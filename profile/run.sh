#!/usr/bin/env bash
# profile/run.sh <submission>...: each submission in turn on CPU 0 with a fresh copy of the seed, mload on the other
# CPUs. Over a window of the hold: requests, the server's CPU (user and kernel) per request; then a perf profile by
# DSO and by symbol, and perf stat. Everything also lands in profile/out. TARGETS spreads users over loopback addresses
# (more connections than one address's ports); the server gets SERVER_NOFILE descriptors (the box's 65,535 by default,
# so past that it opens more rings); NOTRACK=1 takes loopback out of connection tracking (the box has none).
set -uo pipefail
cd "$(dirname "$0")/.."
OUT=profile/out; mkdir -p $OUT
USERS=${USERS:-20000} THINK=${THINK:-0.15} RAMP=${RAMP:-20} HOLD=${HOLD:-70} WINDOW=${WINDOW:-20} PERF=${PERF:-15}
TARGETS=${TARGETS:-127.0.0.1} SERVER_NOFILE=${SERVER_NOFILE:-65535} NOTRACK=${NOTRACK:-1}
sudo sysctl -q kernel.perf_event_paranoid=-1 kernel.kptr_restrict=0 net.ipv4.ip_local_port_range="1024 65535"
sudo prlimit --pid $$ --nofile=1048576:1048576
if [ "$NOTRACK" = 1 ]; then
  sudo iptables -t raw -I PREROUTING -i lo -j NOTRACK && sudo iptables -t raw -I OUTPUT -o lo -j NOTRACK
fi
TCK=$(getconf CLK_TCK)
LAST=$(($(nproc) - 1))
demangle() { if [ -x /opt/swift/usr/bin/swift-demangle ]; then /opt/swift/usr/bin/swift-demangle --simplified; else cat; fi; }
cputime() { awk -v t=$TCK '{ print $14 / t, $15 / t }' /proc/$1/stat; }   # user, system seconds (all threads)
run=0
for sub in "$@"; do
  run=$((run + 1)); tag="$run-$sub"
  rm -rf /tmp/db && mkdir /tmp/db && cp seed/feed.db /tmp/db/feed.db
  SQLITE_PATH=/tmp/db/feed.db JWT_SECRET=twelve-dollar-challenge HOST=0.0.0.0 PORT=3000 \
    taskset -c 0 bash -c "ulimit -n $SERVER_NOFILE && exec bash submissions/$sub/start.sh" > $OUT/$tag.server.log 2>&1 &
  PID=$!
  for _ in $(seq 120); do curl -sf http://127.0.0.1:3000/health >/dev/null && break; sleep 0.5; done
  taskset -c 1-$LAST profile/mload/mload -target $TARGETS -ports 3000 -users $USERS -ramp ${RAMP}s -hold ${HOLD}s \
    -think-scale $THINK -tokens seed/tokens.json > $OUT/$tag.load.log 2>&1 &
  LOAD=$!
  sleep $((RAMP + 10))
  read u0 s0 < <(cputime $PID); t0=$(date +%s.%N); w0=$(grep -c '^t=' $OUT/$tag.load.log)
  sleep $WINDOW
  read u1 s1 < <(cputime $PID); t1=$(date +%s.%N); w1=$(grep -c '^t=' $OUT/$tag.load.log)
  sudo perf stat -e task-clock,context-switches,page-faults,cycles,instructions,branch-misses,cache-misses \
    -p $PID -- sleep 5 > $OUT/$tag.stat.txt 2>&1
  sudo perf record -q -F 1999 -p $PID -o $OUT/$tag.perf.data -- sleep $PERF > /dev/null 2>&1
  wait $LOAD
  echo "server log tail:"; tail -3 $OUT/$tag.server.log
  kill $PID 2>/dev/null; wait $PID 2>/dev/null
  sleep 10
  echo "================ $tag"
  grep RESULT $OUT/$tag.load.log
  python3 - "$OUT/$tag.load.log" "$w0" "$w1" "$u0" "$s0" "$u1" "$s1" "$t0" "$t1" <<'P'
import sys, re
log, w0, w1 = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
u0, s0, u1, s1, t0, t1 = map(float, sys.argv[4:10])
lines = [l for l in open(log) if l.startswith('t=')][w0:w1]
rates = [float(re.search(r'req/s=(\d+)', l).group(1)) for l in lines]
rps = sum(rates) / len(rates) if rates else 0
secs = t1 - t0
user, system = (u1 - u0) / secs, (s1 - s0) / secs
per = lambda c: c * 1e6 / rps if rps else 0
print(f"window {secs:.0f}s: {rps:.0f} req/s; server {100 * (user + system):.0f}% of a CPU "
      f"({100 * user:.0f}% user, {100 * system:.0f}% kernel) = {per(user + system):.1f} us/req "
      f"({per(user):.1f} user + {per(system):.1f} kernel)")
P
  grep -E 'task-clock|context-switches|cycles|instructions|branch-misses|cache-misses|not supported' $OUT/$tag.stat.txt | sed 's/^ */  /'
  echo "-- by DSO"
  sudo perf report -i $OUT/$tag.perf.data --stdio --no-children --sort dso 2>/dev/null | grep -v '^#' | grep -v '^$' | head -8
  echo "-- by symbol (top 40)"
  sudo perf report -i $OUT/$tag.perf.data --stdio --no-children --sort dso,symbol 2>/dev/null | grep -v '^#' | grep -v '^$' \
    | head -40 | demangle | cut -c1-170
done
sudo chmod -R a+r $OUT
