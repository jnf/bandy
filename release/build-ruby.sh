#!/usr/bin/env bash
# Build the Ruby named in .ruby-version as a relocatable install, and tar it.
#
#   release/build-ruby.sh [out-dir]    (default: ./dist)
#
# Runs as root in a debian:trixie arm64 container (release.yml's `ruby` job), so
# glibc and the library sonames match the jukebox (DietPi = Debian 13 Trixie).
# Output: <out-dir>/ruby-<version>-aarch64-linux.tar.gz, one top-level ruby/ dir.
set -euo pipefail

# ruby-build v20261023, the tag the jukebox built 4.0.9 with. ruby-build checks
# Ruby's source tarball against its own sha256 table, so pinning this pins Ruby.
RUBY_BUILD_SHA=b6a92c15f0df872047c74f7dfa0b92dfd4de8a92

root=$(cd "$(dirname "$0")/.." && pwd)
version=$(tr -d '[:space:]' < "$root/.ruby-version")
out=$(mkdir -p "${1:-$root/dist}" && cd "${1:-$root/dist}" && pwd)

# Where Ruby is built and installed. With --enable-load-relative nothing depends
# on this path at runtime; it only has to differ from where the tarball lands.
RUBY_PREFIX=/opt/bandy-build/ruby-$version

# Matches the box: no YJIT (and no rustc installed to build one), no docs.
# Shared libruby comes from ruby-build's definition (enable_shared).
CONFIGURE_OPTS="--enable-load-relative --disable-install-doc --disable-yjit"

echo "==> build deps"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q --no-install-recommends \
  ca-certificates curl git build-essential \
  libssl-dev libyaml-dev zlib1g-dev libffi-dev libgmp-dev

echo "==> ruby-build at $RUBY_BUILD_SHA"
src=$(mktemp -d)
git -C "$src" init -q
git -C "$src" fetch -q --depth 1 https://github.com/rbenv/ruby-build.git "$RUBY_BUILD_SHA"
git -C "$src" checkout -q FETCH_HEAD

echo "==> ruby $version into $RUBY_PREFIX ($CONFIGURE_OPTS)"
rm -rf "$RUBY_PREFIX"
MAKE_OPTS="-j$(nproc)" RUBY_CONFIGURE_OPTS="$CONFIGURE_OPTS" \
  "$src/bin/ruby-build" "$version" "$RUBY_PREFIX"
"$RUBY_PREFIX/bin/ruby" -v

tarball="$out/ruby-$version-aarch64-linux.tar.gz"
base=$(basename "$RUBY_PREFIX")
echo "==> $tarball"
# Rename the top-level dir to ruby/ (S: leave symlink targets alone).
tar -C "$(dirname "$RUBY_PREFIX")" --owner=0 --group=0 --numeric-owner \
  --transform "s,^$base,ruby,S" -czf "$tarball" "$base"

installed=$(du -sh "$RUBY_PREFIX" | cut -f1)
size=$(du -h "$tarball" | cut -f1)
bytes=$(stat -c %s "$tarball")
sha=$(sha256sum "$tarball" | cut -d' ' -f1)
echo "installed $installed, tarball $size ($bytes bytes), sha256 $sha"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### ruby-$version-aarch64-linux.tar.gz"
    echo "- configure: \`$CONFIGURE_OPTS\`"
    echo "- installed: $installed; tarball: $size ($bytes bytes)"
    echo "- sha256: \`$sha\`"
  } >> "$GITHUB_STEP_SUMMARY"
fi
