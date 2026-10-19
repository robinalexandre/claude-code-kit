#!/bin/zsh
# usage: to_photos.sh <file>...
# Saves the files to the Photos library with "Add Photos Only" access (the
# helper cannot see the library), then deletes the local copies once Photos
# has confirmed the save.
set -eu
here=${0:A:h}
src=$here/save-to-photos
app=$src/SaveToPhotos.app

if [[ ! -x $app/Contents/MacOS/SaveToPhotos ]]; then
  mkdir -p $app/Contents/MacOS
  cp $src/Info.plist $app/Contents/
  swiftc -O -swift-version 5 -o $app/Contents/MacOS/SaveToPhotos $src/main.swift
  codesign --force -s - $app
fi

files=(${@:A})
out=$(mktemp) err=$(mktemp)
open -W -n -a $app --stdout $out --stderr $err --args $files
result=$(<$out) problem=$(<$err)
rm -f $out $err

if [[ $result == "saved ${#files}" ]]; then
  rm -f -- $files
  echo "saved ${#files} file(s) to Photos and deleted the local copies"
else
  echo "Photos did not confirm the save, local files kept. ${problem}" >&2
  exit 1
fi
