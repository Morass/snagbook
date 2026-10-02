#!/bin/bash
set -eu

repo=$(mktemp -d)
trap 'rm -rf "$repo"' EXIT
mkdir "$repo/scripts"
cp "$(dirname "$0")/prepublish-check.sh" "$repo/scripts/prepublish-check.sh"
cd "$repo"
git init -q
git config user.name Snagbook
git config user.email snagbook@users.noreply.github.com
printf '%s\n' '{"icon":"128x128@2x.png"}' > config.json
printf '%s\n' 'MIT License' > LICENSE
git add .
git commit -qm 'Test icon filename'

output=$(scripts/prepublish-check.sh)
test "$output" = '✓ nothing personal or private found'
