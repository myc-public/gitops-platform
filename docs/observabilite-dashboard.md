---
title: Dashboard v1 - donation-api (phase 4 Exploitation as code)
created: 2026-09-27
tags:
  - observabilité
  - grafana
  - slo
  - alertes
---

# Dashboard v1 - donation-api (phase 4 Exploitation as code)

Contenu validé le 27/09 (cf. [roadmap observabilité](https://github.com/myc-public/platform-handbook/blob/develop/roadmap/observabilite.md), phase 4).
Implémentation : `gitops-platform/apps/observability` (dashboard JSON, règles d'alerte et datasources provisionnés depuis Git).

## Avant / après

| | Avant (b31) | Après phase 4 |
|---|---|---|
| Dashboards | Aucun (Explore à la main) | 1 dashboard « donation-api — Service » versionné |
| Alertes | Aucune | 6 règles Grafana versionnées |
| Corrélation | `trace_id` copié à la main dans Loki | Clic log → trace, trace → logs, panneau → traces |
| SLO | Aucun | 2 SLO (disponibilité, latence) + budget d'erreur |

## Dashboard « donation-api — Service »

**Variables** : `job` (défaut `inner-apis/inner-donation-api`), `interval` (5m). Toutes les requêtes HTTP excluent `uri=~"/management.*"` (sondes).

### Ligne 1 — État de santé (stat)

| Panneau | Requête |
|---|---|
| Débit (req/s) | `sum(rate(http_server_requests_milliseconds_count{job="$job",uri!~"/management.*"}[5m]))` |
| Taux 5xx (%) | 5xx / total sur 5m (`status=~"5.."`) |
| Latence p95 (ms) | `histogram_quantile(0.95, sum by (le)(rate(http_server_requests_milliseconds_bucket{…}[5m])))` |
| Budget d'erreur restant (7 j) | `1 - (taux_erreur_7j / 0.01)` |
| Version déployée | `target_info{job="$job"}` → label `service_version` |
| Télémétrie reçue | `absent_over_time(target_info{job="$job"}[2m])` → OK / MUETTE |

### Ligne 2 — RED HTTP par route

- req/s par `uri` + `method`
- erreurs par `status` (4xx vs 5xx séparés)
- p50 / p95 / p99 par `uri` (timeseries)
- heatmap de latence (`_bucket`)

### Ligne 3 — SLO

- **SLO disponibilité** : 99 % des requêtes non-5xx, fenêtre glissante 7 jours
- **SLO latence** : 95 % des requêtes < 300 ms, 7 jours
- Burn rate 1h / 6h + budget restant (courbe)
- Prérequis : borne d'histogramme exacte à 300 ms (`management.metrics.distribution.slo.http.server.requests: 300ms` dans `application.yml`) ; sans elle, les buckets par défaut sautent de 268 à 358 ms.

### Ligne 4 — Métier (événements du domaine)

- Dons créés / min par `category` : `sum by (category)(rate(donations_created_total[5m]))`
- Montant moyen par catégorie : `donations_amount_sum / donations_amount_count`
- `domain_events_total` par `event_type`
- **Backlog outbox : reporté** (capacité 9b). `outbox_event` n'a pas de `published_at` et aucun relais ne consomme : « en attente » = toutes les lignes, un compteur monotone sans valeur. À faire avec le relais Kafka / CDC.

### Ligne 5 — Ressources

- JVM heap (utilisé / max), pauses GC, threads
- Pool Hikari : actives / en attente / timeouts
- CPU process

### Ligne 6 — Logs & traces

- `logback_events_total` par `level` (ERROR / WARN)
- Panneau Loki : `{service_name="inner-donation-api"} | json | level=~"ERROR|WARN"` (lien vers la trace)
- Table TraceQL traces en erreur : `{resource.service.name="inner-donation-api" && (status=error || span.outcome="SERVER_ERROR")}` — une 500 traitée par `ErrorHandlingAdvice` laisse le span HTTP en statut `unset` (`exception=none`), seul `outcome=SERVER_ERROR` la signale
- Table TraceQL traces lentes : `{… && duration > 300ms}`

## Alertes (Grafana-managed, pas PrometheusRule)

Les métriques arrivent en OTLP dans le Prometheus d'otel-lgtm ; le Prometheus UWM d'OpenShift (celui qui lit les `PrometheusRule`) ne les voit pas.

| # | Alerte | Condition | Sévérité |
|---|---|---|---|
| A1 | API muette | `target_info` absent depuis 2 min | critique |
| A2 | Taux 5xx | > 5 % sur 5 min pendant 2 min (trafic ≥ 0,1 req/s) | critique |
| A3 | Latence | p95 > 300 ms sur 10 min | warning |
| A4 | Base indisponible | Hikari `pending > 0` ou timeouts pendant 2 min | critique |
| A5 | Logs ERROR | `logback_events_total{level="error"}` > 0 sur 5 min | warning |
| A6 | Burn rate SLO | 1h & 5m > 14,4× (critique) ; 6h & 30m > 6× (warning) | critique / warning |

**Destination** : Grafana uniquement pour le pilote (pas de contact point externe ; webhook / e-mail plus tard avec secret hors Git).

## Corrélation (datasources provisionnées dans Git)

- **Loki → Tempo** : champ `trace_id` cliquable vers la trace.
- **Tempo → Loki** : « Logs for this span » filtré par `trace_id`.
- **Métriques → traces** : pas d'exemplars (le registre OTLP Micrometer n'en produit pas) → via les tables TraceQL de la ligne 6 ; span-metrics Tempo plus tard (capacité 10).

## Scénario de preuve (panne simulée)

1. MySQL à 0 réplica (action de test ponctuelle), trafic sur `GET /api/v1/donors/{id}`.
2. Dashboard : 5xx et Hikari en attente → alertes A2 et A4 se déclenchent.
3. Table « traces en erreur (5xx) » → trace `http get /api/v1/donors` de 30 s (timeout Hikari), `outcome=SERVER_ERROR` ; pas de span JDBC (aucune connexion obtenue).
4. « Logs for this span » → log ERROR `ErrorHandlingAdvice` « Could not open JPA EntityManager for transaction » + WARN Hibernate `SQLState 08S01`, même `trace_id`.
5. Argo CD (selfHeal, ~3 min) remet MySQL à 1 → alertes résolues.

## Décisions (validées le 27/09)

1. SLO : 99 % dispo, 95 % < 300 ms, fenêtre 7 j ; bucket 300 ms ajouté dans `application.yml`.
2. Backlog outbox reporté au relais / CDC.
3. Alertes visibles dans Grafana seulement (pas de contact point externe).
4. Panne simulée par mise à 0 de MySQL, restaurée par le selfHeal Argo.

## Test local du 27/09 (avant déploiement Sandbox)

Même image otel-lgtm (digest épinglé), mêmes fichiers de provisioning montés aux mêmes chemins, app `develop` + borne SLO, MySQL Compose, trafic ~8 req/s.

| Vérification | Résultat |
|---|---|
| Provisioning | Dashboard + 7 règles dans un seul dossier `donation-api` ; dashboards de l'image conservés |
| Requêtes PromQL du dashboard | 37 / 37 valides ; bucket `le="300"` présent |
| Noms de métriques | Conformes sauf `jvm_threads_live` / `jvm_threads_peak` (corrigé) |
| Loki / Tempo | Filtre `severity_text` OK (4xx en WARN) ; TraceQL OK (indexation ~2-3 min) |
| Rechargement à chaud du dashboard | OK (version 4 sans redémarrage) |
| Panne MySQL 00:02:47 | A5 firing 00:03:44, A4 00:05:42, A2 / A3 00:06:03, A6 rapide 00:07:09 |
| Trace → log | Trace 500 de 30 s → log ERROR même `trace_id` |
| Retour MySQL 00:06:52 | A4 résolue 00:09:12, autres à l'expiration de leur fenêtre (A6 lent : jusqu'à 6 h, attendu) |

Corrections apportées pendant le test : `__panelId__` obligatoire avec `__dashboardUid__` (Grafana refusait de démarrer), noms des métriques de threads, requête des traces en erreur, libellé « pas de trafic » au lieu de `NaN`.

**Point d'attention Sandbox** : le selfHeal Argo CD remet MySQL à 1 réplica en quelques secondes ; les alertes à 2 min risquent de ne pas se déclencher. Prévoir une panne plus longue (ex. suspendre l'auto-sync de l'application MySQL via `config.json`, dans Git, le temps du test).

**Dette** : marquer l'observation en erreur dans `ErrorHandlingAdvice` pour les 5xx (span HTTP en `status=error`), afin que `status=error` suffise et que Tempo compte les erreurs.

## Déploiement Sandbox du 27/09 (b33)

Dashboard provisionné, mais Prometheus et Tempo non enregistrés dans Grafana (alertes en `plugin not registered`). Cause : Grafana 13 met à jour au démarrage les plugins livrés dans l'image (13.1.7 → 13.2.1) ; sous l'UID aléatoire d'OpenShift, la suppression de l'ancienne version échoue (`unlinkat .../plugins-bundled/prometheus/1008.js: permission denied`) et le plugin reste désenregistré. Non reproductible en local (conteneur sous l'UID de l'image).

Correctif : `GF_PLUGINS_PREINSTALL_AUTO_UPDATE=false` (plugins figés par le digest de l'image). Vérifié : 18 datasources dont `prometheus` et `tempo`, 7 règles `health=ok`.
