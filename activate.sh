#!/bin/bash
#
# Switch PROJECT_DIR to the deployment NAME: stop the running gateway, point
# PROJECT_DIR/current to NAME, and start the gateway of NAME. Activating the
# previous deployment again rolls back. Run as root, like startstop.sh.
#
# Stopping charon ends all IKE and IPsec SAs, so clients reconnect.

set -euo pipefail

die() {
    echo "$0: $*" >&2
    exit 1
}

[ $# -eq 2 ] || { echo "Usage: $0 PROJECT_DIR NAME" >&2; exit 1; }

PROJECT_DIR=$(readlink -f "$1")
NAME=$2

[ -x "$PROJECT_DIR/$NAME"/startstop.sh ] \
    || die "$PROJECT_DIR/$NAME: not a deployment built by build.sh"

cd "$PROJECT_DIR"

if [ -e startstop.sh ]; then
    ./startstop.sh stop || echo "$0: warning: stopping the running gateway failed" >&2
fi

ln -sfn "$NAME" current.new
mv -T current.new current

for file in startstop.sh profile; do
    if [ "$(readlink "$file" || true)" != current/"$file" ]; then
        if [ -e "$file" ] || [ -L "$file" ]; then
            echo "$0: replacing $file -> $(readlink "$file" || echo '(no link)')" >&2
        fi
        ln -sfn current/"$file" "$file"
    fi
done

./startstop.sh start
