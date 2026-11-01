# Kafka Connect du socle (ADR 0033, DE3) : image Debezium + plugin Elasticsearch, versions epinglees (ADR 0037, DE31).
# Meme Dockerfile pour la pile locale et le deploiement (BuildConfig en EDA8).
# 3.7.0.Final
FROM quay.io/debezium/connect@sha256:02a788e4e02542e4a7ed6ee2eb925677e48370e3973cd33fb2cb271be1da11f8

ADD --checksum=sha256:8bb4077b27d143828898ca8ec8a56c74703f3596dc305d4a2c9a6f0e9cb86f6a \
    https://api.hub.confluent.io/api/plugins/confluentinc/kafka-connect-elasticsearch/versions/16.0.1/archive \
    /tmp/elasticsearch-sink.zip

# Agent JMX 1.0.1 (EDA7) : empreinte relevee sur le jar servi par Nexus
ADD --checksum=sha256:7d61f737fd661610ccc14aea79764faa1ea94a340cbc8f0029b3d2edea3d80c1 \
    https://repo1.maven.org/maven2/io/prometheus/jmx/jmx_prometheus_javaagent/1.0.1/jmx_prometheus_javaagent-1.0.1.jar \
    /kafka/libs/jmx_prometheus_javaagent-1.0.1.jar
# Hors de /kafka/config : ce dossier est un volume de l'image, un volume existant masquerait le fichier
COPY metrics.yaml /kafka/jmx-metrics.yaml

USER root
RUN unzip -q /tmp/elasticsearch-sink.zip -d /kafka/connect \
    && rm /tmp/elasticsearch-sink.zip \
    && chmod 644 /kafka/libs/jmx_prometheus_javaagent-1.0.1.jar \
    && chown -R 1001:0 /kafka/connect
USER 1001
