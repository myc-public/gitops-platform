#!/bin/sh
# Applique la configuration versionnee d'Elasticsearch (ADR 0036, 0037) : rejouable.
# Pipelines, role et compte : mis a jour a chaque passage. Index : crees s'ils manquent, jamais modifies
# (un changement de mapping = un nouvel index -vN, relecture depuis l'offset 0, bascule d'alias).
set -eu

ES="${ELASTICSEARCH_URL:-http://elasticsearch:9200}"
DIR="${CONFIG_DIR:-/config}"

api() {
  methode="$1"; chemin="$2"; shift 2
  code="$(curl -s -o /tmp/reponse -w '%{http_code}' -u "elastic:$ELASTIC_PASSWORD" -X "$methode" \
    -H 'Content-Type: application/json' "$@" "$ES$chemin")"
  echo "$methode $chemin : $code"
  case "$code" in
    200|201) ;;
    *) cat /tmp/reponse >&2; exit 1 ;;
  esac
}

i=0
until curl -s -f -o /dev/null -u "elastic:$ELASTIC_PASSWORD" "$ES/_cluster/health"; do
  i=$((i + 1))
  if [ "$i" -ge 60 ]; then
    echo "Elasticsearch injoignable" >&2
    exit 1
  fi
  sleep 3
done

api PUT /_ingest/pipeline/donors --data @"$DIR/donors-pipeline.json"
api PUT /_ingest/pipeline/donations --data @"$DIR/donations-pipeline.json"

for index in donors-v1 donations-v1; do
  existe="$(curl -s -o /dev/null -w '%{http_code}' -u "elastic:$ELASTIC_PASSWORD" -I "$ES/$index")"
  if [ "$existe" = "404" ]; then
    api PUT "/$index" --data @"$DIR/$index.json"
  else
    echo "$index : deja present"
  fi
done

api PUT /_security/role/eda-sink --data @"$DIR/eda-sink-role.json"
printf '{"password":"%s","roles":["eda-sink"]}' "$ES_SINK_PASSWORD" > /tmp/compte.json
api PUT /_security/user/eda-sink --data @/tmp/compte.json

api PUT /_security/role/eda-read --data @"$DIR/eda-read-role.json"
printf '{"password":"%s","roles":["eda-read"]}' "$ES_READ_PASSWORD" > /tmp/compte.json
api PUT /_security/user/eda-read --data @/tmp/compte.json
rm -f /tmp/compte.json /tmp/reponse
