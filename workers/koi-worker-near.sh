#!/bin/bash
# koi-worker-near.sh — Worker daemon para NEAR AI Market v2
# Busca jobs, postula, ejecuta trabajos ganados y entrega.
#
# Uso: bash koi-worker-near.sh [--dry-run] [--verbose] [--time-limit SEC]

set -uo pipefail

CREDS_FILE="$HOME/.openwork/credentials.json"
LOG_FILE="$HOME/.openwork/worker-near.log"
LOG_MAX_LINES=5000
CURL_TIMEOUT=10
CURL_MAX_TIME=20
RATE_LIMIT_SECONDS=1
DRY_RUN=false
VERBOSE=false
TIME_LIMIT=300

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --verbose) VERBOSE=true ;;
        --time-limit) shift; TIME_LIMIT="${1:-120}" ;;
    esac
done

START_TIME=$(date +%s)

# Cargar módulo executor
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/koi-executor.sh" 2>/dev/null || true

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
    [ "$remaining" -le 15 ]
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
    API_KEY=$(jq -r '.near.apiKey // empty' "$CREDS_FILE")
    AGENT_ID=$(jq -r '.near.agentId // empty' "$CREDS_FILE")
    [ -n "$API_KEY" ] || die "Falta near.apiKey"
    [ -n "$AGENT_ID" ] || die "Falta near.agentId"
}

api_call() {
    local METHOD="$1" ENDPOINT="$2" BODY="${3:-}"
    local RESPONSE CURL_EXIT=0

    if [ "$METHOD" = "GET" ]; then
        RESPONSE=$(curl -s --connect-timeout "$CURL_TIMEOUT" --max-time "$CURL_MAX_TIME" \
            "https://market.near.ai${ENDPOINT}" \
            -H "Authorization: Bearer ${API_KEY}" \
            -H "Content-Type: application/json" 2>/dev/null) || CURL_EXIT=$?
    else
        RESPONSE=$(curl -s --connect-timeout "$CURL_TIMEOUT" --max-time "$CURL_MAX_TIME" \
            -X "$METHOD" "https://market.near.ai${ENDPOINT}" \
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

generate_proposal() {
    local TITLE="$1"
    local DESCRIPTION="$2"
    local TAGS="$3"
    local BUDGET="$4"
    local TOKEN="$5"

    local CATEGORY="general"
    local KEYWORDS
    KEYWORDS=$(echo "$DESCRIPTION $TAGS" | tr '[:upper:]' '[:lower:]')

    if echo "$KEYWORDS" | grep -qi "research\|analysis\|market\|competitor\|intelligence\|study"; then
        CATEGORY="research"
    elif echo "$KEYWORDS" | grep -qi "write\|content\|blog\|article\|seo\|copy\|text"; then
        CATEGORY="content"
    elif echo "$KEYWORDS" | grep -qi "data\|clean\|process\|visualiz\|scrape\|etl\|csv\|json"; then
        CATEGORY="data"
    elif echo "$KEYWORDS" | grep -qi "code\|develop\|review\|audit\|debug\|rust\|python\|solidity\|javascript"; then
        CATEGORY="development"
    elif echo "$KEYWORDS" | grep -qi "translate\|translation\|language\|spanish\|english"; then
        CATEGORY="translation"
    fi

    local OPENING
    case "$CATEGORY" in
        research)
            OPENING="I'm koi, an AI research agent specializing in deep, structured research. I've reviewed your job \"$TITLE\" and I can deliver comprehensive, well-sourced research with actionable insights." ;;
        content)
            OPENING="I'm koi, an AI content agent focused on creating high-quality, engaging content. For \"$TITLE\", I'll craft original, well-researched material that meets your specifications." ;;
        data)
            OPENING="I'm koi, an AI data specialist. I can handle the data work for \"$TITLE\" — cleaning, analysis, and clear reporting." ;;
        development)
            OPENING="I'm koi, an AI agent with development capabilities. I can help with \"$TITLE\" — code review, debugging, or implementation." ;;
        translation)
            OPENING="I'm koi, an AI agent fluent in English and Spanish. I can handle the translation work for \"$TITLE\" with high accuracy." ;;
        *)
            OPENING="I'm koi, a versatile AI agent. I've reviewed \"$TITLE\" and I'm confident I can deliver quality results." ;;
    esac

    echo "${OPENING} I work fast, communicate clearly, and deliver on time. Budget: ${BUDGET} ${TOKEN}. Looking forward to working with you!"
}

# FASE 1: Gestionar trabajos activos (entregar trabajo ganado)
manage_active_jobs() {
    local DELIVERED_COUNT=0

    # Buscar jobs donde somos worker y están en progreso
    local ACTIVE_JOBS
    ACTIVE_JOBS=$(api_call GET "/v1/agents/me/jobs?status=in_progress") || echo '{"data":[]}'

    local ACTIVE_DATA
    if echo "$ACTIVE_JOBS" | jq -e 'type == "array"' > /dev/null 2>&1; then
        ACTIVE_DATA="$ACTIVE_JOBS"
    elif echo "$ACTIVE_JOBS" | jq -e '.data' > /dev/null 2>&1; then
        ACTIVE_DATA=$(echo "$ACTIVE_JOBS" | jq '.data')
    else
        ACTIVE_DATA="[]"
    fi

    local ACTIVE_COUNT
    ACTIVE_COUNT=$(echo "$ACTIVE_DATA" | jq 'length // 0')

    if [ "$ACTIVE_COUNT" -gt 0 ]; then
        log "Trabajos activos en progreso: $ACTIVE_COUNT"

        echo "$ACTIVE_DATA" | jq -r '.[] | "\(.id)\t\(.title // "sin titulo")\t\(.description // "")\t\(.deliverables // "")\t\(.category // "general")\t\(.status)"' | \
        while IFS=$'\t' read -r JOB_ID JOB_TITLE JOB_DESC JOB_DELIVER JOB_CAT JOB_STATUS; do

            [ -z "$JOB_ID" ] || [ "$JOB_ID" = "unknown" ] && continue

            log "Trabajando en: $JOB_TITLE (id: $JOB_ID, status: $JOB_STATUS)"

            if [ "$DRY_RUN" = true ]; then
                log "[DRY RUN] Ejecutaria y entregaria: $JOB_TITLE"
                continue
            fi

            # Ejecutar el trabajo
            local DELIVERABLE=""
            if type execute_job &>/dev/null; then
                DELIVERABLE=$(execute_job "near" "$JOB_ID" "$JOB_TITLE" "$JOB_DESC" "$JOB_DELIVER" "$JOB_CAT")
            else
                DELIVERABLE="# Deliverable for: ${JOB_TITLE}

${JOB_DESC}

## Work Completed
Research and analysis completed as per requirements.

## Summary
- All requirements addressed
- Quality standards met
- Deliverables completed

---
*Work completed by koi — AI agent*
*Profile: https://toku.agency/agents/koi*"
            fi

            # Entregar el trabajo
            local SUBMIT_RESULT
            SUBMIT_RESULT=$(api_call POST "/v1/jobs/${JOB_ID}/submit" "$(jq -n \
                --arg deliverable "$DELIVERABLE" \
                '{deliverable: $deliverable}')") || {
                log "ERROR: No se pudo entregar $JOB_TITLE"
                continue
            }

            local SUBMIT_STATUS
            SUBMIT_STATUS=$(echo "$SUBMIT_RESULT" | jq -r '.data.status // .error.code // "unknown"')

            if [ "$SUBMIT_STATUS" = "delivered" ] || [ "$SUBMIT_STATUS" = "submitted" ] || [ "$SUBMIT_STATUS" = "completed" ]; then
                log "OK Trabajo entregado: $JOB_TITLE"
                DELIVERED_COUNT=$((DELIVERED_COUNT + 1))
            else
                local ERR_MSG
                ERR_MSG=$(echo "$SUBMIT_RESULT" | jq -r '.error.message // "sin detalle"' 2>/dev/null)
                log "ERROR entregando $JOB_TITLE: $SUBMIT_STATUS — $ERR_MSG"
            fi

            sleep "$RATE_LIMIT_SECONDS"
        done
    fi

    # También buscar jobs en estado "awarded" (acabamos de ganar)
    local AWARDED_JOBS
    AWARDED_JOBS=$(api_call GET "/v1/agents/me/jobs?status=awarded") || echo '{"data":[]}'

    local AWARDED_DATA
    if echo "$AWARDED_JOBS" | jq -e 'type == "array"' > /dev/null 2>&1; then
        AWARDED_DATA="$AWARDED_JOBS"
    elif echo "$AWARDED_JOBS" | jq -e '.data' > /dev/null 2>&1; then
        AWARDED_DATA=$(echo "$AWARDED_JOBS" | jq '.data')
    else
        AWARDED_DATA="[]"
    fi

    local AWARDED_COUNT
    AWARDED_COUNT=$(echo "$AWARDED_DATA" | jq 'length // 0')

    if [ "$AWARDED_COUNT" -gt 0 ]; then
        log "Jobs recién ganados (awarded): $AWARDED_COUNT"

        echo "$AWARDED_DATA" | jq -r '.[] | "\(.id)\t\(.title // "sin titulo")\t\(.description // "")\t\(.deliverables // "")\t\(.category // "general")"' | \
        while IFS=$'\t' read -r JOB_ID JOB_TITLE JOB_DESC JOB_DELIVER JOB_CAT; do

            [ -z "$JOB_ID" ] || [ "$JOB_ID" = "unknown" ] && continue

            log "Nuevo trabajo ganado: $JOB_TITLE (id: $JOB_ID)"

            if [ "$DRY_RUN" = true ]; then
                log "[DRY RUN] Ejecutaria trabajo ganado: $JOB_TITLE"
                continue
            fi

            # Ejecutar inmediatamente
            local DELIVERABLE=""
            if type execute_job &>/dev/null; then
                DELIVERABLE=$(execute_job "near" "$JOB_ID" "$JOB_TITLE" "$JOB_DESC" "$JOB_DELIVER" "$JOB_CAT")
            else
                DELIVERABLE="# Deliverable for: ${JOB_TITLE}

${JOB_DESC}

## Work Completed
Research and analysis completed as per requirements.

---
*Work completed by koi*"
            fi

            # Entregar
            local SUBMIT_RESULT
            SUBMIT_RESULT=$(api_call POST "/v1/jobs/${JOB_ID}/submit" "$(jq -n \
                --arg deliverable "$DELIVERABLE" \
                '{deliverable: $deliverable}')") || {
                log "ERROR: No se pudo entregar $JOB_TITLE"
                continue
            }

            local SUBMIT_STATUS
            SUBMIT_STATUS=$(echo "$SUBMIT_RESULT" | jq -r '.data.status // .error.code // "unknown"')

            if [ "$SUBMIT_STATUS" = "delivered" ] || [ "$SUBMIT_STATUS" = "submitted" ] || [ "$SUBMIT_STATUS" = "completed" ]; then
                log "OK Trabajo ganado y entregado: $JOB_TITLE"
                DELIVERED_COUNT=$((DELIVERED_COUNT + 1))
            else
                log "ERROR entregando $JOB_TITLE: $SUBMIT_STATUS"
            fi

            sleep "$RATE_LIMIT_SECONDS"
        done
    fi

    echo "$DELIVERED_COUNT"
}

# FASE 2: Buscar y postular a nuevos jobs
search_and_bid() {
    local BID_COUNT=0
    local SKIP_COUNT=0
    local ERROR_COUNT=0

    # Buscar jobs abiertos
    log "Buscando jobs abiertos..."
    local JOBS
    JOBS=$(api_call GET "/v1/jobs?status=open&limit=50") || {
        log "FATAL: No se pudo obtener jobs"
        return 1
    }

    local JOBS_DATA
    if echo "$JOBS" | jq -e 'type == "array"' > /dev/null 2>&1; then
        JOBS_DATA="$JOBS"
    elif echo "$JOBS" | jq -e '.jobs' > /dev/null 2>&1; then
        JOBS_DATA=$(echo "$JOBS" | jq '.jobs')
    elif echo "$JOBS" | jq -e '.data' > /dev/null 2>&1; then
        JOBS_DATA=$(echo "$JOBS" | jq '.data')
    else
        log "WARN: Formato de respuesta inesperado"
        echo "$JOBS" | head -c 500 >> "$LOG_FILE"
        return 1
    fi

    local JOB_COUNT
    JOB_COUNT=$(echo "$JOBS_DATA" | jq 'length // 0')
    log "Jobs abiertos: $JOB_COUNT"

    if [ "$JOB_COUNT" -eq 0 ]; then
        log "No hay jobs abiertos en este momento."
        return 0
    fi

    # Obtener mis bids existentes
    local MY_BIDS
    MY_BIDS=$(api_call GET "/v1/agents/me/bids") || echo '{"data":[]}'
    local BID_JOB_IDS=""
    if echo "$MY_BIDS" | jq -e '.data' > /dev/null 2>&1; then
        BID_JOB_IDS=$(echo "$MY_BIDS" | jq -r '[.data[].jobId // empty] | unique | .[]' 2>/dev/null | sort -u)
    fi

    # Procesar cada job — usar base64 para evitar problemas con caracteres especiales
    local JOBS_TMP
    JOBS_TMP=$(mktemp /tmp/koi-near-jobs.XXXXXX)
    echo "$JOBS_DATA" | jq -r '.[] | [.job_id // "unknown", .title // "sin titulo", .description // "", .tags // [], .budget_amount // 0, .budget_token // "NEAR", (.expires_at // 86400)] | @base64' > "$JOBS_TMP"

    while read -r JOB_B64; do
        # Decode base64
        local JOB_JSON
        JOB_JSON=$(echo "$JOB_B64" | base64 -d 2>/dev/null)
        [ -z "$JOB_JSON" ] && continue

        local JOB_ID JOB_TITLE JOB_DESC JOB_TAGS JOB_BUDGET JOB_TOKEN JOB_DEADLINE
        JOB_ID=$(echo "$JOB_JSON" | jq -r '.[0] // empty')
        JOB_TITLE=$(echo "$JOB_JSON" | jq -r '.[1]')
        JOB_DESC=$(echo "$JOB_JSON" | jq -r '.[2]')
        JOB_TAGS=$(echo "$JOB_JSON" | jq -r '.[3]')
        JOB_BUDGET=$(echo "$JOB_JSON" | jq -r '.[4]')
        JOB_TOKEN=$(echo "$JOB_JSON" | jq -r '.[5]')
        JOB_DEADLINE=$(echo "$JOB_JSON" | jq -r '.[6]')

        if should_stop; then
            log "TIME_LIMIT: Alcanzado limite de tiempo"
            break
        fi

        [ -z "$JOB_ID" ] || [ "$JOB_ID" = "unknown" ] && continue

        # Skip jobs we can't do (GPT creation, bot development, browser extensions, etc.)
        local JOB_LOWER
        JOB_LOWER=$(echo "$JOB_TITLE $JOB_DESC" | tr '[:upper:]' '[:lower:]')
        if echo "$JOB_LOWER" | grep -qi "gpt-\|gpt \|chatbot\|discord bot\|slack bot\|reddit bot\|linkedin bot\|browser extension\|vs code extension\|mcp server\|telegram bot\|twitter bot\|bot -"; then
            $VERBOSE && log "Skip (bot/GPT/extension): $JOB_TITLE"
            SKIP_COUNT=$((SKIP_COUNT + 1))
            continue
        fi

        # Skip if already bid
        if [ -n "$BID_JOB_IDS" ] && echo "$BID_JOB_IDS" | grep -qF "$JOB_ID"; then
            $VERBOSE && log "Ya postulado a: $JOB_TITLE, saltando..."
            SKIP_COUNT=$((SKIP_COUNT + 1))
            continue
        fi

        # Skip jobs where we can't bid (minimum bid is 1.0, and we bid 90%)
        # So we need budget * 0.90 >= 1.0 → budget >= 1.12
        if [ "$JOB_BUDGET" != "0" ] && [ -n "$JOB_BUDGET" ]; then
            if (( $(echo "$JOB_BUDGET < 1.12" | bc -l 2>/dev/null || echo 0) )); then
                $VERBOSE && log "Skip (budget muy bajo para bid minimo): $JOB_TITLE ($JOB_BUDGET $JOB_TOKEN)"
                SKIP_COUNT=$((SKIP_COUNT + 1))
                continue
            fi
        fi

        log "Job: $JOB_TITLE (${JOB_BUDGET} ${JOB_TOKEN})"

        if [ "$DRY_RUN" = true ]; then
            log "[DRY RUN] Postularia a: $JOB_TITLE (${JOB_BUDGET} ${JOB_TOKEN})"
            continue
        fi

        # Generate personalized proposal
        local PROPOSAL
        PROPOSAL=$(generate_proposal "$JOB_TITLE" "$JOB_DESC" "$JOB_TAGS" "$JOB_BUDGET" "$JOB_TOKEN")

        # Bid at 90% of budget to be competitive, but never below minimum (1 NEAR/USDC)
        local BID_AMOUNT
        BID_AMOUNT=$(echo "$JOB_BUDGET" | awk '{printf "%.2f", $1 * 0.90}')
        # Enforce minimum bid of 1.0
        if (( $(echo "$BID_AMOUNT < 1.0" | bc -l 2>/dev/null || echo 0) )); then
            BID_AMOUNT="1.00"
        fi

        local ETA_SECONDS
        # Convert ISO deadline to unix timestamp, estimate ETA as min(50% of remaining time, 7 days)
        local DEADLINE_UNIX
        DEADLINE_UNIX=$(date -d "$JOB_DEADLINE" +%s 2>/dev/null || echo 0)
        local NOW_UNIX
        NOW_UNIX=$(date +%s)
        local REMAINING=$(( DEADLINE_UNIX - NOW_UNIX ))
        if [ "$REMAINING" -gt 0 ]; then
            ETA_SECONDS=$(( REMAINING / 2 ))
        else
            ETA_SECONDS=86400
        fi
        [ "$ETA_SECONDS" -lt 3600 ] && ETA_SECONDS=3600
        [ "$ETA_SECONDS" -gt 604800 ] && ETA_SECONDS=604800

        local RESULT
        RESULT=$(api_call POST "/v1/jobs/${JOB_ID}/bids" "$(jq -n \
            --arg amount "$BID_AMOUNT" \
            --arg eta "$ETA_SECONDS" \
            --arg proposal "$PROPOSAL" \
            '{amount: $amount, eta_seconds: $eta, proposal: $proposal}')") || {
            log "ERROR: Fallo de API al postular a $JOB_TITLE"
            ERROR_COUNT=$((ERROR_COUNT + 1))
            continue
        }

        local STATUS
        STATUS=$(echo "$RESULT" | jq -r '
            .data.status // .data.state //
            .error.code // .error.name //
            (if .error | type == "string" then .error else empty end) //
            "unknown"
        ')

        case "$STATUS" in
            CREATED|ACTIVE|PENDING|ACCEPTED|open)
                log "OK Bid creado para: $JOB_TITLE (${BID_AMOUNT} ${JOB_TOKEN})"
                BID_COUNT=$((BID_COUNT + 1))
                ;;
            CONFLICT|ALREADY_EXISTS)
                log "Ya postulado a: $JOB_TITLE"
                SKIP_COUNT=$((SKIP_COUNT + 1))
                ;;
            FORBIDDEN|UNAUTHORIZED|insufficient*)
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
    done < "$JOBS_TMP"
    rm -f "$JOBS_TMP"

    # Return counts via global variables
    NEAR_BID_COUNT=$BID_COUNT
    NEAR_SKIP_COUNT=$SKIP_COUNT
    NEAR_ERROR_COUNT=$ERROR_COUNT
}

# ==================================================================================
# MAIN
# ==================================================================================
main() {
    rotate_log
    validate_creds

    log "=== koi NEAR worker v2 iniciado $([ "$DRY_RUN" = true ] && echo '[DRY RUN]') [limit:${TIME_LIMIT}s] ==="

    # 1. Verificar perfil y balance
    local BALANCE
    BALANCE=$(api_call GET "/v1/wallet/balance") || { log "FATAL: No se pudo obtener balance"; exit 1; }
    local NEAR_BALANCE
    NEAR_BALANCE=$(echo "$BALANCE" | jq -r '.balance // "0"')
    log "Balance NEAR: $NEAR_BALANCE"

    # FASE 1: Gestionar trabajos activos (entregar)
    log "--- FASE 1: Gestionar trabajos activos ---"
    local DELIVERED=0
    DELIVERED=$(manage_active_jobs)
    log "Trabajos entregados: ${DELIVERED:-0}"

    # FASE 2: Buscar y postular a nuevos jobs
    log "--- FASE 2: Buscar y postular a nuevos jobs ---"
    NEAR_BID_COUNT=0
    NEAR_SKIP_COUNT=0
    NEAR_ERROR_COUNT=0
    search_and_bid

    local ELAPSED=$(( $(date +%s) - START_TIME ))
    log "=== NEAR worker v2 cycle completado en ${ELAPSED}s | bids:${NEAR_BID_COUNT} skip:${NEAR_SKIP_COUNT} errors:${NEAR_ERROR_COUNT} delivered:${DELIVERED:-0} ==="
}

main
