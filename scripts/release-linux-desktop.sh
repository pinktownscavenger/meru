#!/usr/bin/env bash
# release-linux-desktop.sh asks GitHub Actions to build the Ubuntu desktop
# package from one exact commit, waits for that run and checks its one artifact.
set -euo pipefail

repo=aarora79/meru
workflow=linux-desktop-release.yml

# fail prints one handoff error and stops before a package reaches dist.
fail() {
  printf 'release-linux-desktop: %s\n' "$*" >&2
  exit 1
}

[ "$#" -eq 3 ] || fail "usage: release-linux-desktop.sh VERSION COMMIT DIST_DIR"
version=$1
commit=$2
dist_dir=$3
[[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "VERSION must look like v0.5.0"
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || fail "COMMIT must be 40 lower-case hexadecimal characters"
command -v gh >/dev/null 2>&1 || fail "gh is not installed"

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
title="Meru desktop $version $commit"
artifact="meru-desktop-$version-$commit"
package_name="Meru-$version-linux-amd64.deb"

printf 'release-linux-desktop: dispatch %s\n' "$title"
gh workflow run "$workflow" --repo "$repo" \
  -f "version=$version" -f "commit=$commit"

# GitHub can take a few seconds to list a run after accepting a dispatch. Six
# short checks cover that delay without choosing among ambiguous matching runs.
match_count=0
attempt=1
while [ "$attempt" -le 6 ]; do
  runs=$(gh run list --repo "$repo" --workflow "$workflow" \
    --event workflow_dispatch --limit 100 \
    --json databaseId,displayTitle,url \
    --template '{{range .}}{{printf "%v\t%s\t%s\n" .databaseId .displayTitle .url}}{{end}}')
  match_count=0
  run_id=
  run_url=
  while IFS=$'\t' read -r candidate_id candidate_title candidate_url; do
    [ "$candidate_title" = "$title" ] || continue
    match_count=$((match_count + 1))
    run_id=$candidate_id
    run_url=$candidate_url
  done <<< "$runs"
  [ "$match_count" -eq 0 ] || break
  attempt=$((attempt + 1))
  [ "$attempt" -gt 6 ] || sleep 5
done

[ "$match_count" -ne 0 ] || fail "found no run named $title"
[ "$match_count" -eq 1 ] || fail "found $match_count runs named $title"
printf 'release-linux-desktop: run %s\n' "$run_url"

gh run watch "$run_id" --repo "$repo" --exit-status || \
  fail "GitHub Actions run $run_id did not succeed"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
download_dir="$work/artifact"
mkdir -p "$download_dir"
gh run download "$run_id" --repo "$repo" --name "$artifact" --dir "$download_dir"

file_count=0
downloaded=
while IFS= read -r file; do
  file_count=$((file_count + 1))
  downloaded=$file
done < <(find "$download_dir" -type f -print)
[ "$file_count" -eq 1 ] || fail "artifact must contain exactly one file; found $file_count"
[ "$(basename "$downloaded")" = "$package_name" ] || \
  fail "artifact has $(basename "$downloaded"); expected $package_name"

bash "$script_dir/check-deb.sh" "$version" "$commit" "$downloaded"
mkdir -p "$dist_dir"
install -m 0644 "$downloaded" "$dist_dir/$package_name"
printf 'release-linux-desktop: checked %s\n' "$dist_dir/$package_name"
