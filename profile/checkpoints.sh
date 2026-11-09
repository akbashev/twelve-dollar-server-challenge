#!/usr/bin/env bash
# Writes enough to cycle several checkpoints (likes and posts from 8 users at once), then checks that every write was
# answered with 201 or 200 and that the WAL stayed bounded: it only does if the loop's writes start it over after a
# full copy. SUB names the submission, already built.
set -uo pipefail
cd "$(dirname "$0")/.."
SUB=${SUB:-swift-iouring-akbashev}
export JWT_SECRET=twelve-dollar-challenge HOST=127.0.0.1 PORT=3000
D=$(mktemp -d); cp seed/feed.db $D/feed.db; export SQLITE_PATH=$D/feed.db
bash submissions/$SUB/start.sh > $D/server.log 2>&1 &
SERVER=$!
for _ in $(seq 60); do curl -sf localhost:3000/health > /dev/null && break; sleep 0.5; done
wal() { stat -c %s $D/feed.db-wal 2>/dev/null || echo 0; }
writes() {  # $1: user index, $2: first post id, $3: count
  local t; t=$(jq -r ".[$1].token" seed/tokens.json)
  for id in $(seq $2 $(($2 + $3 - 1))); do
    if (( id % 10 == 0 )); then
      curl -s -o /dev/null -w '%{http_code}\n' -X POST -H "Authorization: Bearer $t" -H 'Content-Type: application/json' \
        -d "{\"body\":\"checkpoint test $id\"}" localhost:3000/posts
    else
      curl -s -o /dev/null -w '%{http_code}\n' -X POST -H "Authorization: Bearer $t" localhost:3000/posts/$id/like
    fi
  done
}
max=0
for round in 1 2 3 4; do
  pids=()
  for u in 0 1 2 3 4 5 6 7; do writes $u $((round * 100000 + u * 2000 + 1)) 1500 > $D/codes.$round.$u & pids+=($!); done
  alive() { for p in "${pids[@]}"; do kill -0 $p 2> /dev/null && return 0; done; return 1; }
  while alive; do s=$(wal); (( s > max )) && max=$s; sleep 0.2; done
  wait "${pids[@]}"
  echo "round $round: WAL now $(( $(wal) / 1024 )) KiB, largest seen $(( max / 1024 )) KiB"
done
echo "answers: $(cat $D/codes.* | sort | uniq -c | xargs)"
sleep 61; curl -s -o /dev/null localhost:3000/health
echo "server log:"; tail -5 $D/server.log
kill $SERVER 2> /dev/null; wait 2> /dev/null; rm -rf $D
