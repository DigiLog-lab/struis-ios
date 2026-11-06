#!/bin/bash
# Dev Box: runs the commands the web Claude sends, on this macOS runner.
#
# Commands arrive as commits on DEVBOX_CMD_REF (files `id` and `cmd.sh`); results leave as a single commit,
# force-pushed to DEVBOX_OUT_REF (files `id`, `state`, `exit`, `times`, `log.tail.txt`, `log.txt.gz` and
# whatever the command put in "$DEVBOX_FILES"). Both refs are watched with `git ls-remote`, which does not
# count against the REST API limit of GITHUB_TOKEN (1,000 requests an hour per repository).
#
# Before each command the work tree is moved to the latest commit of DEVBOX_WORK_BRANCH, so a build after a
# push is incremental (DerivedData lives outside the work tree). The server stops by itself after
# DEVBOX_IDLE_SECONDS without a command, at DEVBOX_DEADLINE_EPOCH, or on the command `__devbox_stop__`.
set -uo pipefail

: "${DEVBOX_WORK_BRANCH:?}"
CMD_REF=${DEVBOX_CMD_REF:-refs/heads/devbox/cmd}
OUT_REF=${DEVBOX_OUT_REF:-refs/heads/devbox/out}
IDLE=${DEVBOX_IDLE_SECONDS:-900}
POLL=${DEVBOX_POLL_SECONDS:-3}
DEADLINE=${DEVBOX_DEADLINE_EPOCH:-$(( $(date +%s) + 19800 ))}
PROGRESS=${DEVBOX_PROGRESS_SECONDS:-15}
STATE=${RUNNER_TEMP:-/tmp}/devbox
mkdir -p "$STATE"

export GIT_AUTHOR_NAME=devbox GIT_AUTHOR_EMAIL=devbox@users.noreply.github.com
export GIT_COMMITTER_NAME=devbox GIT_COMMITTER_EMAIL=devbox@users.noreply.github.com

# publish DIR MESSAGE: one commit holding exactly DIR's files, force-pushed to OUT_REF.
publish() {
  local dir=$1 message=$2 tree commit
  rm -f "$STATE/index"
  tree=$(export GIT_INDEX_FILE="$STATE/index"
         git read-tree --empty && git --work-tree="$dir" add -A -f . && git write-tree) || return 1
  commit=$(git commit-tree "$tree" -m "$message") || return 1
  for attempt in 1 2 3; do
    git push -q --force origin "$commit:$OUT_REF" && return 0
    sleep $(( attempt * 2 ))
  done
  echo "::warning::devbox: could not publish $message"
}

# status DIR ID STATE [EXIT]: the small files of a result.
status() {
  local dir=$1
  printf '%s\n' "$2" > "$dir/id"
  printf '%s\n' "$3" > "$dir/state"
  [[ $# -ge 4 ]] && printf '%s\n' "$4" > "$dir/exit"
  return 0
}

ready=$STATE/ready
mkdir -p "$ready"
status "$ready" "ready-${GITHUB_RUN_ID:-local}" ready
{ echo "run=${GITHUB_RUN_ID:-}"; echo "branch=$DEVBOX_WORK_BRANCH"; echo "ready=$(date +%s)"
  [[ -f "$STATE/warm.txt" ]] && cat "$STATE/warm.txt"; } > "$ready/times"
publish "$ready" "devbox ready"

last=$(git ls-remote origin "$CMD_REF" | cut -f1)
idle_since=$(date +%s)
echo "devbox: ready, watching $CMD_REF (now ${last:-none})"

while :; do
  now=$(date +%s)
  if (( now - idle_since > IDLE )); then echo "devbox: idle for ${IDLE}s, stopping"; break; fi
  if (( now > DEADLINE )); then echo "devbox: deadline reached, stopping"; break; fi
  sha=$(git ls-remote origin "$CMD_REF" | cut -f1)
  if [[ -z "$sha" || "$sha" == "$last" ]]; then sleep "$POLL"; continue; fi
  last=$sha
  received=$(date +%s)
  if ! git fetch -q --depth 1 origin "$CMD_REF"; then sleep "$POLL"; continue; fi
  id=$(git show FETCH_HEAD:id 2>/dev/null | tr -cd 'A-Za-z0-9_-')
  cmd=$(git show FETCH_HEAD:cmd.sh 2>/dev/null)
  [[ -n "$id" ]] || continue
  out=$STATE/out-$id
  rm -rf "$out"; mkdir -p "$out/files"
  if [[ "$cmd" == "__devbox_stop__" ]]; then
    status "$out" "$id" done 0
    echo "received=$received" > "$out/times"
    publish "$out" "devbox $id stop"
    echo "devbox: stop requested"; break
  fi

  # The latest commit of the work branch, keeping ignored and untracked build output.
  sync_log=$(git fetch -q --depth 1 origin "refs/heads/$DEVBOX_WORK_BRANCH" 2>&1 && git checkout -q --force --detach FETCH_HEAD 2>&1)
  synced=$(git rev-parse HEAD)
  started=$(date +%s)
  status "$out" "$id" running
  { echo "received=$received"; echo "started=$started"; echo "commit=$synced"; } > "$out/times"
  log=$STATE/log-$id.txt
  { [[ -n "$sync_log" ]] && echo "$sync_log"; } > "$log"
  publish "$out" "devbox $id running"

  DEVBOX_FILES="$out/files" DEVBOX_ID="$id" bash -c "$cmd" >> "$log" 2>&1 < /dev/null &
  pid=$!
  next=$(( $(date +%s) + PROGRESS ))
  while kill -0 "$pid" 2>/dev/null; do
    sleep 1
    if (( $(date +%s) >= next )); then
      tail -n 200 "$log" > "$out/log.tail.txt"
      publish "$out" "devbox $id running"
      next=$(( $(date +%s) + PROGRESS ))
    fi
  done
  wait "$pid"; code=$?
  finished=$(date +%s)
  echo "finished=$finished" >> "$out/times"
  tail -n 400 "$log" > "$out/log.tail.txt"
  gzip -c "$log" > "$out/log.txt.gz"
  status "$out" "$id" done "$code"
  publish "$out" "devbox $id exit $code"
  echo "devbox: $id exit $code in $(( finished - started ))s"
  idle_since=$(date +%s)
done
