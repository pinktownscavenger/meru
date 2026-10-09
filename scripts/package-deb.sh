#!/usr/bin/env bash
# package-deb.sh builds the fixed app-only package for Ubuntu 24.04 x86-64.

set -euo pipefail

# fail prints one package error and stops before dpkg-deb sees bad input.
fail() {
  printf 'package-deb: %s\n' "$*" >&2
  exit 1
}

[ "$#" -eq 4 ] || fail "usage: package-deb.sh VERSION COMMIT BINARY OUTPUT_DIR"
version=$1
commit=$2
binary=$3
output_dir=$4

[[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "VERSION must look like v0.5.0"
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || fail "COMMIT must be 40 lower-case hexadecimal characters"
[ -f "$binary" ] && [ -x "$binary" ] || fail "$binary is not an executable file"
command -v dpkg-deb >/dev/null 2>&1 || fail "dpkg-deb is not installed"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(cd "$script_dir/.." && pwd)"
desktop_file="$root_dir/deploy/linux/com.meru.desktop.desktop"
icon="$root_dir/docs/img/meru-logo.png"
licence="$root_dir/LICENSE"
for source in "$desktop_file" "$icon" "$licence"; do
  [ -f "$source" ] || fail "required package file is missing: $source"
done

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/DEBIAN" "$stage/usr/bin" "$stage/usr/share/applications" \
  "$stage/usr/share/icons/hicolor/512x512/apps" "$stage/usr/share/doc/meru-desktop" "$output_dir"

cat >"$stage/DEBIAN/control" <<EOF
Package: meru-desktop
Version: ${version#v}
Section: utils
Priority: optional
Architecture: amd64
Maintainer: Meru contributors <noreply@github.com>
Depends: libgtk-4-1, libwebkitgtk-6.0-4, xdg-utils
X-Meru-Commit: $commit
Description: Meru desktop app
 A thin desktop client for the local merud service.
EOF

install -m 0755 "$binary" "$stage/usr/bin/meru-desktop"
install -m 0644 "$desktop_file" "$stage/usr/share/applications/com.meru.desktop.desktop"
install -m 0644 "$icon" "$stage/usr/share/icons/hicolor/512x512/apps/com.meru.desktop.png"
install -m 0644 "$licence" "$stage/usr/share/doc/meru-desktop/copyright"
chmod 0755 "$stage/DEBIAN"
chmod 0644 "$stage/DEBIAN/control"

output="$output_dir/Meru-$version-linux-amd64.deb"
# -Zxz fixes the compression. dpkg-deb on Ubuntu 24.04 picks zstd by default,
# which check-deb.sh couldn't read, and xz reads with tar -J on Ubuntu and macOS.
dpkg-deb --root-owner-group -Zxz --build "$stage" "$output"
printf '%s\n' "$output"
