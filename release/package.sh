#!/usr/bin/env bash
# Package a bandy release: the relocatable Ruby, bandy's gems, and bandy's code.
#
#   release/package.sh <ruby-tarball> [out-dir] [tag]    (out-dir default: ./dist)
#
# Runs as root in a debian:trixie arm64 container (release.yml's `package` job):
# native gems compile here, against the shipped Ruby, so nothing compiles on the
# jukebox. <ruby-tarball> is build-ruby.sh's output.
#
# Output, in <out-dir>:
#   bandy-<tag>-aarch64-linux.tar.gz          (bandy-<sha12>-... without a tag)
#   bandy-<tag>-aarch64-linux.tar.gz.sha256   (sha256sum format)
# The tarball has no top-level dir: extract it into the release dir, then
#   cd <dir> && PATH="$PWD/ruby/bin:$PATH" ruby -S bundle exec ruby test/run.rb
set -euo pipefail

if [ $# -lt 1 ] || [ ! -f "$1" ]; then
  echo "usage: $0 <ruby-tarball> [out-dir] [tag]" >&2
  exit 2
fi

root=$(cd "$(dirname "$0")/.." && pwd)
ruby_tarball=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
out=$(mkdir -p "${2:-$root/dist}" && cd "${2:-$root/dist}" && pwd)
tag=${3:-}
# actions/checkout in a container without git leaves no .git, so prefer CI's SHA.
sha=${GITHUB_SHA:-$(git -C "$root" rev-parse HEAD)}
asset="bandy-${tag:-${sha:0:12}}-aarch64-linux.tar.gz"

# What ships of bandy itself. test/ ships because the box runs the suite before
# switching to a release; release/deploy.sh ships so each release carries the
# deploy.sh CI tested with it, run on the box as current/release/deploy.sh.
CODE=(api scripts test bandy.rb Gemfile Gemfile.lock .ruby-version release/deploy.sh)

echo "==> build deps"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q --no-install-recommends \
  ca-certificates build-essential \
  libssl-dev libyaml-dev zlib1g-dev libffi-dev libgmp-dev

stage=$(mktemp -d)
echo "==> staging in $stage"
tar -xzf "$ruby_tarball" -C "$stage"
[ -x "$stage/ruby/bin/ruby" ] || { echo "no ruby/bin/ruby in $ruby_tarball" >&2; exit 1; }
# --parents: release/deploy.sh lands at release/deploy.sh, not at the top.
(cd "$root" && cp -a --parents "${CODE[@]}" "$stage/")
{
  echo "sha=$sha"
  [ -z "$tag" ] || echo "tag=$tag"
} > "$stage/REVISION"

echo "==> gems: deployment mode, frozen lock, all groups, into vendor/bundle"
# Only the shipped Ruby, and nothing from the environment pointing elsewhere.
unset RUBYOPT RUBYLIB GEM_HOME GEM_PATH BUNDLE_GEMFILE BUNDLE_PATH BUNDLE_APP_CONFIG
export PATH="$stage/ruby/bin:$PATH"
(
  cd "$stage"
  # Writes .bundle/config, which ships: the relative path is resolved against
  # the Gemfile's dir, so the release finds its gems wherever it's extracted.
  bundle config set --local deployment true
  bundle config set --local path vendor/bundle
  bundle install --jobs "$(nproc)"
  bundle check
)
cat "$stage/.bundle/config"

# ELF shared objects under ruby/ and vendor/bundle: libruby and every extension.
shared_objects() {
  find "$stage/ruby" "$stage/vendor/bundle" -type f -name '*.so*' -print0 \
    | while IFS= read -r -d '' f; do
        if [ "$(head -c 4 "$f" | od -An -c | tr -d ' ')" = '177ELF' ]; then printf '%s\0' "$f"; fi
      done
}

pack() {
  tar -C "$stage" --owner=0 --group=0 --numeric-owner --sort=name \
    -czf "$1" ruby vendor .bundle REVISION "${CODE[@]}"
}

echo "==> unstripped, for the record"
so_before=$(shared_objects | du -cb --files0-from=- | tail -1 | cut -f1)
staged_before=$(du -sb "$stage" | cut -f1)
pack "$out/unstripped.tar.gz"
tar_before=$(stat -c %s "$out/unstripped.tar.gz")
rm "$out/unstripped.tar.gz"

echo "==> strip --strip-debug"
count=$(shared_objects | tr -cd '\0' | wc -c)
shared_objects | xargs -0 strip --strip-debug
so_after=$(shared_objects | du -cb --files0-from=- | tail -1 | cut -f1)
staged_after=$(du -sb "$stage" | cut -f1)

echo "==> $out/$asset"
pack "$out/$asset"
tar_after=$(stat -c %s "$out/$asset")
(cd "$out" && sha256sum "$asset" > "$asset.sha256")
cat "$out/$asset.sha256"

mib() { awk -v b="$1" 'BEGIN { printf "%.1fM", b / 1048576 }'; }
summary="shared objects stripped: $count
shared objects: $(mib "$so_before") -> $(mib "$so_after")
staged tree: $(mib "$staged_before") -> $(mib "$staged_after")
tarball: $(mib "$tar_before") ($tar_before bytes) unstripped -> $(mib "$tar_after") ($tar_after bytes) stripped"
echo "$summary"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### $asset"
    echo '```'
    echo "$summary"
    cat "$out/$asset.sha256"
    echo '```'
  } >> "$GITHUB_STEP_SUMMARY"
fi
