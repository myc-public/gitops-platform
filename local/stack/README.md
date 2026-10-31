# Mode pile (K5, K6a) : toute la chaine dans Docker

```
Navigateur / Postman ─► APISIX externe (TLS, WAF, liste blanche, 20 req/s par IP)
   ├─ /, /profil, /assets/*  ─► donation-web (nginx, front statique)
   ├─ /bff/<liste fermee>    ─► web-bff-customers (BFF) ─► Redis (sessions)
   │                                   └──────────────────► APISIX interne (JWT, scopes) ─► donation-api ─► MySQL
   ├─ /realms/*, /resources/* ─► Keycloak (login, OIDC) ──back-channel logout──► web-bff-customers
   └─ /api/v1/* (PROVISOIRE K5, Postman) ─► APISIX interne
```

- Seul le port **8443** (HTTPS) est publie sur la machine. Le front, le BFF, Redis, l'API, Keycloak, MySQL, Mailpit
  et APISIX interne ne sont joignables que par les reseaux Docker (equivalent local des NetworkPolicy).
- Jamais routes par APISIX externe (404) : le back-channel logout du BFF, `/bff/management/*`, `/healthz` du front.
- Les fichiers de configuration sont ceux du deploiement : `apps/apisix-external`, `apps/apisix-internal`,
  `apps/keycloak`, les Compose existants de Keycloak, de l'API et du BFF (repris par `include`, sans copie), et les
  Dockerfile de la CI de l'API, du BFF et du front.
- Donnees **separees du mode dev** (volumes `donation-pile_*`) : le mode dev n'est pas touche.
- `iss` des tokens : `https://localhost:8443/realms/...` (mode dev : `http://localhost:8180/realms/...`).

## Prerequis

- Docker Desktop, Maven, Node 24, Git for Windows (pour `openssl`).
- Les depots `gitops-platform`, `inner-donation-api`, `web-bff` et `donation-web` cote a cote
  (ex. `D:\workspace\public\`).
- Le mode dev arrete (les controles d'isolation verifient que 8080, 8090, 5173, 8180, 3307, 8025 et 6379 sont fermes).

## Premier demarrage (PowerShell)

```powershell
cd D:\workspace\public\gitops-platform\local\stack

# 1. Variables : copier le modele puis remplir chaque valeur vide (generateur en tete du fichier)
Copy-Item .env.example .env
notepad .env

# Mot de passe du compte Debezium pour Kafka Connect : meme valeur que DEBEZIUM_DB_PASSWORD dans .env
if (-not (Test-Path connect.properties)) { Copy-Item connect.properties.example connect.properties }
notepad connect.properties

# 2. Certificat TLS local auto-signe (jamais commite : local/stack/tls/ est ignore par Git)
New-Item -ItemType Directory -Force tls | Out-Null
& "C:\Program Files\Git\usr\bin\openssl.exe" req -x509 -newkey rsa:2048 -nodes -days 365 `
  -subj "/CN=localhost" -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" `
  -keyout tls/tls.key -out tls/tls.crt

# 3. Jar de l'API et du BFF, build du front (images construites avec les memes Dockerfile que la CI)
mvn -f ..\..\..\inner-donation-api\pom.xml -DskipTests package
mvn -f ..\..\..\web-bff\pom.xml -DskipTests package
Push-Location ..\..\..\donation-web; npm ci; npm run build; Pop-Location

# 4. Demarrage (construit apisix-coraza:local, donation-api:local, web-bff:local et donation-web:local)
docker compose up -d --build

# 5. Attendre l'application du realm (code de sortie 0) et le demarrage de l'API
docker compose ps -a
docker compose logs donation-api | Select-String "Started"
```

## Usage courant

```powershell
cd D:\workspace\public\gitops-platform\local\stack
docker compose up -d                       # demarrer
docker compose stop                        # arreter (donnees conservees)
docker compose run --rm keycloak-config    # reappliquer le realm apres une modification
docker compose up -d --build donation-api       # nouvelle version de l'API (apres mvn package)
docker compose up -d --build web-bff-customers  # nouvelle version du BFF (apres mvn package)
docker compose up -d --build donation-web       # nouvelle version du front (apres npm run build)
docker compose run --rm kafka-topics       # reappliquer les topics apres une modification de create-topics.sh
docker compose run --rm kafka-connect-config  # reappliquer les connecteurs apres une modification de connectors/*.json
docker compose down                        # supprimer les conteneurs (donnees conservees)
docker compose down -v                     # remise a zero complete (donnees supprimees)
```

Une modification de `apps/apisix-*/base/apisix.yaml` est prise en compte par
`docker compose restart apisix-ext apisix-int`.

## Tests

Plan de test et collection E2E : `inner-donation-api/postman/PLAN-DE-TEST-E2E.md`
(collection `e2e-donation`, environnement `e2e-pile`).

Parcours navigateur (Playwright, depot `donation-web`) : `E2E_BASE_URL=https://localhost:8443`, utilisateur de test
du realm `myc-customers` (`E2E_USER`, `E2E_PASSWORD` = `TEST_USERS_PASSWORD` de `.env`).

## Limites connues

- **WAF : les corps de requete ne sont pas inspectes.** APISIX ne transmet le corps a un plugin wasm que si
  le plugin le demande (`wasm_process_req_body`), ce que `coraza-proxy-wasm` (ecrit pour Envoy) ne fait pas.
  Le WAF inspecte l'URL, les parametres, les en-tetes et les cookies. Limite acceptee (decision K5 du 2026-10-08) ;
  passage a un WAF dedie qui inspecte les corps apres le deploiement sur le Sandbox OpenShift (dette 16).
- Le certificat est auto-signe : desactiver la verification SSL de Postman (Settings > General) ou utiliser
  `newman --insecure`. HSTS est a 0 en local (sinon le navigateur force HTTPS sur tous les ports de localhost).
