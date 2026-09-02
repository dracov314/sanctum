#!/usr/bin/env bash
# First-run setup: create .env from .env.example with generated secrets.
set -euo pipefail
cd "$(dirname "$0")"

if [ -f .env ]; then
  echo ".env already exists — not overwriting. Edit it by hand if you need to."
  exit 0
fi

gen() { openssl rand -hex 32; }

cp .env.example .env
# Replace the placeholder secret values in place.
sed -i \
  -e "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$(gen)|" \
  -e "s|^SECRET_KEY=.*|SECRET_KEY=$(gen)|" \
  .env

echo "Wrote .env with generated POSTGRES_PASSWORD and SECRET_KEY."
echo "Review it (BASE_URL, SANCTUM_PORT, AUTH_MODE), then:"
echo
echo "  docker compose up -d --build"
echo
echo "The first account you register becomes the admin."
