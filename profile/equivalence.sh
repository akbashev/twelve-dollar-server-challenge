#!/usr/bin/env bash
# The B-tree reads against SQL's answers, byte for byte: after posts whose bodies need escaping (across the 32- and
# 16-byte chunks) and thousands of likes on the newest posts (several leaf pages of the likes index), /feed and
# /posts/:id are fetched with BTREE_READS=1 and then =0 over the same database, and compared. SUB names the
# submission, already built.
set -uo pipefail
cd "$(dirname "$0")/.."
SUB=${SUB:-swift-iouring-akbashev}
export JWT_SECRET=twelve-dollar-challenge HOST=127.0.0.1 PORT=3000
D=$(mktemp -d); cp seed/feed.db $D/feed.db; export SQLITE_PATH=$D/feed.db
start() {
  BTREE_READS=$1 bash submissions/$SUB/start.sh > $D/server.$1.$2.log 2>&1 &
  SERVER=$!
  for _ in $(seq 60); do curl -sf localhost:3000/health > /dev/null && break; sleep 0.5; done
}
stop() { kill $SERVER; wait $SERVER 2> /dev/null; }

start 1 writes
echo "start-up: $(head -1 $D/server.1.writes.log)"
T0=$(jq -r '.[0].token' seed/tokens.json)
long=$(printf 'abcdefghij%.0s' $(seq 30))
cat > $D/bodies.json <<EOF
{"body":"\"quoted\" and \\\\backslash\\\\"}
{"body":"tab\there and a newline\nend"}
{"body":"control \u0001 and \u001f and \u007f in a body longer than thirty-two bytes, then \"quotes\""}
{"body":"exactly thirty-two bytes of text"}
{"body":"sixteen bytes!!!"}
{"body":"é ü ñ 😀 unicode text that is long enough to cross a 32-byte chunk \" boundary"}
{"body":"${long:0:100}\"${long:0:149}\n${long:0:40}"}
{"body":"${long:0:31}\""}
{"body":"${long:0:32}\\\\"}
{"body":"${long:0:47}\t"}
EOF
while IFS= read -r line; do
  curl -s -o /dev/null -w '%{http_code} ' -X POST -H "Authorization: Bearer $T0" -H 'Content-Type: application/json' \
    --data-binary "$line" localhost:3000/posts
done < $D/bodies.json
echo
newest=$(curl -s localhost:3000/feed | jq '.posts[0].id')
echo "newest post: $newest"
# 200 users like each of the 25 newest posts: 5,000 likes.
for u in $(seq 0 199); do
  t=$(jq -r ".[$u].token" seed/tokens.json)
  for id in $(seq $((newest - 24)) $newest); do echo "$t $id"; done
done | xargs -P 8 -n 2 sh -c 'curl -s -o /dev/null -w "%{http_code}\n" -X POST -H "Authorization: Bearer $0" localhost:3000/posts/$1/like' \
  | sort | uniq -c | xargs echo "likes:"
stop

ids="$(seq $((newest - 40)) $newest | xargs) 1 2 3 99999 250000 499999 500000 600000 0"
for mode in 1 0; do
  start $mode read
  curl -s localhost:3000/feed > $D/feed.$mode
  for id in $ids; do curl -s localhost:3000/posts/$id > $D/post.$id.$mode; done
  stop
done
same=0; differ=0
for f in $D/feed $(for id in $ids; do echo $D/post.$id; done); do
  if cmp -s $f.1 $f.0; then same=$((same + 1)); else differ=$((differ + 1)); echo "DIFFERS: $(basename $f)"; diff <(head -c 600 $f.1) <(head -c 600 $f.0) | head -6; fi
done
echo "identical: $same, different: $differ"
echo "like counts in the feed: $(jq -c '[.posts[].like_count]' $D/feed.1)"
rm -rf $D
