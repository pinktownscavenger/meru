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

# mode_of prints one file's numeric mode on macOS or Linux.
mode_of() {
  case "$(uname -s)" in
    Darwin) stat -f %Lp "$1" ;;
    *) stat -c %a "$1" ;;
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

# make_cli_archive writes a small Linux release archive for install helper tests.
make_cli_archive() {
  local directory=$1 release_dir=$2
  mkdir -p "$directory/$release_dir"
  printf '#!/bin/sh\necho meru\n' >"$directory/$release_dir/meru"
  printf '#!/bin/sh\necho merud\n' >"$directory/$release_dir/merud"
  cp "$script_dir/../deploy/systemd/merud.service" "$directory/$release_dir/"
  cp "$script_dir/../deploy/systemd/meru-searxng.container" "$directory/$release_dir/"
  tar -czf "$directory/release.tar.gz" -C "$directory" "$release_dir"
  rm -rf "$directory/$release_dir"
}

# test_linux_release_archives_include_units checks both published Linux targets.
test_linux_release_archives_include_units() {
  local dir platform name archive extracted
  dir=$(mktemp -d)
  mkdir -p "$dir/bin/linux-amd64" "$dir/bin/linux-arm64" "$dir/deploy/systemd"
  cp "$script_dir/../deploy/systemd/merud.service" "$script_dir/../deploy/systemd/meru-searxng.container" "$dir/deploy/systemd/"
  printf 'licence\n' >"$dir/LICENSE"
  printf 'read me\n' >"$dir/README.md"
  for platform in linux-amd64 linux-arm64; do
    printf 'meru\n' >"$dir/bin/$platform/meru"
    printf 'merud\n' >"$dir/bin/$platform/merud"
    name="meru-test-$platform"
    (cd "$dir" && bash "$script_dir/release-archive.sh" "$platform" "$name" "")
    archive="$dir/dist/$name.tar.gz"
    if gzip -dc "$archive" | grep -aFq 'LIBARCHIVE.xattr.com.apple'; then
      rm -rf "$dir"
      test_fail "$platform archive contains macOS extended attributes"
      return
    fi
    if gzip -dc "$archive" | grep -aFq 'SCHILY.fflags'; then
      rm -rf "$dir"
      test_fail "$platform archive contains macOS file flags"
      return
    fi
    extracted="$dir/extracted-$platform"
    mkdir -p "$extracted"
    tar -xzf "$archive" -C "$extracted"
    cmp "$dir/deploy/systemd/merud.service" "$extracted/$name/merud.service"
    cmp "$dir/deploy/systemd/meru-searxng.container" "$extracted/$name/meru-searxng.container"
  done
  grep -Fq 'bash scripts/release-archive.sh "$platform" "$name" "$ext"' "$script_dir/release.sh"
  rm -rf "$dir"
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

# test_manifest_names_every_download rejects an asset that the checksum file omits.
test_manifest_names_every_download() {
  local dir fake_bin log
  dir=$(mktemp -d); fake_bin="$dir/fake"; log="$dir/log"
  printf 'cli\n' >"$dir/meru-v1.2.3-linux-amd64.tar.gz"
  printf 'desktop\n' >"$dir/Meru-v1.2.3-linux-amd64.deb"
  printf '%064d  meru-v1.2.3-linux-amd64.tar.gz\n' 0 >"$dir/SHA256SUMS"
  make_command_stub "$fake_bin" sha256sum
  load_installer
  if COMMAND_LOG="$log" PATH="$fake_bin:$PATH" verify_downloads Linux "$dir" >/dev/null 2>&1; then
    rm -rf "$dir"
    test_fail "checksum verification accepted an unlisted desktop package"
    return
  fi
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
  mode=$(mode_of "$destination/meru")
  assert_equal 755 "$mode"
  mode=$(mode_of "$destination/merud")
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

# test_existing_ollama_is_kept avoids downloads when the loopback API answers.
test_existing_ollama_is_kept() {
  local dir log
  dir=$(mktemp -d); log="$dir/log"
  load_installer
  type install_ollama_linux >/dev/null 2>&1 || { rm -rf "$dir"; test_fail "install_ollama_linux is missing"; return; }
  ollama_ready() { return 0; }
  ask() { printf 'asked\n' >>"$log"; return 0; }
  curl() { printf 'curl %s\n' "$*" >>"$log"; }
  sh() { printf 'sh %s\n' "$*" >>"$log"; }
  install_ollama_linux "$dir"
  [ ! -s "$log" ] || { test_fail "existing Ollama caused work: $(cat "$log")"; rm -rf "$dir"; return; }
  rm -rf "$dir"
}

# test_ollama_installer_is_saved_then_run_after_yes checks URL and command order.
test_ollama_installer_is_saved_then_run_after_yes() {
  local dir log output
  dir=$(mktemp -d); log="$dir/log"
  load_installer
  type install_ollama_linux >/dev/null 2>&1 || { rm -rf "$dir"; test_fail "install_ollama_linux is missing"; return; }
  ollama_ready() { return 1; }
  ask() { return 0; }
  curl() {
    printf 'curl %s\n' "$*" >>"$log"
    while [ "$#" -gt 0 ]; do
      if [ "$1" = -o ]; then shift; printf '#!/bin/sh\n' >"$1"; break; fi
      shift
    done
  }
  sh() { printf 'sh %s\n' "$*" >>"$log"; }
  install_ollama_linux "$dir"
  output=$(cat "$log")
  rm -rf "$dir"
  assert_contains "$output" "https://ollama.com/install.sh"
  assert_contains "$output" "sh $dir/ollama-install.sh"
  case "$output" in curl*"https://ollama.com/install.sh"*"sh $dir/ollama-install.sh") ;;
    *) test_fail "Ollama installer did not download before sh: $output" ;;
  esac
}

# test_declined_ollama_runs_nothing leaves privileged installation to the user.
test_declined_ollama_runs_nothing() {
  local dir log
  dir=$(mktemp -d); log="$dir/log"
  load_installer
  type install_ollama_linux >/dev/null 2>&1 || { rm -rf "$dir"; test_fail "install_ollama_linux is missing"; return; }
  ollama_ready() { return 1; }
  ask() { return 1; }
  curl() { printf 'curl %s\n' "$*" >>"$log"; }
  sh() { printf 'sh %s\n' "$*" >>"$log"; }
  install_ollama_linux "$dir"
  [ ! -s "$log" ] || { test_fail "declined Ollama ran a command: $(cat "$log")"; rm -rf "$dir"; return; }
  rm -rf "$dir"
}

# test_no_tty_runs_no_privileged_or_optional_command prints later commands only.
test_no_tty_runs_no_privileged_or_optional_command() {
  local dir log output
  dir=$(mktemp -d); log="$dir/log"
  load_installer
  type install_ollama_linux >/dev/null 2>&1 || { rm -rf "$dir"; test_fail "install_ollama_linux is missing"; return; }
  type run_meru_setup >/dev/null 2>&1 || { rm -rf "$dir"; test_fail "run_meru_setup is missing"; return; }
  all=0
  has_tty() { return 1; }
  ollama_ready() { return 1; }
  curl() { printf 'curl %s\n' "$*" >>"$log"; }
  sh() { printf 'sh %s\n' "$*" >>"$log"; }
  run_with_tty() { printf 'tty %s\n' "$*" >>"$log"; }
  output=$(install_ollama_linux "$dir"; run_meru_setup)
  [ ! -s "$log" ] || { test_fail "no-terminal path ran a command: $(cat "$log")"; rm -rf "$dir"; return; }
  rm -rf "$dir"
  assert_contains "$output" "meru setup"
}

# test_meru_yes_banner_names_sudo_steps makes non-interactive consent explicit.
test_meru_yes_banner_names_sudo_steps() {
  local output
  load_installer
  type linux_banner >/dev/null 2>&1 || { test_fail "linux_banner is missing"; return; }
  all=1
  output=$(linux_banner v0.0.0)
  assert_contains "$output" "Ollama"
  assert_contains "$output" "SearXNG"
  assert_contains "$output" "desktop package"
  assert_contains "$output" "apt-get"
  assert_contains "$output" "GTK4"
  assert_contains "$output" "sudo"
  assert_contains "$output" "loginctl enable-linger"
  assert_contains "$output" "accepts every step"
}

# test_desktop_package_decline_keeps_core_install leaves the optional app alone.
test_desktop_package_decline_keeps_core_install() {
  local dir log output
  dir=$(mktemp -d); log="$dir/log"
  printf 'package\n' >"$dir/Meru-v1.2.3-linux-amd64.deb"
  load_installer
  all=0
  has_tty() { return 0; }
  ask() { return 1; }
  sudo() { printf 'sudo %s\n' "$*" >>"$log"; }
  output=$(install_desktop_deb "$dir/Meru-v1.2.3-linux-amd64.deb")
  [ ! -s "$log" ] || test_fail "declined desktop package ran sudo"
  assert_contains "$output" "Command-line Meru is ready"
  rm -rf "$dir"
}

# test_desktop_package_accepts_exact_apt_argv keeps the checked path one argument.
test_desktop_package_accepts_exact_apt_argv() {
  local dir log output arg
  dir=$(mktemp -d); log="$dir/log"
  printf 'package\n' >"$dir/Meru package.deb"
  load_installer
  all=0
  has_tty() { return 0; }
  ask() { return 0; }
  sudo() { for arg in "$@"; do printf '<%s>' "$arg" >>"$log"; done; printf '\n' >>"$log"; }
  install_desktop_deb "$dir/Meru package.deb"
  output=$(cat "$log")
  assert_equal "<apt-get><install><--yes><--><$dir/Meru package.deb>" "$output"
  rm -rf "$dir"
}

# test_meru_yes_installs_desktop_without_prompt applies the banner's consent.
test_meru_yes_installs_desktop_without_prompt() {
  local dir log
  dir=$(mktemp -d); log="$dir/log"
  printf 'package\n' >"$dir/Meru-v1.2.3-linux-amd64.deb"
  load_installer
  all=1
  has_tty() { return 1; }
  ask() { test_fail "MERU_YES asked again"; }
  sudo() { printf 'sudo %s\n' "$*" >>"$log"; }
  install_desktop_deb "$dir/Meru-v1.2.3-linux-amd64.deb"
  assert_contains "$(cat "$log")" 'apt-get install --yes --'
  rm -rf "$dir"
}

# test_headless_desktop_keeps_checked_package_for_later runs no privileged command.
test_headless_desktop_keeps_checked_package_for_later() {
  local dir log old_home output cached
  dir=$(mktemp -d); log="$dir/log"; old_home=$HOME
  HOME="$dir/home with spaces"
  printf 'package\n' >"$dir/Meru-v1.2.3-linux-amd64.deb"
  load_installer
  all=0
  has_tty() { return 1; }
  sudo() { printf 'sudo %s\n' "$*" >>"$log"; }
  output=$(install_desktop_deb "$dir/Meru-v1.2.3-linux-amd64.deb")
  cached="$HOME/.cache/meru/Meru-v1.2.3-linux-amd64.deb"
  cmp "$dir/Meru-v1.2.3-linux-amd64.deb" "$cached"
  [ ! -s "$log" ] || test_fail "headless desktop install ran sudo"
  assert_contains "$output" "sudo apt-get install --yes -- '$cached'"
  HOME=$old_home
  rm -rf "$dir"
}

# test_bad_checksum_stops_before_desktop_sudo verifies both downloads precede trust.
test_bad_checksum_stops_before_desktop_sudo() {
  local dir log old_home output status
  dir=$(mktemp -d); log="$dir/log"; old_home=$HOME
  HOME="$dir/home"; bin_dir="$HOME/.local/bin"
  load_installer
  all=1
  linux_banner() { :; }
  curl() {
    while [ "$#" -gt 0 ]; do
      if [ "$1" = -o ]; then shift; printf 'download\n' >"$1"; return 0; fi
      shift
    done
  }
  verify_downloads() {
    [ -f "$2/meru-v1.2.3-linux-amd64.tar.gz" ] || test_fail "CLI archive was not downloaded"
    [ -f "$2/Meru-v1.2.3-linux-amd64.deb" ] || test_fail "desktop package was not downloaded"
    return 1
  }
  sudo() { printf 'sudo %s\n' "$*" >>"$log"; }
  set +e
  output=$(install_linux v1.2.3 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || test_fail "bad checksum returned success"
  [ ! -s "$log" ] || test_fail "checksum failure reached sudo"
  assert_contains "$output" "nothing was installed"
  HOME=$old_home
  rm -rf "$dir"
}

# test_desktop_rerun_changes_no_core_path confines both runs to apt.
test_desktop_rerun_changes_no_core_path() {
  local dir log before after
  dir=$(mktemp -d); log="$dir/log"
  mkdir -p "$dir/core/.meru" "$dir/core/.local/bin" "$dir/core/.config/systemd/user"
  printf 'config\n' >"$dir/core/.meru/config.toml"
  printf 'meru\n' >"$dir/core/.local/bin/meru"
  printf 'service\n' >"$dir/core/.config/systemd/user/merud.service"
  printf 'package\n' >"$dir/Meru-v1.2.3-linux-amd64.deb"
  before=$(find "$dir/core" -type f -exec cksum {} \; | LC_ALL=C sort)
  load_installer
  all=1
  sudo() { printf 'sudo %s\n' "$*" >>"$log"; }
  install_desktop_deb "$dir/Meru-v1.2.3-linux-amd64.deb"
  install_desktop_deb "$dir/Meru-v1.2.3-linux-amd64.deb"
  after=$(find "$dir/core" -type f -exec cksum {} \; | LC_ALL=C sort)
  assert_equal "$before" "$after"
  assert_equal 2 "$(grep -Fc 'sudo apt-get install --yes --' "$log")"
  rm -rf "$dir"
}

# test_linux_banner_does_not_require_user_env supports sparse service environments.
test_linux_banner_does_not_require_user_env() {
  local output
  load_installer
  output=$(unset USER; linux_banner v0.0.0)
  assert_contains "$output" 'loginctl enable-linger'
  assert_contains "$output" "$(id -un)"
}

# test_linux_setup_uses_no_main_override keeps the setup command on lite by default.
test_linux_setup_uses_no_main_override() {
  local dir log output
  dir=$(mktemp -d); log="$dir/log"
  load_installer
  type run_meru_setup >/dev/null 2>&1 || { rm -rf "$dir"; test_fail "run_meru_setup is missing"; return; }
  bin_dir="$dir/home with spaces/.local/bin"
  has_tty() { return 0; }
  ask() { return 0; }
  run_with_tty() { printf '%s\n' "$*" >"$log"; }
  run_meru_setup
  output=$(cat "$log")
  rm -rf "$dir"
  assert_equal "$bin_dir/meru setup" "$output"
  case "$output" in *--main*) test_fail "Ubuntu setup overrode the lite default" ;; esac
}

# test_linux_configures_web_before_setup keeps setup's web check useful.
test_linux_configures_web_before_setup() {
  local dir log output
  dir=$(mktemp -d); log="$dir/log"
  load_installer
  type configure_linux >/dev/null 2>&1 || { rm -rf "$dir"; test_fail "configure_linux is missing"; return; }
  setup_searxng() { printf 'web\n' >>"$log"; }
  ollama_ready() { return 0; }
  run_meru_setup() { printf 'setup\n' >>"$log"; }
  finish_linux_setup() { printf 'service\n' >>"$log"; }
  print_linux_checks() { printf 'checks\n' >>"$log"; }
  configure_linux
  output=$(cat "$log")
  rm -rf "$dir"
  assert_equal $'web\nsetup\nservice\nchecks' "$output"
}

# test_linux_checks_name_acceptance_commands prints the handoff commands.
test_linux_checks_name_acceptance_commands() {
  local output
  load_installer
  type print_linux_checks >/dev/null 2>&1 || { test_fail "print_linux_checks is missing"; return; }
  output=$(print_linux_checks)
  assert_contains "$output" 'meru ping'
  assert_contains "$output" 'meru index -status'
  assert_contains "$output" 'systemctl --user status merud'
  assert_contains "$output" 'journalctl --user -u merud'
  assert_contains "$output" 'indexed file'
}

# test_ready_searxng_is_kept leaves a healthy service that Meru does not own alone.
test_ready_searxng_is_kept() {
  local dir output
  dir=$(mktemp -d)
  load_installer
  type searxng_ready >/dev/null 2>&1 || { rm -rf "$dir"; test_fail "searxng_ready is missing"; return; }
  searxng_ready() { return 0; }
  podman() { return 1; }
  docker() { return 1; }
  output=$(setup_searxng)
  rm -rf "$dir"
  assert_contains "$output" "keeping it"
}

# test_ready_podman_refreshes_verified_quadlet upgrades the old service definition.
test_ready_podman_refreshes_verified_quadlet() {
  local dir log old_home unit
  dir=$(mktemp -d); log="$dir/log"; old_home=$HOME
  load_installer
  HOME="$dir/home"; release_root="$script_dir/../deploy/systemd"
  unit="$HOME/.config/containers/systemd/meru-searxng.container"
  mkdir -p "$(dirname "$unit")"
  printf 'old unchecked Quadlet\n' >"$unit"
  searxng_ready() { return 0; }
  podman() { return 0; }
  docker() { return 1; }
  ask() { return 0; }
  systemctl() { printf 'systemctl %s\n' "$*" >>"$log"; }
  wait_for_searxng() { printf 'wait_for_searxng %s\n' "$*" >>"$log"; }
  setup_searxng >/dev/null
  cmp "$release_root/meru-searxng.container" "$unit"
  grep -Fqx 'systemctl --user restart meru-searxng.service' "$log"
  grep -Fqx 'wait_for_searxng 90' "$log"
  HOME=$old_home
  rm -rf "$dir"
}

# test_ready_podman_refresh_needs_consent keeps optional services unchanged on no.
test_ready_podman_refresh_needs_consent() {
  local dir log old_home unit before after
  dir=$(mktemp -d); log="$dir/log"; old_home=$HOME
  load_installer
  HOME="$dir/home"; release_root="$script_dir/../deploy/systemd"
  unit="$HOME/.config/containers/systemd/meru-searxng.container"
  mkdir -p "$(dirname "$unit")"
  printf 'existing Quadlet\n' >"$unit"
  before=$(cat "$unit")
  searxng_ready() { return 0; }
  podman() { return 0; }
  docker() { return 1; }
  ask() { return 1; }
  systemctl() { printf 'systemctl %s\n' "$*" >>"$log"; }
  setup_searxng >/dev/null
  after=$(cat "$unit")
  assert_equal "$before" "$after"
  [ ! -s "$log" ] || { HOME=$old_home; rm -rf "$dir"; test_fail "declined refresh called systemctl"; return; }
  HOME=$old_home
  rm -rf "$dir"
}

# test_ready_podman_refresh_timeout_prints_recovery explains a failed restart.
test_ready_podman_refresh_timeout_prints_recovery() {
  local dir old_home output
  dir=$(mktemp -d); old_home=$HOME
  load_installer
  HOME="$dir/home"; release_root="$script_dir/../deploy/systemd"
  searxng_ready() { return 0; }
  podman() { return 0; }
  docker() { return 1; }
  ask() { return 0; }
  systemctl() { return 0; }
  wait_for_searxng() { return 1; }
  output=$(setup_searxng)
  assert_contains "$output" "SearXNG did not answer JSON within 90 seconds."
  assert_contains "$output" "Try: podman start meru-searxng"
  HOME=$old_home
  rm -rf "$dir"
}

# test_existing_podman_container_keeps_podman resolves ownership before preference.
test_existing_podman_container_keeps_podman() {
  load_installer
  type searxng_owner >/dev/null 2>&1 || { test_fail "searxng_owner is missing"; return; }
  podman() { [ "$1 $2 $3" = "container exists meru-searxng" ]; }
  docker() { return 1; }
  assert_equal podman "$(searxng_owner)"
}

# test_existing_docker_container_keeps_docker finds Docker when Podman owns none.
test_existing_docker_container_keeps_docker() {
  load_installer
  type searxng_owner >/dev/null 2>&1 || { test_fail "searxng_owner is missing"; return; }
  podman() { return 1; }
  docker() { [ "$1 $2" = "inspect meru-searxng" ]; }
  assert_equal docker "$(searxng_owner)"
}

# test_broken_podman_falls_back_to_docker prefers only a working runtime.
test_broken_podman_falls_back_to_docker() {
  load_installer
  type choose_container_runtime >/dev/null 2>&1 || { test_fail "choose_container_runtime is missing"; return; }
  podman() { return 1; }
  docker() { [ "$1" = info ]; }
  assert_equal docker "$(choose_container_runtime)"
}

# test_existing_broken_podman_does_not_switch_owners avoids duplicate containers.
test_existing_broken_podman_does_not_switch_owners() {
  local dir log output
  dir=$(mktemp -d); log="$dir/log"
  load_installer
  type searxng_owner >/dev/null 2>&1 || { rm -rf "$dir"; test_fail "searxng_owner is missing"; return; }
  searxng_ready() { return 1; }
  podman() {
    printf 'podman %s\n' "$*" >>"$log"
    [ "$1 ${2:-} ${3:-}" = "container exists meru-searxng" ]
  }
  docker() { printf 'docker %s\n' "$*" >>"$log"; return 0; }
  output=$(setup_searxng)
  assert_contains "$output" "podman start meru-searxng"
  if grep -q '^docker ' "$log"; then test_fail "switched an existing Podman container to Docker"; fi
  rm -rf "$dir"
}

# test_no_runtime_skips_with_recovery_text keeps optional web search non-blocking.
test_no_runtime_skips_with_recovery_text() {
  local output
  load_installer
  type choose_container_runtime >/dev/null 2>&1 || { test_fail "choose_container_runtime is missing"; return; }
  searxng_ready() { return 1; }
  podman() { return 1; }
  docker() { return 1; }
  output=$(setup_searxng)
  assert_contains "$output" "Install Podman or Docker"
  assert_contains "$output" "run this installer again"
}

# test_settings_have_json_random_secret_and_modes checks safe defaults on disk.
test_settings_have_json_random_secret_and_modes() {
  local dir settings secret dir_mode file_mode instance_names
  dir=$(mktemp -d); settings="$dir/searxng/settings.yml"
  load_installer
  type write_searxng_settings >/dev/null 2>&1 || { rm -rf "$dir"; test_fail "write_searxng_settings is missing"; return; }
  write_searxng_settings "$dir/searxng"
  grep -q '^    - json$' "$settings"
  secret=$(sed -n 's/^  secret_key: "\([0-9a-f]*\)"$/\1/p' "$settings")
  [ "${#secret}" -eq 64 ] || { test_fail "secret is not 64 hex digits"; rm -rf "$dir"; return; }
  instance_names=$(grep -Fc '  instance_name: "Meru web search"' "$settings")
  assert_equal 1 "$instance_names"
  dir_mode=$(mode_of "$dir/searxng")
  file_mode=$(mode_of "$settings")
  assert_equal 700 "$dir_mode"
  assert_equal 600 "$file_mode"
  rm -rf "$dir"
}

# test_existing_settings_secret_is_kept preserves user changes and the secret.
test_existing_settings_secret_is_kept() {
  local dir settings before after
  dir=$(mktemp -d); settings="$dir/searxng/settings.yml"
  mkdir -p "$dir/searxng"
  printf 'secret_key: "keep-me"\ncustom: true\n' >"$settings"
  before=$(cat "$settings")
  load_installer
  write_searxng_settings "$dir/searxng"
  after=$(cat "$settings")
  rm -rf "$dir"
  assert_equal "$before" "$after"
}

# test_podman_quadlet_binds_loopback_and_uses_percent_h checks the canonical unit.
test_podman_quadlet_binds_loopback_and_uses_percent_h() {
  local unit="$script_dir/../deploy/systemd/meru-searxng.container"
  [ -f "$unit" ] || { test_fail "Podman Quadlet is missing"; return; }
  grep -Eq '^Image=.+@sha256:[0-9a-f]{64}$' "$unit"
  grep -Fqx 'ContainerName=meru-searxng' "$unit"
  grep -Fqx 'PublishPort=127.0.0.1:8888:8080' "$unit"
  grep -Fqx 'Volume=%h/.meru/searxng:/etc/searxng' "$unit"
  grep -Fqx 'Environment=SEARXNG_BASE_URL=http://127.0.0.1:8888/' "$unit"
  grep -Fqx 'Restart=on-failure' "$unit"
  grep -Fqx 'TimeoutStartSec=900' "$unit"
  grep -Fqx 'WantedBy=default.target' "$unit"
}

# test_podman_uses_verified_release_quadlet avoids a second network download.
test_podman_uses_verified_release_quadlet() {
  local dir log old_home
  dir=$(mktemp -d); log="$dir/log"; old_home=$HOME
  make_cli_archive "$dir" meru-test-linux-amd64
  load_installer
  HOME="$dir/home"; bin_dir="$HOME/.local/bin"
  install_cli "$dir/release.tar.gz" meru-test-linux-amd64 "$bin_dir"
  release_root="$dir/meru-test-linux-amd64"
  podman() { return 1; }
  curl() { test_fail "Podman downloaded an unchecked Quadlet"; }
  systemctl() { printf 'systemctl %s\n' "$*" >>"$log"; }
  setup_searxng_podman "$HOME/.meru/searxng"
  cmp "$release_root/meru-searxng.container" "$HOME/.config/containers/systemd/meru-searxng.container"
  HOME=$old_home
  rm -rf "$dir"
}

# test_podman_starts_generated_service_without_enable follows Quadlet's boot model.
test_podman_starts_generated_service_without_enable() {
  local dir log old_home
  dir=$(mktemp -d); log="$dir/log"; old_home=$HOME
  load_installer
  HOME="$dir/home"; release_root="$script_dir/../deploy/systemd"
  podman() { return 1; }
  systemctl() { printf 'systemctl %s\n' "$*" >>"$log"; }
  setup_searxng_podman "$HOME/.meru/searxng"
  grep -Fqx 'systemctl --user daemon-reload' "$log"
  grep -Fqx 'systemctl --user start meru-searxng.service' "$log"
  if grep -Fq ' enable ' "$log"; then test_fail "Quadlet service was passed to systemctl enable"; fi
  HOME=$old_home
  rm -rf "$dir"
}

# test_podman_systemd_failure_returns avoids a 90-second wait after setup failed.
test_podman_systemd_failure_returns() {
  local dir old_home
  dir=$(mktemp -d); old_home=$HOME
  load_installer
  HOME="$dir/home"; release_root="$script_dir/../deploy/systemd"
  podman() { return 1; }
  systemctl() { return 1; }
  if setup_searxng_podman "$HOME/.meru/searxng"; then
    HOME=$old_home
    rm -rf "$dir"
    test_fail "Podman setup hid a systemctl failure"
    return
  fi
  HOME=$old_home
  rm -rf "$dir"
}

# test_docker_argv_binds_loopback_and_restarts checks distinct Docker arguments.
test_docker_argv_binds_loopback_and_restarts() {
  local dir log output
  dir=$(mktemp -d); log="$dir/log"
  mkdir -p "$dir/release"
  printf '%s\n' \
    '[Container]' \
    'Image=registry.test/searxng:test@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
    >"$dir/release/meru-searxng.container"
  load_installer
  release_root="$dir/release"
  type setup_searxng_docker >/dev/null 2>&1 || { rm -rf "$dir"; test_fail "setup_searxng_docker is missing"; return; }
  docker() { local arg; for arg in "$@"; do printf '<%s>' "$arg" >>"$log"; done; printf '\n' >>"$log"; }
  setup_searxng_docker "$dir/home with spaces/.meru/searxng"
  output=$(cat "$log")
  assert_contains "$output" '<--restart><unless-stopped>'
  assert_contains "$output" '<--publish><127.0.0.1:8888:8080>'
  assert_contains "$output" "<$dir/home with spaces/.meru/searxng:/etc/searxng>"
  assert_contains "$output" '<registry.test/searxng:test@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa>'
  rm -rf "$dir"
}

# test_docker_pull_failure_stops_before_run returns to the recovery path.
test_docker_pull_failure_stops_before_run() {
  local dir log
  dir=$(mktemp -d); log="$dir/log"
  load_installer
  release_root="$script_dir/../deploy/systemd"
  docker() {
    printf 'docker %s\n' "$*" >>"$log"
    [ "$1" != pull ]
  }
  if setup_searxng_docker "$dir/settings"; then
    rm -rf "$dir"
    test_fail "Docker setup hid a pull failure"
    return
  fi
  if grep -q '^docker run ' "$log"; then test_fail "Docker ran after its pull failed"; fi
  rm -rf "$dir"
}

# test_searxng_handles_home_with_spaces quotes settings and container paths.
test_searxng_handles_home_with_spaces() {
  local dir settings log
  dir=$(mktemp -d); settings="$dir/home with spaces/.meru/searxng"; log="$dir/log"
  load_installer
  release_root="$script_dir/../deploy/systemd"
  type write_searxng_settings >/dev/null 2>&1 || { rm -rf "$dir"; test_fail "write_searxng_settings is missing"; return; }
  docker() { printf '%s\n' "$#:$*" >>"$log"; }
  write_searxng_settings "$settings"
  setup_searxng_docker "$settings"
  [ -f "$settings/settings.yml" ]
  grep -Fq "$settings:/etc/searxng" "$log"
  rm -rf "$dir"
}

# test_merud_unit_uses_local_bin checks the release install path in the canonical unit.
test_merud_unit_uses_local_bin() {
  local unit="$script_dir/../deploy/systemd/merud.service"
  grep -Fqx 'ExecStart=%h/.local/bin/merud' "$unit"
  grep -Fqx 'Type=simple' "$unit"
  grep -Fqx 'Restart=on-failure' "$unit"
  grep -Fqx 'RestartSec=5' "$unit"
  grep -Fqx 'WantedBy=default.target' "$unit"
}

# test_service_uses_verified_release_unit avoids a second network download.
test_service_uses_verified_release_unit() {
  local dir old_home
  dir=$(mktemp -d); old_home=$HOME
  make_cli_archive "$dir" meru-test-linux-amd64
  load_installer
  HOME="$dir/home"; bin_dir="$HOME/.local/bin"; tmp="$dir/tmp"; mkdir -p "$tmp"
  install_cli "$dir/release.tar.gz" meru-test-linux-amd64 "$bin_dir"
  release_root="$dir/meru-test-linux-amd64"
  curl() { test_fail "service setup downloaded an unchecked unit"; }
  systemctl() { return 0; }
  wait_for_merud() { return 0; }
  install_merud_service
  cmp "$release_root/merud.service" "$HOME/.config/systemd/user/merud.service"
  HOME=$old_home
  rm -rf "$dir"
}

# test_service_copy_failure_stops_before_systemd keeps an old unit from restarting.
test_service_copy_failure_stops_before_systemd() {
  local dir log old_home
  dir=$(mktemp -d); log="$dir/log"; old_home=$HOME
  load_installer
  HOME="$dir/home"; release_root="$script_dir/../deploy/systemd"
  install() { return 1; }
  systemctl() { printf 'systemctl %s\n' "$*" >>"$log"; }
  wait_for_merud() { return 0; }
  if install_merud_service >/dev/null 2>&1; then
    HOME=$old_home
    rm -rf "$dir"
    test_fail "service setup hid a unit copy failure"
    return
  fi
  [ ! -s "$log" ] || { test_fail "systemd ran after the unit copy failed"; HOME=$old_home; rm -rf "$dir"; return; }
  HOME=$old_home
  rm -rf "$dir"
}

# test_service_install_reloads_enables_and_starts records the user-manager calls.
test_service_install_reloads_enables_and_starts() {
  local dir log old_home
  dir=$(mktemp -d); log="$dir/log"; old_home=$HOME
  load_installer
  type install_merud_service >/dev/null 2>&1 || { rm -rf "$dir"; test_fail "install_merud_service is missing"; return; }
  HOME="$dir/home"; bin_dir="$HOME/.local/bin"; release_root="$script_dir/../deploy/systemd"
  systemctl() { printf 'systemctl %s\n' "$*" >>"$log"; }
  wait_for_merud() { return 0; }
  install_merud_service
  grep -Fqx 'systemctl --user daemon-reload' "$log"
  grep -Fqx 'systemctl --user enable merud.service' "$log"
  grep -Fqx 'systemctl --user restart merud.service' "$log"
  HOME=$old_home
  rm -rf "$dir"
}

# test_service_rerun_replaces_one_unit_and_restarts keeps one canonical file.
test_service_rerun_replaces_one_unit_and_restarts() {
  local dir log old_home count
  dir=$(mktemp -d); log="$dir/log"; old_home=$HOME
  load_installer
  HOME="$dir/home"; bin_dir="$HOME/.local/bin"; release_root="$script_dir/../deploy/systemd"
  systemctl() { printf 'systemctl %s\n' "$*" >>"$log"; }
  wait_for_merud() { return 0; }
  install_merud_service
  install_merud_service
  count=$(find "$HOME/.config/systemd/user" -name merud.service -type f | wc -l | tr -d ' ')
  assert_equal 1 "$count"
  count=$(grep -Fc 'systemctl --user restart merud.service' "$log")
  assert_equal 2 "$count"
  HOME=$old_home
  rm -rf "$dir"
}

# test_missing_user_bus_prints_status_and_journal gives exact recovery commands.
test_missing_user_bus_prints_status_and_journal() {
  local dir old_home output
  dir=$(mktemp -d); old_home=$HOME
  load_installer
  type show_merud_failure >/dev/null 2>&1 || { rm -rf "$dir"; test_fail "show_merud_failure is missing"; return; }
  HOME="$dir/home"; bin_dir="$HOME/.local/bin"; release_root="$script_dir/../deploy/systemd"
  systemctl() { return 1; }
  output=$(install_merud_service 2>&1 || true)
  assert_contains "$output" 'systemctl --user status merud'
  assert_contains "$output" 'journalctl --user -u merud -n 50 --no-pager'
  HOME=$old_home
  rm -rf "$dir"
}

# test_service_handles_home_with_spaces quotes the user-unit destination.
test_service_handles_home_with_spaces() {
  local dir old_home
  dir=$(mktemp -d); old_home=$HOME
  load_installer
  HOME="$dir/home with spaces"; bin_dir="$HOME/.local/bin"; release_root="$script_dir/../deploy/systemd"
  systemctl() { return 0; }
  wait_for_merud() { return 0; }
  install_merud_service
  [ -f "$HOME/.config/systemd/user/merud.service" ]
  HOME=$old_home
  rm -rf "$dir"
}

# test_profile_runs_only_after_ping never asks for a profile after service failure.
test_profile_runs_only_after_ping() {
  local dir log
  dir=$(mktemp -d); log="$dir/log"
  load_installer
  type install_user_service >/dev/null 2>&1 || { rm -rf "$dir"; test_fail "install_user_service is missing"; return; }
  install_merud_service() { printf 'service\n' >>"$log"; return 1; }
  offer_user_profile() { printf 'profile\n' >>"$log"; }
  offer_lingering() { printf 'linger\n' >>"$log"; }
  install_user_service >/dev/null 2>&1 || true
  if grep -q '^profile$' "$log"; then test_fail "profile ran after failed ping"; fi
  : >"$log"
  install_merud_service() { printf 'service\n' >>"$log"; return 0; }
  install_user_service
  assert_equal $'service\nprofile\nlinger' "$(cat "$log")"
  rm -rf "$dir"
}

# test_service_waits_for_config keeps a non-interactive first run recoverable.
test_service_waits_for_config() {
  local dir log old_home output
  dir=$(mktemp -d); log="$dir/log"; old_home=$HOME
  load_installer
  type finish_linux_setup >/dev/null 2>&1 || { rm -rf "$dir"; test_fail "finish_linux_setup is missing"; return; }
  HOME="$dir/home"
  install_user_service() { printf 'service\n' >>"$log"; }
  output=$(finish_linux_setup)
  [ ! -s "$log" ] || { test_fail "service started without config"; HOME=$old_home; rm -rf "$dir"; return; }
  assert_contains "$output" 'meru setup'
  assert_contains "$output" 'run this installer again'
  mkdir -p "$HOME/.meru"
  : >"$HOME/.meru/config.toml"
  finish_linux_setup
  assert_equal service "$(cat "$log")"
  HOME=$old_home
  rm -rf "$dir"
}

# test_declined_lingering_never_calls_sudo leaves the login policy unchanged.
test_declined_lingering_never_calls_sudo() {
  local dir log
  dir=$(mktemp -d); log="$dir/log"
  load_installer
  type offer_lingering >/dev/null 2>&1 || { rm -rf "$dir"; test_fail "offer_lingering is missing"; return; }
  ask() { return 1; }
  sudo() { printf 'sudo %s\n' "$*" >>"$log"; }
  loginctl() { printf 'loginctl %s\n' "$*" >>"$log"; }
  offer_lingering
  [ ! -s "$log" ] || { test_fail "declined lingering ran commands"; rm -rf "$dir"; return; }
  rm -rf "$dir"
}

# test_accepted_lingering_runs_exact_loginctl_command checks the privileged argv.
test_accepted_lingering_runs_exact_loginctl_command() {
  local dir log output
  dir=$(mktemp -d); log="$dir/log"
  load_installer
  current_user() { printf 'meru-test\n'; }
  ask() { return 0; }
  sudo() { printf 'sudo %s\n' "$*" >>"$log"; }
  loginctl() { printf 'loginctl %s\n' "$*" >>"$log"; printf 'yes\n'; }
  offer_lingering
  output=$(cat "$log")
  assert_equal $'sudo loginctl enable-linger meru-test\nloginctl show-user meru-test -p Linger --value' "$output"
  rm -rf "$dir"
}

# test_lingering_must_report_yes rejects a command that did not take effect.
test_lingering_must_report_yes() {
  local output
  load_installer
  current_user() { printf 'meru-test\n'; }
  ask() { return 0; }
  sudo() { return 0; }
  loginctl() { printf 'no\n'; }
  if output=$(offer_lingering 2>&1); then
    test_fail "lingering accepted Linger=no"
    return
  fi
  assert_contains "$output" 'Linger=yes'
}

# run_test isolates each test because installer failures call exit.
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
  test_linux_release_archives_include_units \
  test_platform_for_ubuntu_2404_amd64 \
  test_platform_for_macos \
  test_platform_rejects_other_linux \
  test_os_release_is_data_not_code \
  test_source_does_not_run_main \
  test_direct_and_pipe_execution_reach_main \
  test_checksum_failure_writes_no_binary \
  test_manifest_names_every_download \
  test_linux_uses_sha256sum \
  test_macos_uses_shasum \
  test_install_cli_sets_mode_0755 \
  test_path_line_is_added_once \
  test_install_handles_home_with_spaces \
  test_existing_ollama_is_kept \
  test_ollama_installer_is_saved_then_run_after_yes \
  test_declined_ollama_runs_nothing \
  test_no_tty_runs_no_privileged_or_optional_command \
  test_meru_yes_banner_names_sudo_steps \
  test_desktop_package_decline_keeps_core_install \
  test_desktop_package_accepts_exact_apt_argv \
  test_meru_yes_installs_desktop_without_prompt \
  test_headless_desktop_keeps_checked_package_for_later \
  test_bad_checksum_stops_before_desktop_sudo \
  test_desktop_rerun_changes_no_core_path \
  test_linux_banner_does_not_require_user_env \
  test_linux_setup_uses_no_main_override \
  test_linux_configures_web_before_setup \
  test_linux_checks_name_acceptance_commands \
  test_ready_searxng_is_kept \
  test_ready_podman_refreshes_verified_quadlet \
  test_ready_podman_refresh_needs_consent \
  test_ready_podman_refresh_timeout_prints_recovery \
  test_existing_podman_container_keeps_podman \
  test_existing_docker_container_keeps_docker \
  test_broken_podman_falls_back_to_docker \
  test_existing_broken_podman_does_not_switch_owners \
  test_no_runtime_skips_with_recovery_text \
  test_settings_have_json_random_secret_and_modes \
  test_existing_settings_secret_is_kept \
  test_podman_quadlet_binds_loopback_and_uses_percent_h \
  test_podman_uses_verified_release_quadlet \
  test_podman_starts_generated_service_without_enable \
  test_podman_systemd_failure_returns \
  test_docker_argv_binds_loopback_and_restarts \
  test_docker_pull_failure_stops_before_run \
  test_searxng_handles_home_with_spaces \
  test_merud_unit_uses_local_bin \
  test_service_uses_verified_release_unit \
  test_service_copy_failure_stops_before_systemd \
  test_service_install_reloads_enables_and_starts \
  test_service_rerun_replaces_one_unit_and_restarts \
  test_missing_user_bus_prints_status_and_journal \
  test_service_handles_home_with_spaces \
  test_profile_runs_only_after_ping \
  test_service_waits_for_config \
  test_declined_lingering_never_calls_sudo \
  test_accepted_lingering_runs_exact_loginctl_command \
  test_lingering_must_report_yes
do
  run_test "$test_name"
done

if [ "$tests_failed" -ne 0 ]; then
  printf '%d of %d tests failed\n' "$tests_failed" "$tests_run" >&2
  exit 1
fi
printf 'PASS: %d installer tests\n' "$tests_run"
