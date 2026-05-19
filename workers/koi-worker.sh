#!/bin/bash
# koi-worker.sh -- Worker daemon v4 para dealwork.ai
# Busca trabajos, postula inteligentemente, gestiona contratos.
# Integracion con Coinbase para conversion automatica USDC->EUR.
#
# Uso: bash koi-worker.sh [--dry-run] [--verbose] [--skip-coinbase] [--time-limit SEC]
#   --dry-run       : No hace POST reales, solo muestra que haría
#   --verbose       : Log detallado a stdout además del logfile
# Cargar módulo executor
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/koi-executor.sh" 2>/dev/null || true

#   --skip-coinbase : Omite la verificación de Coinbase (útil para runs rápidos)
#   --time-limit SEC: Límite de tiempo en segundos (default: 90)

set -uo pipefail

# == Configuracion =================================================================
CREDS_FILE="$HOME/.openwork/credentials.json"
LOG_FILE="$HOME/.openwork/worker.log"
LOG_MAX_LINES=5000
CURL_TIMEOUT=10
CURL_MAX_TIME=20
RATE_LIMIT_SECONDS=2
DRY_RUN=false
VERBOSE=false
SKIP_COINBASE=false
TIME_LIMIT=90

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --verbose) VERBOSE=true ;;
        --skip-coinbase) SKIP_COINBASE=true ;;
        --time-limit) shift; TIME_LIMIT="${1:-90}" ;;
    esac
done

START_TIME=$(date +%s)

# == Helpers =======================================================================
log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg" >> "$LOG_FILE"
    $VERBOSE && echo "$msg"
}

die() {
    log "ERROR: $1"
    exit 1
}

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
        local lines
        lines=$(wc -l < "$LOG_FILE")
        if [ "$lines" -gt "$LOG_MAX_LINES" ]; then
            tail -n "$((LOG_MAX_LINES / 2))" "$LOG_FILE" > "${LOG_FILE}.tmp"
            mv "${LOG_FILE}.tmp" "$LOG_FILE"
            log "Log rotado (tenia $lines lineas)"
        fi
    fi
}

# == Validacion de credenciales ====================================================
validate_creds() {
    [ -f "$CREDS_FILE" ] || die "No se encuentra $CREDS_FILE"
    [ -r "$CREDS_FILE" ] || die "$CREDS_FILE no es legible"

    if ! jq empty "$CREDS_FILE" 2>/dev/null; then
        die "credentials.json no es JSON valido"
    fi

    AGENT_ID=$(jq -r '.agentAccountId // empty' "$CREDS_FILE")
    HMAC_SECRET=$(jq -r '.hmacSecret // empty' "$CREDS_FILE")
    BASE_URL=$(jq -r '.baseUrl // empty' "$CREDS_FILE")

    [ -n "$AGENT_ID" ] || die "agentAccountId vacio en credentials.json"
    [ -n "$HMAC_SECRET" ] || die "hmacSecret vacio en credentials.json"
    [ -n "$BASE_URL" ] || die "baseUrl vacio en credentials.json"
}

# == API Call con HMAC-SHA256 (dealwork.ai) ========================================
api_call() {
    local METHOD="$1"
    local ENDPOINT="$2"
    local BODY="${3:-}"

    local TS
    TS=$(date +%s)
    local SIG
    SIG=$(printf '%s' "${AGENT_ID}${TS}${BODY}" | openssl dgst -sha256 -hmac "${HMAC_SECRET}" | sed 's/.* //')

    local RESPONSE
    local CURL_EXIT=0

    if [ "$METHOD" = "GET" ]; then
        RESPONSE=$(curl -s \
            --connect-timeout "$CURL_TIMEOUT" \
            --max-time "$CURL_MAX_TIME" \
            "${BASE_URL}${ENDPOINT}" \
            -H "X-Agent-ID: ${AGENT_ID}" \
            -H "X-Timestamp: ${TS}" \
            -H "X-Signature: ${SIG}" \
            2>/dev/null) || CURL_EXIT=$?
    else
        RESPONSE=$(curl -s \
            --connect-timeout "$CURL_TIMEOUT" \
            --max-time "$CURL_MAX_TIME" \
            -X "$METHOD" "${BASE_URL}${ENDPOINT}" \
            -H "Content-Type: application/json" \
            -H "X-Agent-ID: ${AGENT_ID}" \
            -H "X-Timestamp: ${TS}" \
            -H "X-Signature: ${SIG}" \
            -d "$BODY" \
            2>/dev/null) || CURL_EXIT=$?
    fi

    if [ "$CURL_EXIT" -ne 0 ]; then
        log "CURL_ERROR: exit code $CURL_EXIT en $METHOD $ENDPOINT"
        echo '{"error":{"code":"CURL_ERROR","message":"Fallo de conexion"}}'
        return 1
    fi

    if ! echo "$RESPONSE" | jq empty 2>/dev/null; then
        log "JSON_ERROR: Respuesta invalida en $METHOD $ENDPOINT"
        echo '{"error":{"code":"JSON_ERROR","message":"Invalid response"}}'
        return 1
    fi

    echo "$RESPONSE"
}

# == Coinbase API helper ===========================================================
coinbase_api() {
    local METHOD="$1"
    local ENDPOINT="$2"
    local BODY="${3:-}"

    local JWT
    JWT=$(python3 << PYEOF 2>/dev/null
import jwt, time, json, os, sys
from cryptography.hazmat.primitives import serialization

try:
    with open(os.path.expanduser("${CREDS_FILE}")) as f:
        creds = json.load(f)
    cb = creds.get("coinbase", {})
    key_id = cb.get("keyId", "")
    private_key_pem = cb.get("privateKey", "")
    if not key_id or not private_key_pem:
        sys.exit(1)
    private_key = serialization.load_pem_private_key(private_key_pem.encode(), password=None)
    now = int(time.time())
    payload = {
        "sub": key_id, "iss": "cdp", "aud": ["cdp_service"],
        "nbf": now, "exp": now + 120,
        "uri": "${METHOD} api.coinbase.com${ENDPOINT}"
    }
    headers = {"alg": "ES256", "typ": "JWT", "kid": key_id, "nonce": os.urandom(8).hex()}
    print(jwt.encode(payload, private_key, algorithm="ES256", headers=headers))
except Exception as e:
    print(f"ERROR: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
    )

    if [ -z "$JWT" ]; then
        log "COINBASE_ERROR: No se pudo generar JWT"
        return 1
    fi

    local RESPONSE CURL_EXIT=0

    if [ "$METHOD" = "GET" ]; then
        RESPONSE=$(curl -s --connect-timeout 10 --max-time 20 \
            -H "Authorization: Bearer ${JWT}" \
            -H "Content-Type: application/json" \
            "https://api.coinbase.com${ENDPOINT}" 2>/dev/null) || CURL_EXIT=$?
    else
        RESPONSE=$(curl -s --connect-timeout 10 --max-time 20 \
            -X "$METHOD" \
            -H "Authorization: Bearer ${JWT}" \
            -H "Content-Type: application/json" \
            -d "$BODY" \
            "https://api.coinbase.com${ENDPOINT}" 2>/dev/null) || CURL_EXIT=$?
    fi

    [ "$CURL_EXIT" -ne 0 ] && { log "COINBASE_CURL_ERROR: $CURL_EXIT"; return 1; }
    echo "$RESPONSE"
}

# == Obtener jobs nuevos (sin bid previo) =========================================
# Returns JSON array of new jobs
# Uses temp files to avoid pipe/subshell variable scoping issues
get_new_jobs() {
    local JOBS="$1"
    local BIDS="$2"

    local BID_IDS
    BID_IDS=$(echo "$BIDS" | jq -r '[.data[] | (.jobId // empty)] | unique' 2>/dev/null)

    # Write to temp file to avoid pipe/subshell issues with while loops
    local TMPFILE
    TMPFILE=$(mktemp /tmp/koi-newjobs.XXXXXX)
    echo "$JOBS" | jq --argjson bid_ids "$BID_IDS" '
        [.data[] | select(
            (.category == "research" or .category == "writing" or .category == "data" or .category == "analysis")
            and (.id as $id | $bid_ids | index($id) | not)
        )]
    ' > "$TMPFILE" 2>/dev/null
    cat "$TMPFILE"
    rm -f "$TMPFILE"
}

# == Calcular bid amount basado en el job =========================================
calculate_bid() {
    local JOB="$1"
    local BUDGET
    BUDGET=$(echo "$JOB" | jq -r '.budgetMax // .budget // .amount // "0"')

    if [ "$BUDGET" != "0" ] && [ "$BUDGET" != "null" ] && [ -n "$BUDGET" ]; then
        echo "$BUDGET" | awk '{printf "%.2f", $1 * 0.80}'
    else
        echo "12.00"
    fi
}

# == Generar proposal personalizada ================================================
generate_proposal() {
    local JOB="$1"
    local TITLE
    TITLE=$(echo "$JOB" | jq -r '.title // "this project"')
    local CATEGORY
    CATEGORY=$(echo "$JOB" | jq -r '.category // "general"')

    case "$CATEGORY" in
        research)
            echo "I'm koi, an AI research agent. I can deliver thorough, well-sourced research on \"$TITLE\" with structured reports, data compilation, and actionable insights. Fast turnaround, high accuracy." ;;
        writing)
            echo "I'm koi, an AI writing agent. I'll craft clear, engaging content for \"$TITLE\" — whether it's technical writing, blog posts, or documentation. Native-level English with attention to detail." ;;
        data)
            echo "I'm koi, an AI data specialist. I can handle data collection, cleaning, analysis, and visualization for \"$TITLE\". I deliver structured datasets and clear summaries." ;;
        analysis)
            echo "I'm koi, an AI analysis agent. I'll provide deep, structured analysis for \"$TITLE\" with data-backed conclusions and clear recommendations." ;;
        *)
            echo "I'm koi, a versatile AI agent. I can handle \"$TITLE\" efficiently with high-quality output. Let me know the details and I'll get started right away." ;;
    esac
}

# == Coinbase: verificar y convertir USDC a EUR ===================================
check_and_convert_usdc() {
    log "Verificando balance USDC en Coinbase..."

    local ACCOUNTS
    ACCOUNTS=$(coinbase_api GET "/v2/accounts") || {
        log "COINBASE_ERROR: No se pudo obtener cuentas"
        return 1
    }

    local USDC_ACCOUNT_ID
    USDC_ACCOUNT_ID=$(echo "$ACCOUNTS" | jq -r '.data[] | select(.balance.currency == "USDC" and (.balance.amount | tonumber) > 0) | .id' | head -1)

    if [ -z "$USDC_ACCOUNT_ID" ] || [ "$USDC_ACCOUNT_ID" = "null" ]; then
        log "No hay balance USDC disponible para convertir."
        return 0
    fi

    local USDC_AMOUNT
    USDC_AMOUNT=$(echo "$ACCOUNTS" | jq -r ".data[] | select(.id == \"$USDC_ACCOUNT_ID\") | .balance.amount")

    log "Balance USDC encontrado: $USDC_AMOUNT USDC"

    if [ "$DRY_RUN" = true ]; then
        log "[DRY RUN] Convertiria $USDC_AMOUNT USDC a EUR"
        return 0
    fi

    # Obtener tasa de cambio
    local RATE
    RATE=$(coinbase_api GET "/v2/exchange-rates?currency=USDC" | jq -r '.data.rates.EUR // "0"')

    if [ "$RATE" = "0" ] || [ "$RATE" = "null" ]; then
        log "COINBASE_ERROR: No se pudo obtener tasa USDC/EUR"
        return 1
    fi

    local EUR_ESTIMATE
    EUR_ESTIMATE=$(echo "$USDC_AMOUNT $RATE" | awk '{printf "%.2f", $1 * $2}')
    log "Tasa USDC/EUR: $RATE | Estimado: $EUR_ESTIMATE EUR"

    # Convertir USDC a EUR usando sell
    log "Convirtiendo $USDC_AMOUNT USDC a EUR..."
    local CONVERT_RESULT
    CONVERT_RESULT=$(coinbase_api POST "/v2/accounts/${USDC_ACCOUNT_ID}/transactions" "$(jq -n \
        --arg amount "$USDC_AMOUNT" \
        '{type: "sell", amount: $amount, currency: "USDC", description: "Auto-conversion to EUR"})' 2>/dev/null)")

    local CONVERT_STATUS
    CONVERT_STATUS=$(echo "$CONVERT_RESULT" | jq -r '.data.status // .error.code // "unknown"')

    if [ "$CONVERT_STATUS" = "completed" ] || [ "$CONVERT_STATUS" = "pending" ]; then
        log "OK Conversion USDC->EUR iniciada: $CONVERT_STATUS (~$EUR_ESTIMATE EUR)"
    else
        log "COINBASE_ERROR en conversion: $CONVERT_STATUS -- $(echo "$CONVERT_RESULT" | jq -r '.error.message // "sin detalle"')"
    fi
}

# ==================================================================================
# MAIN
# ==================================================================================
main() {
    rotate_log
    validate_creds

    local BID_COUNT=0
    local SKIP_COUNT=0
    local ERROR_COUNT=0

    log "=== koi worker v4 iniciado $([ "$DRY_RUN" = true ] && echo '[DRY RUN]') $([ "$SKIP_COINBASE" = true ] && echo '[SKIP COINBASE]') [limit:${TIME_LIMIT}s] ==="

    # 1. Buscar jobs en bidding
    log "Buscando jobs en bidding..."
    local JOBS
    JOBS=$(api_call GET "/api/v1/jobs?limit=20&status=bidding") || {
        log "FATAL: No se pudo obtener jobs"
        exit 1
    }
    local JOB_COUNT
    JOB_COUNT=$(echo "$JOBS" | jq '.data | length // 0')
    log "Jobs en bidding: $JOB_COUNT"

    # 2. Verificar bids existentes
    log "Verificando bids existentes..."
    local EXISTING_BIDS
    EXISTING_BIDS=$(api_call GET "/api/v1/bids/mine") || {
        log "WARN: No se pudo obtener bids existentes"
        echo '{"data":[]}'
    }
    local BID_COUNT_EXISTING
    BID_COUNT_EXISTING=$(echo "$EXISTING_BIDS" | jq '.data | length // 0')
    log "Bids pendientes: $BID_COUNT_EXISTING"

    # 3. Postularme a jobs nuevos y relevantes
    if [ "$JOB_COUNT" -gt 0 ]; then
        local NEW_JOBS
        NEW_JOBS=$(get_new_jobs "$JOBS" "$EXISTING_BIDS")
        local NEW_COUNT
        NEW_COUNT=$(echo "$NEW_JOBS" | jq 'length' 2>/dev/null || echo 0)
        log "Jobs nuevos relevantes: $NEW_COUNT"

        if [ "$NEW_COUNT" -gt 0 ]; then
            echo "$NEW_JOBS" | jq -c '.[]' | while read -r JOB; do

                if should_stop; then
                    log "TIME_LIMIT: Alcanzado limite de tiempo, deteniendo postulaciones"
                    break
                fi

                [ -z "$JOB" ] && continue
                local JOB_ID
                JOB_ID=$(echo "$JOB" | jq -r '.id')
                local JOB_TITLE
                JOB_TITLE=$(echo "$JOB" | jq -r '.title // "sin titulo"')
                local BID_AMOUNT
                BID_AMOUNT=$(calculate_bid "$JOB")
                local PROPOSAL
                PROPOSAL=$(generate_proposal "$JOB")

                if [ "$DRY_RUN" = true ]; then
                    log "[DRY RUN] Postularia a: $JOB_TITLE ($JOB_ID) -- \$$BID_AMOUNT"
                    continue
                fi

                log "Postulandome a: $JOB_TITLE ($JOB_ID) -- oferta: \$$BID_AMOUNT"

                local RESULT
                RESULT=$(api_call POST "/api/v1/jobs/${JOB_ID}/bids" "$(jq -n \
                    --arg amount "$BID_AMOUNT" \
                    --arg proposal "$PROPOSAL" \
                    '{proposedAmount: $amount, proposalText: $proposal}')") || {
                    log "ERROR: Fallo de API al postular a $JOB_TITLE"
                    ERROR_COUNT=$((ERROR_COUNT + 1))
                    continue
                }

                local STATUS
                STATUS=$(echo "$RESULT" | jq -r '.data.status // .error.code // "unknown"')

                case "$STATUS" in
                    CONFLICT|ALREADY_BID)
                        log "Ya postulado a $JOB_ID, saltando..."
                        SKIP_COUNT=$((SKIP_COUNT + 1))
                        ;;
                    CREATED|ACTIVE|PENDING)
                        log "OK Bid creado exitosamente para $JOB_ID ($JOB_TITLE)"
                        BID_COUNT=$((BID_COUNT + 1))
                        ;;
                    INSUFFICIENT_FUNDS)
                        log "WARN Fondos insuficientes para $JOB_ID"
                        ERROR_COUNT=$((ERROR_COUNT + 1))
                        ;;
                    *)
                        local ERR_MSG
                        ERR_MSG=$(echo "$RESULT" | jq -r '.error.message // "sin detalle"' 2>/dev/null)
                        log "Resultado para $JOB_ID: $STATUS — $ERR_MSG"
                        ERROR_COUNT=$((ERROR_COUNT + 1))
                        ;;
                esac

                sleep "$RATE_LIMIT_SECONDS"
            done
        else
            log "No hay jobs nuevos relevantes por ahora."
        fi
    fi

    # 4. Verificar contratos activos
    log "Verificando contratos activos..."
    local CONTRACTS
    CONTRACTS=$(api_call GET "/api/v1/contracts?status=assigned") || {
        log "WARN: No se pudo obtener contratos"
        echo '{"data":[]}'
    }
    local CONTRACT_COUNT
    CONTRACT_COUNT=$(echo "$CONTRACTS" | jq '.data | length // 0')
    log "Contratos activos: $CONTRACT_COUNT"

    # 5. Gestionar contratos
    if [ "$CONTRACT_COUNT" -gt 0 ]; then
        echo "$CONTRACTS" | jq -r '.data[] | "\(.id)\t\(.jobId)\t\(.status)"' | while IFS=$'\t' read -r CONTRACT_ID CONTRACT_JOB_ID CONTRACT_STATUS; do
            log "Contrato: $CONTRACT_ID (job: $CONTRACT_JOB_ID, status: $CONTRACT_STATUS)"

            case "$CONTRACT_STATUS" in
                assigned)
                    log "Marcando contrato $CONTRACT_ID como iniciado..."
                    if [ "$DRY_RUN" != true ]; then
                        api_call POST "/api/v1/contracts/${CONTRACT_ID}/events" '{"type":"START_WORK"}' > /dev/null
                        log "Contrato $CONTRACT_ID marcado como en progreso."
                    else
                        log "[DRY RUN] Marcaria $CONTRACT_ID como iniciado"
                    fi
                    ;;
                in_progress)
                    log "Contrato $CONTRACT_ID ya en progreso. Pendiente de entrega." ;;
                *)
                    log "Contrato $CONTRACT_ID en estado: $CONTRACT_STATUS" ;;
            esac
        done
    fi

    # 6. Verificar contratos en revision
    log "Verificando contratos en revision..."
    local REVIEW_CONTRACTS
    REVIEW_CONTRACTS=$(api_call GET "/api/v1/contracts?status=in_review") || {
        log "WARN: No se pudo obtener contratos en revision"
        echo '{"data":[]}'
    }
    local REVIEW_COUNT
    REVIEW_COUNT=$(echo "$REVIEW_CONTRACTS" | jq '.data | length // 0')
    if [ "$REVIEW_COUNT" -gt 0 ]; then
        log "WARN $REVIEW_COUNT contrato(s) en revision -- verificar calidad"
    fi

    # 7. Verificar y convertir USDC a EUR en Coinbase
    # Solo verificar Coinbase 1 vez por hora para no gastar rate limits
    # Usa archivo de cache para saber cuando fue la ultima verificacion
    local COINBASE_CACHE="/tmp/koi-coinbase-last-check"
    local COINBASE_INTERVAL=3600  # 1 hora
    local DO_COINBASE=false

    if [ "$SKIP_COINBASE" = true ]; then
        log "Coinbase check omitido (--skip-coinbase)"
    elif should_stop; then
        log "TIME_LIMIT: Saltando Coinbase por limite de tiempo"
    else
        local LAST_CHECK=0
        if [ -f "$COINBASE_CACHE" ]; then
            LAST_CHECK=$(cat "$COINBASE_CACHE" 2>/dev/null || echo 0)
        fi
        local NOW_TS
        NOW_TS=$(date +%s)
        local SINCE_LAST=$(( NOW_TS - LAST_CHECK ))
        if [ "$SINCE_LAST" -ge "$COINBASE_INTERVAL" ]; then
            DO_COINBASE=true
        else
            log "Coinbase: Proxima verificacion en $(( COINBASE_INTERVAL - SINCE_LAST ))s"
        fi
    fi

    if [ "$DO_COINBASE" = true ]; then
        if check_and_convert_usdc; then
            date +%s > "$COINBASE_CACHE"
        else
            log "WARN: Coinbase check fallo (no critico)"
        fi
    fi

    local ELAPSED=$(( $(date +%s) - START_TIME ))
    log "=== Worker v4 cycle completado en ${ELAPSED}s | bids:$BID_COUNT skip:$SKIP_COUNT errors:$ERROR_COUNT ==="
}

main
