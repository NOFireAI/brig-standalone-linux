#!/bin/sh
#
# Check that a hull-assets bundle was built from the urunc this bundle carries.
#
#   scripts/check-assets.sh <bundle.json> <urunc-ref> <urunit-ref>
#
# The initrd in a hull-assets bundle is urunit, and urunit's exec agent has to
# speak the protocol of the urunc shim. hull-assets records the urunc it was
# built from as sources.urunc.ref in its bundle.json. That ref must be
# <urunc-ref>. When bundle.json also records sources.urunit.ref, it must be
# <urunit-ref>, the commit urunc pins in packaging/container-initrd/urunit.pin.
#
# On success it prints the recorded urunc ref and the recorded urunit ref, or
# "-" for no urunit record. The bundle.json read here is the one in the signed
# artifact, so build-bundle.sh calls this after cosign checked
# the digest it pulled.

set -eu

die() {
    echo "check-assets: $*" >&2
    exit 1
}

[ $# -eq 3 ] || die "usage: $0 <bundle.json> <urunc-ref> <urunit-ref>"
json="$1"
urunc_ref="$2"
urunit_ref="$3"

[ -s "$json" ] || die "$json is missing, so the initrd cannot be matched to urunc $urunc_ref"

# sources.<name>.ref, from the one-object-per-source layout hull-assets writes.
# jq is not a build requirement, so sed reads it.
source_ref() {
    tr -d '\n' < "$json" \
        | sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*{[^}]*"ref"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
}

got="$(source_ref urunc)"
[ -n "$got" ] || die "$json records no sources.urunc.ref, so the initrd cannot be matched to urunc $urunc_ref"
[ "$got" = "$urunc_ref" ] || die "the guest assets were built from urunc $got, but this bundle carries urunc $urunc_ref.
    The initrd's exec agent must match the urunc shim. Move ASSETS_VERSION to a hull-assets
    release built from urunc $urunc_ref, or move URUNC_REF_DEFAULT to $got."

# A urunit source whose ref the sed cannot read is refused. Treating it as
# absent would turn the urunit check off for any layout the sed does not model.
got_urunit="$(source_ref urunit)"
if [ -n "$got_urunit" ]; then
    [ "$got_urunit" = "$urunit_ref" ] \
        || die "the guest assets carry urunit $got_urunit, but urunc $urunc_ref pins urunit $urunit_ref"
elif tr -d '\n' < "$json" | grep -q '"urunit"[[:space:]]*:'; then
    die "$json records a urunit source whose ref could not be read, so the initrd cannot be matched to urunit $urunit_ref"
else
    echo "check-assets: $json records no urunit commit; matched on urunc $got alone" >&2
fi

echo "$got ${got_urunit:--}"
