#!/usr/bin/env bash
# check-deb.sh inspects the Ubuntu desktop package without installing it.

set -euo pipefail

# fail prints one failed package contract and stops the release.
fail() {
  printf 'check-deb: %s\n' "$*" >&2
  exit 1
}

# mode_of prints a file's numeric mode on macOS or Linux.
mode_of() {
  case "$(uname -s)" in
    Darwin) stat -f %Lp "$1" ;;
    *) stat -c %a "$1" ;;
  esac
}

# control_field prints one single-line Debian control field.
control_field() {
  local name=$1 file=$2
  sed -n "s/^$name: //p" "$file"
}

[ "$#" -eq 3 ] || fail "usage: check-deb.sh VERSION COMMIT PACKAGE"
version=$1
commit=$2
package=$3
[[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "VERSION must look like v0.5.0"
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || fail "COMMIT must be 40 lower-case hexadecimal characters"
[ -f "$package" ] || fail "package not found: $package"
[ "$(basename "$package")" = "Meru-$version-linux-amd64.deb" ] || fail "package has the wrong file name"
for tool in ar tar strings cmp; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool is not installed"
done

# The profile and postinst must match the repository's copies byte for byte,
# so a release can't ship a script or profile that review never saw.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(cd "$script_dir/.." && pwd)"
apparmor_profile="$root_dir/deploy/linux/meru-desktop.apparmor"
postinst="$root_dir/deploy/linux/postinst"
for source in "$apparmor_profile" "$postinst"; do
  [ -f "$source" ] || fail "required package file is missing: $source"
done

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
members=$(ar t "$package")
control_member=$(printf '%s\n' "$members" | sed -n '/^control\.tar\./p')
data_member=$(printf '%s\n' "$members" | sed -n '/^data\.tar\./p')
# package-deb.sh builds with xz, so a member with any other compression means
# some other tool built this package.
expected_members=$(printf 'control.tar.xz\ndata.tar.xz\ndebian-binary\n' | LC_ALL=C sort)
actual_members=$(printf '%s\n' "$members" | LC_ALL=C sort)
[ "$actual_members" = "$expected_members" ] || fail "package has unexpected ar members"
[ "$(ar p "$package" debian-binary)" = 2.0 ] || fail "package has the wrong Debian format version"

mkdir -p "$work/control" "$work/data"
# -J names the xz compression. GNU tar on Ubuntu can't detect compression
# when it reads a pipe; the Mac's tar can, but takes the flag as well.
ar p "$package" "$control_member" | tar -xJf - -C "$work/control"
ar p "$package" "$data_member" | tar -xJf - -C "$work/data"
[ -f "$work/control/control" ] || fail "package has no control file"
# The control archive holds control, conffiles and the one fixed postinst.
control_paths=$(cd "$work/control" && find . -mindepth 1 | LC_ALL=C sort)
expected_control_paths=$(printf '%s\n' ./conffiles ./control ./postinst | LC_ALL=C sort)
[ "$control_paths" = "$expected_control_paths" ] || fail "package has a missing or extra maintainer script or control file"
cmp -s "$work/control/postinst" "$postinst" || fail "postinst differs from deploy/linux/postinst"
[ "$(mode_of "$work/control/postinst")" = 755 ] || fail "postinst mode is not 0755"
[ "$(cat "$work/control/conffiles")" = /etc/apparmor.d/meru-desktop ] || fail "conffiles must list only /etc/apparmor.d/meru-desktop"
control="$work/control/control"
[ "$(control_field Package "$control")" = meru-desktop ] || fail "package name is not meru-desktop"
[ "$(control_field Version "$control")" = "${version#v}" ] || fail "package version does not match $version"
[ "$(control_field Architecture "$control")" = amd64 ] || fail "package architecture is not amd64"
[ "$(control_field Depends "$control")" = 'libgtk-4-1, libwebkitgtk-6.0-4, xdg-utils' ] || fail "package dependencies changed"
[ "$(control_field X-Meru-Commit "$control")" = "$commit" ] || fail "package commit does not match $commit"

[ -z "$(find "$work/data" -type l -print)" ] || fail "package contains a symbolic link"
paths=$(cd "$work/data" && find . -mindepth 1 | LC_ALL=C sort)
expected_paths=$(printf '%s\n' \
  ./etc \
  ./etc/apparmor.d \
  ./etc/apparmor.d/meru-desktop \
  ./usr \
  ./usr/bin \
  ./usr/bin/meru-desktop \
  ./usr/share \
  ./usr/share/applications \
  ./usr/share/applications/com.meru.desktop.desktop \
  ./usr/share/doc \
  ./usr/share/doc/meru-desktop \
  ./usr/share/doc/meru-desktop/copyright \
  ./usr/share/icons \
  ./usr/share/icons/hicolor \
  ./usr/share/icons/hicolor/512x512 \
  ./usr/share/icons/hicolor/512x512/apps \
  ./usr/share/icons/hicolor/512x512/apps/com.meru.desktop.png | LC_ALL=C sort)
[ "$paths" = "$expected_paths" ] || fail "package contains missing or extra paths"
[ "$(mode_of "$work/data/usr/bin/meru-desktop")" = 755 ] || fail "desktop binary mode is not 0755"
cmp -s "$work/data/etc/apparmor.d/meru-desktop" "$apparmor_profile" || fail "AppArmor profile differs from deploy/linux/meru-desktop.apparmor"
for file in \
  "$work/data/etc/apparmor.d/meru-desktop" \
  "$work/data/usr/share/applications/com.meru.desktop.desktop" \
  "$work/data/usr/share/icons/hicolor/512x512/apps/com.meru.desktop.png" \
  "$work/data/usr/share/doc/meru-desktop/copyright"
do
  [ "$(mode_of "$file")" = 644 ] || fail "$(basename "$file") mode is not 0644"
done
# grep reads the whole stream instead of stopping at the first match. With
# pipefail, an early exit could give strings SIGPIPE and reject a valid binary.
strings "$work/data/usr/bin/meru-desktop" | grep -F "$version" >/dev/null || fail "desktop binary does not contain version $version"

printf 'check-deb: %s is the checked %s package from %s\n' "$(basename "$package")" "$version" "$commit"
