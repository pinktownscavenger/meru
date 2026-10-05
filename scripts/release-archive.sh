#!/usr/bin/env bash
# release-archive.sh packs one platform from bin/ into its release archive.

set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "usage: release-archive.sh <platform> <archive name> <binary suffix>" >&2
  exit 2
fi

platform=$1
name=$2
ext=$3
dir="dist/stage/$name"
tar_owner_args=(--owner=0 --group=0)

# The owner flags differ between the Mac's bsdtar and GNU tar on Linux.
case "$(tar --version 2>/dev/null)" in
  *bsdtar*) tar_owner_args=(--no-xattrs --no-acls --no-fflags --uid 0 --gid 0 --uname root --gname root) ;;
esac

mkdir -p "$dir"
cp "bin/$platform/meru$ext" "bin/$platform/merud$ext" LICENSE README.md "$dir/"

# Linux runs these definitions after install, so the archive checksum must
# cover the exact files that the installer copies into the user's services.
if [ "${platform%%-*}" = linux ]; then
  cp deploy/systemd/merud.service deploy/systemd/meru-searxng.container "$dir/"
fi

# Each archive opens to one folder named for its version and platform.
if [ -n "$ext" ]; then
  (cd dist/stage && zip -q -r -X "../$name.zip" "$name")
else
  tar -C dist/stage "${tar_owner_args[@]}" -czf "dist/$name.tar.gz" "$name"
fi
