#!/usr/bin/env bash
# Prove an extracted Ruby runs from where it sits, not where it was built.
#
#   release/probe-ruby.sh <dir>    (<dir> holds bin/ruby, e.g. the tarball's ruby/)
#
# Exits non-zero on the first failed check and names it. Needs no compiler and
# no network; safe to run on the jukebox from ~/tmp.
set -uo pipefail

if [ $# -ne 1 ] || [ ! -d "$1" ]; then
  echo "usage: $0 <dir>" >&2
  exit 2
fi
dir=$(cd "$1" && pwd -P)
ruby="$dir/bin/ruby"
checks=0

fail() {
  echo "probe-ruby: FAIL [$1] $2" >&2
  exit 1
}
pass() {
  checks=$((checks + 1))
  echo "probe-ruby: ok   [$1]${2:+ $2}"
}

# Nothing from the caller's environment may point Ruby somewhere else.
unset RUBYOPT RUBYLIB GEM_HOME GEM_PATH BUNDLE_GEMFILE BUNDLE_PATH

[ -x "$ruby" ] || fail exists "no executable at $ruby"
pass exists "$ruby"

desc=$("$ruby" -e 'print RUBY_DESCRIPTION' 2>&1) || fail runs "$ruby did not start: $desc"
pass runs
echo "$desc"

for lib in openssl psych zlib fiddle bigdecimal json; do
  err=$("$ruby" -e "require '$lib'" 2>&1) || fail "require $lib" "$err"
  pass "require $lib"
done

relative=$("$ruby" -rrbconfig -e 'print RbConfig::CONFIG["LIBRUBY_RELATIVE"]' 2>&1)
[ "$relative" = yes ] || fail libruby_relative "RbConfig::CONFIG[\"LIBRUBY_RELATIVE\"] is \"$relative\", want \"yes\""
pass libruby_relative

prefix=$("$ruby" -rrbconfig -e 'print File.realpath(RbConfig::CONFIG["prefix"])' 2>&1)
[ "$prefix" = "$dir" ] || fail prefix "RbConfig prefix is $prefix, want $dir"
pass prefix

stray=$("$ruby" -e 'd = ARGV[0]; puts $LOAD_PATH.map { File.expand_path(_1) }.reject { _1.start_with?(d + "/") }' "$dir" 2>&1) \
  || fail load_path "$stray"
[ -z "$stray" ] || fail load_path "entries outside $dir: $stray"
pass load_path

# The binstubs carry a shebang; a baked-in build path would break them here.
for stub in gem bundle; do
  v=$("$dir/bin/$stub" --version 2>&1) || fail "bin/$stub" "$v"
  pass "bin/$stub" "$v"
done

ssl=$("$ruby" -ropenssl -e 'print OpenSSL::OPENSSL_LIBRARY_VERSION' 2>&1) || fail openssl_version "$ssl"
pass openssl_version "$ssl"

echo "probe-ruby: OK, $checks checks, $dir"
