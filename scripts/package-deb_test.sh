#!/usr/bin/env bash
# package-deb_test.sh tests Debian package construction and inspection without Linux or dpkg.

set -u

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(cd "$script_dir/.." && pwd)"
builder="$script_dir/package-deb.sh"
checker="$script_dir/check-deb.sh"
commit=0123456789abcdef0123456789abcdef01234567
dependencies='libgtk-4-1, libwebkitgtk-6.0-4, xdg-utils'
tests_run=0
tests_failed=0

# test_fail records one failed assertion without ending the whole suite.
test_fail() {
  printf 'FAIL: %s\n' "$*" >&2
  return 1
}

# assert_equal compares two exact strings.
assert_equal() {
  local want=$1 got=$2
  [ "$got" = "$want" ] || test_fail "want '$want', got '$got'"
}

# assert_contains checks that text includes one literal part.
assert_contains() {
  local text=$1 part=$2
  case "$text" in *"$part"*) ;; *) test_fail "output does not contain '$part': $text" ;; esac
}

# mode_of prints a file's numeric mode on macOS or Linux.
mode_of() {
  case "$(uname -s)" in
    Darwin) stat -f %Lp "$1" ;;
    *) stat -c %a "$1" ;;
  esac
}

# make_binary writes a small executable that has the desktop app's --version contract.
make_binary() {
  local path=$1 version=$2
  mkdir -p "$(dirname "$path")"
  printf '#!/bin/sh\n[ "$1" = --version ] || exit 2\nprintf "%%s\\n" "%s"\n' "$version" >"$path"
  chmod 0755 "$path"
}

# make_fake_dpkg records the package root and creates the requested output file.
make_fake_dpkg() {
  local bin_dir=$1
  mkdir -p "$bin_dir"
  printf '%s\n' \
    '#!/bin/sh' \
    'set -eu' \
    '[ "$1" = --root-owner-group ] && shift' \
    '[ "$1" = --build ] || exit 2' \
    'root=$2' \
    'output=$3' \
    'mkdir -p "$FAKE_DPKG_SNAPSHOT" "$(dirname "$output")"' \
    'cp -R "$root/." "$FAKE_DPKG_SNAPSHOT/"' \
    ': >"$output"' >"$bin_dir/dpkg-deb"
  chmod 0755 "$bin_dir/dpkg-deb"
}

# make_deb writes a small Debian ar archive for the real checker.
make_deb() {
  local output=$1 version=${2:-v1.2.3} package_commit=${3:-$commit}
  local architecture=${4:-amd64} deps=${5:-$dependencies} mutation=${6:-valid}
  local dir control data
  dir=$(mktemp -d); control="$dir/control"; data="$dir/data"
  mkdir -p "$control" "$data/usr/bin" "$data/usr/share/applications" \
    "$data/usr/share/icons/hicolor/512x512/apps" "$data/usr/share/doc/meru-desktop"
  printf '%s\n' \
    'Package: meru-desktop' \
    "Version: ${version#v}" \
    "Architecture: $architecture" \
    "Depends: $deps" \
    "X-Meru-Commit: $package_commit" \
    'Description: Meru desktop app' >"$control/control"
  make_binary "$data/usr/bin/meru-desktop" "$version"
  cp "$root_dir/deploy/linux/com.meru.desktop.desktop" "$data/usr/share/applications/"
  printf 'png\n' >"$data/usr/share/icons/hicolor/512x512/apps/com.meru.desktop.png"
  cp "$root_dir/LICENSE" "$data/usr/share/doc/meru-desktop/copyright"
  chmod 0755 "$data/usr/bin/meru-desktop"
  chmod 0644 "$data/usr/share/applications/com.meru.desktop.desktop" \
    "$data/usr/share/icons/hicolor/512x512/apps/com.meru.desktop.png" \
    "$data/usr/share/doc/meru-desktop/copyright"
  case "$mutation" in
    extra) printf 'extra\n' >"$data/usr/share/doc/meru-desktop/extra" ;;
    symlink) rm "$data/usr/share/icons/hicolor/512x512/apps/com.meru.desktop.png"; ln -s /tmp/icon "$data/usr/share/icons/hicolor/512x512/apps/com.meru.desktop.png" ;;
    script) printf '#!/bin/sh\n' >"$control/postinst"; chmod 0755 "$control/postinst" ;;
    wrong-mode) chmod 0777 "$data/usr/share/applications/com.meru.desktop.desktop" ;;
    wrong-binary) make_binary "$data/usr/bin/meru-desktop" v9.9.9 ;;
  esac
  printf '2.0\n' >"$dir/debian-binary"
  tar -czf "$dir/control.tar.gz" -C "$control" .
  tar -czf "$dir/data.tar.gz" -C "$data" .
  rm -f "$output"
  (cd "$dir" && ar -qSc "$output" debian-binary control.tar.gz data.tar.gz)
  rm -rf "$dir"
}

# test_builder_writes_app_only_tree checks metadata, paths and fixed modes.
test_builder_writes_app_only_tree() {
  local dir fake snapshot output files
  dir=$(mktemp -d); fake="$dir/fake bin"; snapshot="$dir/package root"; output="$dir/output with spaces"
  make_binary "$dir/input with spaces/meru-desktop" v1.2.3
  make_fake_dpkg "$fake"
  FAKE_DPKG_SNAPSHOT="$snapshot" PATH="$fake:$PATH" \
    "$builder" v1.2.3 "$commit" "$dir/input with spaces/meru-desktop" "$output"
  [ -f "$output/Meru-v1.2.3-linux-amd64.deb" ] || test_fail "builder used the wrong output name"
  assert_contains "$(cat "$snapshot/DEBIAN/control")" 'Version: 1.2.3'
  assert_contains "$(cat "$snapshot/DEBIAN/control")" 'Architecture: amd64'
  assert_contains "$(cat "$snapshot/DEBIAN/control")" "Depends: $dependencies"
  assert_contains "$(cat "$snapshot/DEBIAN/control")" "X-Meru-Commit: $commit"
  files=$(cd "$snapshot" && find . -type f | LC_ALL=C sort)
  assert_equal $'./DEBIAN/control\n./usr/bin/meru-desktop\n./usr/share/applications/com.meru.desktop.desktop\n./usr/share/doc/meru-desktop/copyright\n./usr/share/icons/hicolor/512x512/apps/com.meru.desktop.png' "$files"
  assert_equal 755 "$(mode_of "$snapshot/usr/bin/meru-desktop")"
  assert_equal 644 "$(mode_of "$snapshot/usr/share/applications/com.meru.desktop.desktop")"
  [ -z "$(find "$snapshot/DEBIAN" -type f ! -name control -print)" ] || test_fail "builder wrote a maintainer script"
  rm -rf "$dir"
}

# test_builder_rejects_bad_inputs keeps ambiguous release data out of a package.
test_builder_rejects_bad_inputs() {
  local dir fake snapshot binary
  dir=$(mktemp -d); fake="$dir/fake"; snapshot="$dir/snapshot"; binary="$dir/meru-desktop"
  make_binary "$binary" v1.2.3
  make_fake_dpkg "$fake"
  if FAKE_DPKG_SNAPSHOT="$snapshot" PATH="$fake:$PATH" "$builder" 1.2 "$commit" "$binary" "$dir/out" >/dev/null 2>&1; then
    test_fail "builder accepted a malformed version"
  fi
  if FAKE_DPKG_SNAPSHOT="$snapshot" PATH="$fake:$PATH" "$builder" v1.2.3 abc "$binary" "$dir/out" >/dev/null 2>&1; then
    test_fail "builder accepted a malformed commit"
  fi
  chmod 0644 "$binary"
  if FAKE_DPKG_SNAPSHOT="$snapshot" PATH="$fake:$PATH" "$builder" v1.2.3 "$commit" "$binary" "$dir/out" >/dev/null 2>&1; then
    test_fail "builder accepted a non-executable binary"
  fi
  rm -rf "$dir"
}

# test_checker_accepts_valid_package exercises the inspector's macOS-compatible path.
test_checker_accepts_valid_package() {
  local dir package
  dir=$(mktemp -d); package="$dir/Meru-v1.2.3-linux-amd64.deb"
  make_deb "$package"
  "$checker" v1.2.3 "$commit" "$package"
  rm -rf "$dir"
}

# test_checker_rejects_identity_drift checks version, commit, architecture and dependencies.
test_checker_rejects_identity_drift() {
  local dir package field
  dir=$(mktemp -d); package="$dir/Meru-v1.2.3-linux-amd64.deb"
  for field in version commit architecture dependencies; do
    case "$field" in
      version) make_deb "$package" v1.2.4 ;;
      commit) make_deb "$package" v1.2.3 fedcba9876543210fedcba9876543210fedcba98 ;;
      architecture) make_deb "$package" v1.2.3 "$commit" arm64 ;;
      dependencies) make_deb "$package" v1.2.3 "$commit" amd64 'libgtk-4-1' ;;
    esac
    if "$checker" v1.2.3 "$commit" "$package" >/dev/null 2>&1; then
      test_fail "checker accepted wrong $field"
    fi
  done
  rm -rf "$dir"
}

# test_checker_rejects_package_scope_drift checks files, links, scripts and modes.
test_checker_rejects_package_scope_drift() {
  local dir package mutation
  dir=$(mktemp -d); package="$dir/Meru-v1.2.3-linux-amd64.deb"
  for mutation in extra symlink script wrong-mode wrong-binary; do
    make_deb "$package" v1.2.3 "$commit" amd64 "$dependencies" "$mutation"
    if "$checker" v1.2.3 "$commit" "$package" >/dev/null 2>&1; then
      test_fail "checker accepted $mutation package"
    fi
  done
  rm -rf "$dir"
}

# run_test isolates failures so the suite reports every broken behavior.
run_test() {
  local name=$1 status
  tests_run=$((tests_run + 1))
  (set -e; "$name")
  status=$?
  if [ "$status" -eq 0 ]; then
    printf 'PASS: %s\n' "$name"
  else
    tests_failed=$((tests_failed + 1))
  fi
}

for test_name in \
  test_builder_writes_app_only_tree \
  test_builder_rejects_bad_inputs \
  test_checker_accepts_valid_package \
  test_checker_rejects_identity_drift \
  test_checker_rejects_package_scope_drift
do
  run_test "$test_name"
done

if [ "$tests_failed" -ne 0 ]; then
  printf '%d of %d tests failed\n' "$tests_failed" "$tests_run" >&2
  exit 1
fi
printf 'PASS: %d Debian package tests\n' "$tests_run"
