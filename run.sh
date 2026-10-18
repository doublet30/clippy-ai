#!/usr/bin/env bash
ROOT=$(dirname "$(readlink -f "$0")")
REVVY_AI_ROOT="$ROOT" exec "$ROOT/scripts/revvy-ai" "$@"
