#!/bin/sh
# Prepare a fresh local checkout. Never sources shell code from .env.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
umask 077
if [ ! -f .env ]; then
  CONFIG=$(mktemp "$ROOT/.env.setup.XXXXXX")
  trap 'rm -f "$CONFIG"' EXIT HUP INT TERM
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      VOICEPAD_UID=*) printf 'VOICEPAD_UID=%s\n' "$(id -u)" ;;
      VOICEPAD_GID=*) printf 'VOICEPAD_GID=%s\n' "$(id -g)" ;;
      *) printf '%s\n' "$line" ;;
    esac
  done < .env.example > "$CONFIG"
  mv "$CONFIG" .env
  trap - EXIT HUP INT TERM
  printf 'Created private .env with your current UID/GID.\n'
else
  printf 'Keeping existing .env unchanged.\n'
fi
mkdir -p data
chmod 700 data
printf 'Prepared ./data. If VOICEPAD_DATA_DIR is customized, create that directory separately with the configured UID/GID.\n'
printf 'Start: docker compose up --build -d\nOpen: http://localhost:8791/admin (unless you changed the origin/port).\n'
