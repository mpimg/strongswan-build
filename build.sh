#!/bin/bash
#
# Build strongSwan with bee into the new deployment directory
# PROJECT_DIR/NAME, and link the configuration repository and the log
# directory, shared by all deployments, into it.

set -euo pipefail

usage() {
    cat <<EOF
Usage: $0 [-n NAME] [-c CONF_DIR] [-l LOG_DIR] PROJECT_DIR

Build strongSwan into PROJECT_DIR/NAME.

  -n NAME      name of the deployment directory (default: $(date +%F))
  -c CONF_DIR  configuration repository (default: PROJECT_DIR/conf)
  -l LOG_DIR   log directory (default: PROJECT_DIR/logs)

Every file in CONF_DIR, except for top-level dot files and README*, is
linked to the same relative path in PROJECT_DIR/NAME, for example
CONF_DIR/etc/swanctl/swanctl.conf to PROJECT_DIR/NAME/etc/swanctl/swanctl.conf.
EOF
}

die() {
    echo "$0: $*" >&2
    exit 1
}

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
PACKAGES=(strongswan)

NAME=$(date +%F)
CONF_DIR=
LOG_DIR=

while getopts n:c:l:h opt; do
    case $opt in
        n) NAME=$OPTARG ;;
        c) CONF_DIR=$OPTARG ;;
        l) LOG_DIR=$OPTARG ;;
        h) usage; exit 0 ;;
        *) usage >&2; exit 1 ;;
    esac
done
shift $((OPTIND - 1))

[ $# -eq 1 ] || { usage >&2; exit 1; }

[ -d "$1" ] || die "$1: project directory does not exist"
PROJECT_DIR=$(readlink -f "$1")
CONF_DIR=$(readlink -f "${CONF_DIR:-$PROJECT_DIR/conf}")
LOG_DIR=$(readlink -f "${LOG_DIR:-$PROJECT_DIR/logs}")
PREFIX=$PROJECT_DIR/$NAME

[ ! -e "$PREFIX" ] || die "$PREFIX: deployment already exists"

git -C "$CONF_DIR" rev-parse --git-dir >/dev/null 2>&1 \
    || die "$CONF_DIR: configuration directory is not a git repository"
if [ -n "$(git -C "$CONF_DIR" status --porcelain)" ]; then
    echo "$0: warning: $CONF_DIR has uncommitted changes" >&2
fi

declare -A BEEFILES
for pkg in "${PACKAGES[@]}"; do
    beefiles=("$SCRIPT_DIR/$pkg"-[0-9]*.bee)
    [ ${#beefiles[@]} -eq 1 ] && [ -f "${beefiles[0]}" ] \
        || die "expected exactly one bee file for $pkg, found: ${beefiles[*]}"
    BEEFILES[$pkg]=${beefiles[0]}
done

# A bee repository per deployment, so the same package revision can be built
# again for another PREFIX, and the deployment records what is installed.
export PREFIX
export BEE_REPOSITORY_PREFIX=$PREFIX/bee
export BEE_METADIR=$BEE_REPOSITORY_PREFIX/installed
export BEE_CACHEDIR=$BEE_REPOSITORY_PREFIX/cache
export BEE_TMP_BUILDROOT=${BEE_TMP_BUILDROOT:-${TMPDIR:-/tmp}/bee-$(id -un)/$NAME}
export BEE_MAKEFLAGS=${BEE_MAKEFLAGS:--j$(nproc)}

mkdir -p "$BEE_REPOSITORY_PREFIX"/logs

for pkg in "${PACKAGES[@]}"; do
    beesh --cleanup --install "${BEEFILES[$pkg]}" </dev/null 2>&1 \
        | tee "$BEE_REPOSITORY_PREFIX/logs/$pkg.log"
done

install -m 755 "$SCRIPT_DIR"/startstop.sh "$PREFIX"/startstop.sh
cat >"$PREFIX"/profile <<EOF
PATH=$PREFIX/sbin:$PREFIX/bin:\$PATH
export PATH
EOF

mkdir -p "$LOG_DIR"
ln -s "$LOG_DIR" "$PREFIX"/logs

(cd "$CONF_DIR" && find . \( -path './.*' -o -path './README*' \) -prune \
                       -o \( -type f -o -type l \) -print) \
    | sed 's,^\./,,' | sort \
    | while read -r file; do
        target=$PREFIX/$file
        mkdir -p "$(dirname "$target")"
        if [ -e "$target" ] || [ -L "$target" ]; then
            echo "$0: moving packaged $target to $target.dist" >&2
            mv "$target" "$target".dist
        fi
        ln -sv "$CONF_DIR/$file" "$target"
    done

cat <<EOF

Deployment $PREFIX is ready. To switch to it, as root:

    $SCRIPT_DIR/activate.sh $PROJECT_DIR $NAME
EOF
