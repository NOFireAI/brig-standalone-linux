#!/bin/sh
#
# Fetch the hvi release build-bundle.sh pins, verify it and copy the binary out.
#
#   scripts/fetch-hvi.sh <amd64|arm64> <out-file>
#
# The pins come from the environment: HVI_VERSION (the tag without its v),
# HVI_COMMIT (the full commit the release was built from) and HVI_SHA256 (the
# sha256 of this arch's tarball). COSIGN names the cosign binary, v3 or later.
#
# SHA256SUMS must carry a cosign bundle signed by hvi-vmm's tag-release
# workflow for the pinned tag. The tarball must match both SHA256SUMS and
# HVI_SHA256, and its manifest must name HVI_COMMIT and the sha256 of the hvi
# binary in it. hull's scripts/fetch-hvi.sh checks the macOS tarball of the
# same release the same way.

set -eu

die() {
    echo "fetch-hvi: $*" >&2
    exit 1
}

[ $# -eq 2 ] || die "usage: $0 <amd64|arm64> <out-file>"
arch="$1"
out="$2"

: "${HVI_VERSION:?fetch-hvi: HVI_VERSION is not set}"
: "${HVI_COMMIT:?fetch-hvi: HVI_COMMIT is not set}"
: "${HVI_SHA256:?fetch-hvi: HVI_SHA256 is not set}"
cosign="${COSIGN:-cosign}"

case "$arch" in
    amd64) target=x86_64-unknown-linux-musl ;;
    arm64) target=aarch64-unknown-linux-musl ;;
    *) die "unknown arch '$arch'" ;;
esac
case "$HVI_COMMIT" in
    *[!0-9a-f]*) die "HVI_COMMIT=$HVI_COMMIT is not a commit" ;;
esac
[ "${#HVI_COMMIT}" -eq 40 ] || die "HVI_COMMIT=$HVI_COMMIT is not a full 40-character SHA"
case "$HVI_SHA256" in
    *[!0-9a-f]*) die "HVI_SHA256=$HVI_SHA256 is not a lowercase sha256" ;;
esac
[ "${#HVI_SHA256}" -eq 64 ] || die "HVI_SHA256=$HVI_SHA256 is not a sha256"

tag="v$HVI_VERSION"
archive="hvi-$HVI_VERSION-$target.tar.gz"
identity="^https://github\\.com/brig-sh/hvi-vmm/\\.github/workflows/tag-release\\.yml@refs/tags/$(printf '%s' "$tag" | sed 's/\./\\./g')\$"
issuer=https://token.actions.githubusercontent.com
base="https://github.com/brig-sh/hvi-vmm/releases/download/$tag"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

for f in "$archive" SHA256SUMS SHA256SUMS.cosign.bundle; do
    curl -fsSL --retry 3 -o "$tmp/$f" "$base/$f" || die "cannot download $base/$f"
done

"$cosign" verify-blob \
    --bundle "$tmp/SHA256SUMS.cosign.bundle" \
    --certificate-identity-regexp "$identity" \
    --certificate-oidc-issuer "$issuer" \
    "$tmp/SHA256SUMS" >/dev/null \
    || die "SHA256SUMS of $tag is not signed by brig-sh/hvi-vmm's tag-release workflow"

listed="$(awk -v f="$archive" '$2 == f || $2 == "*" f { print $1; exit }' "$tmp/SHA256SUMS")"
[ -n "$listed" ] || die "SHA256SUMS lists no $archive"
got="$(sha256sum "$tmp/$archive" | awk '{print $1}')"
[ "$got" = "$listed" ] || die "$archive is $got, SHA256SUMS says $listed"
[ "$got" = "$HVI_SHA256" ] || die "$archive is $got, the pin says $HVI_SHA256"

mkdir "$tmp/x"
tar -xzf "$tmp/$archive" -C "$tmp/x" hvi manifest.json || die "$archive has no hvi or manifest.json"
# The manifest is flat JSON with one key per line.
rev="$(sed -n 's/^ *"revision": *"\([0-9a-f]*\)".*/\1/p' "$tmp/x/manifest.json")"
[ "$rev" = "$HVI_COMMIT" ] || die "the manifest names commit '$rev', the pin says $HVI_COMMIT"
want="$(sed -n 's/^ *"hvi": *"\([0-9a-f]*\)".*/\1/p' "$tmp/x/manifest.json")"
have="$(sha256sum "$tmp/x/hvi" | awk '{print $1}')"
[ -n "$want" ] && [ "$have" = "$want" ] || die "hvi is $have, the manifest says '$want'"

install -m 0755 "$tmp/x/hvi" "$out"
echo "fetch-hvi: hvi $HVI_VERSION ($HVI_COMMIT, $target), signature and sums verified"
