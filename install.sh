#!/usr/bin/env bash
# Remote one-line installer. Intended to be run as the target Unix user, no sudo.
set -euo pipefail
REPO='EugeneSlusar/orgBox_Server_Manager'
REF="${ORGBOX_VERSION:-main}"
BASE="https://raw.githubusercontent.com/${REPO}/${REF}"
DEST="$HOME/orgbox_server_manager"

if [[ "$EUID" -eq 0 ]]; then
  printf '%s\n' 'ВНИМАНИЕ: установка выполняется для root. Для пользователя dev войди под dev и запусти команду снова.' >&2
fi
if ! command -v curl >/dev/null 2>&1; then
  echo 'ERROR: curl необходим для загрузки файлов из GitHub.' >&2; exit 1
fi
mkdir -p -- "$DEST"
umask 077
# Download to temporary files before replacing executable. Avoid partially written scripts.
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
curl -fL --retry 2 --connect-timeout 10 --max-time 90 --silent --show-error "$BASE/manager.sh" -o "$tmp/manager.sh"
bash -n "$tmp/manager.sh"
if [[ -e "$DEST/manager.conf" ]]; then
  printf 'Настройки сохранены: %s/manager.conf\n' "$DEST"
else
  curl -fL --retry 2 --connect-timeout 10 --max-time 90 --silent --show-error "$BASE/manager.conf" -o "$tmp/manager.conf"
  cp -- "$tmp/manager.conf" "$DEST/manager.conf"
  chmod 600 "$DEST/manager.conf"
fi
cp -- "$tmp/manager.sh" "$DEST/.manager.sh.new"
chmod 700 "$DEST/.manager.sh.new"
mv -f -- "$DEST/.manager.sh.new" "$DEST/manager.sh"
# Record the installed release; main is a development channel.
if [[ "$REF" =~ ^v([0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
  printf '%s\n' "${BASH_REMATCH[1]}" > "$DEST/VERSION"
fi
exec bash "$DEST/manager.sh" install
