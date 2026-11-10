#!/usr/bin/env bash
# Installs a Swift release toolchain on Ubuntu (22.04 or 24.04, x86-64 or arm64), as root, for building servers on
# small machines. The tarball is unpacked as it downloads and never stored, its signature (and, given one, its
# sha256) checked on the way through, and what a release build doesn't use (the debugger, the editor and
# documentation tools) is left out: about 2.6 GB on disk instead of a 4.8 GB peak.
#
#   sudo SWIFT_VERSION=6.4.2 bash scripts/install-swift.sh
#
# SWIFT_VERSION  the release (default 6.4.2)
# SWIFT_SHA256   the tarball's sha256, checked as well as its signature when given
# SWIFT_PREFIX   where it goes (default /opt/swift); swift and swiftc are linked into /usr/local/bin
# SWIFT_FULL=1   keeps everything (lldb, sourcekit-lsp, docc, swift-format)
# SWIFT_SIGNING_KEY  the fingerprint of the key that signs the release (default: the Swift 6.x release key)
set -euo pipefail
SWIFT_VERSION=${SWIFT_VERSION:-6.4.2}
SWIFT_PREFIX=${SWIFT_PREFIX:-/opt/swift}
# The Swift 6.x release signing key.
SWIFT_SIGNING_KEY=${SWIFT_SIGNING_KEY:-52BB7E3DE28A71BE22EC05FFEF80A866B47A981F}

. /etc/os-release
case "${ID}-${VERSION_ID}" in
  ubuntu-24.04) PLATFORM=ubuntu24.04; GCC=13 ;;
  ubuntu-22.04) PLATFORM=ubuntu22.04; GCC=11 ;;
  *) echo "install-swift: Ubuntu 22.04 or 24.04 only (this is ${PRETTY_NAME:-unknown})" >&2; exit 1 ;;
esac
case "$(uname -m)" in
  x86_64) SUFFIX= ;;
  aarch64) SUFFIX=-aarch64 ;;
  *) echo "install-swift: x86_64 or aarch64 only" >&2; exit 1 ;;
esac

apt-get update -q
apt-get install -y -q --no-install-recommends \
  binutils ca-certificates curl git gnupg2 libc6-dev libcurl4-openssl-dev libedit2 "libgcc-$GCC-dev" \
  libncurses-dev libpython3-dev libsqlite3-0 "libstdc++-$GCC-dev" libxml2-dev libz3-dev pkg-config tzdata unzip \
  zlib1g-dev

NAME="swift-$SWIFT_VERSION-RELEASE-$PLATFORM$SUFFIX"
URL="https://download.swift.org/swift-$SWIFT_VERSION-release/${PLATFORM//./}$SUFFIX/swift-$SWIFT_VERSION-RELEASE/$NAME.tar.gz"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# The signature against swift.org's keys, in a keyring of its own.
export GNUPGHOME="$WORK/gnupg"
mkdir -m 700 "$GNUPGHOME"
# The release key by its fingerprint from a keyserver, as swift.org's own Docker images get it; failing that, swift.org's
# key file (which a CDN sometimes answers with a page instead, from CI machines).
for try in 1 2 3; do
  gpg --batch --quiet --keyserver hkps://keyserver.ubuntu.com --recv-keys "$SWIFT_SIGNING_KEY" 2> /dev/null && break
  # (gpg's import fails as a whole when one old key in the file can't be taken, so what counts is the key being there.)
  curl -fsSL https://www.swift.org/keys/all-keys.asc -o "$WORK/keys.asc" \
    && { gpg --batch --quiet --import "$WORK/keys.asc" 2> /dev/null; gpg --batch --list-keys "$SWIFT_SIGNING_KEY" > /dev/null 2>&1; } \
    && break
  sleep $((5 * try))
done
gpg --batch --list-keys "$SWIFT_SIGNING_KEY" > /dev/null 2>&1 || { echo "install-swift: no Swift signing key" >&2; exit 1; }
curl -fsSL --retry 3 "$URL.sig" -o "$WORK/tarball.sig"

EXCLUDES=()
if [ "${SWIFT_FULL:-0}" != 1 ]; then
  EXCLUDES=(--exclude='usr/bin/lldb*' --exclude='usr/lib/liblldb*' --exclude='usr/lib/python3*'
    --exclude='usr/bin/sourcekit-lsp' --exclude='usr/lib/libsourcekitdInProc.so' --exclude='usr/bin/clangd'
    --exclude='usr/bin/docc' --exclude='usr/share/docc' --exclude='usr/share/doc' --exclude='usr/share/man'
    --exclude='usr/bin/swift-format')
fi

rm -rf "$SWIFT_PREFIX" && mkdir -p "$SWIFT_PREFIX"
# gpg and sha256sum read copies of the download through FIFOs while tar unpacks it; if either check fails,
# everything unpacked is removed.
mkfifo "$WORK/gpg" "$WORK/sha"
gpg --batch --verify "$WORK/tarball.sig" - < "$WORK/gpg" > "$WORK/gpg.out" 2>&1 &
GPG=$!
sha256sum < "$WORK/sha" > "$WORK/sha.out" &
SHA=$!
curl -fsSL "$URL" | tee -p "$WORK/gpg" "$WORK/sha" \
  | tar -C "$SWIFT_PREFIX" -xz --strip-components=1 "${EXCLUDES[@]}"
fail() {
  rm -rf "$SWIFT_PREFIX"
  echo "install-swift: $1" >&2
  exit 1
}
wait "$GPG" || { cat "$WORK/gpg.out" >&2; fail "bad signature on $NAME.tar.gz"; }
wait "$SHA"
if [ -n "${SWIFT_SHA256:-}" ] && [ "$(cut -d' ' -f1 "$WORK/sha.out")" != "$SWIFT_SHA256" ]; then
  fail "sha256 mismatch for $NAME.tar.gz"
fi

for bin in swift swiftc; do ln -sf "$SWIFT_PREFIX/usr/bin/$bin" "/usr/local/bin/$bin"; done
swift --version
du -sh "$SWIFT_PREFIX"
