#!/usr/bin/env bash
#
# domain-script.sh
#
# Creates an nginx reverse-proxy vhost for a Node/Phoenix/etc backend,
# enables it, and provisions a Let's Encrypt cert with certbot.
#
# Usage:
#   sudo ./domain-script.sh -u <upstream_name> -p <port> -d <domain> [-d <domain2> ...]
#
# Example:
#   sudo ./domain-script.sh -u nyumbani -p 2300 \
#        -d nyumbani.victormbashia.com \
#        -d www.nyumbani.victormbashia.com
#
# Notes:
#   - The FIRST -d domain is treated as the primary domain (used for the
#     config filename and as the certbot cert name).
#   - Requires root (writes to /etc/nginx and calls certbot).
#   - Requires certbot with the nginx plugin already installed.

set -euo pipefail

UPSTREAM=""
PORT=""
DOMAINS=()

usage() {
  echo "Usage: sudo $0 -u <upstream_name> -p <port> -d <domain> [-d <domain2> ...]"
  echo
  echo "  -u   Upstream name (used internally in nginx upstream block)"
  echo "  -p   Backend port the app listens on (e.g. 4000)"
  echo "  -d   Domain to serve (repeatable; first one is primary)"
  echo "  -h   Show this help"
  exit 1
}

while getopts ":u:p:d:h" opt; do
  case "$opt" in
    u) UPSTREAM="$OPTARG" ;;
    p) PORT="$OPTARG" ;;
    d) DOMAINS+=("$OPTARG") ;;
    h) usage ;;
    \?) echo "Unknown option: -$OPTARG" >&2; usage ;;
    :) echo "Option -$OPTARG requires an argument." >&2; usage ;;
  esac
done

# ---- Validation ----------------------------------------------------------

if [[ -z "$UPSTREAM" || -z "$PORT" || ${#DOMAINS[@]} -eq 0 ]]; then
  echo "Error: -u, -p, and at least one -d are required." >&2
  usage
fi

if [[ "$EUID" -ne 0 ]]; then
  echo "Error: this script must be run as root (try: sudo $0 ...)" >&2
  exit 1
fi

if ! [[ "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then
  echo "Error: port must be a number between 1 and 65535." >&2
  exit 1
fi

if ! command -v nginx >/dev/null 2>&1; then
  echo "Error: nginx is not installed or not on PATH." >&2
  exit 1
fi

if ! command -v certbot >/dev/null 2>&1; then
  echo "Error: certbot is not installed or not on PATH." >&2
  exit 1
fi

PRIMARY_DOMAIN="${DOMAINS[0]}"
CONFIG_PATH="/etc/nginx/sites-available/${PRIMARY_DOMAIN}"
ENABLED_PATH="/etc/nginx/sites-enabled/${PRIMARY_DOMAIN}"

if [[ -e "$CONFIG_PATH" ]]; then
  echo "Error: $CONFIG_PATH already exists. Refusing to overwrite." >&2
  echo "Remove it manually first if you want to regenerate it." >&2
  exit 1
fi

# Build the space-separated server_name list, e.g:
#   nyumbani.victormbashia.com www.nyumbani.victormbashia.com
SERVER_NAMES="${DOMAINS[*]}"

# Build the certbot -d flags, e.g:
#   -d nyumbani.victormbashia.com -d www.nyumbani.victormbashia.com
CERTBOT_DOMAIN_FLAGS=()
for d in "${DOMAINS[@]}"; do
  CERTBOT_DOMAIN_FLAGS+=("-d" "$d")
done

echo "== Domain setup =="
echo "Upstream name : $UPSTREAM"
echo "Backend port  : $PORT"
echo "Domains       : $SERVER_NAMES"
echo "Config file   : $CONFIG_PATH"
echo

# ---- DNS sanity check (warn, don't block) ---------------------------------

echo "Checking DNS resolution for each domain..."
DNS_WARN=0
for d in "${DOMAINS[@]}"; do
  if command -v dig >/dev/null 2>&1; then
    IP=$(dig +short "$d" | tail -n1)
  else
    IP=$(getent hosts "$d" 2>/dev/null | awk '{print $1}')
  fi
  if [[ -z "$IP" ]]; then
    echo "  WARNING: $d does not currently resolve to any IP." >&2
    DNS_WARN=1
  else
    echo "  $d -> $IP"
  fi
done

if [[ "$DNS_WARN" -eq 1 ]]; then
  echo
  read -r -p "One or more domains have no DNS record yet. Continue anyway? [y/N] " CONFIRM
  if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Aborted. Add the missing DNS record(s) and re-run."
    exit 1
  fi
fi

# ---- Write nginx config ----------------------------------------------------

echo
echo "Writing nginx config to $CONFIG_PATH ..."

cat > "$CONFIG_PATH" <<EOF
upstream ${UPSTREAM} {
    server 127.0.0.1:${PORT};
}

server {
    listen 80;
    listen [::]:80;
    server_name ${SERVER_NAMES};

    location / {
        proxy_http_version 1.1;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Cluster-Client-Ip \$remote_addr;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_pass http://${UPSTREAM};
    }
}
EOF

echo "Config written."

# ---- Enable the site -------------------------------------------------------

if [[ -e "$ENABLED_PATH" ]]; then
  echo "Symlink already exists at $ENABLED_PATH, leaving as-is."
else
  ln -s "$CONFIG_PATH" "$ENABLED_PATH"
  echo "Symlinked into sites-enabled."
fi

# ---- Test and reload nginx -------------------------------------------------

echo
echo "Testing nginx config..."
if ! nginx -t; then
  echo "Error: nginx config test failed. Rolling back symlink and config." >&2
  rm -f "$ENABLED_PATH"
  rm -f "$CONFIG_PATH"
  exit 1
fi

systemctl reload nginx
echo "nginx reloaded successfully."

# ---- Run certbot ------------------------------------------------------------

echo
echo "Requesting certificate via certbot (nginx plugin)..."
certbot --nginx "${CERTBOT_DOMAIN_FLAGS[@]}"

echo
echo "== Done =="
echo "Site: $SERVER_NAMES"
echo "Proxying to: 127.0.0.1:${PORT} (upstream '${UPSTREAM}')"
echo "Config: $CONFIG_PATH"