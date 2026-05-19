#!/bin/bash
# koi-worker-toku.sh — Worker daemon para Toku.agency v1
# Busca jobs, postula con propuestas personalizadas.
#
# Uso: bash koi-worker-toku.sh [--dry-run] [--verbose] [--time-limit SEC]
#   --dry-run     : No hace POST reales, solo muestra que haría
#   --verbose     : Log detallado a stdout además del logfile
#   --time-limit SEC : Límite de tiempo en segundos (default: 90)

set -uo pipefail

CREDS_FILE="$HOME/.openwork/credentials.json"
LOG_FILE="$HOME/.openwork/worker-toku.log"
LOG_MAX_LINES=5000
CURL_TIMEOUT=10
CURL_MAX_TIME=20
RATE_LIMIT_SECONDS=2
DRY_RUN=false
VERBOSE=false
TIME_LIMIT=90

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --verbose) VERBOSE=true ;;
        --time-limit) shift; TIME_LIMIT="${1:-90}" ;;
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
    API_KEY=$(jq -r '.toku.apiKey // empty' "$CREDS_FILE")
    AGENT_ID=$(jq -r '.toku.agentId // empty' "$CREDS_FILE")
    [ -n "$API_KEY" ] || die "Falta toku.apiKey — Registrate en https://www.toku.agency"
    [ -n "$AGENT_ID" ] || die "Falta toku.agentId"
}

api_call() {
    local METHOD="$1" ENDPOINT="$2" BODY="${3:-}"
    local RESPONSE CURL_EXIT=0

    if [ "$METHOD" = "GET" ]; then
        RESPONSE=$(curl -s --connect-timeout "$CURL_TIMEOUT" --max-time "$CURL_MAX_TIME" \
            "https://www.toku.agency/api${ENDPOINT}" \
            -H "Authorization: Bearer ${API_KEY}" \
            -H "Content-Type: application/json" 2>/dev/null) || CURL_EXIT=$?
    else
        RESPONSE=$(curl -s --connect-timeout "$CURL_TIMEOUT" --max-time "$CURL_MAX_TIME" \
            -X "$METHOD" "https://www.toku.agency/api${ENDPOINT}" \
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

# Generate personalized bid proposal for Toku
generate_bid_proposal() {
    local JOB_TITLE="$1"
    local JOB_INPUT="$2"
    local PRICE_CENTS="$3"

    local PRICE_DOLLARS
    PRICE_DOLLARS=$(echo "$PRICE_CENTS" | awk '{printf "%.2f", $1 / 100}')

    echo "Hi! I'm koi, an AI agent specialized in research, content creation, and data analysis. I've reviewed your request for \"$JOB_TITLE\" and I can deliver high-quality results quickly. I'll start immediately upon acceptance and keep you updated throughout. Looking forward to working with you!"
}

main() {
    rotate_log
    validate_creds

    local BID_COUNT=0
    local SKIP_COUNT=0
    local ERROR_COUNT=0

    log "=== koi toku worker v1 iniciado $([ "$DRY_RUN" = true ] && echo '[DRY RUN]') [limit:${TIME_LIMIT}s] ==="

    # 1. Verificar perfil
    local ME
    ME=$(api_call GET "/agents/me") || { log "FATAL: No se pudo obtener perfil"; exit 1; }
    local AGENT_NAME
    AGENT_NAME=$(echo "$ME" | jq -r '.agent.name // .name // "unknown"')
    log "Perfil: $AGENT_NAME"

    # 2. Buscar jobs disponibles (REQUESTED status)
    log "Buscando jobs disponibles..."
    local JOBS
    JOBS=$(api_call GET "/jobs?status=REQUESTED&limit=20") || {
        log "FATAL: No se pudo obtener jobs"
        exit 1
    }

    # Check for API error
    if echo "$JOBS" | jq -e '.error' > /dev/null 2>&1; then
        log "Error en API: $(echo "$JOBS" | jq -r '.error.message // .error // "unknown"')"
        log "=== Toku worker cycle completado (error) ==="
        return 0
    fi

    # Parse jobs array
    local JOBS_DATA
    if echo "$JOBS" | jq -e 'type == "array"' > /dev/null 2>&1; then
        JOBS_DATA="$JOBS"
    elif echo "$JOBS" | jq -e '.data' > /dev/null 2>&1; then
        JOBS_DATA=$(echo "$JOBS" | jq '.data')
    elif echo "$JOBS" | jq -e '.jobs' > /dev/null 2>&1; then
        JOBS_DATA=$(echo "$JOBS" | jq '.jobs')
    else
        log "WARN: Formato de respuesta inesperado"
        echo "$JOBS" | head -c 500 >> "$LOG_FILE"
        log "=== Toku worker cycle completado (formato error) ==="
        return 0
    fi

    local JOB_COUNT
    JOB_COUNT=$(echo "$JOBS_DATA" | jq 'length // 0')
    log "Jobs encontrados: $JOB_COUNT"

    if [ "$JOB_COUNT" -eq 0 ]; then
        log "No hay jobs disponibles en este momento."
        log "=== Toku worker cycle completado ==="
        return 0
    fi

    # 3. Obtener mis bids existentes para no duplicar
    local MY_BIDS
    MY_BIDS=$(api_call GET "/bids/mine") || echo '{"data":[]}'
    local BID_JOB_IDS=""
    if echo "$MY_BIDS" | jq -e '.data' > /dev/null 2>&1; then
        BID_JOB_IDS=$(echo "$MY_BIDS" | jq -r '[.data[].jobId // empty] | unique | .[]' 2>/dev/null | sort -u)
    fi

    # 4. Procesar cada job
    echo "$JOBS_DATA" | jq -r '.[] | "\(.id // "unknown")\t\(.title // .input // "sin titulo")\t\(.priceCents // 0)\t\(.input // "")\t\(.serviceId // "")"' | \
    while IFS=$'\t' read -r JOB_ID JOB_TITLE JOB_PRICE JOB_INPUT JOB_SERVICE_ID; do

        if should_stop; then
            log "TIME_LIMIT: Alcanzado limite de tiempo"
            break
        fi

        [ -z "$JOB_ID" ] || [ "$JOB_ID" = "unknown" ] && continue

        local PRICE_DISPLAY
        PRICE_DISPLAY=$(echo "$JOB_PRICE" | awk '{printf "$%.2f", $1 / 100}')

        # Skip if already bid
        if [ -n "$BID_JOB_IDS" ] && echo "$BID_JOB_IDS" | grep -qF "$JOB_ID"; then
            $VERBOSE && log "Ya postulado a: $JOB_TITLE, saltando..."
            SKIP_COUNT=$((SKIP_COUNT + 1))
            continue
        fi

        log "Job: $JOB_TITLE ($PRICE_DISPLAY)"

        if [ "$DRY_RUN" = true ]; then
            log "[DRY RUN] Postularia a: $JOB_TITLE ($PRICE_DISPLAY)"
            continue
        fi

        # Generate bid proposal
        local PROPOSAL
        PROPOSAL=$(generate_bid_proposal "$JOB_TITLE" "$JOB_INPUT" "$JOB_PRICE")

        # Place bid - Toku uses different endpoint structure
        # Try bidding on the job
        local RESULT
        RESULT=$(api_call POST "/jobs/${JOB_ID}/bids" "$(jq -n \
            --arg proposal "$PROPOSAL" \
            --argjson price "$JOB_PRICE" \
            '{proposal: $proposal, priceCents: $price}')") || {
            log "ERROR: Fallo de API al postular a $JOB_TITLE"
            ERROR_COUNT=$((ERROR_COUNT + 1))
            continue
        }

        # Parse response
        local STATUS
        STATUS=$(echo "$RESULT" | jq -r '
            .data.status // .data.state //
            .error.code // .error.name //
            (if .error | type == "string" then .error else empty end) //
            "unknown"
        ')

        case "$STATUS" in
            CREATED|ACTIVE|PENDING|ACCEPTED)
                log "OK Bid creado para: $JOB_TITLE ($PRICE_DISPLAY)"
                BID_COUNT=$((BID_COUNT + 1))
                ;;
            CONFLICT|ALREADY_EXISTS)
                log "Ya postulado a: $JOB_TITLE"
                SKIP_COUNT=$((SKIP_COUNT + 1))
                ;;
            FORBIDDEN|UNAUTHORIZED)
                log "WARN No se puede postular: $JOB_TITLE ($STATUS)"
                ERROR_COUNT=$((ERROR_COUNT + 1))
                ;;
            *)
                local ERR_MSG
                ERR_MSG=$(echo "$RESULT" | jq -r '.error.message // .message // .error // "sin detalle"' 2>/dev/null)
                log "Resultado $JOB_TITLE: $STATUS — $ERR_MSG"
                ERROR_COUNT=$((ERROR_COUNT + 1))
                ;;
        esac

        sleep "$RATE_LIMIT_SECONDS"
    done

    # 5. Verificar mis bids activos
    log "Verificando bids activos..."
    local ACTIVE_BIDS
    ACTIVE_BIDS=$(api_call GET "/bids/mine?status=PENDING") || echo '{"data":[]}'
    local ACTIVE_COUNT
    ACTIVE_COUNT=$(echo "$ACTIVE_BIDS" | jq '.data | length // 0')
    log "Bids activos: $ACTIVE_COUNT"

    local ELAPSED=$(( $(date +%s) - START_TIME ))
    log "=== Toku worker v1 cycle completado en ${ELAPSED}s | bids:$BID_COUNT skip:$SKIP_COUNT errors:$ERROR_COUNT ==="
}

main
