#!/usr/bin/env bash
# Vérifie la plateforme d'un étudiant du cours DevOps avancé.
#
# À lancer depuis la racine de ton dépôt, cluster démarré :
#   curl -fsSL https://raw.githubusercontent.com/DeepSnowNeeL/devops-avance-support/main/verifier.sh | bash
#
# Le script ne modifie rien dans ton dépôt. Dans le cluster, il fait trois actions :
#   - case 4  : il supprime le déploiement "api" de "dev" pour constater qu'ArgoCD le recrée ;
#   - case 8  : il règle l'API de "dev" à 100 % d'erreurs le temps que l'alerte se déclenche,
#               puis la remet à 0 % ;
#   - case 10 : il tente de créer deux pods en essai à blanc (--dry-run=server) : rien n'est créé.
#
# Tout le script est dans des fonctions, appelées par la dernière ligne : un téléchargement
# interrompu n'exécute rien.

CTX="kind-plateforme"
ATTENTE_SELF_HEAL="${ATTENTE_SELF_HEAL:-180}" # secondes
ATTENTE_ALERTE="${ATTENTE_ALERTE:-240}"       # secondes
INTERVALLE="${INTERVALLE:-3}"                 # secondes entre deux essais
KUSTOMIZATION_DEV="deploy/overlays/dev/kustomization.yaml"
RAISON=""

# Les sous-commandes ne lisent jamais l'entrée standard : avec "curl | bash", c'est le script.
k() { kubectl --context "$CTX" --request-timeout=8s "$@" </dev/null 2>/dev/null; }
tf() { "$TF" -chdir=infra "$@" </dev/null 2>/dev/null; }
suivis() { git ls-files -- "$@" </dev/null 2>/dev/null; }

arret() {
  echo "ARRÊT : $1" >&2
  [ -n "${2:-}" ] && echo "$2" >&2
  echo "Aucune case n'a été vérifiée." >&2
  exit 2
}

verifier_prerequis() {
  command -v git >/dev/null 2>&1 || arret "git est introuvable."
  command -v kubectl >/dev/null 2>&1 || arret "kubectl est introuvable."
  if command -v terraform >/dev/null 2>&1; then TF=terraform
  elif command -v tofu >/dev/null 2>&1; then TF=tofu
  else arret "ni terraform ni tofu n'est installé."; fi

  git rev-parse --git-dir >/dev/null 2>&1 </dev/null \
    || arret "ce répertoire n'est pas un dépôt git." "Lance le script depuis la racine de ton dépôt."
  [ -z "$(git rev-parse --show-prefix </dev/null 2>/dev/null)" ] && [ -d infra ] && [ -d deploy ] \
    || arret "le script doit être lancé depuis la racine du dépôt (là où se trouvent infra/ et deploy/)."

  local sale
  sale="$(git status --porcelain </dev/null 2>/dev/null)"
  [ -z "$sale" ] || arret "des modifications ne sont pas commitées :" "$sale"

  git fetch --quiet </dev/null 2>/dev/null
  local amont
  amont="$(git rev-parse '@{u}' </dev/null 2>/dev/null)" \
    || arret "la branche courante n'a pas de branche distante." "Pousse-la : git push -u origin $(git branch --show-current </dev/null)"
  [ "$(git rev-parse HEAD </dev/null)" = "$amont" ] \
    || arret "le dépôt local et le dépôt distant diffèrent." "Fais git pull puis git push avant de relancer."
}

# Chaque case renvoie 0 si elle est validée. Sinon elle renvoie 1 et renseigne RAISON.

case_1() {
  local etat
  etat="$(tf state list)"
  printf '%s\n' "$etat" | grep -q 'kind_cluster\.' \
    || { RAISON="aucun cluster kind dans le state Terraform (infra/)"; return 1; }
  printf '%s\n' "$etat" | grep -q 'helm_release\.' \
    || { RAISON="aucune release Helm dans le state Terraform (infra/)"; return 1; }
  local dispo
  dispo="$(k -n argocd get deploy argocd-server -o jsonpath='{.status.availableReplicas}')"
  [ "${dispo:-0}" -ge 1 ] 2>/dev/null \
    || { RAISON="argocd-server n'est pas disponible dans le cluster $CTX"; return 1; }
}

case_2() {
  [ -n "$(suivis 'infra/modules/*/*.tf')" ] \
    || { RAISON="aucun module dans infra/modules/ (ou il n'est pas commité)"; return 1; }
  suivis 'infra/*.tf' | while IFS= read -r f; do grep -Eq '^[[:space:]]*module[[:space:]]+"' "$f" && echo oui; done | grep -q oui \
    || { RAISON="aucun bloc module dans les fichiers de infra/"; return 1; }
  [ -n "$(suivis 'infra/*.tfvars')" ] \
    || { RAISON="aucun fichier .tfvars commité dans infra/"; return 1; }
}

case_3() {
  local app etat
  for app in api-dev api-prod; do
    etat="$(k -n argocd get application "$app" -o jsonpath='{.status.sync.status} {.status.health.status}')"
    [ "$etat" = "Synced Healthy" ] \
      || { RAISON="l'application $app est « ${etat:-introuvable} », attendu « Synced Healthy »"; return 1; }
  done
}

case_4() {
  k -n argocd get application api-dev -o jsonpath='{.status.sync.status} {.status.health.status}' >/dev/null \
    || { RAISON="l'application ArgoCD api-dev est introuvable, rien n'a été supprimé"; return 1; }
  local avant apres uid dispo ecoule=0
  avant="$(k -n dev get deploy api -o jsonpath='{.metadata.uid} {.status.availableReplicas}')"
  avant="${avant%% *}"
  [ -n "$avant" ] || { RAISON="le déploiement api est introuvable dans dev"; return 1; }
  k -n dev delete deploy api --wait=true >/dev/null
  while [ "$ecoule" -lt "$ATTENTE_SELF_HEAL" ]; do
    sleep "$INTERVALLE"
    ecoule=$((ecoule + INTERVALLE))
    apres="$(k -n dev get deploy api -o jsonpath='{.metadata.uid} {.status.availableReplicas}')" || continue
    uid="${apres%% *}"
    dispo="${apres#* }"
    if [ -n "$uid" ] && [ "$uid" != "$avant" ] && [ "${dispo:-0}" -ge 1 ] 2>/dev/null; then return 0; fi
  done
  RAISON="le déploiement api supprimé n'a pas été recréé par ArgoCD en ${ATTENTE_SELF_HEAL} s. Pour le restaurer : kubectl apply -k deploy/overlays/dev"
  return 1
}

# Tag déployé en dev selon git, et commit qui l'a écrit (même si le fichier a changé depuis).
tag_dev() {
  sed -n 's/^[[:space:]]*newTag:[[:space:]]*//p' "$KUSTOMIZATION_DEV" 2>/dev/null | tr -d "\"'\r" | head -n 1
}
commit_du_tag() {
  git log -1 --format="$2" -S"newTag: $1" -- "$KUSTOMIZATION_DEV" </dev/null 2>/dev/null
}

case_5() {
  local tag image auteur
  tag="$(tag_dev)"
  [ -n "$tag" ] || { RAISON="aucun newTag dans $KUSTOMIZATION_DEV"; return 1; }
  [ "$tag" != "initial" ] || { RAISON="le tag de dev est encore « initial » : le pipeline n'a jamais déployé"; return 1; }
  auteur="$(commit_du_tag "$tag" %an)"
  [ "$auteur" = "pipeline-ci" ] \
    || { RAISON="le tag « $tag » a été écrit dans git par « $auteur », attendu « pipeline-ci »"; return 1; }
  image="$(k -n dev get deploy api -o jsonpath='{.spec.template.spec.containers[0].image}')"
  [ "${image##*:}" = "$tag" ] \
    || { RAISON="dev exécute « ${image:-rien} » alors que git demande le tag « $tag »"; return 1; }
}

case_6() {
  git grep -q 'kind: SealedSecret' -- deploy </dev/null 2>/dev/null \
    || { RAISON="aucun SealedSecret commité sous deploy/"; return 1; }
  local fuite
  fuite="$(git grep -lE '^kind:[[:space:]]*Secret[[:space:]]*$' </dev/null 2>/dev/null | head -n 1)"
  [ -z "$fuite" ] || { RAISON="un Secret en clair est commité : $fuite"; return 1; }
  local proprietaire refs
  proprietaire="$(k -n dev get secret api-secret -o jsonpath='{.metadata.ownerReferences[0].kind}')" \
    || { RAISON="le secret api-secret est introuvable dans dev"; return 1; }
  [ "$proprietaire" = "SealedSecret" ] \
    || { RAISON="le secret api-secret n'a pas été créé par un SealedSecret"; return 1; }
  refs="$(k -n dev get deploy api -o jsonpath='{.spec.template.spec.containers[*].envFrom[*].secretRef.name} {.spec.template.spec.containers[*].env[*].valueFrom.secretKeyRef.name}')"
  case " $refs " in
    *" api-secret "*) return 0 ;;
  esac
  RAISON="le déploiement api ne consomme pas le secret api-secret"
  return 1
}

case_7() {
  local f trouve=""
  for f in $(git grep -l 'grafana_dashboard' -- deploy </dev/null 2>/dev/null); do
    grep -q 'http_requests_total' "$f" && trouve="$f"
  done
  [ -n "$trouve" ] \
    || { RAISON="aucun ConfigMap commité sous deploy/ avec l'étiquette grafana_dashboard et une requête sur http_requests_total"; return 1; }
  k get configmap -A -l grafana_dashboard -o jsonpath='{range .items[*]}{.data}{end}' | grep -q 'http_requests_total' \
    || { RAISON="le tableau de bord n'est pas dans le cluster (ArgoCD l'a-t-il synchronisé ?)"; return 1; }
  local dispo
  dispo="$(k -n supervision get deploy -l app.kubernetes.io/name=grafana -o jsonpath='{.items[*].status.availableReplicas}')"
  [ "${dispo:-0}" -ge 1 ] 2>/dev/null \
    || { RAISON="Grafana n'est pas disponible dans le namespace supervision"; return 1; }
}

PROMETHEUS="/api/v1/namespaces/supervision/services/http:prometheus-operated:9090/proxy"
API_DEV="/api/v1/namespaces/dev/services/http:api:80/proxy"

etat_alerte() {
  # Une alerte par ligne, puis l'état de celle qui nous intéresse (sans dépendre de jq).
  k get --raw "$PROMETHEUS/api/v1/alerts" | tr -d '\n' | sed 's/},{"labels"/}\
{"labels"/g' \
    | grep '"alertname":"BudgetErreurApi"' | grep -o '"state":"[a-z]*"' \
    | sed 's/"state":"\([a-z]*\)"/\1/' | head -n 1
}

case_8() {
  k get --raw "$PROMETHEUS/api/v1/rules" | grep -q '"name":"BudgetErreurApi"' \
    || { RAISON="aucune alerte BudgetErreurApi chargée dans Prometheus (namespace supervision)"; return 1; }
  [ "$(etat_alerte)" != "firing" ] \
    || { RAISON="l'alerte BudgetErreurApi est déjà déclenchée avant le test : attends qu'elle retombe (2 à 3 minutes) et relance"; return 1; }
  k get --raw "$API_DEV/chaos?erreurs=1" >/dev/null \
    || { RAISON="impossible de joindre /chaos sur le service api de dev"; return 1; }
  local ecoule=0 resultat=1
  while [ "$ecoule" -lt "$ATTENTE_ALERTE" ]; do
    for _ in 1 2 3 4 5; do k get --raw "$API_DEV/" >/dev/null; done
    if [ "$(etat_alerte)" = "firing" ]; then resultat=0; break; fi
    sleep "$INTERVALLE"
    ecoule=$((ecoule + INTERVALLE))
  done
  k get --raw "$API_DEV/chaos?erreurs=0" >/dev/null
  [ "$resultat" = 0 ] \
    || RAISON="100 % d'erreurs injectées pendant ${ATTENTE_ALERTE} s, l'alerte BudgetErreurApi ne s'est pas déclenchée"
  return "$resultat"
}

case_9() {
  local wf
  wf="$(suivis '.github/workflows/*.yml' '.github/workflows/*.yaml')"
  [ -n "$wf" ] || { RAISON="aucun workflow dans .github/workflows/"; return 1; }
  # shellcheck disable=SC2086
  grep -qi 'trivy' $wf || { RAISON="aucun scan Trivy dans le workflow"; return 1; }
  # shellcheck disable=SC2086
  grep -Eq "exit-code:[[:space:]]*[\"']?1|--exit-code[[:space:]]+1" $wf \
    || { RAISON="le scan Trivy n'est pas bloquant (exit-code 1)"; return 1; }
  local introduction deploiement tag
  introduction="$(git log -1 --format=%H -G "[Tt]rivy" -- .github/workflows </dev/null 2>/dev/null)"
  tag="$(tag_dev)"
  deploiement="$(commit_du_tag "$tag" %H)"
  [ -n "$deploiement" ] && [ "$(commit_du_tag "$tag" %an)" = "pipeline-ci" ] \
    || { RAISON="l'image de dev n'a pas été déployée par le pipeline"; return 1; }
  [ "$introduction" != "$deploiement" ] && git merge-base --is-ancestor "$introduction" "$deploiement" </dev/null 2>/dev/null \
    || { RAISON="l'image de dev a été déployée avant la dernière modification du scan : pousse un commit dans app/ pour qu'elle passe le scan"; return 1; }
}

case_10() {
  local essai="verif-$$" refus
  local conforme='{"spec":{"containers":[{"name":"verif","image":"nginx:1.27","resources":{"requests":{"cpu":"10m","memory":"16Mi"},"limits":{"cpu":"100m","memory":"64Mi"}}}]}}'
  refus="$(kubectl --context "$CTX" --request-timeout=8s -n dev run "$essai" --image=nginx:1.27 --dry-run=server </dev/null 2>&1)" \
    && { RAISON="un pod sans resources.limits est accepté dans dev"; return 1; }
  case "$refus" in
    *admission*) ;;
    *) RAISON="l'essai n'a pas pu être fait : $(printf '%s' "$refus" | head -n 1)"; return 1 ;;
  esac
  k -n dev run "$essai" --image=nginx:1.27 --dry-run=server --overrides="$conforme" >/dev/null \
    || { RAISON="un pod conforme (requests et limits déclarées) est refusé lui aussi : la politique refuse tout"; return 1; }
}

LIBELLES="Cluster et ArgoCD issus de Terraform
Module et variables Terraform
Application en dev et prod par ArgoCD
Self-heal : un déploiement supprimé revient
Déploiement par le pipeline
Secret scellé dans git
Tableau de bord RED
SLO et alerte
Scan d'images bloquant
Politique d'admission"
# Ordre d'évaluation : les cases qui agissent sur la plateforme passent en dernier (8 injecte
# des erreurs, 4 supprime un déploiement), pour que leur échec ne fasse pas tomber les autres.
# L'affichage reste dans l'ordre de la grille.
ORDRE="1 2 3 5 6 7 9 10 8 4"

main() {
  verifier_prerequis
  echo "Vérification de la plateforme (cluster $CTX). Compte deux à quatre minutes."
  echo
  local n code="" points=0 libelle ok depot commit
  for n in $ORDRE; do
    RAISON=""
    if "case_$n"; then eval "ok_$n=1"; else eval "ok_$n=0"; fi
    eval "raison_$n=\$RAISON"
  done
  n=1
  while [ "$n" -le 10 ]; do
    libelle="$(printf '%s\n' "$LIBELLES" | sed -n "${n}p")"
    eval "ok=\$ok_$n"
    if [ "$ok" = 1 ]; then
      printf '[ OK ] %2d. %s\n' "$n" "$libelle"
      code="${code}1"
      points=$((points + 2))
    else
      eval "RAISON=\$raison_$n"
      printf '[ECHEC] %2d. %s\n         %s\n' "$n" "$libelle" "$RAISON"
      code="${code}0"
    fi
    n=$((n + 1))
  done
  depot="$(git remote get-url origin </dev/null 2>/dev/null)"
  commit="$(git rev-parse --short=7 HEAD </dev/null)"
  echo
  echo "Dépôt : $depot @ $commit"
  echo "Date  : $(date '+%Y-%m-%d %H:%M')"
  echo "Score : $points/20"
  echo "Code : $code"
  echo
  echo "Relevé : $code $depot $commit"
}

main "$@"
