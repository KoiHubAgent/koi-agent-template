#!/bin/bash
# koi-worker-superteam.sh — Worker daemon para Superteam Earn v2
# Busca bounties, postula automáticamente.
#
# Uso: bash koi-worker-superteam.sh [--dry-run] [--verbose] [--time-limit SEC]

set -uo pipefail

CREDS_FILE="$HOME/.openwork/credentials.json"
LOG_FILE="$HOME/.openwork/worker-superteam.log"
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
    API_KEY=$(jq -r '.superteam.apiKey // empty' "$CREDS_FILE")
    AGENT_ID=$(jq -r '.superteam.agentId // empty' "$CREDS_FILE")
    [ -n "$API_KEY" ] || die "Falta superteam.apiKey"
    [ -n "$AGENT_ID" ] || die "Falta superteam.agentId"
}

api_call() {
    local METHOD="$1" ENDPOINT="$2" BODY="${3:-}"
    local RESPONSE CURL_EXIT=0

    if [ "$METHOD" = "GET" ]; then
        RESPONSE=$(curl -s --connect-timeout "$CURL_TIMEOUT" --max-time "$CURL_MAX_TIME" \
            "https://superteam.fun${ENDPOINT}" \
            -H "Authorization: Bearer ${API_KEY}" \
            -H "Content-Type: application/json" 2>/dev/null) || CURL_EXIT=$?
    else
        RESPONSE=$(curl -s --connect-timeout "$CURL_TIMEOUT" --max-time "$CURL_MAX_TIME" \
            -X "$METHOD" "https://superteam.fun${ENDPOINT}" \
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

    local SUBMIT_COUNT=0
    local SKIP_COUNT=0
    local ERROR_COUNT=0

    log "=== koi superteam worker v2 iniciado $([ "$DRY_RUN" = true ] && echo '[DRY RUN]') [limit:${TIME_LIMIT}s] ==="

    # 1. Buscar bounties activos
    log "Buscando bounties activos..."
    local LISTINGS
    LISTINGS=$(api_call GET "/api/agents/listings/live?take=50&type=bounty") || {
        log "FATAL: No se pudo obtener listings"
        exit 1
    }

    # Check for API error
    if echo "$LISTINGS" | jq -e '.error' > /dev/null 2>&1; then
        log "Error en API: $(echo "$LISTINGS" | jq -r '.error.name // .error // "unknown"')"
        log "=== Superteam worker cycle completado (error) ==="
        return 0
    fi

    # FIX: API returns {data: [...]}, extract .data array
    local LISTINGS_DATA
    if echo "$LISTINGS" | jq -e 'type == "array"' > /dev/null 2>&1; then
        LISTINGS_DATA="$LISTINGS"
    elif echo "$LISTINGS" | jq -e '.data' > /dev/null 2>&1; then
        LISTINGS_DATA=$(echo "$LISTINGS" | jq '.data')
    else
        log "WARN: Formato de respuesta inesperado"
        echo "$LISTINGS" | head -c 500 >> "$LOG_FILE"
        log "=== Superteam worker cycle completado (formato error) ==="
        return 0
    fi

    local LISTING_COUNT
    LISTING_COUNT=$(echo "$LISTINGS_DATA" | jq 'length // 0')
    log "Bounties encontrados: $LISTING_COUNT"

    if [ "$LISTING_COUNT" -eq 0 ]; then
        log "No hay bounties activos en este momento."
        log "=== Superteam worker cycle completado ==="
        return 0
    fi

    # 2. Filtrar bounties elegibles
    local NOW
    NOW=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")

    # Build eligible list:
    # - Status must be OPEN (not CLOSED, COMPLETED, etc.)
    # - Not already won (isWinnersAnnounced == false or null)
    # - Has agentAccess == AGENT_ONLY or null
    # - Deadline in future OR deadline passed but status still OPEN (sponsors sometimes extend)
    local ELIGIBLE_LISTINGS
    ELIGIBLE_LISTINGS=$(echo "$LISTINGS_DATA" | jq --arg now "$NOW" '
        [.[] | select(
            (.status // "OPEN") == "OPEN" and
            (.isWinnersAnnounced // false) == false and
            (.agentAccess // "AGENT_ONLY") == "AGENT_ONLY"
        )]
    ')

    local ELIGIBLE_COUNT
    ELIGIBLE_COUNT=$(echo "$ELIGIBLE_LISTINGS" | jq 'length // 0')
    log "Bounties elegibles (status OPEN, no winners): $ELIGIBLE_COUNT"

    if [ "$ELIGIBLE_COUNT" -eq 0 ]; then
        log "No hay bounties elegibles. Todos cerrados o con ganadores anunciados."
        log "=== Superteam worker cycle completado ==="
        return 0
    fi

    # Log deadline info for visibility
    local EXPIRED_COUNT
    EXPIRED_COUNT=$(echo "$ELIGIBLE_LISTINGS" | jq --arg now "$NOW" '[.[] | select((.deadline // .deadlineAt // .endsAt) != null and (.deadline // .deadlineAt // .endsAt) < $now)] | length')
    local FUTURE_COUNT
    FUTURE_COUNT=$(( ELIGIBLE_COUNT - EXPIRED_COUNT ))
    log "Bounties por deadline: $FUTURE_COUNT futuro, $EXPIRED_COUNT expirado (pero aun OPEN)"

    # 3. Procesar cada bounty elegible
    echo "$ELIGIBLE_LISTINGS" | jq -r '.[] | "\(.id // .listingId // "unknown")\t\(.title // "sin titulo")\t\(.rewardAmount // 0)\t\(.token // "USDC")\t\(.slug // .id // "unknown")"' | \
    while IFS=$'\t' read -r LISTING_ID LISTING_TITLE LISTING_REWARD LISTING_TOKEN LISTING_SLUG; do

        if should_stop; then
            log "TIME_LIMIT: Alcanzado limite de tiempo"
            break
        fi

        [ -z "$LISTING_ID" ] || [ "$LISTING_ID" = "unknown" ] && continue

        local LISTING_DEADLINE
        LISTING_DEADLINE=$(echo "$ELIGIBLE_LISTINGS" | jq -r --arg id "$LISTING_ID" '.[] | select(.id == $id) | .deadline // .deadlineAt // .endsAt // "unknown"')
        local DEADLINE_PASSED=false
        if [ "$LISTING_DEADLINE" != "unknown" ] && [ "$LISTING_DEADLINE" != "null" ]; then
            if [[ "$LISTING_DEADLINE" < "$NOW" ]]; then
                DEADLINE_PASSED=true
            fi
        fi

        if [ "$DEADLINE_PASSED" = true ]; then
            log "Bounty EXPIRADO (pero OPEN): $LISTING_TITLE ($LISTING_REWARD $LISTING_TOKEN, deadline: $LISTING_DEADLINE)"
            $VERBOSE && log "Intentando postular de todas formas (sponsors a veces extienden)..."
        else
            log "Bounty: $LISTING_TITLE ($LISTING_REWARD $LISTING_TOKEN, deadline: $LISTING_DEADLINE)"
        fi

        if [ "$DRY_RUN" = true ]; then
            log "[DRY RUN] Postularia a: $LISTING_TITLE"
            continue
        fi

        # Obtener detalles del listing para verificar elegibilidad
        local DETAILS
        DETAILS=$(api_call GET "/api/agents/listings/details/${LISTING_SLUG}") || {
            log "WARN: No se pudo obtener detalles de: $LISTING_TITLE"
            ERROR_COUNT=$((ERROR_COUNT + 1))
            continue
        }

        if echo "$DETAILS" | jq -e '.error' > /dev/null 2>&1; then
            log "WARN: Error en detalles de: $LISTING_TITLE — $(echo "$DETAILS" | jq -r '.error.name // .error // "unknown"')"
            ERROR_COUNT=$((ERROR_COUNT + 1))
            continue
        fi

        # Check if already submitted
        local ALREADY_SUBMITTED=false
        if echo "$DETAILS" | jq -e '.data.submissions' > /dev/null 2>&1; then
            if echo "$DETAILS" | jq -e '.data.submissions[] | select(.agentId == "'"$AGENT_ID"'")' > /dev/null 2>&1; then
                log "Ya postulado a: $LISTING_TITLE, saltando..."
                SKIP_COUNT=$((SKIP_COUNT + 1))
                ALREADY_SUBMITTED=true
                continue
            fi
        fi

        [ "$ALREADY_SUBMITTED" = true ] && continue

        # Preparar submission
        local SUBMISSION_BODY
        SUBMISSION_BODY=$(jq -n \
            --arg listingId "$LISTING_ID" \
            --arg link "https://github.com/koi-agent/submissions" \
            --arg otherInfo "I'm koi, an AI agent specialized in research, data analysis, and content creation. I can deliver high-quality work for this bounty." \
            --arg telegram "http://t.me/cesardaw1d" \
            '{
                listingId: $listingId,
                link: $link,
                tweet: "",
                otherInfo: $otherInfo,
                telegram: $telegram,
                ask: null
            }')

        local RESULT
        RESULT=$(api_call POST "/api/agents/submissions/create" "$SUBMISSION_BODY") || {
            log "ERROR: Fallo de API al postular a $LISTING_TITLE"
            ERROR_COUNT=$((ERROR_COUNT + 1))
            continue
        }

        # Parse response - handle .error as string or object
        local STATUS
        STATUS=$(echo "$RESULT" | jq -r '
            .data.status // .data.state //
            .error.code // .error.name //
            (if .error | type == "string" then .error else empty end) //
            "unknown"
        ')

        case "$STATUS" in
            CREATED|ACTIVE|PENDING)
                log "OK Submission creada para: $LISTING_TITLE"
                SUBMIT_COUNT=$((SUBMIT_COUNT + 1))
                ;;
            CONFLICT|ALREADY_EXISTS)
                log "Ya postulado a: $LISTING_TITLE (detectado por API)"
                SKIP_COUNT=$((SKIP_COUNT + 1))
                ;;
            FORBIDDEN|UNAUTHORIZED)
                log "WARN No se puede postular: $LISTING_TITLE ($STATUS — agent not eligible)"
                ERROR_COUNT=$((ERROR_COUNT + 1))
                ;;
            *)
                local ERR_MSG
                ERR_MSG=$(echo "$RESULT" | jq -r '.error.message // .message // "sin detalle"' 2>/dev/null)
                log "Resultado $LISTING_TITLE: $STATUS — $ERR_MSG"
                ERROR_COUNT=$((ERROR_COUNT + 1))
                ;;
        esac

        sleep "$RATE_LIMIT_SECONDS"
    done

    local ELAPSED=$(( $(date +%s) - START_TIME ))
    log "=== Superteam worker v2 cycle completado en ${ELAPSED}s | submissions:$SUBMIT_COUNT skip:$SKIP_COUNT errors:$ERROR_COUNT ==="
}

main
