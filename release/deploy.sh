#!/usr/bin/env bash
# Put a published bandy release on the jukebox and switch to it, or roll back.
#
#   deploy.sh <tag>        download, check, extract, test, switch, prune
#   deploy.sh --rollback   test the other kept release, then switch to it
#
# Works only in ~/bandy/releases/, ~/bandy/current, and its own dir under ~/tmp/
# (the SD card; /tmp is RAM on the jukebox). bandy's state in ~/bandy (.env,
# store/, logs/, downloads/, collection/) is never touched. Any failure before the
# switch leaves ~/bandy/current where it was and names the step that failed.
#
# Refuses to run while bandy is running, or while another deploy.sh is.
#
# Test-only: BANDY_DEPLOY_BASE_URL replaces the GitHub release URL, so CI can
# serve doctored tarballs from file://. Never set it on the jukebox.
set -euo pipefail

BASE_URL=${BANDY_DEPLOY_BASE_URL:-https://github.com/jnf/bandy/releases/download}
ROOT="$HOME/bandy"
RELEASES="$ROOT/releases"
CURRENT="$ROOT/current"
KEEP=2

step="setup"
work=""
staging=""
aside=""
newlink=""

say() { printf '==> %s\n' "$*"; }
die() { printf 'deploy.sh: %s\n' "$*" >&2; exit 1; }

health() {
  local avail swap
  avail=$(awk '/^MemAvailable:/ { printf "%d", $2 / 1024 }' /proc/meminfo)
  swap=$(awk '/^SwapTotal:/ { t = $2 } /^SwapFree:/ { f = $2 } END { printf "%d", (t - f) / 1024 }' /proc/meminfo)
  say "health ($1): load $(cut -d' ' -f1-3 /proc/loadavg), ${avail}M available, ${swap}M swap used"
}

cleanup() {
  local status=$?
  [ -z "$newlink" ] || rm -f "$newlink"
  [ -z "$staging" ] || rm -rf "$staging"
  [ -z "$aside" ] || rm -rf "$aside"
  [ -z "$work" ] || rm -rf "$work"
  if [ "$status" -ne 0 ]; then
    if [ "$step" = "prune" ]; then
      printf 'deploy.sh: switched, but pruning failed; current -> %s\n' "$(readlink "$CURRENT" 2>/dev/null || echo '?')" >&2
    else
      printf 'deploy.sh: FAILED at step: %s. current is unchanged: %s\n' \
        "$step" "$(readlink "$CURRENT" 2>/dev/null || echo '(none)')" >&2
    fi
  fi
  exit "$status"
}
trap cleanup EXIT

usage() {
  echo "usage: deploy.sh <tag> | deploy.sh --rollback" >&2
  exit 2
}

# bandy is a ruby process with bandy.rb in its argv: `current/ruby/bin/ruby
# current/bandy.rb` under cron, or any older way of starting it. Read /proc
# directly: comm must be exactly `ruby` (so an editor or a shell mentioning
# bandy.rb doesn't count) and one argv element must be a file named bandy.rb.
bandy_pids() {
  local d pid comm arg
  for d in /proc/[0-9]*; do
    pid=${d#/proc/}
    [ "$pid" != "$$" ] || continue
    comm=$(cat "$d/comm" 2>/dev/null) || continue
    [ "$comm" = "ruby" ] || continue
    while IFS= read -r -d '' arg; do
      if [ "${arg##*/}" = "bandy.rb" ]; then
        echo "$pid"
        break
      fi
    done 2>/dev/null < "$d/cmdline" || true
  done
}

refuse_if_bandy_running() {
  local pids pid
  pids=$(bandy_pids)
  if [ -n "$pids" ]; then
    for pid in $pids; do
      printf '  %s: %s\n' "$pid" "$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)" >&2
    done
    die "bandy is running (PID $(echo $pids)); try again when it's done"
  fi
}

# The release's suite, with the release's own Ruby and gems, run from a scratch
# dir under ~/tmp so its logs/ and temp files never land in the release or in
# ~/bandy/logs. Passes only on exit 0 and a minitest summary with no failures or
# errors. Niced: playback comes first.
run_suite() {
  local rel=$1 dir="$work/suite" status summary
  mkdir -p "$dir/logs" "$dir/tmp"
  health "before suite"
  set +e
  (
    unset RUBYOPT RUBYLIB GEM_HOME GEM_PATH BUNDLE_PATH BUNDLE_APP_CONFIG
    export BUNDLE_GEMFILE="$rel/Gemfile" TMPDIR="$dir/tmp" PATH="$rel/ruby/bin:$PATH"
    cd "$dir" && nice -n 10 "$rel/ruby/bin/ruby" -S bundle exec ruby "$rel/test/run.rb"
  ) 2>&1 | tee "$work/suite.out"
  status=${PIPESTATUS[0]}
  set -e
  health "after suite"
  summary=$(grep -E '^[0-9]+ runs, [0-9]+ assertions, [0-9]+ failures, [0-9]+ errors' "$work/suite.out" | tail -1 || true)
  [ -n "$summary" ] || die "suite crashed (exit $status): no minitest summary"
  say "suite: $summary (exit $status)"
  [ "$status" -eq 0 ] || die "suite failed (exit $status): $summary"
  echo "$summary" | grep -qE ' 0 failures, 0 errors' || die "suite failed: $summary"
}

# Point current at releases/<name>: a new symlink under a temp name, renamed over
# current in one rename(2). Readers see the old target or the new, never neither.
switch_to() {
  newlink="$ROOT/.current.new.$$"
  ln -sfn "releases/$1" "$newlink"
  mv -T "$newlink" "$CURRENT"
  newlink=""
  say "current -> releases/$1"
}

current_name() {
  if [ -L "$CURRENT" ]; then
    local t
    t=$(readlink "$CURRENT")
    echo "${t##*/}"
  fi
}

[ $# -eq 1 ] || usage
case "$1" in
  --rollback) mode=rollback ;;
  -*) usage ;;
  *) mode=deploy; tag=$1 ;;
esac

if [ "$mode" = deploy ]; then
  # The tag becomes a path and a URL: a date tag or an rc tag, nothing else.
  [[ $tag =~ ^v[0-9][0-9A-Za-z.-]*$ ]] && [[ $tag != *..* ]] || die "not a release tag: $tag"
fi
case "$BASE_URL" in
  https://*) proto="=https" ;;
  file://*) proto="=file"; say "TEST ONLY: BANDY_DEPLOY_BASE_URL=$BASE_URL" ;;
  *) die "BANDY_DEPLOY_BASE_URL must be https:// or file://" ;;
esac

[ -d "$ROOT" ] || die "no $ROOT"
if [ -e "$CURRENT" ] && [ ! -L "$CURRENT" ]; then
  die "$CURRENT exists and isn't a symlink; refusing to replace it"
fi
for tool in curl sha256sum tar flock; do
  command -v "$tool" > /dev/null || die "needs $tool"
done
mkdir -p "$RELEASES" "$HOME/tmp"

# One deploy at a time.
exec 9> "$RELEASES/.lock"
flock -n 9 || die "another deploy.sh is running"

refuse_if_bandy_running

before=$(current_name)
work=$(mktemp -d "$HOME/tmp/bandy-deploy.XXXXXX")

if [ "$mode" = rollback ]; then
  [ -n "$before" ] || die "nothing to roll back from: no current"
  others=()
  for d in "$RELEASES"/*/; do
    d=${d%/}
    [ -d "$d" ] || continue
    [ "${d##*/}" = "$before" ] || others+=("${d##*/}")
  done
  [ "${#others[@]}" -eq 1 ] || die "rollback needs exactly one other release in $RELEASES; found ${#others[@]}: ${others[*]:-}"
  target=${others[0]}
  say "rolling back: $before -> $target"
  step="rollback suite ($target)"
  run_suite "$RELEASES/$target"
  step="switch"
  switch_to "$target"
  say "rolled back to $target"
  exit 0
fi

if [ "$before" = "$tag" ]; then
  say "$tag is already current; nothing to do"
  exit 0
fi

asset="bandy-$tag-aarch64-linux.tar.gz"
url="$BASE_URL/$tag/$asset"

step="1 download"
say "step $step: $url"
health "before download"
for f in "$asset" "$asset.sha256"; do
  curl -q --fail --location --silent --show-error --retry 2 --connect-timeout 20 \
    --proto "$proto" --proto-redir "$proto" -o "$work/$f" "$url${f#"$asset"}"
done
ls -l "$work/$asset"

step="2 sha256"
say "step $step"
# Exactly one line, naming this asset: sha256sum -c would follow any path it named.
line=$(cat "$work/$asset.sha256")
[[ $line =~ ^([0-9a-f]{64})\ [\ *](.+)$ ]] && [ "${BASH_REMATCH[2]}" = "$asset" ] \
  || die "$asset.sha256 isn't one sha256sum line for $asset"
want=${BASH_REMATCH[1]}
got=$(sha256sum "$work/$asset" | cut -d' ' -f1)
[ "$got" = "$want" ] || die "sha256 mismatch: published $want, downloaded $got"
say "sha256 ok: $got"

step="3 extract"
say "step $step"
# Into a hidden staging dir beside releases/<tag> (same filesystem, so the move
# into place is a rename). releases/<tag> only ever holds a release that passed.
staging=$(mktemp -d "$RELEASES/.staging-$tag.XXXXXX")
nice -n 10 tar -xzf "$work/$asset" -C "$staging"
rm -f "$work/$asset"
[ -x "$staging/ruby/bin/ruby" ] && [ -f "$staging/test/run.rb" ] || die "$asset isn't a bandy release"
cat "$staging/REVISION"

step="4 suite"
say "step $step"
run_suite "$staging"

step="5 switch"
say "step $step"
if [ -e "$RELEASES/$tag" ]; then
  # A redeploy of a kept, non-current tag: these fresh, checked bytes replace it.
  aside="$RELEASES/.replaced-$tag.$$"
  mv "$RELEASES/$tag" "$aside"
fi
mv "$staging" "$RELEASES/$tag"
staging=""
switch_to "$tag"
grep -q "^tag=$tag\$" "$CURRENT/REVISION" || say "warning: current/REVISION doesn't name $tag"

step="prune"
# Keep two (D11): the new current and what was current before it. Everything
# else goes, including staging left by a deploy that was killed.
for d in "$RELEASES"/* "$RELEASES"/.staging-* "$RELEASES"/.replaced-*; do
  [ -e "$d" ] || continue
  name=${d##*/}
  [ "$name" = "$tag" ] && continue
  [ -n "$before" ] && [ "$name" = "$before" ] && continue
  [ "$d" = "$aside" ] && continue
  say "pruning $name"
  rm -rf "$d"
done
kept=$(cd "$RELEASES" && ls -1)
say "kept: $(echo $kept)"
[ "$(echo "$kept" | wc -l)" -le "$KEEP" ] || die "more than $KEEP releases left"

step="done"
say "deployed $tag"
