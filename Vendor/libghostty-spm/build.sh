#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"

exec "$ROOT_DIR/Script/build.sh" "$@"
