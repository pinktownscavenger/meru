#!/usr/bin/env bash
# install.sh installs Meru from a GitHub release. Run it with:
#
#   curl -fsSL https://github.com/aarora79/meru/releases/latest/download/install.sh | bash
#
# It downloads the release, checks every file against SHA256SUMS, puts meru
# and merud in ~/.local/bin and Meru.app in /Applications, and then offers
# the next steps: Ollama, the models, `meru setup`, and starting merud at
# login. It first lists what it will install and asks once: everything, each
# step in turn, or quit. MERU_YES=1 answers "everything" without asking.
# MERU_VERSION=v0.4.1 installs a given release instead of the latest.
#
# Meru never runs this script itself and never checks for updates; you run
# it again to update. MERU_APP_DIR puts Meru.app somewhere other than
# /Applications, such as a test folder.

# set -e stops at the first failed command, -u at an unset variable, and
# pipefail makes a pipeline fail when any part of it fails.
set -euo pipefail

repo="aarora79/meru"
bin_dir="$HOME/.local/bin"
# all is 1 when the user answers "install everything" at the start, or sets
# MERU_YES=1 to skip the question.
all="${MERU_YES:-0}"

say() { printf '\n==> %s\n' "$*"; }
fail() { printf 'install.sh: %s\n' "$*" >&2; exit 1; }

# has_tty reports whether this process can ask questions on its controlling terminal.
has_tty() {
  { : </dev/tty; } 2>/dev/null
}

# ask prints a yes/no question and returns 0 for yes. The script's own input
# is the curl pipe, so answers come from the terminal, /dev/tty. With no
# terminal, such as in CI, every answer is no.
ask() {
  local reply
  # With "install everything" chosen at the start, every step says yes.
  if [ "$all" = 1 ]; then printf '%s yes\n' "$1"; return 0; fi
  # Opening /dev/tty fails when there is no terminal, even if the file
  # exists, so try it quietly first.
  if ! has_tty; then return 1; fi
  printf '%s [y/N] ' "$1" >/dev/tty
  read -r reply </dev/tty || return 1
  case "$reply" in [yY]|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}

# os_release_value reads one key from os-release as text. It never executes the file.
os_release_value() {
  local path=$1 key=$2 line value
  while IFS= read -r line; do
    case "$line" in
      "$key="*)
        value=${line#*=}
        case "$value" in
          \"*\") value=${value#\"}; value=${value%\"} ;;
          \'*\') value=${value#\'}; value=${value%\'} ;;
        esac
        printf '%s\n' "$value"
        return 0
        ;;
    esac
  done <"$path"
  return 1
}

# platform_for maps one supported machine to the matching release archive name.
platform_for() {
  local kernel=$1 machine=$2 os_release_path=$3 id version_id
  case "$kernel:$machine" in
    Darwin:arm64) printf 'darwin-arm64\n' ;;
    Darwin:x86_64) printf 'darwin-amd64\n' ;;
    Linux:x86_64)
      id=$(os_release_value "$os_release_path" ID 2>/dev/null || true)
      version_id=$(os_release_value "$os_release_path" VERSION_ID 2>/dev/null || true)
      if [ "$id" = ubuntu ] && [ "$version_id" = 24.04 ]; then
        printf 'linux-amd64\n'
      else
        printf 'install.sh: this stage supports Ubuntu 24.04 on x86-64; use the release archive for %s %s\n' "$kernel" "$machine" >&2
        return 1
      fi
      ;;
    *)
      printf 'install.sh: unsupported system %s %s; use the matching release archive\n' "$kernel" "$machine" >&2
      return 1
      ;;
  esac
}

# verify_downloads checks files in a download directory with the platform tool.
verify_downloads() {
  local os=$1 directory=$2
  case "$os" in
    Linux) (cd "$directory" && sha256sum -c --ignore-missing SHA256SUMS) ;;
    Darwin) (cd "$directory" && shasum -a 256 -c --ignore-missing SHA256SUMS) ;;
    *) printf 'install.sh: no checksum tool for %s\n' "$os" >&2; return 1 ;;
  esac
}

# install_cli extracts a verified archive and installs both command-line programs.
install_cli() {
  local archive=$1 release_dir=$2 destination=$3 extract_dir
  extract_dir=$(dirname "$archive")
  tar -xzf "$archive" -C "$extract_dir"
  mkdir -p "$destination"
  install -m 0755 "$extract_dir/$release_dir/meru" "$extract_dir/$release_dir/merud" "$destination/"
}

# ensure_path_line adds the local binary directory to one shell profile once.
ensure_path_line() {
  local profile_file=$1 directory=$2 line
  line="export PATH=\"$directory:\$PATH\""
  if [ -f "$profile_file" ] && grep -Fqx "$line" "$profile_file"; then
    return 0
  fi
  mkdir -p "$(dirname "$profile_file")"
  printf '%s\n' "$line" >>"$profile_file"
}

# ollama_ready checks Ollama's loopback API without using a configured proxy.
ollama_ready() {
  curl --noproxy '*' -fsS --max-time 2 http://127.0.0.1:11434/api/version >/dev/null 2>&1
}

# install_ollama_linux keeps a working Ollama or runs its saved installer after consent.
install_ollama_linux() {
  local temp_dir=$1 installer_file="$1/ollama-install.sh"
  ollama_install_ran=0
  if ollama_ready; then
    echo "Ollama is already answering on 127.0.0.1:11434."
    return 0
  fi
  if ! ask "Download and run Ollama's Linux installer? It may use sudo."; then
    echo "Install Ollama later from https://ollama.com/download/linux."
    return 0
  fi
  curl -fsSL -o "$installer_file" https://ollama.com/install.sh || fail "couldn't download Ollama's installer"
  ollama_install_ran=1
  sh "$installer_file"
}

# wait_for_ollama waits for the local API and prints service checks on failure.
wait_for_ollama() {
  local seconds=$1 waited=0
  while [ "$waited" -lt "$seconds" ]; do
    ollama_ready && return 0
    sleep 1
    waited=$((waited + 1))
  done
  printf 'Ollama did not answer on http://127.0.0.1:11434. Check:\n' >&2
  printf '  systemctl status ollama --no-pager\n' >&2
  printf '  journalctl -u ollama -n 50 --no-pager\n' >&2
  return 1
}

# run_with_tty gives an interactive child the terminal instead of the curl pipe.
run_with_tty() {
  "$@" </dev/tty
}

# run_meru_setup hands config and model setup to the existing command-line client.
run_meru_setup() {
  if has_tty && ask "Run meru setup now (models, config, folders, and tools)?"; then
    run_with_tty "$bin_dir/meru" setup
  else
    echo "Run 'meru setup' when you're ready. A new setup uses the lite profile by default."
  fi
}

# linux_banner names every download and privileged step before work begins.
linux_banner() {
  local version=$1
  echo
  echo "  Meru $version for Ubuntu 24.04 on x86-64"
  echo "  -----------------------------------------"
  echo "  This installer downloads Meru from GitHub."
  echo "  It can download Ollama's installer, which may use sudo."
  echo "  It can pull the SearXNG image, docker.io/searxng/searxng:latest, with Podman or Docker."
  echo "  For a headless server, it can run: sudo loginctl enable-linger \"$USER\""
  echo "  It installs neither Podman nor Docker."
  if [ "$all" = 1 ]; then
    echo "  MERU_YES=1 accepts every step, including Ollama's installer and lingering."
  fi
  echo
}

# searxng_ready accepts the JSON search response Meru's web tool needs.
searxng_ready() {
  local response
  response=$(curl --noproxy '*' -fsS --max-time 3 'http://127.0.0.1:8888/search?q=test&format=json' 2>/dev/null) || return 1
  case "$response" in *'"results"'*) return 0 ;; *) return 1 ;; esac
}

# searxng_owner reports which runtime already owns the named container.
searxng_owner() {
  if command -v podman >/dev/null 2>&1 && podman container exists meru-searxng >/dev/null 2>&1; then
    printf 'podman\n'
    return 0
  fi
  if command -v docker >/dev/null 2>&1 && docker inspect meru-searxng >/dev/null 2>&1; then
    printf 'docker\n'
    return 0
  fi
}

# container_runtime_ready checks that a named runtime can reach its engine.
container_runtime_ready() {
  local runtime=$1
  command -v "$runtime" >/dev/null 2>&1 && "$runtime" info >/dev/null 2>&1
}

# choose_container_runtime prefers working rootless Podman, then working Docker.
choose_container_runtime() {
  if container_runtime_ready podman; then
    printf 'podman\n'
  elif container_runtime_ready docker; then
    printf 'docker\n'
  fi
}

# write_searxng_settings creates the bounded JSON-enabled settings once.
write_searxng_settings() {
  local directory=$1 settings="$1/settings.yml" secret
  mkdir -p "$directory"
  chmod 0700 "$directory"
  if [ -f "$settings" ]; then
    chmod 0600 "$settings"
    return 0
  fi
  secret=$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')
  [ "${#secret}" -eq 64 ] || fail "couldn't make SearXNG's secret key"
  printf '%s\n' \
    '# SearXNG settings, written by the Meru installer.' \
    '# SearXNG reads this file as /etc/searxng/settings.yml in its container.' \
    'use_default_settings: true' \
    '' \
    'general:' \
    '  instance_name: "Meru web search"' \
    '' \
    'search:' \
    '  safe_search: 1' \
    '  autocomplete: ""' \
    '  formats:' \
    '    - html' \
    '    - json' \
    '' \
    'server:' \
    '  base_url: "http://127.0.0.1:8888/"' \
    "  secret_key: \"$secret\"" \
    '  limiter: false' \
    '  public_instance: false' \
    '  image_proxy: false' >"$settings"
  chmod 0600 "$settings"
}

# setup_searxng_podman installs the Quadlet and starts its user service.
setup_searxng_podman() {
  local settings_dir=$1 unit_dir unit raw_url
  if podman container exists meru-searxng >/dev/null 2>&1; then
    podman start meru-searxng >/dev/null
    return 0
  fi
  unit_dir="$HOME/.config/containers/systemd"
  unit="$unit_dir/meru-searxng.container"
  raw_url="https://raw.githubusercontent.com/$repo/$version/deploy/systemd/meru-searxng.container"
  mkdir -p "$unit_dir"
  curl -fsSL -o "$unit" "$raw_url" || return 1
  systemctl --user daemon-reload
  systemctl --user enable --now meru-searxng.service
  : "$settings_dir"
}

# setup_searxng_docker pulls and runs one loopback-only Docker container.
setup_searxng_docker() {
  local settings_dir=$1
  local -a args=(
    run --detach
    --name meru-searxng
    --restart unless-stopped
    --publish 127.0.0.1:8888:8080
    --volume "$settings_dir:/etc/searxng"
    --env SEARXNG_BASE_URL=http://127.0.0.1:8888/
    docker.io/searxng/searxng:latest
  )
  docker pull docker.io/searxng/searxng:latest
  docker "${args[@]}"
}

# wait_for_searxng waits for one JSON response from the local search service.
wait_for_searxng() {
  local seconds=$1 waited=0
  while [ "$waited" -lt "$seconds" ]; do
    searxng_ready && return 0
    sleep 1
    waited=$((waited + 1))
  done
  return 1
}

# print_searxng_recovery names commands for the runtime that owns the service.
print_searxng_recovery() {
  case "$1" in
    podman)
      echo "Try: podman start meru-searxng"
      echo "Then check: systemctl --user status meru-searxng and journalctl --user -u meru-searxng -n 50"
      ;;
    docker)
      echo "Try: docker start meru-searxng"
      echo "Then check: docker ps -a --filter name=meru-searxng and docker logs meru-searxng"
      ;;
  esac
}

# setup_searxng keeps an existing owner or starts the optional local service.
setup_searxng() {
  local owner runtime settings_dir
  if searxng_ready; then
    echo "SearXNG already answers JSON on 127.0.0.1:8888; keeping it."
    return 0
  fi
  owner=$(searxng_owner)
  if [ -n "$owner" ]; then
    if ! container_runtime_ready "$owner"; then
      echo "The existing meru-searxng container belongs to $owner, but $owner is not working."
      print_searxng_recovery "$owner"
      return 0
    fi
    runtime=$owner
  else
    runtime=$(choose_container_runtime)
    if [ -z "$runtime" ]; then
      echo "Install Podman or Docker, start it, and run this installer again to add web search."
      return 0
    fi
  fi
  if ! ask "Set up optional SearXNG web search with $runtime?"; then
    echo "Skipped web search. Run this installer again when you want it."
    return 0
  fi
  settings_dir="$HOME/.meru/searxng"
  write_searxng_settings "$settings_dir"
  if [ -n "$owner" ]; then
    "$runtime" start meru-searxng >/dev/null || { print_searxng_recovery "$runtime"; return 0; }
  elif [ "$runtime" = podman ]; then
    setup_searxng_podman "$settings_dir" || { print_searxng_recovery podman; return 0; }
  else
    setup_searxng_docker "$settings_dir" || { print_searxng_recovery docker; return 0; }
  fi
  if ! wait_for_searxng 90; then
    echo "SearXNG did not answer JSON within 90 seconds."
    print_searxng_recovery "$runtime"
  fi
}

# download_merud_unit gets the canonical unit from the same release as the binaries.
download_merud_unit() {
  local destination=$1
  curl -fsSL -o "$destination" "https://raw.githubusercontent.com/$repo/$version/deploy/systemd/merud.service"
}

# show_merud_failure prints the two commands that explain a user-service failure.
show_merud_failure() {
  echo "merud did not start. Check:"
  echo "  systemctl --user status merud"
  echo "  journalctl --user -u merud -n 50 --no-pager"
}

# wait_for_merud waits for the installed client to reach the daemon socket.
wait_for_merud() {
  local seconds=$1 waited=0
  while [ "$waited" -lt "$seconds" ]; do
    "$bin_dir/meru" ping >/dev/null 2>&1 && return 0
    sleep 1
    waited=$((waited + 1))
  done
  return 1
}

# install_merud_service installs one canonical unit and restarts it on every run.
install_merud_service() {
  local work_dir source unit_dir unit
  work_dir=${tmp:-}
  if [ -z "$work_dir" ]; then
    work_dir=$(mktemp -d)
  fi
  source="$work_dir/merud.service"
  unit_dir="$HOME/.config/systemd/user"
  unit="$unit_dir/merud.service"
  mkdir -p "$work_dir" "$unit_dir"
  download_merud_unit "$source" || { echo "Could not download the merud user unit."; return 1; }
  install -m 0644 "$source" "$unit"
  if ! systemctl --user daemon-reload; then
    show_merud_failure
    return 1
  fi
  if ! systemctl --user enable merud.service; then
    show_merud_failure
    return 1
  fi
  if ! systemctl --user restart merud.service; then
    show_merud_failure
    return 1
  fi
  if ! wait_for_merud 60; then
    show_merud_failure
    return 1
  fi
  echo "merud is running as a systemd user service."
}

# offer_user_profile asks for the profile only after the daemon answers ping.
offer_user_profile() {
  if has_tty && ask "Tell Meru about you now?"; then
    run_with_tty "$bin_dir/meru" setup user
  else
    echo "Run 'meru setup user' when you're ready."
  fi
}

# offer_lingering enables a headless user service only after explicit consent.
offer_lingering() {
  local state
  if ! ask "Keep merud running on this server while you are logged out? This uses sudo loginctl enable-linger."; then
    echo "Lingering was not enabled. merud runs while your user has a login session."
    return 0
  fi
  if ! sudo loginctl enable-linger "$USER"; then
    echo "Could not enable lingering for $USER." >&2
    return 1
  fi
  state=$(loginctl show-user "$USER" -p Linger --value) || return 1
  if [ "$state" != yes ]; then
    echo "Lingering did not report Linger=yes for $USER." >&2
    return 1
  fi
  echo "Lingering is enabled for $USER."
}

# install_user_service starts merud before profile and lingering questions.
install_user_service() {
  install_merud_service || return 1
  offer_user_profile
  offer_lingering
}

# install_linux installs the verified CLI, then delegates setup to existing commands.
install_linux() {
  local version=$1 base cli release_dir choice
  linux_banner "$version"
  if [ "$all" != 1 ] && has_tty; then
    printf 'Install everything [a], choose each step [s], or quit [q]? ' >/dev/tty
    read -r choice </dev/tty || choice=q
    case "$choice" in
      [aA]*) all=1 ;;
      [sS]*) all=0 ;;
      *) echo "Nothing installed."; return 0 ;;
    esac
  fi

  tmp=$(mktemp -d)
  # EXIT removes the download folder whether this path succeeds or fails.
  trap 'rm -rf "$tmp"' EXIT
  base="https://github.com/$repo/releases/download/$version"
  cli="meru-$version-linux-amd64.tar.gz"
  release_dir="meru-$version-linux-amd64"
  curl -fsSL -o "$tmp/$cli" "$base/$cli" || fail "couldn't download $cli from $base"
  curl -fsSL -o "$tmp/SHA256SUMS" "$base/SHA256SUMS" || fail "couldn't download SHA256SUMS from $base"

  say "Checking the downloads against SHA256SUMS"
  verify_downloads Linux "$tmp" || fail "a download doesn't match SHA256SUMS; nothing was installed"
  say "Installing meru and merud in $bin_dir"
  install_cli "$tmp/$cli" "$release_dir" "$bin_dir"
  ensure_path_line "$HOME/.profile" '$HOME/.local/bin'
  export PATH="$bin_dir:$PATH"

  say "Ollama runs the models"
  install_ollama_linux "$tmp"
  if ollama_ready; then
    run_meru_setup
  elif [ "${ollama_install_ran:-0}" = 1 ] && wait_for_ollama 60; then
    run_meru_setup
  else
    echo "Run 'meru setup' after Ollama starts."
  fi
  setup_searxng
  install_user_service
}

# main performs the install when Bash executes this file rather than sourcing it.
main() {
local kernel machine platform os arch
kernel=$(uname -s)
machine=$(uname -m)
platform=$(platform_for "$kernel" "$machine" /etc/os-release) || exit 1
os=$kernel
arch=${platform#*-}

# The latest release's tag: github.com/<repo>/releases/latest redirects to
# .../releases/tag/<tag>, and curl's url_effective is where it landed.
version="${MERU_VERSION:-}"
if [ -z "$version" ]; then
  url="$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$repo/releases/latest")"
  version="${url##*/}"
fi
case "$version" in v[0-9]*.[0-9]*.[0-9]*) ;; *) fail "couldn't find the release to install (got '$version')" ;; esac
if [ "$platform" = linux-amd64 ]; then
  install_linux "$version"
  return
fi
# What this Mac will get, so the banner can list it before anything starts.
mem_gb=$(( $(sysctl -n hw.memsize) / 1073741824 ))
# The answer model to offer for this much memory, from docs/running.md,
# "Which model for which Mac": the model's file plus what Ollama holds for
# a 32,768-token context must fit beside the router, macOS and your apps.
# The same table as the Mac installer's (internal/config/recommend.go):
# 64 GB or more gets Qwen 3.6 35B at 8 bits, 48 to 63 GB the same model at
# 4 bits, 32 to 47 GB Gemma 4 at 4 bits, and less the lite models alone.
answer_model=""; answer_size=""; pulled_answer=0
if [ "$mem_gb" -ge 64 ]; then
  answer_model="qwen3.6:35b-a3b-mxfp8"; answer_size="38 GB"
elif [ "$mem_gb" -ge 48 ]; then
  answer_model="qwen3.6:35b"; answer_size="23 GB"
elif [ "$mem_gb" -ge 32 ]; then
  answer_model="gemma4:26b-a4b-it-qat"; answer_size="15 GB"
fi
has_ollama=0; command -v ollama >/dev/null 2>&1 && has_ollama=1
has_brew=0; command -v brew >/dev/null 2>&1 && has_brew=1

echo
echo "  Meru $version for macOS on $arch"
echo "  --------------------------------"
echo "  This takes several minutes, most of it downloading models."
echo "  Here is what it installs:"
echo
echo "    - meru and merud, about 40 MB, in $bin_dir"
[ "$arch" = "arm64" ] && echo "    - Meru.app, about 12 MB, in ${MERU_APP_DIR:-/Applications}"
if [ "$has_ollama" = 1 ]; then
  echo "    - Ollama: already installed"
elif [ "$has_brew" = 1 ]; then
  echo "    - Ollama, with Homebrew"
else
  echo "    - Ollama: install it yourself from https://ollama.com/download"
fi
echo "    - the lite models, about 2 GB: MiniCPM5-2B and nomic-embed-text"
if [ -n "$answer_model" ]; then
  echo "    - $answer_model, $answer_size, a stronger answer model for this Mac's $mem_gb GB"
fi
echo "    - meru setup, which asks its own questions: your folders and about you"
echo "    - merud, started now and at every login"
echo
echo "  Nothing goes anywhere but the downloads from GitHub, Homebrew and Ollama."
echo

if [ "$all" != 1 ] && { : </dev/tty; } 2>/dev/null; then
  printf 'Install everything [a], choose each step [s], or quit [q]? ' >/dev/tty
  read -r choice </dev/tty || choice=q
  case "$choice" in
    [aA]*) all=1 ;;
    [sS]*) all=0 ;;
    *) echo "Nothing installed."; exit 0 ;;
  esac
fi

say "Installing Meru $version for macOS on $arch"

tmp="$(mktemp -d)"
# trap removes the download folder when the script ends, however it ends.
trap 'rm -rf "$tmp"' EXIT
base="https://github.com/$repo/releases/download/$version"
cli="meru-$version-darwin-$arch.tar.gz"
app="Meru-$version-macos-arm64.zip"

files=("$cli" SHA256SUMS)
[ "$arch" = "arm64" ] && files+=("$app")
for f in "${files[@]}"; do
  curl -fsSL -o "$tmp/$f" "$base/$f" || fail "couldn't download $f from $base"
done

say "Checking the downloads against SHA256SUMS"
verify_downloads "$os" "$tmp" || fail "a download doesn't match SHA256SUMS; nothing was installed"

say "Installing meru and merud in $bin_dir"
install_cli "$tmp/$cli" "meru-$version-darwin-$arch" "$bin_dir"
case ":$PATH:" in
  *":$bin_dir:"*) ;;
  *)
    echo "$bin_dir isn't on your PATH."
    if ask "Add it to ~/.zshrc?"; then
      ensure_path_line "$HOME/.zshrc" '$HOME/.local/bin'
      echo "Added. Open a new Terminal window for it to take effect."
    fi
    export PATH="$bin_dir:$PATH"
    ;;
esac

if [ "$arch" = "arm64" ]; then
  apps="${MERU_APP_DIR:-/Applications}"
  [ -w "$apps" ] || apps="$HOME/Applications"
  say "Installing Meru.app in $apps"
  mkdir -p "$apps"
  rm -rf "$apps/Meru.app"
  ditto -x -k "$tmp/$app" "$apps"
  echo "Meru.app isn't signed by Apple, so macOS blocks it the first time."
  if ask "Clear the quarantine flag so it opens normally?"; then
    xattr -dr com.apple.quarantine "$apps/Meru.app"
  else
    echo "To open it later: right-click Meru.app, choose Open, then Open again."
  fi
else
  echo "Meru.app is built for Apple silicon only; on this Mac use meru and meru chat."
fi

say "Ollama runs the models"
if command -v ollama >/dev/null 2>&1; then
  echo "Ollama is installed: $(ollama --version 2>/dev/null || echo unknown version)."
elif command -v brew >/dev/null 2>&1 && ask "Install Ollama with Homebrew?"; then
  brew install ollama
  brew services start ollama
else
  echo "Install Ollama from https://ollama.com/download, open it, then run this script again or carry on below."
fi

if command -v ollama >/dev/null 2>&1; then
  echo "This Mac has $mem_gb GB of memory. Meru's lite models need about 2 GB."
  if ask "Download the lite models (MiniCPM5-2B and nomic-embed-text)?"; then
    ollama pull hf.co/openbmb/MiniCPM5-2B-GGUF:Q4_K_M
    ollama pull nomic-embed-text
  fi
  if [ -n "$answer_model" ] && ask "Also download $answer_model ($answer_size), a stronger answer model?"; then
    ollama pull "$answer_model"
    pulled_answer=1
  fi
fi

# how_to_use says how to make the downloaded model the one that answers,
# for a Mac that already had a config.toml, which this script leaves alone.
how_to_use() {
  echo "To answer with $answer_model: open Meru.app, Settings, Models, and click Use for answers on its card,"
  echo "or set main = \"$answer_model\" under [models] in ~/.meru/config.toml and restart merud."
}

say "Setting up Meru"
config="$HOME/.meru/config.toml"
had_config=0; [ -f "$config" ] && had_config=1
# meru setup asks its own questions, so it needs a terminal even when every
# step says yes. --main makes the answer model just downloaded the one a
# new config.toml names, so Meru answers with it from the first question.
setup_args=(setup)
[ "$pulled_answer" = 1 ] && setup_args+=(--main "$answer_model")
if { : </dev/tty; } 2>/dev/null && ask "Run meru setup now (config, folders, and questions about you)?"; then
  "$bin_dir/meru" "${setup_args[@]}" </dev/tty
else
  echo "Run 'meru setup' when you're ready."
fi
# Without meru setup there is no config.toml yet. Write one from the
# template with the answer model filled in, so merud still starts with it.
if [ "$pulled_answer" = 1 ] && [ ! -f "$config" ]; then
  mkdir -p "$HOME/.meru"
  "$bin_dir/meru" config template |
    sed "s|^main  = \"\".*|main  = \"$answer_model\"   # picked for this Mac's memory; writes the answer|" >"$config"
  echo "Wrote $config with $answer_model as the answer model."
fi

plist="$HOME/Library/LaunchAgents/com.meru.merud.plist"
if ask "Start merud now and at every login?"; then
  mkdir -p "$HOME/Library/LaunchAgents" "$HOME/.meru"
  curl -fsSL "https://raw.githubusercontent.com/$repo/$version/deploy/launchd/com.meru.merud.plist" |
    sed -e "s|__HOME__/go/bin/merud|$bin_dir/merud|" -e "s|__HOME__|$HOME|g" >"$plist"
  launchctl unload "$plist" 2>/dev/null || true
  launchctl load "$plist"
  sleep 2
  "$bin_dir/meru" ping || echo "merud didn't answer yet; check ~/.meru/merud.err.log."
else
  echo "Start it yourself with: merud &"
fi

say "Done"
echo "Ask a question:   meru \"what can you do?\""
echo "Chat:             meru chat"
[ "$arch" = "arm64" ] && echo "Desktop app:      open Meru.app"
echo "Gmail, Calendar and Drive: https://github.com/$repo/blob/main/docs/google-setup.md"
if [ "$pulled_answer" = 1 ] && [ "$had_config" = 1 ]; then how_to_use; fi
}

# BASH_SOURCE differs from $0 when another script sources this file. With
# `curl ... | bash`, BASH_SOURCE is empty, so that published form also runs main.
if [ -z "${BASH_SOURCE[0]:-}" ] || [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
