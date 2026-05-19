#!/bin/bash
# koi-worker-mastodon.sh — Worker de promoción en Mastodon
# Publica contenido promocional de productos Gumroad y logros del agente.
#
# Uso: bash koi-worker-mastodon.sh [--dry-run] [--verbose]

set -uo pipefail

CREDS_FILE="$HOME/.openwork/credentials.json"
LOG_FILE="$HOME/.openwork/worker-mastodon.log"
DRY_RUN=false
VERBOSE=false

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --verbose) VERBOSE=true ;;
    esac
done

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg" >> "$LOG_FILE"
    $VERBOSE && echo "$msg"
}

die() { log "ERROR: $1"; exit 1; }

validate_creds() {
    [ -f "$CREDS_FILE" ] || die "No se encuentra $CREDS_FILE"
    ACCESS_TOKEN=$(jq -r '.mastodon.accessToken // empty' "$CREDS_FILE")
    [ -n "$ACCESS_TOKEN" ] || die "Falta mastodon.accessToken"
}

# Post a toot
post_toot() {
    local TEXT="$1"
    local VISIBILITY="${2:-public}"

    if [ "$DRY_RUN" = true ]; then
        log "[DRY RUN] Toot: ${TEXT:0:80}..."
        return 0
    fi

    local RESPONSE
    RESPONSE=$(curl -s --connect-timeout 10 --max-time 15 \
        "https://mastodon.social/api/v1/statuses" \
        -H "Authorization: Bearer ${ACCESS_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg text "$TEXT" --arg vis "$VISIBILITY" '{status: $text, visibility: $vis}')" 2>/dev/null)

    local ID
    ID=$(echo "$RESPONSE" | jq -r '.id // empty')
    if [ -n "$ID" ]; then
        log "OK Toot publicado (ID: $ID): ${TEXT:0:60}..."
        return 0
    else
        local ERR
        ERR=$(echo "$RESPONSE" | jq -r '.error // "unknown"')
        log "ERROR publicando toot: $ERR"
        return 1
    fi
}

main() {
    validate_creds

    log "=== koi mastodon worker iniciado $([ "$DRY_RUN" = true ] && echo '[DRY_RUN]') ==="

    # Verificar cuenta
    local ME
    ME=$(curl -s "https://mastodon.social/api/v1/accounts/verify_credentials" \
        -H "Authorization: Bearer ${ACCESS_TOKEN}" 2>/dev/null)
    local ACCT
    ACCT=$(echo "$ME" | jq -r '.acct // "unknown"')
    log "Cuenta: @$ACCT"

    # Seleccionar contenido basado en hora del día (3 posts diarios posibles)
    local HOUR
    HOUR=$(date +%H)
    local POST_INDEX=$(( HOUR / 8 ))  # 0=mañana, 1=tarde, 2=noche

    case $POST_INDEX in
        0) # Mañana — producto destacado del día
            post_toot "🔬 Research Prompt Pack — 50+ prompts optimizados para investigación profunda con IA.

Ideal para analistas, investigadores y creadores de contenido que quieren resultados estructurados y de calidad.

🔗 https://cesardaw.gumroad.com/l/koi-research-prompts

#AI #research #prompts #productividad"
            ;;
        1) # Tarde — automatización / n8n
            post_toot "⚡ n8n Content Pipeline — De investigación a blog post en minutos.

Template listo para usar que automatiza todo el flujo: research → outline → draft → publish.

🔗 https://cesardaw.gumroad.com/l/koi-n8n-workflow

#n8n #automation #content #IA"
            ;;
        2) # Noche — bundle / oferta
            post_toot "🎏 Bundle Completo koi — Todo lo que necesitas para trabajar con IA:

✅ Research Prompt Pack
✅ n8n Content Pipeline
✅ AI Agent Template
✅ Earn with AI Guide
🎁 Bonus exclusivos

🔗 https://cesardaw.gumroad.com/l/koi-complete-bundle

#AI #automation #Gumroad"
            ;;
    esac

    log "=== Mastodon worker cycle completado ==="
}

main
