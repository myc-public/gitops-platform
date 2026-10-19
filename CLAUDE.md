# gitops-platform

Source de vérité du déploiement (Argo CD sur minikube -> Sandbox OpenShift), pile locale et tests de bout en bout.
Lire d'abord [README.md](README.md). Règles communes du socle : `platform-handbook`.

## Commandes

- Rendu d'une application : `k kustomize apps/<app>/overlays/dev` (aucun apply : Argo CD synchronise depuis `main`).
- Realms : `python tools/check-realm-rbac.py` après toute modification de `apps/keycloak/**`.
- Pile locale : `local/stack/README.md` ; tests BFF : `tools/tests/sec-bff.ps1`.

## Règles propres à ce dépôt

- Tout changement passe par Git et Argo CD : jamais `oc apply`, `oc edit` ni `oc create` sur une ressource gérée.
  Seul `bootstrap/` s'applique à la main, avec `apply -f`, depuis des manifestes versionnés ou des copies hors Git.
- Aucun secret dans Git : seuls les `*.example.yaml` sont versionnés ; `*.dev.yaml` et `local/**/.env` ne sont
  jamais affichés ni écrasés.
- Tags d'image immuables ; Jenkins ne touche que `newTag` dans `overlays/<env>/kustomization.yaml`.
- `apps/keycloak/base/realm/*.yaml` est dans une ConfigMap générée : toute modification, même un commentaire,
  relance l'import du realm. Ne jamais écrire la syntaxe de substitution `$(env:NOM)` dans un commentaire.
- Nouveau type de ressource : AppProject (`namespaceResourceWhitelist`) et `argocd-cm-inclusions.yaml`.
- La pile locale monte les fichiers de `apps/` tels quels : un changement de config se teste d'abord en pile.
