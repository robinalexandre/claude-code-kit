#!/bin/bash
# Git merge driver for the files of the encrypted folders (see .gitattributes and git_setup in
# sync.sh). Git hands a merge driver the files as stored, encrypted, so they would conflict every
# time both machines changed one: this one decrypts them, merges JSON by key as json-merge.sh
# does and other text line by line, and encrypts the result again. Without the key, a conflict.
#   crypt-merge.sh BASE OURS THEIRS PATH    writes the result to OURS
set -u
dir=$(dirname "${BASH_SOURCE[0]}")
tmp=$(mktemp -d "${TMPDIR:-/tmp}/crypt-merge.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT

is_cipher() { [ "$(LC_ALL=C head -c 10 "$1" | LC_ALL=C tr -d '\0')" = GITCRYPT ]; }

# plain FILE OUT: FILE decrypted to OUT, as it is when it was not encrypted.
plain() {
  if [ ! -s "$1" ]; then
    : > "$2"
  elif is_cipher "$1"; then
    git-crypt smudge < "$1" > "$2" 2> /dev/null && ! is_cipher "$2"
  else
    cp "$1" "$2"
  fi
}

plain "$1" "$tmp/base" && plain "$2" "$tmp/ours" && plain "$3" "$tmp/theirs" || exit 1
case "$4" in
  *.json)
    bash "$dir/json-merge.sh" "$tmp/base" "$tmp/ours" "$tmp/theirs" || exit 1
    rc=0
    ;;
  *)
    git merge-file -q "$tmp/ours" "$tmp/base" "$tmp/theirs"
    rc=$?
    ;;
esac
if is_cipher "$2" || is_cipher "$3"; then
  git-crypt clean < "$tmp/ours" > "$tmp/out" 2> /dev/null && is_cipher "$tmp/out" || exit 1
  mv "$tmp/out" "$2"
else
  mv "$tmp/ours" "$2"
fi
[ "$rc" -eq 0 ]
