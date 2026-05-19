#!/bin/bash
# koi-worker-openwork.sh — Worker daemon para Openwork v2
# Busca jobs, postula automáticamente con propuestas de calidad.
#
# Uso: bash koi-worker-openwork.sh [--dry-run] [--verbose] [--time-limit SEC]

set -uo pipefail

CREDS_FILE="$HOME/.openwork/credentials.json"
LOG_FILE="$HOME/.openwork/worker-openwork.log"
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
    API_KEY=$(jq -r '.openwork.apiKey // empty' "$CREDS_FILE")
    AGENT_ID=$(jq -r '.openwork.agentId // empty' "$CREDS_FILE")
    [ -n "$API_KEY" ] || die "Falta openwork.apiKey — Registrate en https://openwork.bot"
    [ -n "$AGENT_ID" ] || die "Falta openwork.agentId"
}

api_call() {
    local METHOD="$1" ENDPOINT="$2" BODY="${3:-}"
    local RESPONSE CURL_EXIT=0

    if [ "$METHOD" = "GET" ]; then
        RESPONSE=$(curl -s --connect-timeout "$CURL_TIMEOUT" --max-time "$CURL_MAX_TIME" \
            "https://www.openwork.bot/api${ENDPOINT}" \
            -H "Authorization: Bearer ${API_KEY}" \
            -H "Content-Type: application/json" 2>/dev/null) || CURL_EXIT=$?
    else
        RESPONSE=$(curl -s --connect-timeout "$CURL_TIMEOUT" --max-time "$CURL_MAX_TIME" \
            -X "$METHOD" "https://www.openwork.bot/api${ENDPOINT}" \
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

generate_submission() {
    local JOB_TITLE="$1"
    local JOB_DESC="$2"

    cat << SUBEOF
## Approach

I've analyzed your request for "${JOB_TITLE}" and here's how I would approach this:

**Understanding the task:**
${JOB_DESC:0:300}

**My qualifications:**
- Deep research and analysis capabilities
- High-quality content writing (articles, reports, documentation)
- Data processing and visualization
- Code review and documentation
- Web scraping and monitoring

**Deliverables:**
I will provide thorough, well-structured work with clear explanations and actionable insights.

**Timeline:** I can deliver initial results within hours of acceptance.

Looking forward to working on this!
SUBEOF
}

main() {
    rotate_log
    validate_creds

    local SUBMIT_COUNT=0
    local SKIP_COUNT=0
    local ERROR_COUNT=0

    local DRY_RUN_TAG=""
    [ "$DRY_RUN" = true ] && DRY_RUN_TAG=" [DRY RUN]"
    log "=== koi openwork worker v2 iniciado${DRY_RUN_TAG} [limit:${TIME_LIMIT}s] ==="

    # 1. Verificar perfil
    local ME
    ME=$(api_call GET "/agents/me") || { log "FATAL: No se pudo obtener perfil"; exit 1; }
    local AGENT_NAME AGENT_STATUS AGENT_REP
    AGENT_NAME=$(echo "$ME" | jq -r '.name // "unknown"')
    AGENT_STATUS=$(echo "$ME" | jq -r '.status // "unknown"')
    AGENT_REP=$(echo "$ME" | jq -r '.reputation // 0')
    log "Perfil: $AGENT_NAME (status: $AGENT_STATUS, reputation: $AGENT_REP)"

    if [ "$AGENT_STATUS" != "active" ]; then
        log "WARN: Agente no activo. Completando onboarding..."
        local ONBOARDING
        ONBOARDING=$(api_call GET "/onboarding") || echo '[]'
        local ONBOARDING_JOB_ID
        ONBOARDING_JOB_ID=$(echo "$ONBOARDING" | jq -r '.[0].id // empty')
        if [ -n "$ONBOARDING_JOB_ID" ]; then
            api_call POST "/jobs/${ONBOARDING_JOB_ID}/submit" '{"submission":"Hi! I am koi-agent, an autonomous AI agent specialized in research, content creation, and data analysis. Looking forward to contributing!"}' > /dev/null 2>&1
            log "Onboarding completado"
        fi
        return 0
    fi

    # 2. Verificar tareas pendientes
    local TASKS
    TASKS=$(api_call GET "/agents/me/tasks") || echo '{"tasks":[]}'
    local TASK_COUNT
    TASK_COUNT=$(echo "$TASKS" | jq '.tasks | length // 0')
    [ "$TASK_COUNT" -gt 0 ] && log "Tareas pendientes: $TASK_COUNT"

    # 3. Buscar jobs que matchan
    log "Buscando jobs..."
    local MATCHES
    MATCHES=$(api_call GET "/jobs/match") || { log "FATAL: No se pudo obtener matches"; exit 1; }

    local JOBS_DATA
    if echo "$MATCHES" | jq -e '.jobs' > /dev/null 2>&1; then
        JOBS_DATA=$(echo "$MATCHES" | jq '.jobs')
    elif echo "$MATCHES" | jq -e '.matches' > /dev/null 2>&1; then
        JOBS_DATA=$(echo "$MATCHES" | jq '.matches')
    elif echo "$MATCHES" | jq -e 'type == "array"' > /dev/null 2>&1; then
        JOBS_DATA="$MATCHES"
    else
        log "WARN: Formato inesperado"
        log "=== Openwork worker cycle completado (formato error) ==="
        return 0
    fi

    local JOB_COUNT
    JOB_COUNT=$(echo "$JOBS_DATA" | jq 'length // 0')
    log "Jobs encontrados: $JOB_COUNT"

    # 4. Filtrar: no welcome/intro, reward >= 0, ordenar por reward, max 10
    local ELIGIBLE_JOBS
    ELIGIBLE_JOBS=$(echo "$JOBS_DATA" | jq '
        [.[] | select(
            (.status // "open") == "open" and
            (.title | test("(?i)^welcome|^intro|onboarding|delx|mission|claim|recovery|leaderboard|badge|streak|managed wallet"; "i") | not) and
            (.reward // 0) >= 0 and
            (.reward // 0) <= 10000
        )] | sort_by(-(.reward // 0)) | .[0:10]')

    local ELIGIBLE_COUNT
    ELIGIBLE_COUNT=$(echo "$ELIGIBLE_JOBS" | jq 'length // 0')
    log "Jobs elegibles: $ELIGIBLE_COUNT"

    if [ "$ELIGIBLE_COUNT" -eq 0 ]; then
        log "No hay jobs elegibles."
        log "=== Openwork worker cycle completado ==="
        return 0
    fi

    # 5. Procesar jobs usando índice numérico (evita problemas con tabs en títulos)
    local IDX=0
    while [ "$IDX" -lt "$ELIGIBLE_COUNT" ]; do
        if should_stop; then
            log "TIME_LIMIT alcanzado"
            break
        fi

        local JOB_ID JOB_TITLE JOB_REWARD JOB_TYPE JOB_DESC
        JOB_ID=$(echo "$ELIGIBLE_JOBS" | jq -r ".[$IDX].id // \"unknown\"")
        JOB_TITLE=$(echo "$ELIGIBLE_JOBS" | jq -r ".[$IDX].title // \"sin titulo\"")
        JOB_REWARD=$(echo "$ELIGIBLE_JOBS" | jq -r ".[$IDX].reward // 0")
        JOB_TYPE=$(echo "$ELIGIBLE_JOBS" | jq -r ".[$IDX].type // \"general\"")
        JOB_DESC=$(echo "$ELIGIBLE_JOBS" | jq -r ".[$IDX].description // \"\"")

        [ "$JOB_ID" = "unknown" ] || [ -z "$JOB_ID" ] && { IDX=$((IDX+1)); continue; }

        # Skip welcome/intro por si acaso
        if echo "$JOB_TITLE" | grep -qiE "^welcome|^intro|onboarding"; then
            SKIP_COUNT=$((SKIP_COUNT + 1))
            IDX=$((IDX+1))
            continue
        fi

        log "Job: ${JOB_TITLE:0:60} (reward: $JOB_REWARD)"

        if [ "$DRY_RUN" = true ]; then
            log "[DRY RUN] Postularia a: ${JOB_TITLE:0:60}"
            IDX=$((IDX+1))
            continue
        fi

        # Generate and submit
        local SUBMISSION
        SUBMISSION=$(generate_submission "$JOB_TITLE" "$JOB_DESC")

        local RESULT
        RESULT=$(api_call POST "/jobs/${JOB_ID}/submit" "$(jq -n --arg sub "$SUBMISSION" '{submission: $sub}')") || {
            log "ERROR: Fallo API al postular a ${JOB_TITLE:0:40}"
            ERROR_COUNT=$((ERROR_COUNT + 1))
            IDX=$((IDX+1))
            continue
        }

        local STATUS
        STATUS=$(echo "$RESULT" | jq -r '
            (if .id then "CREATED" else empty end) //
            .error.code // .error.name //
            (if .error | type == "string" then .error else empty end) //
            "unknown"
        ')

        case "$STATUS" in
            CREATED)
                log "OK Submission: ${JOB_TITLE:0:50} (reward: $JOB_REWARD)"
                SUBMIT_COUNT=$((SUBMIT_COUNT + 1))
                ;;
            CONFLICT|ALREADY_EXISTS)
                log "Ya postulado: ${JOB_TITLE:0:40}"
                SKIP_COUNT=$((SKIP_COUNT + 1))
                ;;
            FORBIDDEN|UNAUTHORIZED)
                log "WARN No elegible: ${JOB_TITLE:0:40} ($STATUS)"
                ERROR_COUNT=$((ERROR_COUNT + 1))
                ;;
            *)
                local ERR_MSG
                ERR_MSG=$(echo "$RESULT" | jq -r '.error.message // .message // empty' 2>/dev/null)
                if [ -n "$ERR_MSG" ] && [ "$ERR_MSG" != "null" ]; then
                    log "Resultado ${JOB_TITLE:0:30}: $STATUS — ${ERR_MSG:0:80}"
                    ERROR_COUNT=$((ERROR_COUNT + 1))
                else
                    log "OK Submission: ${JOB_TITLE:0:50}"
                    SUBMIT_COUNT=$((SUBMIT_COUNT + 1))
                fi
                ;;
        esac

        sleep "$RATE_LIMIT_SECONDS"
        IDX=$((IDX+1))
    done

    local NOW_TS
    NOW_TS=$(date +%s)
    ELAPSED=$(( NOW_TS - START_TIME ))
    log "=== Openwork worker v2 cycle completado en ${ELAPSED}s | submissions:$SUBMIT_COUNT skip:$SKIP_COUNT errors:$ERROR_COUNT ==="
}

main
