#!/bin/sh
#
# Run scripts/fetch-hvi.sh against a stub curl and cosign, and check that it
# installs hvi only when every check passes. The stub curl serves a release
# built here; the stub cosign accepts the bundle only when it reads "good" and
# the identity is hvi-vmm's tag-release workflow for the tag.

set -eu

here="$(cd "$(dirname "$0")/.." && pwd)"

skip() { echo "SKIP: $*"; exit 0; }
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok - $*"; }

command -v sha256sum >/dev/null 2>&1 || skip "fetch-hvi.sh needs sha256sum"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/stub"

version=9.9.9-rc.1
commit=5555555555555555555555555555555555555555
archive="hvi-$version-x86_64-unknown-linux-musl.tar.gz"

sha() { sha256sum "$1" | awk '{print $1}'; }

# release [rev] [manifest-sha]: build the release in $T/rel. The manifest names
# rev and the sha of hvi unless told otherwise.
release() {
    rm -rf "$T/rel" "$T/pkg"
    mkdir -p "$T/rel" "$T/pkg"
    echo "hvi $version" > "$T/pkg/hvi"
    chmod 0755 "$T/pkg/hvi"
    cat > "$T/pkg/manifest.json" <<EOF
{
  "component": "binaries",
  "target": "x86_64-unknown-linux-musl",
  "version": "$version",
  "revision": "${1:-$commit}",
  "files": {
    "hvi": "${2:-$(sha "$T/pkg/hvi")}"
  }
}
EOF
    tar -czf "$T/rel/$archive" -C "$T/pkg" hvi manifest.json
    echo "$(sha "$T/rel/$archive")  $archive" > "$T/rel/SHA256SUMS"
    echo good > "$T/rel/SHA256SUMS.cosign.bundle"
}

cat > "$T/stub/curl" <<STUB
#!/bin/sh
while [ \$# -gt 1 ]; do
    case "\$1" in -o) out="\$2"; shift 2 ;; *) shift ;; esac
done
case "\$1" in
    https://github.com/brig-sh/hvi-vmm/releases/download/v$version/*) ;;
    *) exit 22 ;;
esac
cp "$T/rel/\${1##*/}" "\$out"
STUB

cat > "$T/stub/cosign" <<'STUB'
#!/bin/sh
while [ $# -gt 1 ]; do
    case "$1" in
        --bundle) bundle="$2"; shift 2 ;;
        --certificate-identity-regexp) id="$2"; shift 2 ;;
        *) shift ;;
    esac
done
[ "$id" = '^https://github\.com/brig-sh/hvi-vmm/\.github/workflows/tag-release\.yml@refs/tags/v9\.9\.9-rc\.1$' ] || exit 1
[ "$(cat "$bundle")" = good ]
STUB
chmod 0755 "$T/stub"/*

# fetch [VAR=value...]: run fetch-hvi.sh for amd64, output in $T/out.log.
fetch() {
    rm -f "$T/hvi"
    env PATH="$T/stub:$PATH" COSIGN="$T/stub/cosign" \
        HVI_VERSION=$version HVI_COMMIT=$commit HVI_SHA256="$(sha "$T/rel/$archive")" "$@" \
        sh "$here/scripts/fetch-hvi.sh" amd64 "$T/hvi" > "$T/out.log" 2>&1
}

# refused <message> [VAR=value...]: fetch must fail with <message> and install
# nothing.
refused() {
    msg="$1"; shift
    if fetch "$@"; then cat "$T/out.log" >&2; fail "fetch-hvi.sh passed: $msg"; fi
    grep -q "$msg" "$T/out.log" || { cat "$T/out.log" >&2; fail "no '$msg' in the output"; }
    [ ! -e "$T/hvi" ] || fail "hvi was installed although: $msg"
}

# 1. A release that checks out is installed.
release
fetch || { cat "$T/out.log" >&2; fail "a good release was refused"; }
grep -qx "hvi $version" "$T/hvi" || fail "the installed hvi is not the release's"
ok "a signed release that matches its pins is installed"

# 2. A bundle cosign rejects.
echo forged > "$T/rel/SHA256SUMS.cosign.bundle"
refused "is not signed by brig-sh/hvi-vmm's tag-release workflow"
ok "an unsigned SHA256SUMS is refused"

# 3. A tarball that SHA256SUMS does not list.
release
echo "x" >> "$T/rel/$archive"
refused "SHA256SUMS says" HVI_SHA256="$(sha "$T/rel/$archive")"
ok "a tarball other than the one SHA256SUMS lists is refused"

# 4. A signed release whose tarball is not the pinned one.
release
refused "the pin says" HVI_SHA256=0000000000000000000000000000000000000000000000000000000000000000
ok "a tarball other than the pinned one is refused"

# 5. A manifest that names another commit.
release 6666666666666666666666666666666666666666
refused "the manifest names commit '6666666666666666666666666666666666666666'"
ok "a release built from another commit is refused"

# 6. A binary that is not the one the manifest names.
release "$commit" 7777777777777777777777777777777777777777777777777777777777777777
refused "the manifest says '7777777777777777777777777777777777777777777777777777777777777777'"
ok "a binary other than the one the manifest names is refused"

# 7. Pins that are not a commit and a sha are refused before anything is fetched.
release
refused "is not a full 40-character SHA" HVI_COMMIT=65570c7
refused "is not a sha256" HVI_SHA256=abc
ok "a short commit or sha pin is refused"
