#!/usr/bin/env bash
exec quickshell -p "$(dirname "$(readlink -f "$0")")" "$@"
