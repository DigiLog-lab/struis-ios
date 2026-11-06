#!/bin/bash
# Dev Box: runs the commands the web Claude sends, on this macOS runner (docs/development-method.md).
#
# Each command is its own branch `devbox-cmd/<id>` (files `cmd.sh`); its result is its own branch
# `devbox-out/<id>` (files `id`, `state`, `exit`, `times`, `log.tail.txt`, `log.txt.gz` and whatever the
# command put in "$DEVBOX_FILES"), force-pushed while it runs. One branch per command, so a command sent
# while another waits, or a result finished right after another, never overwrites it. Ids start with the
# time (scripts/devbox/mac.py), so sorting the names runs commands in the order they were sent. The server
# deletes a command's branch when it takes it; mac.py deletes a result's branch when it has read it.
# Branches are watched with `git ls-remote`, which does not count against the REST API limit of
# GITHUB_TOKEN (1,000 requests an hour per repository).
#
# `devbox-out/ready` says that this Dev Box is waiting for commands; it is deleted when the server ends.
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
CMD_PREFIX=refs/heads/devbox-cmd/
OUT_PREFIX=refs/heads/devbox-out/
IDLE=${DEVBOX_IDLE_SECONDS:-900}
POLL=${DEVBOX_POLL_SECONDS:-3}
DEADLINE=${DEVBOX_DEADLINE_EPOCH:-$(( $(date +%s) + 19800 ))}
PROGRESS=${DEVBOX_PROGRESS_SECONDS:-15}
COMMAND_MAX=${DEVBOX_COMMAND_SECONDS:-3600}
KEEP_RESULTS=${DEVBOX_KEEP_RESULTS_SECONDS:-86400}
STATE=${RUNNER_TEMP:-/tmp}/devbox
mkdir -p "$STATE"

export GIT_AUTHOR_NAME=devbox GIT_AUTHOR_EMAIL=devbox@users.noreply.github.com
export GIT_COMMITTER_NAME=devbox GIT_COMMITTER_EMAIL=devbox@users.noreply.github.com

# publish DIR NAME MESSAGE: one commit holding exactly DIR's files, force-pushed to devbox-out/NAME.
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
}

delete_ref() { git push -q origin ":$1" 2>/dev/null || true; }

# status DIR ID STATE [EXIT]: the small files of a result.
status() {
  local dir=$1
  printf '%s\n' "$2" > "$dir/id"
  printf '%s\n' "$3" > "$dir/state"
  [[ $# -ge 4 ]] && printf '%s\n' "$4" > "$dir/exit"
  return 0
}

# The waiting commands, oldest first: "<sha> <id>" per line.
pending() {
  git ls-remote origin "${CMD_PREFIX}*" | while read -r sha ref; do
    printf '%s %s\n' "$sha" "${ref#"$CMD_PREFIX"}"
  done | sort -k2
}

# Results nobody read within KEEP_RESULTS (an --async command never waited for).
cleanup_old_results() {
  local now ref id stamp when
  now=$(date +%s)
  git ls-remote origin "${OUT_PREFIX}*" | while read -r _ ref; do
    id=${ref#"$OUT_PREFIX"}
    stamp=${id%%-*}
    [[ "$stamp" =~ ^[0-9]{8}T[0-9]{6}$ ]] || continue
    when=$(date -j -u -f '%Y%m%dT%H%M%S' "$stamp" +%s 2>/dev/null || date -u -d "${stamp:0:8} ${stamp:9:2}:${stamp:11:2}:${stamp:13:2}" +%s 2>/dev/null) || continue
    (( now - when > KEEP_RESULTS )) && delete_ref "$ref"
  done
}

trap 'delete_ref "${OUT_PREFIX}ready"' EXIT

cleanup_old_results
ready=$STATE/ready
mkdir -p "$ready"
status "$ready" "ready" ready
{ echo "run=${GITHUB_RUN_ID:-local}"; echo "branch=$DEVBOX_WORK_BRANCH"; echo "ready=$(date +%s)"
  [[ -f "$STATE/warm.txt" ]] && cat "$STATE/warm.txt"; } > "$ready/times"
publish "$ready" ready "devbox ready"

idle_since=$(date +%s)
echo "devbox: ready, watching ${CMD_PREFIX}*"

while :; do
  now=$(date +%s)
  if (( now - idle_since > IDLE )); then echo "devbox: idle for ${IDLE}s, stopping"; break; fi
  if (( now > DEADLINE )); then echo "devbox: deadline reached, stopping"; break; fi
  next_command=$(pending | head -n 1)
  if [[ -z "$next_command" ]]; then sleep "$POLL"; continue; fi
  sha=${next_command%% *}
  id=${next_command#* }
  received=$(date +%s)
  if ! git fetch -q --depth 1 origin "$sha"; then sleep "$POLL"; continue; fi
  cmd=$(git show "$sha:cmd.sh" 2>/dev/null)
  delete_ref "$CMD_PREFIX$id"
  [[ "$id" =~ ^[A-Za-z0-9_-]+$ ]] || continue
  out=$STATE/out-$id
  rm -rf "$out"; mkdir -p "$out/files"
  if [[ "$id" == *-stop || "$id" == *-kill ]]; then
    status "$out" "$id" done 0
    echo "received=$received" > "$out/times"
    publish "$out" "$id" "devbox $id (nothing running)"
    if [[ "$id" == *-stop ]]; then echo "devbox: stop requested"; break; fi
    continue
  fi

  # The latest commit of the work branch, keeping ignored and untracked build output.
  sync_log=$(git fetch -q --depth 1 origin "refs/heads/$DEVBOX_WORK_BRANCH" 2>&1 && git checkout -q --force --detach FETCH_HEAD 2>&1)
  synced=$(git rev-parse HEAD)
  started=$(date +%s)
  log=$STATE/log-$id.txt
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
      kill -TERM -- "-$pid" 2>/dev/null
      sleep 5
      kill -KILL -- "-$pid" 2>/dev/null
      killed=done
    fi
  done
  wait "$pid"; code=$?
  finished=$(date +%s)
  echo "finished=$finished" >> "$out/times"
  tail -n 400 "$log" > "$out/log.tail.txt"
  gzip -c "$log" > "$out/log.txt.gz"
  status "$out" "$id" done "$code"
  publish "$out" "$id" "devbox $id exit $code"
  echo "devbox: $id exit $code in $(( finished - started ))s"
  idle_since=$(date +%s)
  if [[ -n "$stop_after" ]]; then echo "devbox: stop requested"; break; fi
done
