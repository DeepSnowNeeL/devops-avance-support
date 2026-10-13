#!/usr/bin/env bash
# Vérifie la plateforme d'un étudiant du cours DevOps avancé.
#
# À lancer depuis la racine de ton dépôt, cluster démarré :
#   curl -fsSL https://raw.githubusercontent.com/DeepSnowNeeL/devops-avance-support/main/verifier.sh | bash
#
# Le script ne modifie rien dans ton dépôt. Dans le cluster, il fait une seule action :
# il supprime le déploiement "api" de "dev" pour constater qu'ArgoCD le recrée (case 4).
#
# Tout le script est dans des fonctions, appelées par la dernière ligne : un téléchargement
# interrompu n'exécute rien.

CTX="kind-plateforme"
ATTENTE_SELF_HEAL="${ATTENTE_SELF_HEAL:-180}" # secondes
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

case_5() {
  local tag image auteur
  tag="$(sed -n 's/^[[:space:]]*newTag:[[:space:]]*//p' "$KUSTOMIZATION_DEV" 2>/dev/null | tr -d "\"'\r" | head -n 1)"
  [ -n "$tag" ] || { RAISON="aucun newTag dans $KUSTOMIZATION_DEV"; return 1; }
  [ "$tag" != "initial" ] || { RAISON="le tag de dev est encore « initial » : le pipeline n'a jamais déployé"; return 1; }
  # Le commit qui a écrit ce tag, même si le fichier a été modifié depuis pour autre chose.
  auteur="$(git log -1 --format=%an -S"newTag: $tag" -- "$KUSTOMIZATION_DEV" </dev/null 2>/dev/null)"
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
CASES_ACTIVES=6
# Ordre d'évaluation : la case 4 supprime un déploiement, elle passe donc en dernier pour que
# son échec ne fasse pas tomber les cases qui lisent ce déploiement. L'affichage reste dans
# l'ordre de la grille.
ORDRE="1 2 3 5 6 4"

main() {
  verifier_prerequis
  echo "Vérification de la plateforme (cluster $CTX)"
  echo
  local n code="" points=0 libelle ok
  for n in $ORDRE; do
    RAISON=""
    if "case_$n"; then eval "ok_$n=1"; else eval "ok_$n=0"; fi
    eval "raison_$n=\$RAISON"
  done
  n=1
  while [ "$n" -le 10 ]; do
    libelle="$(printf '%s
' "$LIBELLES" | sed -n "${n}p")"
    if [ "$n" -gt "$CASES_ACTIVES" ]; then
      printf '[ -- ] %2d. %s (seconde journée)
' "$n" "$libelle"
      code="${code}0"
    else
      eval "ok=\$ok_$n"
      if [ "$ok" = 1 ]; then
        printf '[ OK ] %2d. %s
' "$n" "$libelle"
        code="${code}1"
        points=$((points + 2))
      else
        eval "RAISON=\$raison_$n"
        printf '[ECHEC] %2d. %s
         %s
' "$n" "$libelle" "$RAISON"
        code="${code}0"
      fi
    fi
    n=$((n + 1))
  done
  echo
  echo "Dépôt : $(git remote get-url origin </dev/null 2>/dev/null) @ $(git rev-parse --short=7 HEAD </dev/null)"
  echo "Date  : $(date '+%Y-%m-%d %H:%M')"
  echo "Score : $points/20"
  echo "Code : $code"
}

main "$@"
