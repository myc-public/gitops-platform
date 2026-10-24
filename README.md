# gitops-platform

Source de vérité du déploiement (Argo CD). Argo CD tourne sur **minikube** (profil et namespace `argocd`) et déploie à distance sur le **Sandbox OpenShift** (namespace `gregorie769-dev`). Ce dépôt ne contient **que de la configuration** : le code vit dans les dépôts applicatifs, les JARs dans Nexus, les images dans le registry interne OpenShift. Il porte aussi la pile locale (mêmes fichiers que le déploiement) et les tests de bout en bout du BFF.
Vue d'ensemble du socle : [platform-handbook](https://github.com/myc-public/platform-handbook).

```
gitops-platform/
├── bootstrap/                     # appliqué à la main, une fois (paradoxe d'amorçage)
│   ├── root.yaml                  # Application "root" (app-of-apps)
│   ├── minikube-argocd/           # installation d'Argo, resource.inclusions, modèle du Secret de cluster
│   ├── sandbox-cluster/           # identité d'Argo sur le Sandbox (SA argocd-deployer)
│   └── secrets/dev/*.example.yaml # modèles des Secrets hors Git
├── argocd/
│   ├── projects/                  # AppProject : périmètre et droits
│   └── applicationsets/           # génère 1 Application par (app, environnement)
├── apps/
│   └── <app>/
│       ├── base/                  # manifests communs (Kustomize), image = nom logique
│       └── overlays/<env>/        # dev aujourd'hui ; kustomization.yaml (namespace, images) + config.json
├── images/apisix-coraza/          # Dockerfile d'APISIX + WAF Coraza (construit par Jenkins, BuildConfig)
├── local/                         # dev local : keycloak/ (Keycloak seul), stack/ (toute la chaîne, « mode pile »)
├── tools/                         # check-realm-rbac.py, tests/sec-bff.ps1
└── docs/                          # documentation propre à ce dépôt
```

## Applications

| Application | Contenu |
|---|---|
| `donation-api` | API des dons + MySQL |
| `keycloak` | Keycloak + PostgreSQL, realms `myc-customers` et `myc-internal` (keycloak-config-cli) |
| `apisix-external` | Passerelle de bordure : TLS, WAF Coraza, limitation de débit, routes du front et du BFF |
| `apisix-internal` | Passerelle interne : validation JWT, scopes, quotas |
| `web-bff` | BFF `web-bff-customers` + Redis des sessions |
| `donation-web` | Front React (nginx) |
| `observability` | `grafana/otel-lgtm` (Loki, Tempo, Prometheus, Grafana), tableaux et alertes as code |

## Règles

- **Git est la seule voie de changement.** Pas de `oc apply`/`oc edit` manuel sur les ressources gérées (`selfHeal` les annulerait).
- **Tags d'image immuables** (`<version>-<sha>-b<build>`), jamais `latest`. Jenkins ne modifie que la ligne `newTag` de `overlays/<env>/kustomization.yaml`.
- **Promotion** : `dev` = commit direct de Jenkins sur `main` (synchro automatique). `uat`/`preprod`/`prod` = branche `promote/...` poussée par Jenkins, **Pull Request** vers `main`, synchro manuelle en prod (`autoSync: false`).
- **Aucun secret dans Git.** Les Secrets sont créés hors dépôt à partir des modèles `bootstrap/secrets/dev/*.example.yaml` ; cible : Sealed Secrets ou External Secrets.
- Moindre privilège : l'`AppProject` limite dépôts, namespaces et types de ressources.

## Bootstrap (une fois)

Ces ressources ne peuvent pas être synchronisées par Argo CD lui-même : ce sont elles qui lui donnent accès au cluster. Ordre et commandes : [`runbooks/reconstruction.md`](https://github.com/myc-public/platform-handbook/blob/develop/runbooks/reconstruction.md) de `platform-handbook` (étapes 4 à 8), point d'entrée unique.

| Élément | Où | Rôle |
|---|---|---|
| `bootstrap/sandbox-cluster/` | Sandbox | ServiceAccount `argocd-deployer`, rôle `edit` limité au namespace ([README](bootstrap/sandbox-cluster/README.md)) |
| Secret de cluster `sandbox-gregorie769-dev` | minikube, hors Git | token de `argocd-deployer` ; modèle `bootstrap/minikube-argocd/cluster-secret.example.yaml` |
| `bootstrap/minikube-argocd/argocd-cm-inclusions.yaml` | minikube | liste blanche des types surveillés : sans elle, les Applications restent en `Unknown` |
| `bootstrap/root.yaml` | minikube | app-of-apps : AppProject, ApplicationSet, Applications |
| Secrets applicatifs (7 modèles) | Sandbox, hors Git | base de l'API, comptes `/management`, Grafana, Keycloak (base, admin, realm), BFF ; absents = pods en `CreateContainerConfigError` |

> `k` est le raccourci de `kubectl` fourni par minikube (profil `argocd`, contexte `argocd` : `function k { minikube -p argocd kubectl -- --context=argocd @args }` dans le profil PowerShell) ; `ocs` est la fonction qui cible le Sandbox (kubeconfig `sandbox.config`).

Si un environnement vit dans un **autre namespace** que celui du build, autoriser le pull de l'image par un `RoleBinding` versionné (rôle `system:image-puller`, groupe `system:serviceaccounts:<ns-cible>`, dans `<ns-build>`), jamais par `oc policy`.

## Dev local

- Keycloak seul (pour une API ou le BFF lancés depuis l'IDE) : `docker compose -f local/keycloak/compose.yaml --env-file local/keycloak/.env up -d` ; console `http://localhost:8180/admin`, Mailpit `http://localhost:8025`.
- Toute la chaîne dans Docker, derrière APISIX externe sur `https://localhost:8443` : [`local/stack/README.md`](local/stack/README.md).
- `.env` : copies de `local/*/.env.example`, ignorées par Git ; ne jamais écraser un `.env` existant.

## Tests et contrôles

| Outil | Rôle |
|---|---|
| `python tools/check-realm-rbac.py` | Règles R1-R6 des realms (Groupe -> Rôle métier -> Permission) |
| `tools/tests/sec-bff.ps1 -Cible Pile\|Sandbox -Groupe …` | Tests SEC-BFF (`inner-donation-api/postman/PLAN-DE-TEST-E2E.md` § 5.9) |

## Ajouter un environnement ou une application

1. Copier `apps/<app>/overlays/dev` vers `apps/<app>/overlays/<env>` ; adapter `namespace`, `newName` et `config.json`.
2. Ajouter le namespace dans `destinations` de `argocd/projects/inner-apis.yaml`.
3. Pour une nouvelle app : créer `apps/<app>/base`, puis ses overlays. L'ApplicationSet la découvre seul.
4. **Nouveau type de ressource** (ex. `PersistentVolumeClaim`, `Secret`) : l'ajouter à la fois dans `namespaceResourceWhitelist` de l'AppProject **et** dans `bootstrap/minikube-argocd/argocd-cm-inclusions.yaml` (puis le réappliquer), sinon Argo CD ne le verra pas.

## Documentation

| Fichier | Contenu |
|---|---|
| [docs/observabilite-dashboard.md](docs/observabilite-dashboard.md) | Tableau Grafana as code, alertes A1-A6 |
| [local/stack/README.md](local/stack/README.md) | Mode pile : flux, ports, démarrage, tests |
| [bootstrap/sandbox-cluster/README.md](bootstrap/sandbox-cluster/README.md) | Identité d'Argo CD sur le Sandbox |
| `REBUILD.md` | Page de renvoi vers les runbooks de `platform-handbook` |
