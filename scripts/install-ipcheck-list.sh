#!/usr/bin/env bash
set -euo pipefail

DAT_URL="${DAT_URL:-https://raw.githubusercontent.com/roxelAlex/ip-checker-lists/main/ipcheck-list.dat}"
SERVICE_NAME="${SERVICE_NAME:-remnanode}"
SCRIPT_NAME="update-ipcheck-list.sh"

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "Run as root."
    exit 1
  fi
}

find_base_dir() {
  if [ -n "${BASE_DIR:-}" ] && { [ -f "${BASE_DIR}/docker-compose.yml" ] || [ -f "${BASE_DIR}/compose.yml" ]; }; then
    echo "$BASE_DIR"
    return 0
  fi

  for d in \
    /opt/remnanode \
    /opt/remnawave \
    "$PWD" \
    /srv/remnanode \
    /srv/remnawave
  do
    [ -f "$d/docker-compose.yml" ] || [ -f "$d/compose.yml" ] || continue
    if grep -qE '^[[:space:]]*remnanode:' "$d"/docker-compose.yml 2>/dev/null || \
       grep -qE '^[[:space:]]*remnanode:' "$d"/compose.yml 2>/dev/null; then
      echo "$d"
      return 0
    fi
  done

  while IFS= read -r f; do
    d="$(dirname "$f")"
    if grep -qE '^[[:space:]]*remnanode:' "$f" 2>/dev/null; then
      echo "$d"
      return 0
    fi
  done < <(find /opt /srv /root /home -maxdepth 3 \( -name docker-compose.yml -o -name compose.yml \) 2>/dev/null)

  return 1
}

compose_file_in_dir() {
  local dir="$1"
  if [ -f "$dir/docker-compose.yml" ]; then
    echo "$dir/docker-compose.yml"
  elif [ -f "$dir/compose.yml" ]; then
    echo "$dir/compose.yml"
  else
    return 1
  fi
}

main() {
  need_root

  if ! command -v docker >/dev/null 2>&1; then
    echo "docker not found"
    exit 1
  fi

  BASE_DIR="$(find_base_dir || true)"
  if [ -z "${BASE_DIR}" ]; then
    echo "Could not auto-detect RemnaNode directory."
    echo "Retry like this:"
    echo "  BASE_DIR=/opt/remnawave bash <(curl -fsSL URL)"
    exit 1
  fi

  COMPOSE_FILE="$(compose_file_in_dir "$BASE_DIR")"

  DAT_DST="${BASE_DIR}/ipcheck-list.dat"
  UPDATE_SCRIPT="${BASE_DIR}/${SCRIPT_NAME}"
  OVERRIDE_FILE="${BASE_DIR}/docker-compose.override.yml"
  CRON_FILE="/etc/cron.d/remnanode-ipcheck-list"

  echo "Using BASE_DIR=${BASE_DIR}"
  echo "Using COMPOSE_FILE=${COMPOSE_FILE}"

  mkdir -p "${BASE_DIR}"

  echo "Downloading ipcheck-list.dat..."
  curl -fsSL "${DAT_URL}" -o "${DAT_DST}"
  chmod 0644 "${DAT_DST}"

  echo "Writing docker-compose.override.yml..."
  cat > "${OVERRIDE_FILE}" <<OVERRIDE
services:
  ${SERVICE_NAME}:
    volumes:
      - ${DAT_DST}:/usr/local/share/xray/ipcheck-list.dat:ro
OVERRIDE

  echo "Writing update script..."
  cat > "${UPDATE_SCRIPT}" <<UPD
#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="${BASE_DIR}"
DAT_URL="${DAT_URL}"
DAT_DST="${DAT_DST}"
TMP="\$(mktemp)"

cleanup() {
  rm -f "\${TMP}"
}
trap cleanup EXIT

curl -fsSL "\${DAT_URL}" -o "\${TMP}"

if [ ! -f "\${DAT_DST}" ] || ! cmp -s "\${TMP}" "\${DAT_DST}"; then
  install -m 0644 "\${TMP}" "\${DAT_DST}"
  cd "${BASE_DIR}"
  docker compose up -d
fi
UPD

  chmod +x "${UPDATE_SCRIPT}"

  echo "Writing cron..."
  cat > "${CRON_FILE}" <<CRON
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
0 * * * * root ${UPDATE_SCRIPT} >/var/log/remnanode-ipcheck-list.log 2>&1
CRON
  chmod 0644 "${CRON_FILE}"

  echo "Applying compose..."
  cd "${BASE_DIR}"
  docker compose up -d

  echo
  echo "Done."
  echo "Check inside container:"
  echo "  docker exec remnanode ls -l /usr/local/share/xray/ipcheck-list.dat"
  echo
  echo 'Use this in Xray routing:'
  echo '  "ext:ipcheck-list.dat:ipcheck-list"'
}

main "$@"
