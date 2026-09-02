#!/usr/bin/env bash
#
# install.sh — installs domain-deploy to /usr/local/bin
#
# Usage:
#   Install latest tagged release (recommended):
#     curl -fsSL https://raw.githubusercontent.com/mbashia/nginx-deploy-site/main/install.sh | sudo bash
#
#   Install a specific version/tag:
#     curl -fsSL https://raw.githubusercontent.com/mbashia/nginx-deploy-site/main/install.sh | sudo bash -s -- v1.0.0
#
#   Install straight from main (latest, possibly unreleased changes):
#     curl -fsSL https://raw.githubusercontent.com/mbashia/nginx-deploy-site/main/install.sh | sudo bash -s -- main

set -euo pipefail

REPO="mbashia/nginx-deploy-site"
BIN_NAME="domain-deploy"
DEST="/usr/local/bin/${BIN_NAME}"
REQUESTED_REF="${1:-}"

if [[ "$EUID" -ne 0 ]]; then
  echo "Please run with sudo." >&2
  exit 1
fi

# Resolve which ref (tag or branch) to install from.
if [[ -n "$REQUESTED_REF" ]]; then
  REF="$REQUESTED_REF"
  echo "Requested ref: ${REF}"
else
  echo "No version specified, looking up latest tagged release..."
  LATEST_TAG="$(curl -fsSL "https://api.github.com/repos/${REPO}/tags" \
    | grep -m1 '"name"' \
    | sed -E 's/.*"name":\s*"([^"]+)".*/\1/' || true)"

  if [[ -n "$LATEST_TAG" ]]; then
    REF="$LATEST_TAG"
    echo "Latest tag: ${REF}"
  else
    echo "WARNING: could not find any tags, falling back to 'main'." >&2
    REF="main"
  fi
fi

RAW_URL="https://raw.githubusercontent.com/${REPO}/${REF}/domain-deploy.sh"

echo "Installing ${BIN_NAME} (${REF}) to ${DEST}..."
if ! curl -fsSL "${RAW_URL}" -o "${DEST}"; then
  echo "Error: failed to download ${RAW_URL}" >&2
  echo "Check that the ref '${REF}' exists and domain-deploy.sh is at the repo root." >&2
  exit 1
fi
chmod +x "${DEST}"

echo "Done. Installed ${REF}."
echo "Run: ${BIN_NAME} -u <upstream> -p <port> -d <domain>"
echo "Check version anytime with: ${BIN_NAME} -v"