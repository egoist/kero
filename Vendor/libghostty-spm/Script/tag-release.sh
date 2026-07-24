#!/bin/zsh

set -euo pipefail

cd "$(dirname "$0")/.."

if [ ! -f .root ]; then
    echo "[-] malformed project structure"
    exit 1
fi

usage() {
    cat <<'EOF'
Usage: ./Script/tag-release.sh [options]

Options:
  --push                push the new tag to origin after creating it
  --suffix <value>      override the ci-style release suffix
  -h, --help            show this help

Notes:
  - release tags follow the ci pattern: 1.0.<suffix>
  - this script tags swift source releases only
  - this script does not create storage.* tags or update binaries
EOF
}

PUSH_TAG=0
RELEASE_SUFFIX=

while [ $# -gt 0 ]; do
    case "$1" in
        --push)
            PUSH_TAG=1
            shift
            ;;
        --suffix)
            RELEASE_SUFFIX="$2"
            shift 2
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            echo "[-] unknown argument: $1"
            usage
            exit 1
            ;;
    esac
done

if [ -z "$RELEASE_SUFFIX" ]; then
    RELEASE_SUFFIX=$(date -u +%s)
fi

RELEASE_TAG="1.0.$RELEASE_SUFFIX"
RELEASE_DATE=$(date -u +%Y-%m-%d)
HEAD_SHA=$(git rev-parse --short=12 HEAD)

if git rev-parse "$RELEASE_TAG" >/dev/null 2>&1; then
    echo "[-] tag already exists: $RELEASE_TAG"
    exit 1
fi

TAG_MESSAGE=$(cat <<EOF
Swift source release $RELEASE_DATE

Tag: $RELEASE_TAG
Commit: $HEAD_SHA
EOF
)

git tag -a "$RELEASE_TAG" -m "$TAG_MESSAGE"
echo "[+] created tag $RELEASE_TAG for $HEAD_SHA on $RELEASE_DATE"

if [ "$PUSH_TAG" -eq 1 ]; then
    git push origin "$RELEASE_TAG"
    echo "[+] pushed tag $RELEASE_TAG"
fi
