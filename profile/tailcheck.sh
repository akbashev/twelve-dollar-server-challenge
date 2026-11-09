#!/usr/bin/env bash
# The feed plan's fallbacks against SQL's answers. "future": the newest post is dated 2099, so the startup check
# passes and the next insert breaks the order: the plan must turn itself off there. "gap": a post deleted, so the
# startup check fails. Each /feed is fetched with BTREE_READS=1 and =0 over the same database and compared. SUB names
# the submission, already built.
set -uo pipefail
cd "$(dirname "$0")/.."
SUB=${SUB:-swift-iouring-akbashev}
export JWT_SECRET=twelve-dollar-challenge HOST=127.0.0.1 PORT=3000
T0=$(jq -r '.[0].token' seed/tokens.json)
status=0
start() {  # $1: BTREE_READS, $2: log name
  BTREE_READS=$1 bash submissions/$SUB/start.sh > $D/$2.log 2>&1 &
  SERVER=$!
  for _ in $(seq 60); do curl -sf localhost:3000/health > /dev/null && break; sleep 0.5; done
}
stop() { kill $SERVER; wait $SERVER 2> /dev/null; }
same() {  # $1: label, $2 $3: files
  if cmp -s "$2" "$3"; then echo "  $1: identical"; else echo "  $1: DIFFERENT"; diff <(head -c 400 "$2") <(head -c 400 "$3"); status=1; fi
}
for scenario in future gap; do
  D=$(mktemp -d); cp seed/feed.db $D/feed.db; export SQLITE_PATH=$D/feed.db
  case $scenario in
    future) sqlite3 $D/feed.db "UPDATE posts SET created_at = '2099-01-01T00:00:00.000Z' WHERE id = (SELECT max(id) FROM posts)" ;;
    gap) sqlite3 $D/feed.db "DELETE FROM posts WHERE id = (SELECT max(id) FROM posts) - 5" ;;
  esac
  echo "== $scenario"
  start 0 sql.before; curl -s localhost:3000/feed > $D/before.0; stop
  start 1 btree
  echo "  start-up: $(head -1 $D/btree.log)"
  curl -s localhost:3000/feed > $D/before.1
  curl -s -o /dev/null -w '  POST /posts %{http_code}\n' -X POST -H "Authorization: Bearer $T0" \
    -H 'Content-Type: application/json' -d '{"body":"after the check"}' localhost:3000/posts
  curl -s localhost:3000/feed > $D/after.1
  stop
  grep -h 'feed through' $D/btree.log | sed 's/^/  log: /'
  start 0 sql.after; curl -s localhost:3000/feed > $D/after.0; stop
  same "feed before the insert" $D/before.1 $D/before.0
  same "feed after the insert" $D/after.1 $D/after.0
  echo "  newest after: $(jq -c '.posts[0] | {id, created_at}' $D/after.1), second: $(jq -c '.posts[1] | {id, created_at}' $D/after.1)"
  rm -rf $D
done
exit $status
