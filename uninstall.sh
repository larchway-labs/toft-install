#!/bin/sh
# Launchpad — remove this install.
#
#   ./uninstall.sh            stop everything, keep the database and the releases
#   ./uninstall.sh --purge    ...and destroy them, the image, and this directory
#
# The default is reversible: `docker compose up -d` brings the same install back
# with every app, secret and audit row intact. --purge is not reversible by
# anything, which is why it asks you to type the word. It takes the whole
# install directory, dumps and backups in it included — they decrypt with the
# ENCRYPTION_KEY that goes in the same breath. Move anything you want to keep
# out of there first. What survives is what was never this install's: Docker,
# and the postgres image.

set -eu

PURGE=0
DIR=
YES=0

while [ $# -gt 0 ]; do
    case $1 in
    --purge) PURGE=1 ;;
    --yes | -y) YES=1 ;;
    --dir)
        shift
        DIR=$1
        ;;
    --help | -h)
        sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
    *)
        echo "unknown option $1" >&2
        exit 1
        ;;
    esac
    shift
done

# Which directory *is* the install. install.sh copies this script beside the
# .env it writes, so the usual answer is "the one this script is in" — but the
# copy people have to hand is as often the unpacked bundle or a checkout, whose
# compose.yml is identical and whose .env is somewhere else entirely. Anchoring
# on compose.yml alone finds that one and then removes nothing, so .env is what
# marks an install, and there is exactly one other place it can be: install.sh
# writes to ~/.launchpad and nowhere else unless it was told to.
HERE=$(cd "$(dirname "$0")" && pwd)
if [ -z "$DIR" ]; then
    for d in "$HERE" "${HOME:-.}/.launchpad"; do
        if [ -f "$d/.env" ] && [ -f "$d/compose.yml" ]; then
            DIR=$d
            break
        fi
    done
    # No .env anywhere: an install that failed before it was configured, or one
    # already purged. There may still be containers to stop, and a compose.yml
    # beside this script is enough to do that.
    [ -n "$DIR" ] || DIR=$HERE
    [ "$DIR" = "$HERE" ] || printf '\nUsing the install in %s\n' "$DIR"
fi

[ -f "$DIR/compose.yml" ] || {
    echo "no compose.yml in $DIR — pass --dir (an install lives in ~/.launchpad unless install.sh was given one)" >&2
    exit 1
}
cd "$DIR"

# `docker compose down` finds containers, networks and volumes by the project
# label, so nothing it removes depends on a value in .env — but compose
# interpolates the whole file before it runs anything, and compose.yml marks
# four variables required precisely so an incomplete .env fails at `up` instead
# of starting a broken container. That refusal is right there and wrong here: a
# missing or half-written .env is exactly the state someone needs this script
# for. These placeholders only satisfy the interpolation; `down` creates no
# container, so no service ever sees them.
compose() {
    POSTGRES_PASSWORD=${POSTGRES_PASSWORD:-unused} \
        LAUNCHPAD_VERSION=${LAUNCHPAD_VERSION:-unused} \
        JWT_SECRET=${JWT_SECRET:-unused} \
        ENCRYPTION_KEY=${ENCRYPTION_KEY:-unused} \
        docker compose "$@"
}

if [ "$PURGE" = 0 ]; then
    compose down
    printf '\nStopped. The database and every built release are still here.\n'
    printf 'Start it again with:  cd %s && docker compose up -d\n\n' "$DIR"
    exit 0
fi

printf '\n  This destroys, permanently and with no backup:\n\n'
printf '    - the database: every app, user, secret, API key and audit row\n'
printf '    - every built release on the data volume\n'
printf '    - the Launchpad image\n'
printf '    - %s and everything in it: .env and the only copy of\n' "$DIR"
printf '      ENCRYPTION_KEY, and any dumps or backups you put there\n\n'

if [ "$YES" != 1 ]; then
    # Openable, not merely present: /dev/tty exists in contexts where opening it
    # fails, and testing with -e turns this refusal into a raw shell error.
    { : </dev/tty; } 2>/dev/null || {
        echo "no terminal to confirm on; pass --yes if you are certain" >&2
        exit 1
    }
    printf '  Type DELETE to confirm: ' >/dev/tty
    read -r reply </dev/tty || reply=
    [ "$reply" = DELETE ] || {
        printf '\n  Not confirmed. Nothing was removed.\n\n'
        exit 1
    }
fi

compose down -v

# The image is this product's, and the project name is fixed, so there is no
# second install on this machine still using it. A purge that leaves most of a
# gigabyte behind has not done the thing the word means. Read the name out of
# .env before removing it, and take every tag of that repository: an install
# that was upgraded has the old ones too. postgres:17-alpine is deliberately not
# touched — it is a public base image this box may well be using elsewhere, and
# it is not ours to delete.
IMAGE=$(sed -n 's/^LAUNCHPAD_IMAGE=//p' "$DIR/.env" 2>/dev/null | tail -1)

IMAGE_GONE=0
if [ -n "$IMAGE" ] && docker images -q "$IMAGE" 2>/dev/null | grep -q .; then
    # By reference and one at a time, never by image ID: an ID can carry tags
    # this install did not put there, and removing it would take them with it —
    # or refuse, which on a list passed in one call takes the rest down with it.
    # An untagged leftover has no reference to name, so that one goes by ID.
    docker images --format '{{.Repository}}:{{.Tag}}|{{.ID}}' "$IMAGE" 2>/dev/null |
        while IFS='|' read -r ref id; do
            case $ref in *':<none>') ref=$id ;; esac
            docker image rm "$ref" >/dev/null 2>&1 || true
        done
    docker images -q "$IMAGE" 2>/dev/null | grep -q . || IMAGE_GONE=1
fi

# The directory and everything in it, this script included. Not file by file
# with an rmdir at the end that declines on whatever is left: the operator asked
# for the install to be gone, and a dump of the database they are about to
# destroy is not a thing to preserve half of — it decrypts with an
# ENCRYPTION_KEY that is going in the same breath. The confirmation above says
# so in as many words, which is what earns this line.
#
# Deleting the running script is safe: the shell holds an open descriptor and
# the inode outlives the name. Removing $DIR rather than $0 is deliberate — when
# this was run from an unpacked bundle instead of from the install, $0 is the
# wrong file and the install's own copy is the right one.
case $DIR in
/ | /usr | /etc | /home | /var | /opt)
    echo "refusing to remove $DIR" >&2
    exit 1
    ;;
esac
cd /
rm -rf "$DIR" "${TMPDIR:-/tmp}/launchpad-install.log"

printf '\n  Removed: both containers, both volumes'
[ "$IMAGE_GONE" = 1 ] && printf ', the %s image' "$IMAGE"
printf ' and %s.\n' "$DIR"
printf '  Left alone: postgres:17-alpine, a public image this machine may use elsewhere.\n\n'
