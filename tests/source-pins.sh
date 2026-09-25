#!/bin/sh
#
# Run build-bundle.sh against a stub git and docker, and check which urunc and
# urunit commits it asks for. Nothing is fetched: the stub git records the ref
# it was asked to fetch and answers rev-parse with it, the stub docker fakes the
# urunc build and fails the urunit build, which ends the run.
#
# Needs the tools build-bundle.sh checks for (curl, tar, sha256sum, awk, sed).

set -eu

here="$(cd "$(dirname "$0")/.." && pwd)"

skip() { echo "SKIP: $*"; exit 0; }
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok - $*"; }

command -v sha256sum >/dev/null 2>&1 || skip "build-bundle.sh needs sha256sum"

urunc_pin="$(sed -n 's/^URUNC_REF_DEFAULT=\([0-9a-f]*\)$/\1/p' "$here/scripts/build-bundle.sh")"
urunit_pin="$(sed -n 's/^URUNIT_REF_DEFAULT=\([0-9a-f]*\)$/\1/p' "$here/scripts/build-bundle.sh")"
urunc_branch="$(sed -n 's/^URUNC_BRANCH_DEFAULT=\(.*\)$/\1/p' "$here/scripts/build-bundle.sh")"
[ "${#urunc_pin}" -eq 40 ] || fail "no URUNC_REF_DEFAULT in build-bundle.sh"
[ "${#urunit_pin}" -eq 40 ] || fail "no URUNIT_REF_DEFAULT in build-bundle.sh"
tip=1111111111111111111111111111111111111111

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/stub"

# git: log every call. fetch remembers what it was asked for, and rev-parse
# HEAD answers with it, or with $STUB_HEAD, or with $tip for a branch.
cat > "$T/stub/git" <<STUB
#!/bin/sh
echo "git \$*" >> "$T/git.log"
while [ \$# -gt 0 ]; do
    case "\$1" in
        -C|-c) shift 2 ;;
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
esac
exit 0
STUB

# docker: the urunc build writes the two binaries the script copies out; the
# urunit build fails.
cat > "$T/stub/docker" <<'STUB'
#!/bin/sh
case "$*" in
    *"apk add"*) exit 1 ;;
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
chmod 0755 "$T/stub"/*

# build [VAR=value...]: run build-bundle.sh with those variables, output in
# $T/out.log. URUNC_* and URUNIT_* start unset.
build() {
    : > "$T/git.log"
    : > "$T/fetched"
    # Every run ends in a failure, by design: at the stub urunit build or at
    # the check under test.
    env -u URUNC_REF -u URUNC_BRANCH -u URUNIT_REF -u URUNIT_BRANCH \
        PATH="$T/stub:$PATH" "$@" \
        sh "$here/scripts/build-bundle.sh" --arch amd64 --version test --out "$T/dist" \
        > "$T/out.log" 2>&1 || true
}

# 1. Defaults: both repos are fetched at their pinned commit, by SHA.
build
grep -qx "git -C .*/urunc-src fetch -q --depth 1 origin $urunc_pin" "$T/git.log" \
    || { cat "$T/git.log" "$T/out.log" >&2; fail "urunc was not fetched at its pin"; }
grep -qx "git -C .*/urunit-src fetch -q --depth 1 origin $urunit_pin" "$T/git.log" \
    || { cat "$T/git.log" "$T/out.log" >&2; fail "urunit was not fetched at its pin"; }
grep -q "urunc: checked out urunc-dev/urunc@$urunc_pin (pinned" "$T/out.log" \
    || { cat "$T/out.log" >&2; fail "the build log does not name the pinned urunc"; }
if grep -q -e "git clone" -e "WARNING" "$T/git.log" "$T/out.log"; then
    fail "a pinned build cloned a branch or warned"
fi
ok "a default build fetches urunc and urunit at their pinned commits"

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

# 5. A ref that is not a full SHA is refused before anything is fetched.
build URUNIT_REF=urunit_agent
grep -q "URUNIT_REF='urunit_agent' is not a commit" "$T/out.log" \
    || { cat "$T/out.log" >&2; fail "a branch name as a ref was not refused"; }
build URUNC_REF=0818ff1
grep -q "URUNC_REF='0818ff1' is not a commit" "$T/out.log" \
    || { cat "$T/out.log" >&2; fail "a short SHA was not refused"; }
[ ! -s "$T/git.log" ] || fail "git ran for a refused build"
ok "a ref that is not a full SHA is refused"
