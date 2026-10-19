# DevOps avancé : support du cours

Ce dépôt contient deux choses : l'application que tu déploies pendant le cours, et le script
qui vérifie ta plateforme.

## L'application (`app/`)

Une petite API Python, à copier dans le dossier `app/` de ton dépôt :

```bash
git clone https://github.com/DeepSnowNeeL/devops-avance-support.git /tmp/support
cp /tmp/support/app/* app/
```

| Route | Rôle |
|---|---|
| `/` | réponse JSON : nom du service, version, présence du secret `JETON` |
| `/healthz` | readiness probe |
| `/metrics` | métriques Prometheus : `http_requests_total`, `http_request_duration_seconds` |
| `/chaos?erreurs=0.3&latence=500` | règle le taux d'erreurs (0 à 1) et la latence ajoutée (en ms) |

Elle écoute sur le port **8080**.

## Les règles d'usage de l'IA (`racine/`)

`AGENTS.md` et `CLAUDE.md` sont à copier **à la racine de ton dépôt** :

```bash
cp /tmp/support/racine/AGENTS.md /tmp/support/racine/CLAUDE.md .
```

Les assistants de code (Claude Code, Copilot, Cursor, Codex...) les lisent automatiquement.
Ils leur demandent de t'expliquer les choses plutôt que de construire la plateforme à ta place :
c'est la règle du cours, et tu seras interrogé sur ta plateforme.

## Le script de vérification (`verifier.sh`)

Depuis **la racine de ton dépôt**, cluster démarré, tout commité et poussé :

```bash
curl -fsSL https://raw.githubusercontent.com/DeepSnowNeeL/devops-avance-support/main/verifier.sh | bash
```

Il affiche une ligne par case de la grille, puis ton score et un code de dix chiffres :

```text
[ OK ]   1. Cluster et ArgoCD issus de Terraform
[ECHEC]  3. Application en dev et prod par ArgoCD
         l'application api-dev est « introuvable », attendu « Synced Healthy »
...
Score : 4/20
Code : 1100000000

Relevé : 1100000000 https://github.com/<toi>/<ton-depot>.git a1b2c3d
```

- `[ OK ]` : la case est validée.
- `[ECHEC]` : elle ne l'est pas, la ligne suivante dit pourquoi.
- Les cases des TP que tu n'as pas encore faits sont en `[ECHEC]` : c'est normal.
- La dernière ligne, le **relevé**, est ce que le formateur recopie.

Lance-le aussi souvent que tu veux. Pour la note, tu le lances devant le formateur.

### Ce que fait le script

Il **lit** ton dépôt et ton cluster. Il ne modifie rien dans ton dépôt. Dans le cluster, il
fait trois actions :

- il supprime le déploiement `api` de `dev`, pour constater qu'ArgoCD le recrée. Sinon, il
  t'indique la commande pour le restaurer ;
- il règle l'API de `dev` à 100 % d'erreurs le temps que l'alerte `BudgetErreurApi` se
  déclenche, puis la remet à 0 % ;
- il tente de créer deux pods **en essai à blanc** (`--dry-run=server`) : rien n'est créé.

Il dure deux à quatre minutes. Après un passage, l'alerte met deux à trois minutes à retomber :
attends avant de le relancer.

Il refuse de démarrer si ton dépôt contient des modifications non commitées ou non poussées :
ce qui est vérifié, c'est ce qui est dans git.

### Les noms sur lesquels il s'appuie

| Élément | Valeur |
|---|---|
| Cluster kind | `plateforme` (contexte kubectl `kind-plateforme`) |
| Namespace d'ArgoCD | `argocd` |
| Namespaces applicatifs | `dev`, `prod` |
| Deployment et Service de l'application | `api` |
| Applications ArgoCD | `api-dev`, `api-prod` |
| Répertoires du dépôt | `infra/`, `app/`, `deploy/base/`, `deploy/overlays/dev/`, `deploy/overlays/prod/`, `deploy/argocd/`, `deploy/plateforme/` |
| Auteur des commits du pipeline | `pipeline-ci` |
| Secret consommé par l'application | `api-secret`, clé `JETON` |
| Namespace de la supervision | `supervision` |
| Dashboard Grafana | un `ConfigMap` avec le label `grafana_dashboard: "1"`, commité sous `deploy/` |
| Alerte du SLO | `BudgetErreurApi` |
