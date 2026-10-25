#!/usr/bin/env bash
# release-linux-desktop_test.sh checks the GitHub handoff without contacting
# GitHub. A fake gh records each command and supplies controlled run results.
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
helper="$repo_root/scripts/release-linux-desktop.sh"
version=v0.4.12
commit=0123456789abcdef0123456789abcdef01234567
passed=0

fail_test() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  case $1 in
    *"$2"*) ;;
    *) fail_test "expected output to contain: $2" ;;
  esac
}

assert_file_contains() {
  grep -F -- "$2" "$1" >/dev/null || fail_test "$1 does not contain: $2"
}

new_case() {
  case_dir=$(mktemp -d)
  fake_bin="$case_dir/bin"
  dist="$case_dir/dist"
  log="$case_dir/gh.log"
  GH_RUNS=
  GH_WATCH_STATUS=0
  GH_DOWNLOAD_SOURCE=
  mkdir -p "$fake_bin" "$dist"

  cat > "$fake_bin/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$fake_bin/sleep"

  cat > "$fake_bin/gh" <<'EOF'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$GH_LOG"
case "$1 $2" in
  "workflow run") exit 0 ;;
  "run list") printf '%b' "${GH_RUNS:-}" ;;
  "run watch") exit "${GH_WATCH_STATUS:-0}" ;;
  "run download")
    if [ -n "${GH_DOWNLOAD_SOURCE:-}" ]; then
      while [ "$#" -gt 0 ]; do
        if [ "$1" = "--dir" ]; then
          shift
          mkdir -p "$1"
          cp -R "$GH_DOWNLOAD_SOURCE"/. "$1"/
          exit 0
        fi
        shift
      done
    fi
    exit 1
    ;;
  *) exit 2 ;;
esac
EOF
  chmod +x "$fake_bin/gh"
}

run_helper() {
  set +e
  output=$(PATH="$fake_bin:$PATH" GH_LOG="$log" GH_RUNS="${GH_RUNS:-}" \
    GH_WATCH_STATUS="${GH_WATCH_STATUS:-0}" \
    GH_DOWNLOAD_SOURCE="${GH_DOWNLOAD_SOURCE:-}" \
    bash "$helper" "$version" "$commit" "$dist" 2>&1)
  status=$?
  set -e
}

make_package() {
  package_dir="$case_dir/package"
  package_stage="$case_dir/package-stage"
  control="$package_stage/control"
  data="$package_stage/data"
  mkdir -p "$package_dir" "$control" "$data/usr/bin" \
    "$data/usr/share/applications" \
    "$data/usr/share/icons/hicolor/512x512/apps" \
    "$data/usr/share/doc/meru-desktop"
  printf '%s\n' \
    'Package: meru-desktop' \
    "Version: ${version#v}" \
    'Architecture: amd64' \
    'Depends: libgtk-4-1, libwebkitgtk-6.0-4, xdg-utils' \
    "X-Meru-Commit: $commit" \
    'Description: Meru desktop app' > "$control/control"
  printf '#!/bin/sh\necho %s\n' "$version" > "$data/usr/bin/meru-desktop"
  chmod 0755 "$data/usr/bin/meru-desktop"
  cp "$repo_root/deploy/linux/com.meru.desktop.desktop" \
    "$data/usr/share/applications/"
  printf 'png\n' > "$data/usr/share/icons/hicolor/512x512/apps/com.meru.desktop.png"
  cp "$repo_root/LICENSE" "$data/usr/share/doc/meru-desktop/copyright"
  chmod 0644 "$data/usr/share/applications/com.meru.desktop.desktop" \
    "$data/usr/share/icons/hicolor/512x512/apps/com.meru.desktop.png" \
    "$data/usr/share/doc/meru-desktop/copyright"
  printf '2.0\n' > "$package_stage/debian-binary"
  # xz, as scripts/package-deb.sh builds it; check-deb.sh refuses gzip.
  tar -cJf "$package_stage/control.tar.xz" -C "$control" .
  tar -cJf "$package_stage/data.tar.xz" -C "$data" .
  (cd "$package_stage" && ar -qSc \
    "$package_dir/Meru-$version-linux-amd64.deb" \
    debian-binary control.tar.xz data.tar.xz)
}

pass() {
  passed=$((passed + 1))
  echo "PASS: $1"
}

test_dispatches_exact_inputs_and_uses_run_id() {
  new_case
  make_package
  GH_RUNS="77\tMeru desktop $version $commit\thttps://example.test/runs/77\n"
  GH_DOWNLOAD_SOURCE=$package_dir
  run_helper
  [ "$status" -eq 0 ] || fail_test "$output"
  assert_file_contains "$log" "workflow run linux-desktop-release.yml --repo aarora79/meru -f version=$version -f commit=$commit"
  assert_file_contains "$log" "run watch 77 --repo aarora79/meru --exit-status"
  assert_file_contains "$log" "run download 77 --repo aarora79/meru --name meru-desktop-$version-$commit"
  assert_contains "$output" "https://example.test/runs/77"
  [ -f "$dist/Meru-$version-linux-amd64.deb" ] || fail_test "package was not copied"
  pass "test_dispatches_exact_inputs_and_uses_run_id"
}

test_zero_matching_runs_fails() {
  new_case
  GH_RUNS="81\tSome other run\thttps://example.test/runs/81\n"
  run_helper
  [ "$status" -ne 0 ] || fail_test "zero matches succeeded"
  assert_contains "$output" "found no run"
  pass "test_zero_matching_runs_fails"
}

test_duplicate_matching_runs_fail() {
  new_case
  GH_RUNS="81\tMeru desktop $version $commit\thttps://example.test/runs/81\n82\tMeru desktop $version $commit\thttps://example.test/runs/82\n"
  run_helper
  [ "$status" -ne 0 ] || fail_test "duplicate matches succeeded"
  assert_contains "$output" "found 2 runs"
  pass "test_duplicate_matching_runs_fail"
}

test_failed_or_cancelled_run_fails() {
  for conclusion in failed cancelled; do
    new_case
    GH_RUNS="91\tMeru desktop $version $commit\thttps://example.test/runs/91\n"
    GH_WATCH_STATUS=1
    run_helper
    [ "$status" -ne 0 ] || fail_test "$conclusion run succeeded"
    [ ! -e "$dist/Meru-$version-linux-amd64.deb" ] || fail_test "$conclusion run copied a package"
  done
  pass "test_failed_or_cancelled_run_fails"
}

test_wrong_artifact_count_fails() {
  new_case
  make_package
  cp "$package_dir/Meru-$version-linux-amd64.deb" "$package_dir/extra.deb"
  GH_RUNS="101\tMeru desktop $version $commit\thttps://example.test/runs/101\n"
  GH_DOWNLOAD_SOURCE=$package_dir
  run_helper
  [ "$status" -ne 0 ] || fail_test "two packages succeeded"
  assert_contains "$output" "exactly one file"
  pass "test_wrong_artifact_count_fails"
}

test_wrong_package_name_fails() {
  new_case
  make_package
  mv "$package_dir/Meru-$version-linux-amd64.deb" "$package_dir/wrong.deb"
  GH_RUNS="102\tMeru desktop $version $commit\thttps://example.test/runs/102\n"
  GH_DOWNLOAD_SOURCE=$package_dir
  run_helper
  [ "$status" -ne 0 ] || fail_test "wrong name succeeded"
  assert_contains "$output" "expected Meru-$version-linux-amd64.deb"
  pass "test_wrong_package_name_fails"
}

test_checker_failure_leaves_dist_clean() {
  new_case
  mkdir -p "$case_dir/bad"
  printf 'not a package\n' > "$case_dir/bad/Meru-$version-linux-amd64.deb"
  GH_RUNS="103\tMeru desktop $version $commit\thttps://example.test/runs/103\n"
  GH_DOWNLOAD_SOURCE="$case_dir/bad"
  run_helper
  [ "$status" -ne 0 ] || fail_test "bad package succeeded"
  [ ! -e "$dist/Meru-$version-linux-amd64.deb" ] || fail_test "bad package reached dist"
  pass "test_checker_failure_leaves_dist_clean"
}

test_bad_arguments_stop_before_dispatch() {
  new_case
  set +e
  output=$(PATH="$fake_bin:$PATH" GH_LOG="$log" bash "$helper" 0.4.12 "$commit" "$dist" 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail_test "bad version succeeded"
  [ ! -s "$log" ] || fail_test "bad version reached gh"
  pass "test_bad_arguments_stop_before_dispatch"
}

test_publisher_checks_deb_before_hash_and_tag() {
  release_script="$repo_root/scripts/release.sh"
  helper_line=$(grep -nF 'bash scripts/release-linux-desktop.sh "$version" "$commit" dist' \
    "$release_script" | cut -d: -f1)
  hash_line=$(grep -nF 'shasum -a 256 *.tar.gz *.zip *.dmg *.deb' \
    "$release_script" | cut -d: -f1)
  tag_line=$(grep -nF 'git tag -a "$version"' "$release_script" | cut -d: -f1)
  [ -n "$helper_line" ] && [ "$helper_line" -lt "$hash_line" ] && \
    [ "$hash_line" -lt "$tag_line" ] || fail_test "publisher orders the Linux check after a hash or tag"
  assert_file_contains "$release_script" 'dist/*.dmg dist/*.deb dist/SHA256SUMS'
  assert_file_contains "$release_script" 'gh auth status'
  pass "test_publisher_checks_deb_before_hash_and_tag"
}

test_dispatches_exact_inputs_and_uses_run_id
test_zero_matching_runs_fails
test_duplicate_matching_runs_fail
test_failed_or_cancelled_run_fails
test_wrong_artifact_count_fails
test_wrong_package_name_fails
test_checker_failure_leaves_dist_clean
test_bad_arguments_stop_before_dispatch
test_publisher_checks_deb_before_hash_and_tag

echo "PASS: $passed Linux desktop release handoff tests"
