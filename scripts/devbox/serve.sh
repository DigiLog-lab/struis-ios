#!/bin/bash
# Dev Box: runs the commands the web Claude sends, on this macOS runner (docs/development-method.md).
#
# Each work branch has its own Dev Box and its own branches `devboxes/<key>/...`, <key> being the first 12
# hex digits of the SHA-1 of the work branch's name (box_key, the same as scripts/devbox/mac.py): several Dev
# Boxes run at once, one per work branch, and each runs only the commands sent for its branch.
# Each command is its own branch `devboxes/<key>/cmd/<id>` (files `cmd.sh`); its result is its own branch
# `devboxes/<key>/out/<id>` (files `id`, `state`, `exit`, `times`, `log.tail.txt`, `log.txt.gz` and whatever the
# command put in "$DEVBOX_FILES"), force-pushed while it runs. One branch per command, so a command sent
# while another waits, or a result finished right after another, never overwrites it. Ids start with the
# time (scripts/devbox/mac.py), so sorting the names runs commands in the order they were sent. Only the
# server deletes branches (the web Claude's token cannot: a deleting push is refused with 403, 2026-11-07):
# a command's branch when it takes it, a result's branch DEVBOX_KEEP_RESULTS_SECONDS after it finished, and
# results left by Dev Boxes that have ended when it starts.
# Branches are watched with `git ls-remote`, which does not count against the REST API limit of
# GITHUB_TOKEN (1,000 requests an hour per repository).
#
# `devboxes/<key>/out/ready` says that this Dev Box is waiting for commands; it is deleted when the server ends.
#
# Before each command the work tree is moved to the latest commit of DEVBOX_WORK_BRANCH, so a build after a
# push is incremental (DerivedData lives outside the work tree). Run a copy of this script from outside the
# work tree: bash reads a script while it runs, and the move would change it underneath.
#
# The server stops by itself after DEVBOX_IDLE_SECONDS without a command, at DEVBOX_DEADLINE_EPOCH, or on a
# command whose id ends in `-stop`. A running command is ended by a command whose id ends in `-kill` (or
# `-stop`), after DEVBOX_COMMAND_SECONDS, or at the deadline. Commands run with job control on (`set -m`),
# in their own process group: without it, bash starts a background command with SIGINT ignored, and
# `kill -INT` of `simctl io recordVideo` never stops the recording (2026-11-07, the first preflight run held
# its runner until the job's time limit).
set -uo pipefail

: "${DEVBOX_WORK_BRANCH:?}"
# box_key BRANCH: the name of BRANCH's Dev Box in its branches (scripts/devbox/mac.py box_key).
box_key() {
  if command -v shasum >/dev/null 2>&1; then printf '%s' "$1" | shasum -a 1; else printf '%s' "$1" | sha1sum; fi | cut -c1-12
}
BOXES_PREFIX=refs/heads/devboxes/
KEY=$(box_key "$DEVBOX_WORK_BRANCH")
[[ "$KEY" =~ ^[0-9a-f]{12}$ ]] || { echo "::error::devbox: no key for $DEVBOX_WORK_BRANCH"; exit 1; }
CMD_PREFIX=$BOXES_PREFIX$KEY/cmd/
OUT_PREFIX=$BOXES_PREFIX$KEY/out/
# Results of the Dev Box before 2026-11-09, when there was one Dev Box at a time: cleaned up like the others.
LEGACY_OUT_PREFIX=refs/heads/devbox-out/
IDLE=${DEVBOX_IDLE_SECONDS:-900}
POLL=${DEVBOX_POLL_SECONDS:-3}
DEADLINE=${DEVBOX_DEADLINE_EPOCH:-$(( $(date +%s) + 19800 ))}
PROGRESS=${DEVBOX_PROGRESS_SECONDS:-15}
COMMAND_MAX=${DEVBOX_COMMAND_SECONDS:-3600}
KEEP_RESULTS=${DEVBOX_KEEP_RESULTS_SECONDS:-3600}
STATE=${RUNNER_TEMP:-/tmp}/devbox
mkdir -p "$STATE"

export GIT_AUTHOR_NAME=devbox GIT_AUTHOR_EMAIL=devbox@users.noreply.github.com
export GIT_COMMITTER_NAME=devbox GIT_COMMITTER_EMAIL=devbox@users.noreply.github.com

# publish DIR NAME MESSAGE: one commit holding exactly DIR's files, force-pushed to devboxes/<key>/out/NAME.
publish() {
  local dir=$1 name=$2 message=$3 tree commit
  rm -f "$STATE/index"
  tree=$(export GIT_INDEX_FILE="$STATE/index"
         git read-tree --empty && git --work-tree="$dir" add -A -f . && git write-tree) || return 1
  commit=$(git commit-tree "$tree" -m "$message") || return 1
  for attempt in 1 2 3; do
    git push -q --force origin "$commit:$OUT_PREFIX$name" && return 0
    sleep $(( attempt * 2 ))
  done
  echo "::warning::devbox: could not publish $name"
  return 1
}

# Final results whose publication failed: "<dir> <name>" per line, published again while waiting, so a
# push outage does not leave `mac.py wait` looking at "running" for ever.
unpublished=$STATE/unpublished.txt
: > "$unpublished"
publish_final() {
  publish "$1" "$2" "$3" || echo "$1 $2" >> "$unpublished"
}
retry_unpublished() {
  local dir name rest=$STATE/unpublished.rest
  [[ -s "$unpublished" ]] || return 0
  : > "$rest"
  while read -r dir name; do
    publish "$dir" "$name" "devbox $name (published again)" || echo "$dir $name" >> "$rest"
  done < "$unpublished"
  mv "$rest" "$unpublished"
}

delete_ref() {
  local attempt
  for attempt in 1 2 3; do
    git push -q origin ":$1" 2>/dev/null && return 0
    sleep "$attempt"
  done
  return 1
}

# Ids this server has taken. A command whose branch could not be deleted is still never run twice.
consumed=$STATE/consumed.txt
touch "$consumed"

# status DIR ID STATE [EXIT]: the small files of a result.
status() {
  local dir=$1
  printf '%s\n' "$2" > "$dir/id"
  printf '%s\n' "$3" > "$dir/state"
  [[ $# -ge 4 ]] && printf '%s\n' "$4" > "$dir/exit"
  return 0
}

# The waiting commands, oldest first: "<sha> <id>" per line. Taken ones whose branch is still there (a
# failed delete) are deleted again instead of listed.
pending() {
  local sha ref id
  git ls-remote origin "${CMD_PREFIX}*" | while read -r sha ref; do
    id=${ref#"$CMD_PREFIX"}
    if grep -qxF "$id" "$consumed"; then delete_ref "$ref"; continue; fi
    printf '%s %s\n' "$sha" "$id"
  done | sort -k2
}

# signal_tree SIGNAL PID: PID, its process group and every descendant with its group. Commands run with
# `set -m`, so a job started inside one is in a group of its own and `kill -- -PID` alone misses it.
signal_tree() {
  local signal=$1 pid=$2 child
  for child in $(pgrep -P "$pid" 2>/dev/null); do signal_tree "$signal" "$child"; done
  kill "-$signal" -- "-$pid" 2>/dev/null
  kill "-$signal" "$pid" 2>/dev/null
  return 0
}

# Results of this Dev Box, KEEP_RESULTS after they finished: "<finished epoch> <id>" per line.
finished_list=$STATE/finished.txt
: > "$finished_list"
cleanup_finished() {
  local now when id rest=$STATE/finished.rest
  now=$(date +%s)
  : > "$rest"
  while read -r when id; do
    if (( now - when > KEEP_RESULTS )); then delete_ref "$OUT_PREFIX$id"; else echo "$when $id" >> "$rest"; fi
  done < "$finished_list"
  mv "$rest" "$finished_list"
}

# Results left by earlier Dev Boxes, KEEP_RESULTS after they finished (their `times`): this branch's earlier
# Dev Boxes, those of other branches that have ended (no `ready`; a running one deletes its own), and the
# single Dev Box before 2026-11-09. A result that never finished (its Dev Box ended while it ran) goes by the
# time in its id. One fetch of every result and one push that deletes them all: a fetch and a push per branch
# took minutes at start (2026-11-07).
cleanup_old_results() {
  local now ref id sha finished stamp when i box listing
  local -a shas=() refs=() old=() live=()
  now=$(date +%s)
  listing=$(git ls-remote origin "${BOXES_PREFIX}*" "${LEGACY_OUT_PREFIX}*") || return 0
  while read -r sha ref; do
    [[ "$ref" == "$BOXES_PREFIX"*/out/ready && "$ref" != "${OUT_PREFIX}ready" ]] || continue
    box=${ref#"$BOXES_PREFIX"}; live+=("${box%%/*}")
  done <<< "$listing"
  while read -r sha ref; do
    [[ -n "$ref" ]] || continue
    id=${ref##*/}
    [[ "$id" == ready ]] && continue
    if [[ "$ref" == "$BOXES_PREFIX"* ]]; then
      box=${ref#"$BOXES_PREFIX"}
      [[ "${box#*/}" == out/* ]] || continue
      [[ " ${live[*]-} " == *" ${box%%/*} "* ]] && continue
    fi
    shas+=("$sha"); refs+=("$ref")
  done <<< "$listing"
  (( ${#refs[@]} )) || return 0
  git fetch -q --depth 1 origin "${shas[@]}" 2>/dev/null || true
  for i in "${!refs[@]}"; do
    sha=${shas[$i]}; ref=${refs[$i]}; id=${ref##*/}
    finished=$(git show "$sha:times" 2>/dev/null | sed -n 's/^finished=\([0-9]*\)$/\1/p')
    if [[ -n "$finished" ]]; then
      when=$finished
    else
      stamp=${id%%-*}
      [[ "$stamp" =~ ^[0-9]{8}T[0-9]{6}$ ]] || continue
      when=$(date -j -u -f '%Y%m%dT%H%M%S' "$stamp" +%s 2>/dev/null || date -u -d "${stamp:0:8} ${stamp:9:2}:${stamp:11:2}:${stamp:13:2}" +%s 2>/dev/null) || continue
    fi
    (( now - when > KEEP_RESULTS )) && old+=(":$ref")
  done
  (( ${#old[@]} )) || return 0
  echo "devbox: deleting ${#old[@]} old results"
  git push -q origin "${old[@]}" 2>/dev/null || for ref in "${old[@]}"; do delete_ref "${ref#:}" || true; done
}

trap 'delete_ref "${OUT_PREFIX}ready"' EXIT

cleanup_old_results
ready=$STATE/ready
mkdir -p "$ready"
status "$ready" "ready" ready
{ echo "run=${GITHUB_RUN_ID:-local}"; echo "branch=$DEVBOX_WORK_BRANCH"; echo "key=$KEY"; echo "ready=$(date +%s)"
  [[ -f "$STATE/warm.txt" ]] && cat "$STATE/warm.txt"; } > "$ready/times"
publish "$ready" ready "devbox ready"

idle_since=$(date +%s)
echo "devbox: ready, watching ${CMD_PREFIX}*"

while :; do
  now=$(date +%s)
  if (( now - idle_since > IDLE )); then echo "devbox: idle for ${IDLE}s, stopping"; break; fi
  if (( now > DEADLINE )); then echo "devbox: deadline reached, stopping"; break; fi
  next_command=$(pending | head -n 1)
  if [[ -z "$next_command" ]]; then
    retry_unpublished
    (( now % 60 < POLL )) && cleanup_finished
    sleep "$POLL"; continue
  fi
  sha=${next_command%% *}
  id=${next_command#* }
  received=$(date +%s)
  if ! git fetch -q --depth 1 origin "$sha"; then sleep "$POLL"; continue; fi
  cmd=$(git show "$sha:cmd.sh" 2>/dev/null)
  echo "$id" >> "$consumed"
  delete_ref "$CMD_PREFIX$id" || echo "::warning::devbox: could not delete the branch of $id (it will not run again)"
  [[ "$id" =~ ^[A-Za-z0-9_-]+$ ]] || continue
  out=$STATE/out-$id
  rm -rf "$out"; mkdir -p "$out/files"
  if [[ "$id" == *-stop || "$id" == *-kill ]]; then
    status "$out" "$id" done 0
    echo "received=$received" > "$out/times"
    publish_final "$out" "$id" "devbox $id (nothing running)"
    echo "$(date +%s) $id" >> "$finished_list"
    if [[ "$id" == *-stop ]]; then echo "devbox: stop requested"; break; fi
    continue
  fi

  # The latest commit of the work branch, keeping ignored and untracked build output. If it cannot be had,
  # the command is not run: its result would be about older code.
  started=$(date +%s)
  log=$STATE/log-$id.txt
  if ! sync_log=$(git fetch -q --depth 1 origin "refs/heads/$DEVBOX_WORK_BRANCH" 2>&1 && git checkout -q --force --detach FETCH_HEAD 2>&1); then
    { echo "$sync_log"; echo "devbox: could not move to the latest commit of $DEVBOX_WORK_BRANCH; the command was not run"; } > "$log"
    { echo "received=$received"; echo "started=$started"; echo "finished=$(date +%s)"; } > "$out/times"
    cp "$log" "$out/log.tail.txt"
    status "$out" "$id" done 125
    publish_final "$out" "$id" "devbox $id not run"
    echo "$(date +%s) $id" >> "$finished_list"
    idle_since=$(date +%s)
    continue
  fi
  synced=$(git rev-parse HEAD)
  { [[ -n "$sync_log" ]] && echo "$sync_log"; } > "$log"
  status "$out" "$id" running
  { echo "received=$received"; echo "started=$started"; echo "commit=$synced"; } > "$out/times"
  publish "$out" "$id" "devbox $id running"

  set -m
  DEVBOX_FILES="$out/files" DEVBOX_ID="$id" bash -c "set -m; $cmd" >> "$log" 2>&1 < /dev/null &
  pid=$!
  set +m
  next=$(( $(date +%s) + PROGRESS ))
  stop_after=""
  killed=""
  while kill -0 "$pid" 2>/dev/null; do
    sleep 1
    now=$(date +%s)
    if [[ -z "$killed" ]] && (( now - started > COMMAND_MAX || now > DEADLINE )); then
      echo "devbox: command $id ended by the time limit" >> "$log"
      killed=pending
    fi
    if (( now >= next )); then
      tail -n 200 "$log" > "$out/log.tail.txt"
      publish "$out" "$id" "devbox $id running"
      next=$(( now + PROGRESS ))
      # A kill or stop sent while this command runs. Other commands wait for their turn.
      while read -r _ control; do
        [[ "$control" == *-kill || "$control" == *-stop ]] || continue
        delete_ref "$CMD_PREFIX$control"
        [[ "$control" == *-stop ]] && stop_after=yes
        echo "devbox: command $id ended by $control" >> "$log"
        [[ -z "$killed" ]] && killed=pending
      done < <(pending)
    fi
    if [[ "$killed" == pending ]]; then
      signal_tree TERM "$pid"
      sleep 5
      signal_tree KILL "$pid"
      killed=done
    fi
  done
  wait "$pid"; code=$?
  finished=$(date +%s)
  echo "finished=$finished" >> "$out/times"
  tail -n 400 "$log" > "$out/log.tail.txt"
  gzip -c "$log" > "$out/log.txt.gz"
  status "$out" "$id" done "$code"
  publish_final "$out" "$id" "devbox $id exit $code"
  echo "$finished $id" >> "$finished_list"
  echo "devbox: $id exit $code in $(( finished - started ))s"
  idle_since=$(date +%s)
  if [[ -n "$stop_after" ]]; then echo "devbox: stop requested"; break; fi
done
retry_unpublished
