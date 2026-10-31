# Kafka Connect du socle (ADR 0033, DE3) : image Debezium + plugin Elasticsearch, versions epinglees (ADR 0037, DE31).
# Meme Dockerfile pour la pile locale et le deploiement (BuildConfig en EDA8).
# 3.7.0.Final
FROM quay.io/debezium/connect@sha256:02a788e4e02542e4a7ed6ee2eb925677e48370e3973cd33fb2cb271be1da11f8

ADD --checksum=sha256:8bb4077b27d143828898ca8ec8a56c74703f3596dc305d4a2c9a6f0e9cb86f6a \
    https://api.hub.confluent.io/api/plugins/confluentinc/kafka-connect-elasticsearch/versions/16.0.1/archive \
    /tmp/elasticsearch-sink.zip

USER root
RUN unzip -q /tmp/elasticsearch-sink.zip -d /kafka/connect \
    && rm /tmp/elasticsearch-sink.zip \
    && chown -R 1001:0 /kafka/connect
USER 1001
