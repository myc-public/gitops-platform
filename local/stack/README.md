# Mode pile (K5) : toute la chaine dans Docker

```
Postman / navigateur ─► APISIX externe (TLS, WAF, liste blanche, 20 req/s par IP) ─► APISIX interne (JWT, scopes)
                                         │                                                   │
                                         └──► Keycloak (login, OIDC)                         └──► donation-api ─► MySQL
```

- Seul le port **8443** (HTTPS) est publie sur la machine. L'API, Keycloak, MySQL, Mailpit et APISIX interne
  ne sont joignables que par les reseaux Docker (equivalent local des NetworkPolicy).
- Les fichiers de configuration sont ceux du deploiement : `apps/apisix-external`, `apps/apisix-internal`,
  `apps/keycloak`, et les Compose existants de Keycloak et de l'API (repris par `include`, sans copie).
- Donnees **separees du mode dev** (volumes `donation-pile_*`) : le mode dev n'est pas touche.
- `iss` des tokens : `https://localhost:8443/realms/...` (mode dev : `http://localhost:8180/realms/...`).

## Prerequis

- Docker Desktop, Maven, Git for Windows (pour `openssl`).
- Les depots `gitops-platform` et `inner-donation-api` cote a cote (ex. `D:\workspace\public\`).
- Le mode dev arrete (les controles d'isolation verifient que 8080, 8180, 3307 et 8025 sont fermes).

## Premier demarrage (PowerShell)

```powershell
cd D:\workspace\public\gitops-platform\local\stack

# 1. Variables : copier le modele puis remplir chaque valeur vide (generateur en tete du fichier)
Copy-Item .env.example .env
notepad .env

# 2. Certificat TLS local auto-signe (jamais commite : local/stack/tls/ est ignore par Git)
New-Item -ItemType Directory -Force tls | Out-Null
& "C:\Program Files\Git\usr\bin\openssl.exe" req -x509 -newkey rsa:2048 -nodes -days 365 `
  -subj "/CN=localhost" -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" `
  -keyout tls/tls.key -out tls/tls.crt

# 3. Jar de l'API (l'image de l'API est construite avec le meme Dockerfile que la CI)
mvn -f ..\..\..\inner-donation-api\pom.xml -DskipTests package

# 4. Demarrage (construit les images apisix-coraza:local et donation-api:local)
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
docker compose up -d --build donation-api  # nouvelle version de l'API (apres mvn package)
docker compose down                        # supprimer les conteneurs (donnees conservees)
docker compose down -v                     # remise a zero complete (donnees supprimees)
```

Une modification de `apps/apisix-*/base/apisix.yaml` est prise en compte par
`docker compose restart apisix-ext apisix-int`.

## Tests

Plan de test et collection E2E : `inner-donation-api/postman/PLAN-DE-TEST-E2E.md`
(collection `e2e-donation`, environnement `e2e-pile`).

## Limites connues

- **WAF : les corps de requete ne sont pas inspectes.** APISIX ne transmet le corps a un plugin wasm que si
  le plugin le demande (`wasm_process_req_body`), ce que `coraza-proxy-wasm` (ecrit pour Envoy) ne fait pas.
  Le WAF inspecte l'URL, les parametres, les en-tetes et les cookies. Limite acceptee (decision K5 du 2026-10-08) ;
  passage a un WAF dedie qui inspecte les corps apres le deploiement sur le Sandbox OpenShift (dette 16).
- Le certificat est auto-signe : desactiver la verification SSL de Postman (Settings > General) ou utiliser
  `newman --insecure`. HSTS est a 0 en local (sinon le navigateur force HTTPS sur tous les ports de localhost).
