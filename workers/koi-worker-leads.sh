#!/bin/bash
# koi-worker-leads.sh — Worker de generación de leads B2B
# Busca empresas sin web o con mala presencia digital y genera leads.
#
# Uso: bash koi-worker-leads.sh [--dry-run] [--verbose] [--time-limit SEC]

set -uo pipefail

CREDS_FILE="$HOME/.openwork/credentials.json"
LOG_FILE="$HOME/.openwork/worker-leads.log"
LEADS_DB="$HOME/.openwork/leads.csv"
LOG_MAX_LINES=5000
CURL_TIMEOUT=10
CURL_MAX_TIME=20
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

init_leads_db() {
    if [ ! -f "$LEADS_DB" ]; then
        echo "id,name,email,phone,website,city,category,source,status,notes,created_at" > "$LEADS_DB"
        log "Base de datos de leads creada"
    fi
}

lead_exists() {
    local name="$1"
    grep -qF "$name" "$LEADS_DB" 2>/dev/null
}

add_lead() {
    local name="$1" email="$2" phone="$3" website="$4" city="$5" category="$6" source="$7" notes="$8"
    local id
    id=$(date +%s%N | cut -c1-13)
    echo "$id,$name,$email,$phone,$website,$city,$category,$source,new,$notes,$(date -Iseconds)" >> "$LEADS_DB"
    log "Lead aadido: $name ($city, $category)"
}

search_businesses() {
    local city="$1"
    local category="$2"
    # Buscar en DuckDuckGo con query más específica
    local query="\"${category}\" \"${city}\" \"email\" contacto"
    
    curl -s "https://html.duckduckgo.com/html/?q=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$query'))")" \
        -H "User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36" 2>/dev/null | \
        python3 -c "
import sys, re, html as h
text = sys.stdin.read()
# Extraer nombres de negocios de los resultados
# Buscar patrones como nombre del negocio seguido de ciudad
results = re.findall(r'result__a[^>]*>([^<]{5,80})</a>', text)
for r in results[:10]:
    r = re.sub(r'<[^>]+>', '', r).strip()
    r = h.unescape(r)
    # Filtrar resultados genéricos
    bad = ['contacto', 'teléfono', 'información', 'dirección', 'navegación', 'inicio', 'blog', 'datos', 'titular', 'página', 'web', 'site']
    if r and len(r) > 5 and not any(b in r.lower() for b in bad):
        print(r)
" 2>/dev/null
}

extract_emails_from_page() {
    local url="$1"
    curl -s --max-time 10 "$url" 2>/dev/null | \
        grep -oE '[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}' | \
        sort -u | head -5
}

send_lead_email() {
    local to_email="$1"
    local lead_name="$2"
    local city="$3"
    local category="$4"
    
    if [ "$DRY_RUN" = true ]; then
        log "[DRY RUN] Email para: $to_email ($lead_name)"
        return 0
    fi
    
    local email_queue="$HOME/.openwork/email_queue"
    echo "${to_email}|${lead_name}|${city}|${category}" >> "$email_queue"
    log "Email encolado: $to_email ($lead_name)"
}

generate_report() {
    local total_leads new_leads contacted
    total_leads=$(tail -n +2 "$LEADS_DB" | wc -l)
    new_leads=$(grep ",new," "$LEADS_DB" 2>/dev/null | wc -l)
    contacted=$(grep ",contacted," "$LEADS_DB" 2>/dev/null | wc -l)
    log "=== REPORTE: Total=$total_leads Nuevos=$new_leads Contactados=$contacted ==="
}

main() {
    rotate_log
    init_leads_db

    local LEAD_COUNT=0
    local SKIP_COUNT=0
    local ERROR_COUNT=0

    log "=== koi leads worker iniciado $([ "$DRY_RUN" = true ] && echo '[DRY_RUN]') ==="

    # Ciudades y categorias
    local CITIES=("Madrid" "Barcelona" "Valencia" "Sevilla" "Bilbao")
    local CATEGORIES=("restaurante" "peluqueria" "gimnasio" "dentista" "abogado" "fontanero" "electricista" "cafeteria")
    
    local DAY_OF_YEAR
    DAY_OF_YEAR=$(date +%j)
    local city_idx=$(( DAY_OF_YEAR % ${#CITIES[@]} ))
    local cat_idx=$(( (DAY_OF_YEAR / 7) % ${#CATEGORIES[@]} ))
    
    local CITY="${CITIES[$city_idx]}"
    local CATEGORY="${CATEGORIES[$cat_idx]}"
    
    log "Buscando: $CATEGORY en $CITY"

    # 1. Buscar negocios
    log "Buscando negocios..."
    local results
    results=$(search_businesses "$CITY" "$CATEGORY")
    
    if [ -z "$results" ]; then
        log "No se encontraron resultados en esta iteracion."
    else
        local count=0
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            count=$((count + 1))
            [ "$count" -gt 10 ] && break
            
            # Extraer nombre del negocio (primeras palabras)
            local name
            name=$(echo "$line" | cut -c1-60)
            
            if lead_exists "$name"; then
                SKIP_COUNT=$((SKIP_COUNT + 1))
                continue
            fi
            
            log "Lead encontrado: $name"
            add_lead "$name" "" "" "" "$CITY" "$CATEGORY" "web_scraping" "Encontrado via DDG"
            LEAD_COUNT=$((LEAD_COUNT + 1))
            
        done <<< "$results"
    fi

    # 2. Buscar emails de contacto genericos de la ciudad
    log "Buscando emails de contacto..."
    local email_results
    email_results=$(curl -s "https://html.duckduckgo.com/html/?q=$(python3 -c "import urllib.parse; print(urllib.parse.quote('email contacto ${CATEGORY} ${CITY}'))")" \
        -H "User-Agent: Mozilla/5.0" 2>/dev/null | \
        grep -oE '[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}' | sort -u | head -10)
    
    if [ -n "$email_results" ]; then
        while IFS= read -r email; do
            [ -z "$email" ] && continue
            local email_name
            email_name=$(echo "$email" | cut -d'@' -f1 | tr '.' ' ')
            if ! lead_exists "$email"; then
                add_lead "$email_name" "$email" "" "" "$CITY" "$CATEGORY" "email_scraping" "Email encontrado"
                LEAD_COUNT=$((LEAD_COUNT + 1))
            fi
        done <<< "$email_results"
    fi

    generate_report

    local ELAPSED=$(( $(date +%s) - START_TIME ))
    log "=== Leads worker completado en ${ELAPSED}s | leads:$LEAD_COUNT skip:$SKIP_COUNT errors:$ERROR_COUNT ==="
}

main
