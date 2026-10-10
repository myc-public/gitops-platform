# REBUILD — reconstruire le socle sur un nouveau cluster

Point d'entrée pour remonter toute la chaîne (Jenkins → Nexus / registry → GitOps → Argo CD → OpenShift) sur un **nouveau cluster OpenShift** (Sandbox renouvelé, OpenShift Local, OKD...), à partir de Git seul et des secrets sauvegardés.

État de référence : tag Git `sandbox-v2` sur tous les dépôts (build #33, 28/09/2026 : pipeline CI/CD, observabilité phases 1-4, API First L0, architecture sécurité). Précédent : `sandbox-v1` (build #25, 24/09).
Commandes en PowerShell. `ocs` = `oc --kubeconfig "$HOME\.kube\sandbox.config"` (profil PowerShell), `k` = `kubectl`.

## 0. Prérequis

| Élément | Valeur de référence |
|---|---|
| Outils | `oc`, `kubectl`, `terraform`, Docker Desktop, minikube v1.37, 7-Zip, `cloudflared` |
| minikube | profil `minikube`, driver docker, 2 CPU, 3 Go, Kubernetes v1.34.0 |
| Sauvegarde | `D:\backup\socle-sandbox-v2-<date>\` : `fichiers-locaux.7z` (chiffré, en-têtes compris : fichiers hors Git, dump MySQL, mémoire Claude), `nexus-data.tgz` |
| Dépôts | `myc-public/*` clonés sous `D:\workspace\public` |

Se placer sur l'état de référence dans chaque dépôt :
```powershell
Get-ChildItem D:\workspace\public -Directory | Where-Object { Test-Path "$($_.FullName)\.git" } | ForEach-Object { git -C $_.FullName fetch --tags; git -C $_.FullName checkout sandbox-v2 }
```
Restaurer les fichiers hors Git (secrets Terraform et tfstate, copies des secrets applicatifs `*.dev.yaml`, `local/.env`, README locaux, dump MySQL et mémoire Claude dans `_backup\`) à leur place (mot de passe demandé) :
```powershell
& "C:\Program Files\7-Zip\7z.exe" x "D:\backup\socle-sandbox-v2-<date>\fichiers-locaux.7z" -o"D:\workspace\public"
# Si la console refuse le mot de passe (caracteres speciaux mal transmis) : ouvrir l'archive dans l'interface 7-Zip et extraire vers D:\workspace\public
Copy-Item D:\workspace\public\_backup\claude-memory\* "$HOME\.claude\projects\D--workspace-public\memory\" -Force   # optionnel
```

## 1. Nexus et tunnel (poste local)

Si le volume `nexus-data` a été perdu :
```powershell
docker volume create nexus-data
docker run --rm -v nexus-data:/data -v "D:\backup\socle-sandbox-v2-<date>:/backup" alpine tar xzf /backup/nexus-data.tgz -C /data
```
Démarrer le conteneur `nexus` (voir `jenkins-on-openshift-with-terraform/README_local.md`), puis le tunnel ; reporter l'URL obtenue dans `nexus_url` de `terraform/secrets.auto.tfvars`.

## 2. Nouveau cluster : relever ses identifiants

```powershell
oc login --token=<token> --server=<URL API> --kubeconfig "$HOME\.kube\sandbox.config"
ocs whoami --show-server        # URL d'API        -> Secret de cluster Argo (étape 5)
ocs project -q                  # namespace        -> normalement inchangé (<utilisateur>-dev)
ocs get ingresses.config/cluster -o jsonpath='{.spec.domain}'   # domaine des Routes -> apps_domain (étape 3)
```

**L'URL d'API n'est plus dans Git** : Argo désigne le cluster par son nom (`sandbox-gregorie769-dev`) et `resource.inclusions` utilise le motif `https://api.*:6443`. Elle ne vit que dans le Secret de cluster (hors Git).

**Si le namespace change** (rare), remplacer `gregorie769-dev` dans :
- `gitops-platform` : `apps/*/overlays/dev/kustomization.yaml` (`namespace`, `newName`), `apps/*/overlays/dev/config.json`, `argocd/projects/inner-apis.yaml`, `bootstrap/sandbox-cluster/*.yaml`, `bootstrap/secrets/dev/*.example.yaml`, `bootstrap/minikube-argocd/cluster-secret.example.yaml` ;
- `jenkins-on-openshift-with-terraform` : `terraform/terraform.tfvars` (`namespace`), `variables.tf` (`jenkins_image`), `config/agents.yaml`.

## 3. Jenkins (Terraform)

Dans `terraform/terraform.tfvars` : `kubeconfig_path`, `kubeconfig_context` (nouveau contexte), `apps_domain` (étape 2), `namespace`.
```powershell
cd D:\workspace\public\jenkins-on-openshift-with-terraform\terraform
# Seulement si le CLUSTER change : l'ancien state décrit un cluster disparu (sauvegardé).
# Même cluster, namespace vidé : garder le state, Terraform constate seul que les ressources ont disparu.
# Remove-Item terraform.tfstate, terraform.tfstate.backup -ErrorAction SilentlyContinue
terraform init
# 1) BuildConfig + ImageStream seuls, puis l'image : sinon l'apply complet attend 10 min un pod sans image (timeout, ImagePullBackOff)
terraform apply -target=openshift_build_config.jenkins -target=openshift_image_stream.jenkins
ocs start-build jenkins --from-dir=jenkins-image --follow    # dossier terraform/jenkins-image
# 2) Le reste (Deployment, Route, secrets...)
terraform apply
terraform output jenkins_route_host
# 3) Image du WAF (APISIX externe) : construite depuis gitops-platform/main (images/apisix-coraza)
ocs start-build apisix-coraza --follow
ocs get istag apisix-coraza:3.19.0-coraza0.6.0 -o jsonpath='{.image.metadata.name}'   # digest
```
Attendu : pod `jenkins` 1/1, console Jenkins accessible sur `https://jenkins-<namespace>.<apps_domain>`.
Le digest de `apisix-coraza` change à chaque reconstruction : le reporter (PR) dans
`apps/apisix-external/overlays/dev/kustomization.yaml` (`images: digest`) **avant l'étape 8**, sinon `ImagePullBackOff`.

## 4. Argo CD (minikube)

```powershell
minikube start --driver=docker --cpus=2 --memory=3072 --kubernetes-version=v1.34.0
cd D:\workspace\public\gitops-platform
k --context minikube apply --server-side --force-conflicts -k bootstrap/minikube-argocd/install
k --context minikube apply --server-side --field-manager=gitops-bootstrap -f bootstrap/minikube-argocd/argocd-cm-inclusions.yaml
k --context minikube get pods -n argocd                   # 6 pods 1/1 (dex à 0 réplica, voulu)
```

## 5. Identité d'Argo CD sur le cluster

> **Ordre : faire les étapes 6 et 7 AVANT celle-ci.** Dès qu'Argo a un token valide, il déploie seul (`autoSync` en dev) :
> sans secrets ni image, les pods restent en erreur. Si minikube contient déjà l'Argo d'un ancien Sandbox, seul le Secret
> de cluster est à mettre à jour (même nom).

```powershell
ocs apply -f bootstrap/sandbox-cluster/                   # SA argocd-deployer + RoleBinding edit + Secret de token
$t = ocs get secret argocd-deployer-token -o jsonpath='{.data.token}'
[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($t))   # -> bearerToken
ocs get secret argocd-deployer-token -o jsonpath='{.data.ca\.crt}'  # -> caData (déjà en base64)
```
Compléter la copie hors Git de `bootstrap/minikube-argocd/cluster-secret.example.yaml` (`server` = URL d'API de l'étape 2, `bearerToken`, `caData`), puis :
```powershell
k --context minikube apply -f <copie-hors-depot>.yaml
```

## 6. Secrets applicatifs (hors Git)

Copies restaurées à l'étape 0 (modèles : `bootstrap/secrets/dev/*.example.yaml`). Vérifier avant qu'aucune valeur n'est restée
celle du modèle (`CHANGE_ME`) : MySQL et Grafana ne lisent leur mot de passe qu'à la première initialisation de leur volume.

```powershell
ocs apply -f bootstrap/secrets/dev/donation-api-db-secret.dev.yaml
ocs apply -f bootstrap/secrets/dev/donation-api-management-secret.dev.yaml
ocs apply -f bootstrap/secrets/dev/observability-grafana-secret.dev.yaml   # compte admin Grafana (stack otel-lgtm)
ocs apply -f bootstrap/secrets/dev/keycloak-db-secret.dev.yaml           # PostgreSQL de Keycloak
ocs apply -f bootstrap/secrets/dev/keycloak-admin-secret.dev.yaml        # admin de démarrage (lu aussi par l'import des realms)
ocs apply -f bootstrap/secrets/dev/keycloak-realm-secret.dev.yaml        # secrets clients + mot de passe des utilisateurs de test
```
PostgreSQL et le compte admin Keycloak ne sont créés qu'au premier démarrage : mêmes précautions que MySQL.

## 7. Premier build Jenkins

Lancer le job `inner-donation-api` sur la branche **`develop`** (seule branche liée à l'overlay `dev` ; `main` vise l'overlay `prod`, absent) : il publie le jar dans Nexus, construit l'image dans le nouveau registry et commite le nouveau `newTag` dans `gitops-platform` (`main`).
Reconstruction **depuis un tag** (code plus ancien que `develop`) : construire aussi la branche `main` (l'étape « Update GitOps » échoue, attendu), puis pointer l'overlay `dev` vers cette image par un commit sur `gitops-platform/main` (`newTag`).
À faire **avant** l'étape 8 : l'overlay référence sinon une image absente du nouveau registry (`ImagePullBackOff`).

## 8. App-of-apps

```powershell
k --context minikube apply -f bootstrap/root.yaml
k --context minikube get applications -n argocd           # root + donation-api-dev + observability-dev : Synced / Healthy (≈ 3 min)
```
`observability-dev` déploie otel-lgtm (Grafana, Prometheus, Loki, Tempo) avec le dashboard `donation-api — Service` et les 7 alertes provisionnés depuis Git (`apps/observability/base/grafana`) : rien à restaurer, l'historique de télémétrie n'est pas sauvegardé.
Piège connu : alertes en `plugin not registered` → vérifier `GF_PLUGINS_PREINSTALL_AUTO_UPDATE=false` dans `apps/observability/base/deployment.yaml` (mise à jour des plugins impossible sous UID aléatoire).

**Optionnel — restaurer le jeu de données de test** (sinon Flyway crée un schéma vide) :
```powershell
Get-Content D:\workspace\public\_backup\donation-api-mysql.sql -Raw | oc --kubeconfig "$HOME\.kube\sandbox.config" exec -i deploy/donation-api-mysql -- bash -c 'MYSQL_PWD="$MYSQL_PASSWORD" mysql -u"$MYSQL_USER" "$MYSQL_DATABASE"'
```

## 9. Recette

La chaine securisee n'a qu'une entree publique : la Route `donation` (APISIX externe + WAF). L'API n'a plus de Route,
`/management` et `/docs` ne sont pas exposes : la sante de l'API se controle de l'interieur
(`exec` : `oc --kubeconfig ...`, la fonction `ocs` avale le `--`).
```powershell
k --context minikube get applications -n argocd           # toutes Synced / Healthy
ocs get pods                                              # tout 1/1 (hors builds et Job keycloak-config termine)
ocs get routes -o custom-columns=NOM:.metadata.name,TLS:.spec.tls.termination   # donation, grafana, jenkins (edge)
oc --kubeconfig "$HOME\.kube\sandbox.config" exec deploy/donation-api -- curl -s localhost:8080/management/health      # {"status":"UP"...}
oc --kubeconfig "$HOME\.kube\sandbox.config" exec deploy/donation-api -- curl -s localhost:8080/management/info        # build.version

$u = "https://" + (ocs get route donation -o jsonpath='{.spec.host}')
curl.exe -s -o NUL -w "oidc %{http_code}`n"    "$u/realms/myc-internal/.well-known/openid-configuration"   # 200
curl.exe -s -o NUL -w "api %{http_code}`n"     "$u/api/v1/donors"                                         # 401
curl.exe -s -o NUL -w "admin %{http_code}`n"   "$u/admin/master/console/"                                 # 404

# Observabilite
$g = "https://" + (ocs get route grafana -o jsonpath='{.spec.host}')
curl.exe -s -o NUL -w "grafana anonyme %{http_code}`n" "$g/api/search"      # 401
```
Recette fonctionnelle et securite : `inner-donation-api/postman/PLAN-DE-TEST-E2E.md`, collection `e2e-donation`,
environnement `e2e-sandbox` (toute verte sauf G2, dette 16), puis controles 6.1 et 6.3 a 6.5.

Connecté à Grafana (compte de `observability-grafana-secret`) :
- `/d/donation-api-service/donation-api-e28094-service?var-env=dev` : « Télémétrie reçue » = OK, « Version déployée » renseignée ;
- Alerting : 7 règles `donation-api`, santé `ok` ;
- Postman observabilité (S1 / S2) : à reprendre avec un token `donation-service` sur l'URL publique (lot prévu après O1-6) ; le dashboard montre le trafic, les dons par catégorie et les 4xx, Tempo les traces avec spans SQL.
Consigner le résultat dans `jenkins-on-openshift-with-terraform/docs/ROADMAP.md` (journal).

## Reprise de session (Sandbox existant)

Le Developer Sandbox met à 0 les déploiements après ~12 h de fonctionnement, et Argo CD (sur minikube, hors du cluster)
ne les relance que lorsqu'il tourne (dette 19). Avant chaque session :
```powershell
minikube start                                            # Argo CD reprend la main
k --context minikube get applications -n argocd           # attendre Synced / Healthy (quelques minutes)
ocs get deploy                                            # tout à 1/1, sauf peut-être jenkins
```
- **Jenkins à 0** (géré par Terraform, jamais relancé par Argo) : `terraform plan -target=kubernetes_deployment.jenkins -out=jenkins.tfplan`,
  vérifier `replicas 0 -> 1`, puis `terraform apply jenkins.tfplan` (dossier `jenkins-on-openshift-with-terraform/terraform`).
- **Tunnel Nexus** (avant un build) : si `cloudflared` a été arrêté, le relancer, reporter la nouvelle URL dans `nexus_url`
  (`terraform/secrets.auto.tfvars`) et appliquer Terraform sur le Deployment Jenkins.
- **Session `ocs` expirée** : `oc login --token=<token> --server=<URL API> --kubeconfig "$HOME\.kube\sandbox.config"`.
- Une mise en veille d'`otel-lgtm` produit des lignes ERROR « Failed to export » côté API (alerte A5), qui retombent ~5 min après sa relance.
