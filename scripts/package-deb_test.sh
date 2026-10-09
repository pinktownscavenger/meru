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
# It requires -Zxz, the compression the checker reads on Ubuntu and macOS.
make_fake_dpkg() {
  local bin_dir=$1
  mkdir -p "$bin_dir"
  printf '%s\n' \
    '#!/bin/sh' \
    'set -eu' \
    '[ "$1" = --root-owner-group ] && shift' \
    '[ "$1" = -Zxz ] || exit 3' \
    'shift' \
    '[ "$1" = --build ] || exit 2' \
    'root=$2' \
    'output=$3' \
    'mkdir -p "$FAKE_DPKG_SNAPSHOT" "$(dirname "$output")"' \
    'cp -R "$root/." "$FAKE_DPKG_SNAPSHOT/"' \
    ': >"$output"' >"$bin_dir/dpkg-deb"
  chmod 0755 "$bin_dir/dpkg-deb"
}

# make_deb writes a small Debian ar archive for the real checker, compressed
# with xz as package-deb.sh builds it; the gzip mutation uses gzip instead.
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
  local ext=xz flag=-J
  [ "$mutation" = gzip ] && { ext=gz; flag=-z; }
  tar "$flag" -cf "$dir/control.tar.$ext" -C "$control" .
  tar "$flag" -cf "$dir/data.tar.$ext" -C "$data" .
  rm -f "$output"
  (cd "$dir" && ar -qSc "$output" debian-binary "control.tar.$ext" "data.tar.$ext")
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

# test_linux_build_rejects_an_arm_host stops before an amd64 cgo cross-build.
test_linux_build_rejects_an_arm_host() {
  local dir fake log output status
  dir=$(mktemp -d); fake="$dir/fake"; log="$dir/log"
  mkdir -p "$fake"
  printf '%s\n' \
    '#!/bin/sh' \
    'case "$1" in -s) echo Linux ;; -m) echo aarch64 ;; esac' >"$fake/uname"
  printf '#!/bin/sh\nprintf "pkg-config\n" >>"$COMMAND_LOG"\n' >"$fake/pkg-config"
  printf '#!/bin/sh\nprintf "go %%s\n" "$*" >>"$COMMAND_LOG"\n' >"$fake/go"
  chmod 0755 "$fake/uname" "$fake/pkg-config" "$fake/go"
  set +e
  output=$(COMMAND_LOG="$log" PATH="$fake:$PATH" make -s -C "$root_dir" desktop-linux 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || { rm -rf "$dir"; test_fail "ARM host reached the desktop build"; return; }
  assert_contains "$output" "Linux x86-64"
  ! grep -Fq 'pkg-config' "$log" || { rm -rf "$dir"; test_fail "ARM host reached pkg-config"; return; }
  ! grep -Fq 'go build' "$log" || { rm -rf "$dir"; test_fail "ARM host reached go build"; return; }
  rm -rf "$dir"
}

# test_workflows_require_ldd_success keeps a failed ldd from passing through !.
test_workflows_require_ldd_success() {
  local workflow text
  for workflow in \
    "$root_dir/.github/workflows/ci.yml" \
    "$root_dir/.github/workflows/linux-desktop-release.yml"
  do
    text=$(cat "$workflow")
    case "$text" in
      *'! ldd '*) test_fail "$workflow negates ldd itself"; return ;;
    esac
    assert_contains "$text" 'ldd bin/linux-amd64/meru-desktop > "$RUNNER_TEMP/meru-desktop-ldd.txt"'
    assert_contains "$text" '! grep -F '\''not found'\'' "$RUNNER_TEMP/meru-desktop-ldd.txt"'
  done
}

# test_checker_accepts_valid_package exercises the inspector's macOS-compatible path.
test_checker_accepts_valid_package() {
  local dir package
  dir=$(mktemp -d); package="$dir/Meru-v1.2.3-linux-amd64.deb"
  make_deb "$package"
  "$checker" v1.2.3 "$commit" "$package"
  rm -rf "$dir"
}

# test_checker_consumes_the_strings_stream prevents grep from closing a real,
# large Go binary's strings pipe early and turning SIGPIPE into a false failure.
test_checker_consumes_the_strings_stream() {
  local dir package fake
  dir=$(mktemp -d); package="$dir/Meru-v1.2.3-linux-amd64.deb"; fake="$dir/fake"
  make_deb "$package"
  mkdir -p "$fake"
  printf '%s\n' \
    '#!/bin/sh' \
    'printf "v1.2.3\n"' \
    "awk 'BEGIN { for (i = 0; i < 200000; i++) print \"more binary text\" }'" \
    >"$fake/strings"
  chmod 0755 "$fake/strings"
  PATH="$fake:$PATH" "$checker" v1.2.3 "$commit" "$package"
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
  for mutation in extra symlink script wrong-mode wrong-binary gzip; do
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
  test_linux_build_rejects_an_arm_host \
  test_workflows_require_ldd_success \
  test_checker_accepts_valid_package \
  test_checker_consumes_the_strings_stream \
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
