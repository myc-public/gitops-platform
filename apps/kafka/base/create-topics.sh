#!/bin/sh
# Source unique des topics metier (ADR 0034) : rejouable, cree ce qui manque et realigne la configuration.
# Le nombre de partitions n'est jamais modifie : il conditionne le hachage des cles (ADR 0034).
set -eu

BOOTSTRAP="${KAFKA_BOOTSTRAP:-kafka:9092}"
BIN=/opt/kafka/bin

topic() {
  "$BIN/kafka-topics.sh" --bootstrap-server "$BOOTSTRAP" --create --if-not-exists \
    --topic "$1" --partitions "$2" --replication-factor 1
  "$BIN/kafka-configs.sh" --bootstrap-server "$BOOTSTRAP" --alter \
    --entity-type topics --entity-name "$1" --add-config "$3"
}

topic donor.events 3 cleanup.policy=compact
topic donation.events 3 cleanup.policy=compact
# 30 jours : file d'erreurs commune aux deux flux, pas un historique
topic events.dlt 1 cleanup.policy=delete,retention.ms=2592000000
