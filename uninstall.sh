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
DIR=$(cd "$(dirname "$0")" && pwd)
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

[ -f "$DIR/compose.yml" ] || {
    echo "no compose.yml in $DIR — pass --dir" >&2
    exit 1
}
cd "$DIR"

if [ "$PURGE" = 0 ]; then
    docker compose down
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

docker compose down -v
rm -f "$DIR/.env" "$DIR/compose.yml" "$DIR/compose.metadata.yml" \
    "$DIR/.env.example" "$DIR/SHA256SUMS" "$DIR/install.log"
printf '\n  Removed. %s may still hold this script and a backups/ directory.\n\n' "$DIR"
