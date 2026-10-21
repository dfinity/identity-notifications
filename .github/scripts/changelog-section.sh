#!/usr/bin/env bash
# Prints the `## <version>` section of a changelog, and fails when the section
# is missing or has no entries.
#
# Usage: changelog-section.sh <Changelog.md> <version>
set -euo pipefail

changelog=$1
version=$2

section=$(awk -v heading="## $version" '
  $0 == heading { found = 1; next }
  found && /^## / { exit }
  found { print }
' "$changelog")

if ! grep -q '[^[:space:]]' <<<"$section"; then
  echo "::error file=$changelog::No entries under \"## $version\" in $changelog. Rename \"## Next\" to \"## $version\" before tagging (see Releasing.md)." >&2
  exit 1
fi

printf '%s\n' "$section" | sed -e '/./,$!d'
