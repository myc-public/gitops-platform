# Image apisix-coraza (K5, D5-10) : APISIX epingle + WAF Coraza (OWASP CRS) en plugin wasm.
# Construite par la CI pour OpenShift, et par Docker Compose en local (meme fichier) : aucun telechargement
# au demarrage, wasm verifie par sha256 a la construction. Mise a jour = changer les versions ET les empreintes.
#   docker build -t apisix-coraza:local images/apisix-coraza

# --- Etape 1 : telechargement et verification du wasm Coraza
FROM alpine@sha256:5291449c3df73caf6ed85e649dec1b9e818b39a5d8c871e97afc13e9cd5e8fa8 AS coraza
# coraza-proxy-wasm 0.6.0 (juillet 2025, Coraza 3.3.3, CRS 4.14) ; veille : derniere version connue (ADR 07/10)
ARG CORAZA_VERSION=0.6.0
ARG CORAZA_ZIP_SHA256=cca4e3c75cf6b2e615907f936a1b6dcd0955250e0fb7d3b1c2ecef807d84603c
ARG CORAZA_WASM_SHA256=f36e710529167482df820b790981230092da098d26d21aebb16f1d9c8c4e26d5
RUN wget -q -O /tmp/coraza.zip \
        "https://github.com/corazawaf/coraza-proxy-wasm/releases/download/${CORAZA_VERSION}/coraza-proxy-wasm-${CORAZA_VERSION}.zip" \
    && echo "${CORAZA_ZIP_SHA256}  /tmp/coraza.zip" | sha256sum -c - \
    && unzip -q /tmp/coraza.zip -d /tmp/coraza \
    && echo "${CORAZA_WASM_SHA256}  /tmp/coraza/coraza-proxy-wasm.wasm" | sha256sum -c -

# --- Etape 2 : APISIX 3.19.0-debian, epingle par digest
FROM apache/apisix@sha256:9a7e45dc943fbf10ec916d1232bae4cda9302ae28a4696cfb83c2da01d261141
COPY --from=coraza /tmp/coraza/coraza-proxy-wasm.wasm /usr/local/apisix/proxywasm/coraza-proxy-wasm.wasm
