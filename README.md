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
| `/healthz` | sonde de disponibilité |
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
[ -- ]   7. Tableau de bord RED (seconde journée)
...
Score : 4/20
Code : 1100000000
```

- `[ OK ]` : la case est validée.
- `[ECHEC]` : elle ne l'est pas, la ligne suivante dit pourquoi.
- `[ -- ]` : la case n'est pas encore vérifiée par cette version du script.

Lance-le aussi souvent que tu veux. Pour la note, tu le lances devant le formateur.

### Ce que fait le script

Il **lit** ton dépôt et ton cluster. Il ne modifie rien dans ton dépôt. Dans le cluster, il
fait une seule action : il supprime le déploiement `api` du namespace `dev`, pour constater
qu'ArgoCD le recrée. Si ArgoCD ne le recrée pas, le script t'indique la commande pour le
restaurer.

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
