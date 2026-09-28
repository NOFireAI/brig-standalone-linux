#!/bin/sh
#
# Install a minimal fake bundle from a release served over http, and from a
# local tarball, and check when the release's checksums.txt, .sig and .pem are
# kept beside the boot assets' SHA256SUMS: only when checksums.txt lists that
# SHA256SUMS under a *.boot-assets.sha256 name and the signature came with it,
# cosign or not.
#
# Needs a normal user with a subuid range, and python3 to serve the release, on
# Linux.

set -eu

here="$(cd "$(dirname "$0")/.." && pwd)"
user="$(id -un)"

skip() { echo "SKIP: $*"; exit 0; }
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok - $*"; }

[ "$(uname -s)" = Linux ] || skip "install.sh installs on Linux only"
[ "$(id -u)" -ne 0 ] || skip "a user install refuses root; run this as a normal user"
grep -q "^$user:" /etc/subuid 2>/dev/null || skip "no subuid range for $user"
grep -q "^$user:" /etc/subgid 2>/dev/null || skip "no subgid range for $user"
command -v python3 >/dev/null 2>&1 || skip "no python3 to serve the release"

T="$(mktemp -d)"
server=""
trap '[ -z "$server" ] || kill "$server" 2>/dev/null; rm -rf "$T"' EXIT
mkdir -p "$T/stub" "$T/nocosign" "$T/rel" "$T/bare"

# make_release <name> <with-sums> <listed>: a fake rootless bundle in $T/rel,
# with a checksums.txt that lists the tarball, and the record when <listed> is
# yes, and stand-ins for its signature and certificate. Any other <listed> but
# no is the name the record is listed under instead.
make_release() {
    bdir="$T/src/$1"
    rm -rf "$T/src"
    mkdir -p "$bdir/bin" "$bdir/etc" "$bdir/share/guest"
    printf '#!/bin/sh\necho setup-ran\n' > "$bdir/bin/brig-rootless-setup.sh"
    printf '#!/bin/sh\necho brig 0.3.0\n' > "$bdir/bin/brig"
    chmod 0755 "$bdir/bin"/*
    : > "$bdir/etc/brig-env.sh"
    echo kernel > "$bdir/share/guest/bzImage"
    echo initrd > "$bdir/share/guest/container-initrd"
    if [ "$2" = yes ]; then
        ( cd "$bdir/share/guest" && sha256sum -- bzImage container-initrd ) \
            > "$bdir/share/guest/SHA256SUMS"
    fi
    cat > "$bdir/pins.env" <<'PINS'
BUNDLE_VERSION=v9.9.9
BRIG_VERSION=v0.3.0
ROOTLESS=true
PINS
    tar -C "$T/src" -czf "$T/rel/$1.tar.gz" "$1"
    ( cd "$T/rel" && sha256sum -- "$1.tar.gz" > checksums.txt )
    if [ "$2" = yes ] && [ "$3" != no ]; then
        rec="$1.boot-assets.sha256"
        [ "$3" = yes ] || rec="$3"
        sum="$(sha256sum "$bdir/share/guest/SHA256SUMS" | awk '{print $1}')"
        echo "$sum  $rec" >> "$T/rel/checksums.txt"
    fi
    echo signature > "$T/rel/checksums.txt.sig"
    echo certificate > "$T/rel/checksums.txt.pem"
}

# The host checks pass, as in install-summary.sh. In $T/stub cosign answers
# yes, so the stand-in signature is taken whatever cosign this host has.
# $T/nocosign is the same without cosign.
cat > "$T/stub/getfacl" <<STUB
#!/bin/sh
echo "user:$user:rw-"
STUB
printf '#!/bin/sh\necho 0\n' > "$T/stub/sysctl"
printf '#!/bin/sh\n[ "$*" = "-n true" ]\n' > "$T/stub/sudo"
printf '#!/bin/sh\nexit 1\n' > "$T/stub/modinfo"
for b in newuidmap setfacl systemctl cosign; do
    printf '#!/bin/sh\nexit 0\n' > "$T/stub/$b"
done
chmod 0755 "$T/stub"/*
cp -p "$T/stub"/* "$T/nocosign/"
rm "$T/nocosign/cosign"

port="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
python3 -m http.server --bind 127.0.0.1 --directory "$T/rel" "$port" > "$T/http.log" 2>&1 &
server=$!
i=0
until curl -sf -o /dev/null "http://127.0.0.1:$port/"; do
    i=$((i + 1))
    [ "$i" -lt 50 ] || fail "the release server did not come up"
    sleep 0.1
done
url="http://127.0.0.1:$port"

# install_from <bundle> [<stub dir>]: a user install into a fresh HOME, from a
# URL or a path.
install_from() {
    rm -rf "${T:?}/home" "${T:?}/run"
    mkdir -p "$T/home" "$T/run"
    if ! env -u XDG_CONFIG_HOME -u XDG_DATA_HOME \
        HOME="$T/home" XDG_RUNTIME_DIR="$T/run" PATH="${2:-$T/stub}:$PATH" \
        INSTALL_BRIG_BUNDLE="$1" \
        sh "$here/install.sh" > "$T/out.log" 2>&1; then
        cat "$T/out.log" >&2
        fail "the install from $1 failed"
    fi
}
guest="$T/home/.local/share/brig/data/share/guest"

kept() {
    for f in checksums.txt checksums.txt.sig checksums.txt.pem; do
        cmp -s "$1/$f" "$guest/$f" || fail "$2: $f was not kept beside the boot assets"
    done
}
none_kept() {
    for f in checksums.txt checksums.txt.sig checksums.txt.pem; do
        [ ! -e "$guest/$f" ] || fail "$1: $f was kept"
    done
}

name=brig-standalone-v9.9.9-rootless-linux-amd64
make_release "$name" yes yes

install_from "$url/$name.tar.gz"
kept "$T/rel" "release install"
[ -f "$guest/SHA256SUMS" ] || fail "the bundle's SHA256SUMS is missing"
ok "a release install keeps checksums.txt, its signature and its certificate"

# Without cosign the signature is not checked here, and it is still fetched
# and kept, for brig to check with the bundle's own cosign.
if PATH="$T/nocosign:$PATH" command -v cosign >/dev/null 2>&1; then
    echo "SKIP: this host has cosign on PATH, so the no-cosign install cannot be run"
else
    before="$(grep -c 'GET /checksums.txt.sig ' "$T/http.log" || true)"
    install_from "$url/$name.tar.gz" "$T/nocosign"
    after="$(grep -c 'GET /checksums.txt.sig ' "$T/http.log" || true)"
    [ "$after" -gt "$before" ] || fail "without cosign the signature was not fetched"
    kept "$T/rel" "no-cosign install"
    ok "a release install with no cosign still fetches and keeps the signature"
fi

cp "$T/rel/$name.tar.gz" "$T/bare/"
install_from "$T/bare/$name.tar.gz"
none_kept "local tarball alone"
ok "a local tarball with nothing beside it keeps no release record"

install_from "$T/rel/$name.tar.gz"
kept "$T/rel" "local tarball beside the release files"
ok "a local tarball keeps the release files copied across beside it"

make_release "$name" yes no
install_from "$url/$name.tar.gz"
none_kept "unlisted record"
grep -q 'does not list this bundle' "$T/out.log" \
    || { cat "$T/out.log" >&2; fail "an unlisted record was dropped without a warning"; }
ok "a checksums.txt that does not list SHA256SUMS keeps none, and says so"

# brig takes the record only under a *.boot-assets.sha256 name.
make_release "$name" yes "$name.pins.env"
install_from "$url/$name.tar.gz"
none_kept "record under another name"
grep -q 'does not list this bundle' "$T/out.log" \
    || { cat "$T/out.log" >&2; fail "a record under another name was dropped without a warning"; }
ok "a checksums.txt that lists SHA256SUMS under another name keeps none, and says so"

make_release "$name" yes yes
rm "$T/rel/checksums.txt.sig"
install_from "$url/$name.tar.gz"
none_kept "no signature"
grep -q 'gave no checksums.txt.sig' "$T/out.log" \
    || { cat "$T/out.log" >&2; fail "a release with no signature was dropped without a warning"; }
ok "a release with no signature keeps none, and says so"

old=brig-standalone-v9.9.8-rootless-linux-amd64
make_release "$old" no no
install_from "$url/$old.tar.gz"
none_kept "no SHA256SUMS"
ok "a bundle with no SHA256SUMS keeps no release record"
