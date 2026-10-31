#!/bin/sh
# Applique chaque connecteur versionne (ADR 0033, DE7) : PUT idempotent, nom du connecteur = nom du fichier.
set -eu

CONNECT_URL="${CONNECT_URL:-http://kafka-connect:8083}"

i=0
until curl -sf "$CONNECT_URL/connectors" > /dev/null; do
  i=$((i + 1))
  if [ "$i" -ge 60 ]; then
    echo "Kafka Connect injoignable" >&2
    exit 1
  fi
  sleep 3
done

for f in /connectors/*.json; do
  name="$(basename "$f" .json)"
  code="$(curl -s -o /tmp/reponse -w '%{http_code}' -X PUT -H 'Content-Type: application/json' \
    --data @"$f" "$CONNECT_URL/connectors/$name/config")"
  echo "$name : $code"
  case "$code" in
    200|201) ;;
    *) cat /tmp/reponse >&2; exit 1 ;;
  esac
done
