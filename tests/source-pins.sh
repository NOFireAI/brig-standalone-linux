#!/bin/sh
#
# Run build-bundle.sh against a stub git, docker and curl, and check which urunc
# commit it asks for and which urunit commit it records. Nothing is fetched: the
# stub git records the ref it was asked to fetch, answers rev-parse with it and
# plants the urunit.pin the build reads from the urunc checkout; the stub docker
# fakes the urunc build; the stub curl fails the first download, which ends the
# run.
#
# Needs the tools build-bundle.sh checks for (curl, tar, sha256sum, awk, sed).

set -eu

here="$(cd "$(dirname "$0")/.." && pwd)"

skip() { echo "SKIP: $*"; exit 0; }
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok - $*"; }

command -v sha256sum >/dev/null 2>&1 || skip "build-bundle.sh needs sha256sum"

urunc_pin="$(sed -n 's/^URUNC_REF_DEFAULT=\([0-9a-f]*\)$/\1/p' "$here/scripts/build-bundle.sh")"
urunc_branch="$(sed -n 's/^URUNC_BRANCH_DEFAULT=\(.*\)$/\1/p' "$here/scripts/build-bundle.sh")"
[ "${#urunc_pin}" -eq 40 ] || fail "no URUNC_REF_DEFAULT in build-bundle.sh"
tip=1111111111111111111111111111111111111111
# The urunit commit the stub urunc checkout pins in its urunit.pin. The build
# has no urunit pin of its own: it reads that file.
urunit_pin=3333333333333333333333333333333333333333

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/stub"

# git: log every call. fetch remembers what it was asked for, and rev-parse
# HEAD answers with it, or with $STUB_HEAD, or with $tip for a branch. A
# checkout of the urunc source plants urunit.pin, as the real commit carries
# one; STUB_NO_PIN=1 leaves it out.
cat > "$T/stub/git" <<STUB
#!/bin/sh
echo "git \$*" >> "$T/git.log"
dir=.
while [ \$# -gt 0 ]; do
    case "\$1" in
        -C) dir="\$2"; shift 2 ;;
        -c) shift 2 ;;
        *) break ;;
    esac
done
case "\$1" in
    fetch) for a in "\$@"; do last="\$a"; done; echo "\$last" > "$T/fetched" ;;
    rev-parse)
        f="\$(cat "$T/fetched")"
        if [ -n "\${STUB_HEAD:-}" ]; then echo "\$STUB_HEAD"
        elif [ "\${#f}" -eq 40 ]; then echo "\$f"
        else echo $tip; fi ;;
    checkout)
        case "\$dir" in
            */urunc-src)
                if [ -z "\${STUB_NO_PIN:-}" ]; then
                    mkdir -p "\$dir/packaging/container-initrd"
                    printf 'URUNIT_REPO=%s\nURUNIT_REF=%s\n' \
                        "\${STUB_PIN_REPO:-https://github.com/NOFireAI/urunit.git}" $urunit_pin \\
                        > "\$dir/packaging/container-initrd/urunit.pin"
                fi ;;
        esac ;;
esac
exit 0
STUB

# docker: the urunc build writes the binaries the script copies out. Anything
# else is logged and fails: urunit and the initrd are no longer built.
cat > "$T/stub/docker" <<STUB
#!/bin/sh
echo "docker \$*" >> "$T/docker.log"
STUB
cat >> "$T/stub/docker" <<'STUB'
case "$*" in
    *"make static"*)
        prev=""
        for a in "$@"; do
            case "$prev" in -v) case "$a" in *:/app) src="${a%:/app}" ;; esac ;; esac
            prev="$a"
        done
        mkdir -p "$src/dist"
        : > "$src/dist/urunc_static_amd64"
        : > "$src/dist/containerd-shim-urunc-v2_static_amd64"
        exit 0 ;;
esac
exit 1
STUB
# curl: every download fails, so the run ends at the first one after urunc.
printf '#!/bin/sh\nexit 22\n' > "$T/stub/curl"
chmod 0755 "$T/stub"/*

# build [VAR=value...]: run build-bundle.sh with those variables, output in
# $T/out.log. URUNC_* and URUNIT_* start unset.
build() {
    : > "$T/git.log"
    : > "$T/docker.log"
    : > "$T/fetched"
    # Every run ends in a failure, by design: at the first download or at the
    # check under test.
    env -u URUNC_REF -u URUNC_BRANCH -u URUNIT_REF -u URUNIT_BRANCH -u URUNIT_REPO -u HVI_REF -u HVI_BRANCH \
        PATH="$T/stub:$PATH" "$@" \
        sh "$here/scripts/build-bundle.sh" --arch amd64 --version test --out "$T/dist" \
        > "$T/out.log" 2>&1 || true
}

# 1. Defaults: urunc is fetched at its pinned commit, by SHA. urunit is not
# fetched or built; the build reads the commit urunc's urunit.pin names.
build
grep -qx "git -C .*/urunc-src fetch -q --depth 1 origin $urunc_pin" "$T/git.log" \
    || { cat "$T/git.log" "$T/out.log" >&2; fail "urunc was not fetched at its pin"; }
grep -q "urunc: checked out urunc-dev/urunc@$urunc_pin (pinned" "$T/out.log" \
    || { cat "$T/out.log" >&2; fail "the build log does not name the pinned urunc"; }
grep -q "urunit: urunc $urunc_pin pins NOFireAI/urunit@$urunit_pin" "$T/out.log" \
    || { cat "$T/out.log" >&2; fail "the build log does not name urunc's urunit pin"; }
grep -q "failed to download" "$T/out.log" \
    || { cat "$T/out.log" >&2; fail "the build did not get past the urunc build"; }
if grep -q "urunit-src" "$T/git.log"; then fail "urunit was fetched"; fi
grep -q "make static" "$T/docker.log" || fail "the urunc build did not run"
if grep -qv "make static" "$T/docker.log"; then
    cat "$T/docker.log" >&2; fail "docker ran for something other than the urunc build"
fi
if grep -q -e "git clone" -e "WARNING" "$T/git.log" "$T/out.log"; then
    fail "a pinned build cloned a branch or warned"
fi
ok "a default build fetches urunc at its pin and builds no urunit or initrd"

# 1b. A urunc commit with no urunit.pin is refused, and so is a pin that names
# no full commit.
build STUB_NO_PIN=1
grep -q "has no packaging/container-initrd/urunit.pin" "$T/out.log" \
    || { cat "$T/out.log" >&2; fail "a urunc commit without urunit.pin was not refused"; }
ok "a urunc without a urunit pin is refused"

# 1c. A urunit.pin whose repo is not <owner>/<repo> on GitHub is refused: the
# repo goes into pins.env.
build STUB_PIN_REPO=git@github.com:NOFireAI/urunit.git
grep -q "URUNIT_REPO='git@github.com:NOFireAI/urunit' is not <owner>/<repo> on GitHub" "$T/out.log" \
    || { cat "$T/out.log" >&2; fail "a urunit.pin with an ssh URL was not refused"; }
ok "a urunit.pin repo that is not <owner>/<repo> is refused"

# 2. A checkout that is not the pinned commit fails the build.
build STUB_HEAD=2222222222222222222222222222222222222222
grep -q "checked out 2222222222222222222222222222222222222222, not the pinned $urunc_pin" "$T/out.log" \
    || { cat "$T/out.log" >&2; fail "a wrong checkout was not refused"; }
ok "a checkout other than the pin fails the build"

# 3. An empty ref builds the branch tip, and says so.
build URUNC_REF=
grep -qx "git -C .*/urunc-src fetch -q --depth 1 origin refs/heads/$urunc_branch" "$T/git.log" \
    || { cat "$T/git.log" >&2; fail "URUNC_REF= did not fetch the branch"; }
grep -q "WARNING: urunc: built urunc-dev/urunc@$tip, the tip of $urunc_branch" "$T/out.log" \
    || { cat "$T/out.log" >&2; fail "a tip build did not warn"; }
ok "URUNC_REF= builds the tip of the branch, with a warning"

# 4. A branch without a ref is refused before anything is fetched.
build URUNC_BRANCH=feat/something-else
grep -q "URUNC_BRANCH=feat/something-else is set but URUNC_REF is not" "$T/out.log" \
    || { cat "$T/out.log" >&2; fail "a branch without a ref was not refused"; }
[ ! -s "$T/git.log" ] || fail "git ran for a refused build"
ok "a branch without a ref is refused"

# 4b. The urunit build knobs are gone, so setting one is refused, and so is
# the hvi source build that no longer exists.
for v in URUNIT_REF=4444444444444444444444444444444444444444 URUNIT_REF= \
    URUNIT_BRANCH=main URUNIT_REPO=NOFireAI/urunit; do
    build "$v"
    grep -q "urunit is no longer built here" "$T/out.log" \
        || { cat "$T/out.log" >&2; fail "$v was not refused"; }
    [ ! -s "$T/git.log" ] || fail "git ran for a refused build ($v)"
done
build HVI_REF=24dc2c5f643ae23551ceb158600676c33636a21f
grep -q "hvi is no longer built from source" "$T/out.log" \
    || { cat "$T/out.log" >&2; fail "HVI_REF was not refused"; }
[ ! -s "$T/git.log" ] || fail "git ran for a refused build"
ok "URUNIT_REF, URUNIT_BRANCH, URUNIT_REPO and HVI_REF are refused"

# 5. A ref that is not a full SHA is refused before anything is fetched.
build URUNC_REF=urunc_agent
grep -q "URUNC_REF='urunc_agent' is not a commit" "$T/out.log" \
    || { cat "$T/out.log" >&2; fail "a branch name as a ref was not refused"; }
build URUNC_REF=0818ff1
grep -q "URUNC_REF='0818ff1' is not a commit" "$T/out.log" \
    || { cat "$T/out.log" >&2; fail "a short SHA was not refused"; }
[ ! -s "$T/git.log" ] || fail "git ran for a refused build"
ok "a ref that is not a full SHA is refused"
