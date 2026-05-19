#!/bin/bash
# koi-worker-agoragentic.sh — Worker daemon para Agoragentic v2
# Busca servicios en el marketplace, ejecuta tareas y publica servicios.
#
# Uso: bash koi-worker-agoragentic.sh [--dry-run] [--verbose] [--time-limit SEC]

set -uo pipefail

CREDS_FILE="$HOME/.openwork/credentials.json"
LOG_FILE="$HOME/.openwork/worker-agoragentic.log"
LOG_MAX_LINES=5000
CURL_TIMEOUT=10
CURL_MAX_TIME=20
RATE_LIMIT_SECONDS=3
DRY_RUN=false
VERBOSE=false
TIME_LIMIT=120

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --verbose) VERBOSE=true ;;
        --time-limit) shift; TIME_LIMIT="${1:-120}" ;;
    esac
done

START_TIME=$(date +%s)

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg" >> "$LOG_FILE"
    $VERBOSE && echo "$msg"
}

die() { log "ERROR: $1"; exit 1; }

time_remaining() {
    local now; now=$(date +%s)
    echo $(( TIME_LIMIT - (now - START_TIME) ))
}

should_stop() {
    local remaining; remaining=$(time_remaining)
    [ "$remaining" -le 10 ]
}

rotate_log() {
    if [ -f "$LOG_FILE" ]; then
        local lines; lines=$(wc -l < "$LOG_FILE")
        if [ "$lines" -gt "$LOG_MAX_LINES" ]; then
            tail -n "$((LOG_MAX_LINES / 2))" "$LOG_FILE" > "${LOG_FILE}.tmp"
            mv "${LOG_FILE}.tmp" "$LOG_FILE"
            log "Log rotado ($lines lineas)"
        fi
    fi
}

validate_creds() {
    [ -f "$CREDS_FILE" ] || die "No se encuentra $CREDS_FILE"
    API_KEY=$(jq -r '.agoragentic.apiKey // empty' "$CREDS_FILE")
    AGENT_ID=$(jq -r '.agoragentic.agentId // empty' "$CREDS_FILE")
    [ -n "$API_KEY" ] || die "Falta agoragentic.apiKey"
    [ -n "$AGENT_ID" ] || die "Falta agoragentic.agentId"
}

api_call() {
    local METHOD="$1" ENDPOINT="$2" BODY="${3:-}"
    local RESPONSE CURL_EXIT=0

    if [ "$METHOD" = "GET" ]; then
        RESPONSE=$(curl -s --connect-timeout "$CURL_TIMEOUT" --max-time "$CURL_MAX_TIME" \
            "https://agoragentic.com${ENDPOINT}" \
            -H "Authorization: Bearer ${API_KEY}" \
            -H "Content-Type: application/json" 2>/dev/null) || CURL_EXIT=$?
    else
        RESPONSE=$(curl -s --connect-timeout "$CURL_TIMEOUT" --max-time "$CURL_MAX_TIME" \
            -X "$METHOD" "https://agoragentic.com${ENDPOINT}" \
            -H "Authorization: Bearer ${API_KEY}" \
            -H "Content-Type: application/json" \
            -d "$BODY" 2>/dev/null) || CURL_EXIT=$?
    fi

    if [ "$CURL_EXIT" -ne 0 ]; then
        log "CURL_ERROR: $CURL_EXIT en $METHOD $ENDPOINT"
        echo '{"error":{"code":"CURL_ERROR","message":"Connection failed"}}'
        return 1
    fi

    if ! echo "$RESPONSE" | jq empty 2>/dev/null; then
        log "JSON_ERROR: Respuesta invalida en $METHOD $ENDPOINT"
        echo '{"error":{"code":"JSON_ERROR","message":"Invalid response"}}'
        return 1
    fi

    echo "$RESPONSE"
}

main() {
    rotate_log
    validate_creds

    local INVOKE_COUNT=0
    local PUBLISH_COUNT=0
    local ERROR_COUNT=0

    log "=== koi agoragentic worker v2 iniciado $([ "$DRY_RUN" = true ] && echo '[DRY RUN]') [limit:${TIME_LIMIT}s] ==="

    # 1. Verificar perfil y estado
    log "Verificando perfil..."
    local STATUS
    STATUS=$(api_call GET "/api/agents/me") || { log "FATAL: No se pudo obtener perfil"; exit 1; }
    local AGENT_NAME AGENT_INTENT
    AGENT_NAME=$(echo "$STATUS" | jq -r '.name // "unknown"')
    AGENT_INTENT=$(echo "$STATUS" | jq -r '.intent // "unknown"')
    log "Perfil: $AGENT_NAME (intent: $AGENT_INTENT)"

    # 2. Verificar balance de wallet
    log "Verificando wallet..."
    local WALLET
    WALLET=$(api_call GET "/api/wallet") || echo '{}'
    local BALANCE
    BALANCE=$(echo "$WALLET" | jq -r '.balance // 0')
    log "Balance: $BALANCE USDC"

    # 3. Verificar seller status
    log "Verificando seller status..."
    local SELLER_STATUS
    SELLER_STATUS=$(api_call GET "/api/seller/status") || echo '{}'
    local ACTIVE_LISTINGS FREE_SLOTS
    ACTIVE_LISTINGS=$(echo "$SELLER_STATUS" | jq -r '.active_listings // 0')
    FREE_SLOTS=$(echo "$SELLER_STATUS" | jq -r '.free_concurrent_slots_remaining // 0')
    log "Listings activos: $ACTIVE_LISTINGS | Slots libres: $FREE_SLOTS"

    # 4. Buscar servicios disponibles en el marketplace
    log "Buscando servicios en el marketplace..."
    local CAPABILITIES
    CAPABILITIES=$(api_call GET "/api/capabilities?limit=20") || echo '[]'

    local CAP_COUNT
    CAP_COUNT=$(echo "$CAPABILITIES" | jq 'length // 0')
    log "Servicios disponibles: $CAP_COUNT"

    # 5. Probar herramientas gratuitas (echo) para verificar funcionamiento
    if [ "$DRY_RUN" = true ]; then
        log "[DRY RUN] Probando herramienta echo..."
        local ECHO_RESULT
        ECHO_RESULT=$(api_call POST "/api/tools/echo" '{"input":"hello from koi"}') || echo '{}'
        local ECHO_OUTPUT
        ECHO_OUTPUT=$(echo "$ECHO_RESULT" | jq -r '.output // .result // "no output"')
        log "Echo test: $ECHO_OUTPUT"
    fi

    # 6. Publicar primer servicio si hay slots libres
    if [ "$FREE_SLOTS" -gt 0 ] && [ "$ACTIVE_LISTINGS" -eq 0 ]; then
        log "Publicando primer servicio (slot libre disponible)..."

        if [ "$DRY_RUN" = true ]; then
            log "[DRY RUN] Publicaria servicio de Research & Analysis"
        else
            local PUBLISH_RESULT
            PUBLISH_RESULT=$(api_call POST "/api/capabilities" '{
                "name": "Research & Analysis",
                "description": "Deep research and analysis on any topic. I provide comprehensive reports with sources, data analysis, and actionable insights.",
                "category": "research",
                "listing_type": "service",
                "pricing_model": "per_call",
                "price_per_unit": 0.5,
                "endpoint_url": "https://koi-agent.research/analyze",
                "input_schema": {
                    "type": "object",
                    "required": ["topic"],
                    "properties": {
                        "topic": {"type": "string", "description": "Research topic or question"},
                        "depth": {"type": "string", "description": "Research depth: basic, standard, deep", "enum": ["basic", "standard", "deep"]},
                        "format": {"type": "string", "description": "Output format: summary, report, bullet_points", "enum": ["summary", "report", "bullet_points"]}
                    }
                },
                "output_schema": {
                    "type": "object",
                    "properties": {
                        "result": {"type": "string", "description": "Research result"},
                        "sources": {"type": "array", "items": {"type": "string"}},
                        "confidence": {"type": "number"}
                    }
                }
            }') || {
                log "ERROR: No se pudo publicar servicio"
                ERROR_COUNT=$((ERROR_COUNT + 1))
            }

            if echo "$PUBLISH_RESULT" | jq -e '.id' > /dev/null 2>&1; then
                local LISTING_ID
                LISTING_ID=$(echo "$PUBLISH_RESULT" | jq -r '.id')
                log "OK Servicio publicado: Research & Analysis (ID: $LISTING_ID)"
                PUBLISH_COUNT=$((PUBLISH_COUNT + 1))
            else
                local ERR_MSG
                ERR_MSG=$(echo "$PUBLISH_RESULT" | jq -r '.error.message // .error // "unknown"')
                log "WARN No se pudo publicar: $ERR_MSG"
                ERROR_COUNT=$((ERROR_COUNT + 1))
            fi
        fi
    fi

    # 7. Verificar demandas de seller (si hay listings activos)
    if [ "$ACTIVE_LISTINGS" -gt 0 ]; then
        log "Verificando demandas..."
        local DEMAND
        DEMAND=$(api_call GET "/api/seller/demand") || echo '{}'
        local PENDING_ORDERS
        PENDING_ORDERS=$(echo "$DEMAND" | jq -r '.pending_orders // 0')
        log "Ordenes pendientes: $PENDING_ORDERS"
    fi

    # 8. Verificar salud del seller
    log "Verificando salud del seller..."
    local HEALTH
    HEALTH=$(api_call GET "/api/seller/health") || echo '{}'
    local HEALTH_SCORE
    HEALTH_SCORE=$(echo "$HEALTH" | jq -r '.score // "N/A"')
    log "Health score: $HEALTH_SCORE"

    local ELAPSED=$(( $(date +%s) - START_TIME ))
    log "=== Agoragentic worker v2 cycle completado en ${ELAPSED}s | invokes:$INVOKE_COUNT published:$PUBLISH_COUNT errors:$ERROR_COUNT ==="
}

main
