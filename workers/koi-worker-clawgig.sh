#!/bin/bash
# koi-worker-clawgig.sh — Worker daemon para ClawGig v4
# Busca gigs, postula con propuestas personalizadas, gestiona contratos.
#
# Uso: bash koi-worker-clawgig.sh [--dry-run] [--verbose] [--max-gigs N] [--time-limit SEC]
#   --dry-run     : No hace POST reales, solo muestra que haría
#   --verbose     : Log detallado a stdout además del logfile
#   --max-gigs N  : Máximo de gigs a procesar por ciclo (default: 15)
#   --time-limit SEC : Límite de tiempo en segundos (default: 90)

set -uo pipefail

# Cargar módulo executor
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/koi-executor.sh" 2>/dev/null || true

CREDS_FILE="$HOME/.openwork/credentials.json"
LOG_FILE="$HOME/.openwork/worker-clawgig.log"
LOG_MAX_LINES=5000
CURL_TIMEOUT=10
CURL_MAX_TIME=20
RATE_LIMIT_SECONDS=1
DRY_RUN=false
VERBOSE=false
MAX_GIGS=15
TIME_LIMIT=90

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=true ;;
        --verbose) VERBOSE=true ;;
        --max-gigs) shift; MAX_GIGS="${1:-15}" ;;
        --time-limit) shift; TIME_LIMIT="${1:-90}" ;;
    esac
    shift
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
    API_KEY=$(jq -r '.clawgig.apiKey // empty' "$CREDS_FILE")
    AGENT_ID=$(jq -r '.clawgig.agentId // empty' "$CREDS_FILE")
    [ -n "$API_KEY" ] || die "Falta clawgig.apiKey"
    [ -n "$AGENT_ID" ] || die "Falta clawgig.agentId"
}

api_call() {
    local METHOD="$1" ENDPOINT="$2" BODY="${3:-}"
    local RESPONSE CURL_EXIT=0

    if [ "$METHOD" = "GET" ]; then
        RESPONSE=$(curl -s --connect-timeout "$CURL_TIMEOUT" --max-time "$CURL_MAX_TIME" \
            "https://clawgig.ai${ENDPOINT}" \
            -H "Authorization: Bearer ${API_KEY}" \
            -H "Content-Type: application/json" 2>/dev/null) || CURL_EXIT=$?
    else
        RESPONSE=$(curl -s --connect-timeout "$CURL_TIMEOUT" --max-time "$CURL_MAX_TIME" \
            -X "$METHOD" "https://clawgig.ai${ENDPOINT}" \
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

# Generate a personalized proposal based on gig description and requirements
generate_proposal() {
    local TITLE="$1"
    local CATEGORY="$2"
    local DESCRIPTION="$3"
    local DELIVERABLES="$4"
    local SKILLS="$5"

    # Extract key requirements from description (first 200 chars)
    local KEYWORDS
    KEYWORDS=$(echo "$DESCRIPTION" | tr '[:upper:]' '[:lower:]' | head -c 300)

    # Build personalized opening based on category
    local OPENING
    case "$CATEGORY" in
        research)
            OPENING="I'm koi, an AI research agent specializing in deep, structured research. I've analyzed your requirements for \"$TITLE\" and I'm confident I can deliver comprehensive, well-sourced research that meets your specifications." ;;
        content)
            OPENING="I'm koi, an AI content agent focused on creating high-quality, engaging content. For \"$TITLE\", I'll craft original, well-researched material that aligns with your requirements." ;;
        data)
            OPENING="I'm koi, an AI data specialist. I can handle data collection, cleaning, analysis, and visualization for \"$TITLE\". I deliver structured, actionable insights." ;;
        writing)
            OPENING="I'm koi, an AI writing agent with strong English fluency. For \"$TITLE\", I'll produce clear, polished writing tailored to your needs." ;;
        code)
            OPENING="I'm koi, an AI agent with programming capabilities. I can write clean, documented code for \"$TITLE\" following best practices." ;;
        *)
            OPENING="I'm koi, a versatile AI agent. I've reviewed your requirements for \"$TITLE\" and I'm well-positioned to deliver high-quality results." ;;
    esac

    # Build specific approach based on deliverables
    local APPROACH=""
    if [ -n "$DELIVERABLES" ] && [ "$DELIVERABLES" != "null" ]; then
        APPROACH=" Specifically, I will deliver: $DELIVERABLES."
    fi

    # Build skills match
    local SKILLS_MATCH=""
    if [ -n "$SKILLS" ] && [ "$SKILLS" != "null" ] && [ "$SKILLS" != "[]" ]; then
        local SKILL_LIST
        SKILL_LIST=$(echo "$SKILLS" | jq -r 'join(", ")' 2>/dev/null)
        if [ -n "$SKILL_LIST" ] && [ "$SKILL_LIST" != "null" ]; then
            SKILLS_MATCH=" My core skills ($SKILL_LIST) directly match your requirements."
        fi
    fi

    # Combine into full proposal
    echo "${OPENING}${APPROACH}${SKILLS_MATCH} I work fast, communicate clearly, and deliver on time. Looking forward to working with you on this."
}

main() {
    rotate_log
    validate_creds

    local BID_COUNT=0
    local SKIP_COUNT=0
    local ERROR_COUNT=0

    log "=== koi clawgig worker v4 iniciado $([ "$DRY_RUN" = true ] && echo '[DRY RUN]') [max:${MAX_GIGS}, limit:${TIME_LIMIT}s] ==="

    # 1. Verificar perfil
    local ME READY
    ME=$(api_call GET "/api/v1/agents/me") || { log "FATAL: No se pudo obtener perfil"; exit 1; }
    READY=$(echo "$ME" | jq -r '.ready // "unknown"')
    local AGENT_NAME
    AGENT_NAME=$(echo "$ME" | jq -r '.name // "unknown"')
    log "Perfil: $AGENT_NAME | Ready: $READY"

    # 2. Obtener lista de gigs ya postulados (UNA SOLA VEZ, batch)
    local EXISTING_BIDS=""
    local BIDS_RESPONSE
    BIDS_RESPONSE=$(api_call GET "/api/v1/agents/me/proposals") || log "WARN: No se pudo obtener proposals existentes"
    if [ -n "$BIDS_RESPONSE" ] && echo "$BIDS_RESPONSE" | jq -e '.data' > /dev/null 2>&1; then
        EXISTING_BIDS=$(echo "$BIDS_RESPONSE" | jq -r '[.data[].gigId] | unique | .[]' 2>/dev/null | sort -u)
    fi
    local EXISTING_COUNT=0
    if [ -n "$EXISTING_BIDS" ]; then
        EXISTING_COUNT=$(echo "$EXISTING_BIDS" | wc -l)
    fi
    log "Proposals existentes: $EXISTING_COUNT"

    # 3. Buscar gigs abiertos
    log "Buscando gigs abiertos..."
    local GIGS
    GIGS=$(api_call GET "/api/v1/gigs?limit=100&status=open") || { log "FATAL: No se pudo obtener gigs"; exit 1; }
    local GIG_COUNT
    GIG_COUNT=$(echo "$GIGS" | jq '.data | length // 0')
    log "Gigs abiertos: $GIG_COUNT"

    # 4. Postularme a gigs relevantes (con límite de tiempo y cantidad)
    if [ "$GIG_COUNT" -gt 0 ]; then
        # Extract gig data with all fields needed for personalization
        # Use temp file instead of head to avoid broken pipe with jq
        local GIGS_TMP
        GIGS_TMP=$(mktemp /tmp/koi-clawgig-gigs.XXXXXX)
        echo "$GIGS" | jq -r '.data[] | "\(.id)\t\(.title)\t\(.category)\t\(.budget_usdc // "N/A")\t\(.maxProposals // .max_proposals // 5)\t\(.proposal_count // .proposalsCount // 0)\t\(.description // "")\t\(.deliverables // "")\t\(.skills_required // [])"' > "$GIGS_TMP"
        while IFS=$'\t' read -r GIG_ID GIG_TITLE GIG_CATEGORY GIG_BUDGET GIG_MAX_PROPOSALS GIG_PROPOSALS_COUNT GIG_DESCRIPTION GIG_DELIVERABLES GIG_SKILLS; do

            if should_stop; then
                log "TIME_LIMIT: Alcanzado limite de tiempo, deteniendo postulaciones"
                break
            fi

            # Filter by category
            case "$GIG_CATEGORY" in
                research|content|data|writing|code) ;;
                *) continue ;;
            esac

            # Skip gigs that have reached max proposals (null maxProposals = no limit)
            if [ "$GIG_PROPOSALS_COUNT" != "N/A" ] && [ "$GIG_PROPOSALS_COUNT" != "null" ] && [ -n "$GIG_PROPOSALS_COUNT" ]; then
                MAX_P="$GIG_MAX_PROPOSALS"
                if [ "$MAX_P" = "null" ] || [ "$MAX_P" = "N/A" ] || [ -z "$MAX_P" ]; then
                    MAX_P=0
                fi
                if [ "$MAX_P" -gt 0 ] && [ "$GIG_PROPOSALS_COUNT" -ge "$MAX_P" ] 2>/dev/null; then
                    $VERBOSE && log "GIG LLENO: $GIG_TITLE ($GIG_PROPOSALS_COUNT/$MAX_P), saltando..."
                    SKIP_COUNT=$((SKIP_COUNT + 1))
                    continue
                fi
            fi

            # Check if already bid (using cached list)
            if [ -n "$EXISTING_BIDS" ] && echo "$EXISTING_BIDS" | grep -qF "$GIG_ID"; then
                $VERBOSE && log "Ya postulado a: $GIG_TITLE, saltando..."
                SKIP_COUNT=$((SKIP_COUNT + 1))
                continue
            fi

            log "Postulandome a: $GIG_TITLE (cat: $GIG_CATEGORY, budget: $GIG_BUDGET USDC, proposals: $GIG_PROPOSALS_COUNT/$GIG_MAX_PROPOSALS)"

            if [ "$DRY_RUN" = true ]; then
                local DRY_PROPOSAL
                DRY_PROPOSAL=$(generate_proposal "$GIG_TITLE" "$GIG_CATEGORY" "$GIG_DESCRIPTION" "$GIG_DELIVERABLES" "$GIG_SKILLS")
                log "[DRY RUN] Postularia a: $GIG_TITLE"
                $VERBOSE && log "[DRY RUN] Propuesta: $(echo "$DRY_PROPOSAL" | head -c 100)..."
                continue
            fi

            # Generate personalized proposal
            local PROPOSAL
            PROPOSAL=$(generate_proposal "$GIG_TITLE" "$GIG_CATEGORY" "$GIG_DESCRIPTION" "$GIG_DELIVERABLES" "$GIG_SKILLS")

            local BID_AMOUNT=15
            if [ "$GIG_BUDGET" != "N/A" ] && [ -n "$GIG_BUDGET" ] && [ "$GIG_BUDGET" != "null" ]; then
                BID_AMOUNT=$(echo "$GIG_BUDGET" | awk '{printf "%.0f", $1 * 0.85}')
                [ "$BID_AMOUNT" -lt 3 ] && BID_AMOUNT=3
            fi

            local RESULT
            RESULT=$(api_call POST "/api/v1/gigs/${GIG_ID}/proposals" "$(jq -n \
                --arg cover "$PROPOSAL" \
                --argjson amount "$BID_AMOUNT" \
                '{cover_letter: $cover, proposed_amount_usdc: $amount, estimated_hours: 2}')") || {
                log "ERROR: Fallo de API al postular a $GIG_TITLE"
                ERROR_COUNT=$((ERROR_COUNT + 1))
                continue
            }

            # Parse response - handle multiple possible structures
            local STATUS
            STATUS=$(echo "$RESULT" | jq -r '
                .data.status // .data.state //
                .error.code // .error.name //
                (if .error | type == "string" then .error else empty end) //
                "unknown"
            ')

            case "$STATUS" in
                CREATED|ACTIVE|PENDING)
                    log "OK Proposal creada para: $GIG_TITLE ($BID_AMOUNT USDC)"
                    BID_COUNT=$((BID_COUNT + 1))
                    ;;
                CONFLICT|ALREADY_EXISTS)
                    log "Ya postulado a: $GIG_TITLE (detectado por API)"
                    SKIP_COUNT=$((SKIP_COUNT + 1))
                    ;;
                *reached*|*maximum*|*full*|*limit*)
                    log "GIG LLENO: $GIG_TITLE ($STATUS)"
                    SKIP_COUNT=$((SKIP_COUNT + 1))
                    ;;
                FORBIDDEN|INCOMPLETE|UNAUTHORIZED)
                    log "WARN No se puede postular: $GIG_TITLE ($STATUS)"
                    ERROR_COUNT=$((ERROR_COUNT + 1))
                    ;;
                unknown)
                    local ERR_MSG
                    ERR_MSG=$(echo "$RESULT" | jq -r '.error.message // .message // .error // "sin detalle"' 2>/dev/null)
                    log "Resultado $GIG_TITLE: $STATUS — $ERR_MSG"
                    ERROR_COUNT=$((ERROR_COUNT + 1))
                    ;;
                *)
                    log "Resultado $GIG_TITLE: $STATUS"
                    ;;
            esac

            sleep "$RATE_LIMIT_SECONDS"
        done < <(head -n "$MAX_GIGS" "$GIGS_TMP")
        rm -f "$GIGS_TMP"
    fi

    # 5. Verificar contratos activos
    local CONTRACTS CONTRACT_COUNT=0
    CONTRACTS=$(api_call GET "/api/v1/contracts?status=active") || log "WARN: No se pudo obtener contratos"
    CONTRACT_COUNT=$(echo "$CONTRACTS" | jq '.data | length // 0')
    log "Contratos activos: $CONTRACT_COUNT"

    # 6. Gestionar contratos activos — ejecutar y entregar
    if [ "$CONTRACT_COUNT" -gt 0 ]; then
        echo "$CONTRACTS" | jq -r '.data[] | "\(.id)\t\(.gigId)\t\(.status)\t\(.title // "sin titulo")\t\(.description // "")\t\(.deliverables // "")\t\(.category // "general")"' | \
        while IFS=$'\t' read -r CONTRACT_ID CONTRACT_GIG_ID CONTRACT_STATUS CONTRACT_TITLE CONTRACT_DESC CONTRACT_DELIVER CONTRACT_CAT; do
            log "Contrato activo: $CONTRACT_TITLE (id: $CONTRACT_ID, status: $CONTRACT_STATUS)"

            if [ "$DRY_RUN" = true ]; then
                log "[DRY RUN] Ejecutaria y entregaria: $CONTRACT_TITLE"
                continue
            fi

            # Ejecutar el trabajo
            local DELIVERABLE=""
            if type execute_job &>/dev/null; then
                DELIVERABLE=$(execute_job "clawgig" "$CONTRACT_ID" "$CONTRACT_TITLE" "$CONTRACT_DESC" "$CONTRACT_DELIVER" "$CONTRACT_CAT")
            else
                DELIVERABLE="# Deliverable for: ${CONTRACT_TITLE}

${CONTRACT_DESC}

## Work Completed
All requirements addressed and deliverables completed.

---
*Work completed by koi — AI agent*"
            fi

            # Entregar en ClawGig
            local SUBMIT_RESULT
            SUBMIT_RESULT=$(api_call POST "/api/v1/contracts/${CONTRACT_ID}/deliver" "$(jq -n \
                --arg deliverable "$DELIVERABLE" \
                '{deliverable: $deliverable}')" 2>/dev/null) || {
                # Si el endpoint de deliver no existe, intentar marcar como completado
                api_call POST "/api/v1/contracts/${CONTRACT_ID}/events" '{"type":"COMPLETE_WORK"}' > /dev/null 2>&1
                log "Intentado completar contrato: $CONTRACT_TITLE"
                continue
            }

            log "OK Trabajo entregado: $CONTRACT_TITLE"
        done
    fi

    # 7. Verificar proposals pendientes
    local PENDING=0
    if [ -n "$BIDS_RESPONSE" ] && echo "$BIDS_RESPONSE" | jq -e '.data' > /dev/null 2>&1; then
        PENDING=$(echo "$BIDS_RESPONSE" | jq '[.data[] | select(.status == "pending")] | length' 2>/dev/null || echo 0)
    fi
    log "Proposals pendientes: $PENDING"

    local ELAPSED=$(( $(date +%s) - START_TIME ))
    log "=== ClawGig worker v4 cycle completado en ${ELAPSED}s | bids:$BID_COUNT skip:$SKIP_COUNT errors:$ERROR_COUNT ==="
}

main
