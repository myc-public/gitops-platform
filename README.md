# gitops-platform

Source de vérité du déploiement (Argo CD / OpenShift GitOps). Ce dépôt ne contient **que de la configuration** : le code vit dans les dépôts applicatifs, les JARs dans Nexus, les images dans le registry interne OpenShift.

```
gitops-platform/
├── bootstrap/root.yaml            # Application "root" (app-of-apps), appliquée UNE fois à la main
├── argocd/
│   ├── projects/                  # AppProject : périmètre et droits par équipe
│   └── applicationsets/           # génère 1 Application par (app, environnement)
└── apps/
    └── <app>/
        ├── base/                  # manifests communs (Kustomize), image = nom logique
        └── overlays/
            └── <env>/             # dev | uat | preprod | prod
                ├── kustomization.yaml   # namespace + images (newName/newTag)
                └── config.json          # cluster, namespace, autoSync (lu par l'ApplicationSet)
```

## Règles

- **Git est la seule voie de changement.** Pas de `oc apply`/`oc edit` manuel sur les ressources gérées (`selfHeal` les annulerait).
- **Tags d'image immuables** (`<version>-<sha>-b<build>`), jamais `latest`. Jenkins ne modifie que la ligne `newTag` de `overlays/<env>/kustomization.yaml`.
- **Promotion** : `dev` = commit direct de Jenkins sur `main` (synchro automatique). `uat`/`preprod`/`prod` = branche `promote/...` poussée par Jenkins, **Pull Request** vers `main`, synchro manuelle en prod (`autoSync: false`).
- **Aucun secret dans Git.** `donation-api-db-secret` est créé hors dépôt ; cible : Sealed Secrets ou External Secrets.
- Moindre privilège : l'`AppProject` limite dépôts, namespaces et types de ressources.

## Bootstrap (une fois)

```bash
# 1. Autoriser Argo CD sur le namespace cible
oc label namespace gregorie769-dev argocd.argoproj.io/managed-by=openshift-gitops

# 2. Lancer l'app-of-apps : Argo CD crée ensuite AppProject + ApplicationSet + Applications
oc apply -f bootstrap/root.yaml
```

Si un environnement vit dans un **autre namespace** que celui du build, autoriser le pull de l'image :

```bash
oc policy add-role-to-group system:image-puller system:serviceaccounts:<ns-cible> -n <ns-build>
```

## Ajouter un environnement ou une application

1. Copier `apps/<app>/overlays/dev` vers `apps/<app>/overlays/<env>` ; adapter `namespace`, `newName` et `config.json`.
2. Ajouter le namespace dans `destinations` de `argocd/projects/inner-apis.yaml`.
3. Pour une nouvelle app : créer `apps/<app>/base`, puis ses overlays. L'ApplicationSet la découvre seul.
