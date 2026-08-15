#!/bin/sh
# Launchpad — remove this install.
#
#   ./uninstall.sh            stop everything, keep the database and the releases
#   ./uninstall.sh --purge    ...and destroy them, and this directory
#
# The default is reversible: `docker compose up -d` brings the same install back
# with every app, secret and audit row intact. --purge is not reversible by
# anything, which is why it asks you to type the word.

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
        sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
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
# marks an install, and the two directories install.sh chooses between are
# searched before this gives up.
HERE=$(cd "$(dirname "$0")" && pwd)
if [ -z "$DIR" ]; then
    for d in "$HERE" /opt/launchpad "${HOME:-.}/.launchpad"; do
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
    echo "no compose.yml in $DIR — pass --dir (installs live in /opt/launchpad or ~/.launchpad)" >&2
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
printf '    - %s/.env, including the only copy of ENCRYPTION_KEY\n\n' "$DIR"

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
rm -f "$DIR/.env" "$DIR/compose.yml" "$DIR/compose.metadata.yml" \
    "$DIR/.env.example" "$DIR/SHA256SUMS" "$DIR/install.log"
printf '\n  Removed. %s may still hold this script and a backups/ directory.\n\n' "$DIR"
