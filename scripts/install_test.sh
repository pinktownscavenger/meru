#!/usr/bin/env bash
# install_test.sh tests the release installer without network access or host changes.

set -u

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
installer="$script_dir/install.sh"
tests_run=0
tests_failed=0

# fail records one failed assertion without ending the whole test file.
test_fail() {
  printf 'FAIL: %s\n' "$*" >&2
  return 1
}

# assert_equal compares the exact strings a helper returns.
assert_equal() {
  local want=$1 got=$2
  [ "$got" = "$want" ] || test_fail "want '$want', got '$got'"
}

# assert_contains checks that command output includes one expected phrase.
assert_contains() {
  local text=$1 part=$2
  case "$text" in
    *"$part"*) ;;
    *) test_fail "output does not contain '$part': $text" ;;
  esac
}

# load_installer sources the functions under test. The installer must not run main.
load_installer() {
  # shellcheck source=install.sh
  source "$installer"
}

# test_platform_for_ubuntu_2404_amd64 accepts the one verified Linux target.
test_platform_for_ubuntu_2404_amd64() {
  local dir got
  dir=$(mktemp -d)
  printf 'ID=ubuntu\nVERSION_ID="24.04"\n' >"$dir/os-release"
  load_installer
  got=$(platform_for Linux x86_64 "$dir/os-release")
  rm -rf "$dir"
  assert_equal linux-amd64 "$got"
}

# test_platform_for_macos keeps both existing Mac release names.
test_platform_for_macos() {
  load_installer
  assert_equal darwin-arm64 "$(platform_for Darwin arm64 /does/not/matter)"
  assert_equal darwin-amd64 "$(platform_for Darwin x86_64 /does/not/matter)"
}

# test_platform_rejects_other_linux gives unsupported distributions a clear error.
test_platform_rejects_other_linux() {
  local dir output
  dir=$(mktemp -d)
  printf 'ID=debian\nVERSION_ID="12"\n' >"$dir/os-release"
  load_installer
  if output=$(platform_for Linux x86_64 "$dir/os-release" 2>&1); then
    rm -rf "$dir"
    test_fail "Debian was accepted"
    return
  fi
  rm -rf "$dir"
  assert_contains "$output" "Ubuntu 24.04"
}

# test_os_release_is_data_not_code proves parsing never executes file contents.
test_os_release_is_data_not_code() {
  local dir marker got
  dir=$(mktemp -d)
  marker="$dir/executed"
  printf 'ID=ubuntu\nEVIL=$(touch "%s")\nVERSION_ID="24.04"\n' "$marker" >"$dir/os-release"
  load_installer
  got=$(os_release_value "$dir/os-release" ID)
  [ ! -e "$marker" ] || { rm -rf "$dir"; test_fail "os-release executed code"; return; }
  rm -rf "$dir"
  assert_equal ubuntu "$got"
}

# test_source_does_not_run_main ensures tests and other callers can load helpers.
test_source_does_not_run_main() {
  local output
  output=$(bash -c 'source "$1"; printf loaded' _ "$installer" 2>&1) || test_fail "$output"
  assert_equal loaded "$output"
}

# test_direct_and_pipe_execution_reach_main covers both published entry forms.
test_direct_and_pipe_execution_reach_main() {
  local direct piped
  direct=$(MERU_VERSION=not-a-version bash "$installer" 2>&1 || true)
  piped=$(MERU_VERSION=not-a-version bash <"$installer" 2>&1 || true)
  assert_contains "$direct" "couldn't find the release"
  assert_contains "$piped" "couldn't find the release"
}

# make_cli_archive writes a small release archive for install helper tests.
make_cli_archive() {
  local directory=$1 release_dir=$2
  mkdir -p "$directory/$release_dir"
  printf '#!/bin/sh\necho meru\n' >"$directory/$release_dir/meru"
  printf '#!/bin/sh\necho merud\n' >"$directory/$release_dir/merud"
  tar -czf "$directory/release.tar.gz" -C "$directory" "$release_dir"
}

# make_command_stub records one checksum program's argv.
make_command_stub() {
  local path=$1 name=$2
  mkdir -p "$path"
  printf '#!/bin/sh\nprintf "%%s %%s\\n" "%s" "$*" >>"$COMMAND_LOG"\n' "$name" >"$path/$name"
  chmod +x "$path/$name"
}

# test_checksum_failure_writes_no_binary keeps a bad archive out of the bin folder.
test_checksum_failure_writes_no_binary() {
  local dir destination
  dir=$(mktemp -d)
  destination="$dir/bin"
  make_cli_archive "$dir" meru-test-linux-amd64
  printf '%064d  release.tar.gz\n' 0 >"$dir/SHA256SUMS"
  load_installer
  type verify_downloads >/dev/null 2>&1 || { rm -rf "$dir"; test_fail "verify_downloads is missing"; return; }
  if verify_downloads "$(uname -s)" "$dir" >/dev/null 2>&1; then
    install_cli "$dir/release.tar.gz" meru-test-linux-amd64 "$destination"
  fi
  [ ! -e "$destination/meru" ] || { rm -rf "$dir"; test_fail "bad checksum installed meru"; return; }
  rm -rf "$dir"
}

# test_linux_uses_sha256sum checks the GNU checksum command and arguments.
test_linux_uses_sha256sum() {
  local dir fake_bin log output
  dir=$(mktemp -d); fake_bin="$dir/fake bin"; log="$dir/log"
  : >"$dir/SHA256SUMS"
  make_command_stub "$fake_bin" sha256sum
  make_command_stub "$fake_bin" shasum
  load_installer
  COMMAND_LOG="$log" PATH="$fake_bin:$PATH" verify_downloads Linux "$dir"
  output=$(cat "$log")
  rm -rf "$dir"
  assert_equal "sha256sum -c --ignore-missing SHA256SUMS" "$output"
}

# test_macos_uses_shasum checks the macOS checksum command and arguments.
test_macos_uses_shasum() {
  local dir fake_bin log output
  dir=$(mktemp -d); fake_bin="$dir/fake bin"; log="$dir/log"
  : >"$dir/SHA256SUMS"
  make_command_stub "$fake_bin" sha256sum
  make_command_stub "$fake_bin" shasum
  load_installer
  COMMAND_LOG="$log" PATH="$fake_bin:$PATH" verify_downloads Darwin "$dir"
  output=$(cat "$log")
  rm -rf "$dir"
  assert_equal "shasum -a 256 -c --ignore-missing SHA256SUMS" "$output"
}

# test_install_cli_sets_mode_0755 installs both release programs as executables.
test_install_cli_sets_mode_0755() {
  local dir destination mode
  dir=$(mktemp -d); destination="$dir/output"
  make_cli_archive "$dir" meru-test-linux-amd64
  load_installer
  install_cli "$dir/release.tar.gz" meru-test-linux-amd64 "$destination"
  mode=$(stat -f %Lp "$destination/meru" 2>/dev/null || stat -c %a "$destination/meru")
  assert_equal 755 "$mode"
  mode=$(stat -f %Lp "$destination/merud" 2>/dev/null || stat -c %a "$destination/merud")
  rm -rf "$dir"
  assert_equal 755 "$mode"
}

# test_path_line_is_added_once makes rerunning the installer idempotent.
test_path_line_is_added_once() {
  local dir profile count
  dir=$(mktemp -d); profile="$dir/profile"
  load_installer
  ensure_path_line "$profile" '$HOME/.local/bin'
  ensure_path_line "$profile" '$HOME/.local/bin'
  count=$(grep -Fc 'export PATH="$HOME/.local/bin:$PATH"' "$profile")
  rm -rf "$dir"
  assert_equal 1 "$count"
}

# test_install_handles_home_with_spaces keeps every install path quoted.
test_install_handles_home_with_spaces() {
  local dir destination profile
  dir=$(mktemp -d); destination="$dir/home with spaces/.local/bin"
  profile="$dir/home with spaces/.profile"
  make_cli_archive "$dir" meru-test-linux-amd64
  load_installer
  install_cli "$dir/release.tar.gz" meru-test-linux-amd64 "$destination"
  ensure_path_line "$profile" '$HOME/.local/bin'
  [ -x "$destination/meru" ] || { rm -rf "$dir"; test_fail "meru missing from spaced path"; return; }
  [ -f "$profile" ] || { rm -rf "$dir"; test_fail "profile missing from spaced path"; return; }
  rm -rf "$dir"
}

# run_test isolates each test because installer failures call exit.
run_test() {
  local name=$1
  tests_run=$((tests_run + 1))
  if ("$name"); then
    printf 'PASS: %s\n' "$name"
  else
    tests_failed=$((tests_failed + 1))
  fi
}

for test_name in \
  test_platform_for_ubuntu_2404_amd64 \
  test_platform_for_macos \
  test_platform_rejects_other_linux \
  test_os_release_is_data_not_code \
  test_source_does_not_run_main \
  test_direct_and_pipe_execution_reach_main \
  test_checksum_failure_writes_no_binary \
  test_linux_uses_sha256sum \
  test_macos_uses_shasum \
  test_install_cli_sets_mode_0755 \
  test_path_line_is_added_once \
  test_install_handles_home_with_spaces
do
  run_test "$test_name"
done

if [ "$tests_failed" -ne 0 ]; then
  printf '%d of %d tests failed\n' "$tests_failed" "$tests_run" >&2
  exit 1
fi
printf 'PASS: %d installer tests\n' "$tests_run"
