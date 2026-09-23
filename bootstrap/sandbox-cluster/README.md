# Bootstrap RBAC sandbox pour Argo CD

Applique une seule fois, à la main, sur le sandbox (`ocs apply -f .`). Ne peut pas être synchronisé par Argo CD lui-même : paradoxe d'amorçage, ces ressources donnent à Argo CD les droits qu'il lui faut pour atteindre ce cluster — même statut que `bootstrap/root.yaml`.

Contenu : un ServiceAccount `argocd-deployer`, un RoleBinding scopé au seul namespace `gregorie769-dev` sur le ClusterRole `edit` (jamais cluster-admin), et un Secret de token de service account (aucune valeur en clair dans le fichier : Kubernetes remplit `data.token`/`data.ca.crt` après apply).
