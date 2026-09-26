# REBUILD — reconstruire le socle sur un nouveau cluster

Point d'entrée pour remonter toute la chaîne (Jenkins → Nexus / registry → GitOps → Argo CD → OpenShift) sur un **nouveau cluster OpenShift** (Sandbox renouvelé, OpenShift Local, OKD...), à partir de Git seul et des secrets sauvegardés.

État de référence : tag Git `sandbox-v1` sur tous les dépôts (build #25, 24/09/2026).
Commandes en PowerShell. `ocs` = `oc --kubeconfig "$HOME\.kube\sandbox.config"` (profil PowerShell), `k` = `kubectl`.

## 0. Prérequis

| Élément | Valeur de référence |
|---|---|
| Outils | `oc`, `kubectl`, `terraform`, Docker Desktop, minikube v1.37, 7-Zip, `cloudflared` |
| minikube | profil `minikube`, driver docker, 2 CPU, 3 Go, Kubernetes v1.34.0 |
| Sauvegarde | `D:\backup\socle-sandbox-v1-<date>\` : `fichiers-locaux.7z` (chiffré), `nexus-data.tgz` |
| Dépôts | `myc-public/*` clonés sous `D:\workspace\public` |

Restaurer les fichiers locaux (secrets Terraform, copies des secrets applicatifs, `local/.env`, `docs/ROADMAP.md`...) à leur place :
```powershell
& "C:\Program Files\7-Zip\7z.exe" x "D:\backup\socle-sandbox-v1-<date>\fichiers-locaux.7z" -o"D:\workspace\public"
```

## 1. Nexus et tunnel (poste local)

Si le volume `nexus-data` a été perdu :
```powershell
docker volume create nexus-data
docker run --rm -v nexus-data:/data -v "D:\backup\socle-sandbox-v1-<date>:/backup" alpine tar xzf /backup/nexus-data.tgz -C /data
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
Remove-Item terraform.tfstate, terraform.tfstate.backup -ErrorAction SilentlyContinue   # l'ancien state décrit un cluster disparu (sauvegardé)
terraform init
terraform apply                                            # crée BuildConfig / ImageStream / Deployment / Route
ocs start-build jenkins --from-dir=../jenkins-image --follow  # 1re fois : Terraform ne déclenche pas le build de l'image
terraform output jenkins_route_host
```
Attendu : pod `jenkins` 1/1, console Jenkins accessible sur `https://jenkins-<namespace>.<apps_domain>`.

## 4. Argo CD (minikube)

```powershell
minikube start --driver=docker --cpus=2 --memory=3072 --kubernetes-version=v1.34.0
cd D:\workspace\public\gitops-platform
k --context minikube apply --server-side --force-conflicts -k bootstrap/minikube-argocd/install
k --context minikube apply --server-side --field-manager=gitops-bootstrap -f bootstrap/minikube-argocd/argocd-cm-inclusions.yaml
k --context minikube get pods -n argocd                   # 6 pods 1/1 (dex à 0 réplica, voulu)
```

## 5. Identité d'Argo CD sur le cluster

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

Copies restaurées à l'étape 0 (modèles : `bootstrap/secrets/dev/*.example.yaml`) :
```powershell
ocs apply -f bootstrap/secrets/dev/donation-api-db-secret.dev.yaml
ocs apply -f bootstrap/secrets/dev/donation-api-management-secret.dev.yaml
ocs apply -f bootstrap/secrets/dev/observability-grafana-secret.dev.yaml   # compte admin Grafana (stack otel-lgtm)
```

## 7. Premier build Jenkins

Lancer le job `inner-donation-api` (branche `main`) : il publie le jar dans Nexus, construit l'image dans le nouveau registry et commite le nouveau `newTag` dans `gitops-platform` (`main`).
À faire **avant** l'étape 8 : l'overlay référence sinon une image absente du nouveau registry (`ImagePullBackOff`).

## 8. App-of-apps

```powershell
k --context minikube apply -f bootstrap/root.yaml
k --context minikube get applications -n argocd           # root + donation-api-dev : Synced / Healthy (≈ 3 min)
```

## 9. Recette

```powershell
$h = "https://" + (ocs get route donation-api -o jsonpath='{.spec.host}')
ocs get pods                                              # donation-api 1/1, donation-api-mysql 1/1
curl.exe -s -o NUL -w "health %{http_code}`n"  "$h/management/health"        # 200
curl.exe -s -o NUL -w "loggers %{http_code}`n" "$h/management/loggers"       # 401
curl.exe -s -o NUL -w "api-docs %{http_code}`n" "$h/docs/api-docs"           # 200
curl.exe -s "$h/management/info"                                             # build.version
```
Consigner le résultat dans `jenkins-on-openshift-with-terraform/docs/ROADMAP.md` (journal).
