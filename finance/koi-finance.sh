#!/bin/bash
# koi-finance.sh — Skill financiera de Operación Sustento
# Maneja todo el tema financiero: ingresos, gastos, impuestos, reinversión.
#
# Uso: bash koi-finance.sh [ingreso|gasto|balance|impuestos|reinvertir|reporte|gumroad]

set -uo pipefail

FINANCE_DIR="$HOME/.openclaw/workspace/finance"
LEDGER="$FINANCE_DIR/ledger.csv"
REPORTS_DIR="$FINANCE_DIR/reports"
GUMROAD_DIR="$FINANCE_DIR/gumroad"

# Crear estructura si no existe
mkdir -p "$FINANCE_DIR" "$REPORTS_DIR" "$GUMROAD_DIR"

# Inicializar ledger si no existe
if [ ! -f "$LEDGER" ]; then
    echo "fecha,tipo,categoria,descripcion,moneda,monto,plataforma,notas" > "$LEDGER"
fi

log_finance() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$FINANCE_DIR/finance.log"
}

# === INGRESOS ===
record_income() {
    local categoria="$1"
    local descripcion="$2"
    local moneda="$3"
    local monto="$4"
    local plataforma="$5"
    local notas="${6:-}"
    
    echo "$(date '+%Y-%m-%d'),ingreso,$categoria,$descripcion,$moneda,$monto,$plataforma,$notas" >> "$LEDGER"
    log_finance "INGRESO: $categoria — $descripcion — $monto $moneda ($plataforma)"
    echo "✅ Ingreso registrado: $descripcion ($monto $moneda)"
}

# === GASTOS ===
record_expense() {
    local categoria="$1"
    local descripcion="$2"
    local moneda="$3"
    local monto="$4"
    local plataforma="${5:-}"
    local notas="${6:-}"
    
    echo "$(date '+%Y-%m-%d'),gasto,$categoria,$descripcion,$moneda,$monto,$plataforma,$notas" >> "$LEDGER"
    log_finance "GASTO: $categoria — $descripcion — $monto $moneda"
    echo "✅ Gasto registrado: $descripcion ($monto $moneda)"
}

# === BALANCE ===
show_balance() {
    echo "═══════════════════════════════════════════════════════════════"
    echo "  💰  OPERACIÓN SUSTENTO — Balance Financiero"
    echo "  $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
    
    if [ ! -f "$LEDGER" ] || [ $(wc -l < "$LEDGER") -le 1 ]; then
        echo "  Sin transacciones registradas todavía."
        echo ""
        echo "  Para registrar ingresos:"
        echo "    bash koi-finance.sh ingreso [categoria] [descripcion] [moneda] [monto] [plataforma]"
        echo ""
        echo "  Para registrar gastos:"
        echo "    bash koi-finance.sh gasto [categoria] [descripcion] [moneda] [monto]"
        return
    fi
    
    # Calcular totales por moneda
    echo "  📊 RESUMEN POR MONEDA"
    echo "  ─────────────────────────────────────────────────"
    
    for moneda in USD USDC EUR NEAR OPENWORK; do
        local ingresos
        ingresos=$(grep ",ingreso," "$LEDGER" 2>/dev/null | grep ",$moneda," | awk -F',' '{sum+=$6} END {printf "%.2f", sum+0}')
        local gastos
        gastos=$(grep ",gasto," "$LEDGER" 2>/dev/null | grep ",$moneda," | awk -F',' '{sum+=$6} END {printf "%.2f", sum+0}')
        local balance
        balance=$(echo "$ingresos - $gastos" | bc 2>/dev/null || echo "0")
        
        if [ "$ingresos" != "0.00" ] || [ "$gastos" != "0.00" ]; then
            printf "  %-10s | Ingresos: %10s | Gastos: %10s | Balance: %10s\n" "$moneda" "$ingresos" "$gastos" "$balance"
        fi
    done
    
    echo ""
    echo "  📈 INGRESOS POR CATEGORÍA"
    echo "  ─────────────────────────────────────────────────"
    
    grep ",ingreso," "$LEDGER" 2>/dev/null | awk -F',' '{cat[$3]+=$6} END {for (c in cat) printf "  %-25s %10s\n", c, cat[c]}' | sort -k2 -rn
    
    echo ""
    echo "  📉 GASTOS POR CATEGORÍA"
    echo "  ─────────────────────────────────────────────────"
    
    grep ",gasto," "$LEDGER" 2>/dev/null | awk -F',' '{cat[$3]+=$6} END {for (c in cat) printf "  %-25s %10s\n", c, cat[c]}' | sort -k2 -rn
    
    echo ""
    echo "  🔄 INGRESOS POR PLATAFORMA"
    echo "  ─────────────────────────────────────────────────"
    
    grep ",ingreso," "$LEDGER" 2>/dev/null | awk -F',' '{plat[$7]+=$6} END {for (p in plat) printf "  %-25s %10s\n", p, plat[p]}' | sort -k2 -rn
    
    echo ""
    echo "  📅 ÚLTIMAS 10 TRANSACCIONES"
    echo "  ─────────────────────────────────────────────────"
    tail -10 "$LEDGER" | grep -v "^fecha" | while IFS=',' read -r fecha tipo cat desc moneda monto plataforma notas; do
        if [ "$tipo" = "ingreso" ]; then
            printf "  %s | ✅ %-20s | %s %s | %s\n" "$fecha" "$desc" "$monto" "$moneda" "$plataforma"
        else
            printf "  %s | ❌ %-20s | %s %s | %s\n" "$fecha" "$desc" "$monto" "$moneda" "$plataforma"
        fi
    done
}

# === IMPUESTOS ===
tax_report() {
    echo "═══════════════════════════════════════════════════════════════"
    echo "  📋  OPERACIÓN SUSTENTO — Reporte de Impuestos"
    echo "  $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
    
    local year=$(date '+%Y')
    local mes=$(date '+%m')
    
    echo "  📊 Ingresos del año $year:"
    echo "  ─────────────────────────────────────────────────"
    
    local total_ingresos
    total_ingresos=$(grep ",ingreso," "$LEDGER" 2>/dev/null | grep "^$year" | awk -F',' '{sum+=$6} END {printf "%.2f", sum+0}')
    echo "  Total ingresos: $total_ingresos"
    
    echo ""
    echo "  📊 Gastos del año $year:"
    echo "  ─────────────────────────────────────────────────"
    
    local total_gastos
    total_gastos=$(grep ",gasto," "$LEDGER" 2>/dev/null | grep "^$year" | awk -F',' '{sum+=$6} END {printf "%.2f", sum+0}')
    echo "  Total gastos: $total_gastos"
    
    echo ""
    echo "  💰 Base imponible estimada:"
    echo "  ─────────────────────────────────────────────────"
    
    local base_imponible
    base_imponible=$(echo "$total_ingresos - $total_gastos" | bc 2>/dev/null || echo "0")
    echo "  Ingresos - Gastos = $base_imponible"
    
    echo ""
    echo "  ⚠️  NOTA: Este es un reporte estimado."
    echo "  Consulta con un contador para declaración oficial."
    echo ""
    echo "  📝 Categorías de gastos deducibles:"
    echo "    - Servicios de hosting y cloud"
    echo "    - APIs y herramientas de desarrollo"
    echo "    - Software y licencias"
    echo "    - Marketing y publicidad"
    echo "    - Formación y educación"
    echo "    - Gastos de oficina (proporcional)"
}

# === REINVERSIÓN ===
reinvest_analysis() {
    echo "═══════════════════════════════════════════════════════════════"
    echo "  🔄  OPERACIÓN SUSTENTO — Análisis de Reinversión"
    echo "  $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
    
    local total_ingresos
    total_ingresos=$(grep ",ingreso," "$LEDGER" 2>/dev/null | awk -F',' '{sum+=$6} END {printf "%.2f", sum+0}')
    local total_gastos
    total_gastos=$(grep ",gasto," "$LEDGER" 2>/dev/null | awk -F',' '{sum+=$6} END {printf "%.2f", sum+0}')
    local balance
    balance=$(echo "$total_ingresos - $total_gastos" | bc 2>/dev/null || echo "0")
    
    echo "  Balance actual: $balance"
    echo ""
    
    if (( $(echo "$balance > 0" | bc -l 2>/dev/null || echo 0) )); then
        echo "  📊 Distribución recomendada de ganancias:"
        echo "  ─────────────────────────────────────────────────"
        
        local reinvertir
        reinvertir=$(echo "$balance * 0.40" | bc 2>/dev/null || echo "0")
        local reservar_impuestos
        reservar_impuestos=$(echo "$balance * 0.30" | bc 2>/dev/null || echo "0")
        local retirar
        retirar=$(echo "$balance * 0.30" | bc 2>/dev/null || echo "0")
        
        printf "  🔄 Reinvertir (40%%):     %s\n" "$reinvertir"
        printf "  🏦 Reservar impuestos (30%%): %s\n" "$reservar_impuestos"
        printf "  💸 Retirar (30%%):         %s\n" "$retirar"
        
        echo ""
        echo "  🎯 Opciones de reinversión:"
        echo "    1. Más plataformas freelance (API keys, verificación)"
        echo "    2. Publicidad en redes sociales"
        echo "    3. Herramientas de automatización"
        echo "    4. Formación y skills nuevos"
        echo "    5. Contratar sub-agents"
    else
        echo "  ⚠️  Sin ganancias para reinvertir todavía."
        echo "  Sigue trabajando en generar ingresos primero."
    fi
}

# === GUMROAD ===
gumroad_status() {
    echo "═══════════════════════════════════════════════════════════════"
    echo "  🛒  OPERACIÓN SUSTENTO — Gumroad Store"
    echo "  $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
    
    # Verificar si hay API key configurada
    if [ -f "$GUMROAD_DIR/api_key.txt" ]; then
        echo "  ✅ API key configurada"
        # Aquí se conectaría a la API de Gumroad
        echo "  📦 Productos en Gumroad:"
        echo "    (Requiere conexión API)"
    else
        echo "  ⚠️  API key de Gumroad no configurada"
        echo ""
        echo "  Para configurar:"
        echo "    1. Ve a https://gumroad.com/settings/advanced"
        echo "    2. Generate API key"
        echo "    3. Guarda la key:"
        echo "       echo 'TU_API_KEY' > ~/.openclaw/workspace/finance/gumroad/api_key.txt"
    fi
    
    echo ""
    echo "  📦 Productos listos para subir:"
    echo "  ─────────────────────────────────────────────────"
    
    local products_dir="$HOME/david/.openclaw/workspace/products"
    for dir in prompt-packs n8n-workflows agent-templates guides; do
        if [ -d "$products_dir/$dir" ]; then
            local count
            count=$(ls "$products_dir/$dir"/*.{md,json} 2>/dev/null | wc -l)
            echo "    ✅ $dir: $count archivo(s)"
        fi
    done
    
    echo ""
    echo "  💡 Estrategia de precios recomendada:"
    echo "    Prompt Pack:     \$19 (entry level)"
    echo "    n8n Workflow:    \$49 (mid tier)"
    echo "    Agent Template:  \$99 (premium)"
    echo "    Guide:           \$29 (education)"
    echo "    Bundle:         \$149 (ahorro \$47)"
}

# === REPORTE COMPLETO ===
full_report() {
    local report_file="$REPORTS_DIR/report-$(date '+%Y-%m-%d').txt"
    
    {
        echo "═══════════════════════════════════════════════════════════════"
        echo "  🎏  OPERACIÓN SUSTENTO — Reporte Financiero Completo"
        echo "  Generado: $(date '+%Y-%m-%d %H:%M:%S %Z')"
        echo "═══════════════════════════════════════════════════════════════"
        echo ""
        
        echo "=== BALANCE ==="
        show_balance 2>/dev/null
        echo ""
        
        echo "=== IMPUESTOS ==="
        tax_report 2>/dev/null
        echo ""
        
        echo "=== REINVERSIÓN ==="
        reinvest_analysis 2>/dev/null
        echo ""
        
        echo "=== GUMROAD ==="
        gumroad_status 2>/dev/null
        
    } > "$report_file"
    
    echo "📄 Reporte guardado en: $report_file"
    cat "$report_file"
}

# === MAIN ===
case "${1:-balance}" in
    ingreso)
        record_income "$2" "$3" "$4" "$5" "$6" "${7:-}"
        ;;
    gasto)
        record_expense "$2" "$3" "$4" "$5" "${6:-}" "${7:-}"
        ;;
    balance)
        show_balance
        ;;
    impuestos)
        tax_report
        ;;
    reinvertir)
        reinvest_analysis
        ;;
    gumroad)
        gumroad_status
        ;;
    reporte)
        full_report
        ;;
    *)
        echo "Uso: bash koi-finance.sh [ingreso|gasto|balance|impuestos|reinvertir|gumroad|reporte]"
        echo ""
        echo "Ejemplos:"
        echo "  bash koi-finance.sh ingreso freelance 'Blog post' USD 25 ClawGig"
        echo "  bash koi-finance.sh gasto hosting 'VPS mensual' USD 10 Hetzner"
        echo "  bash koi-finance.sh balance"
        echo "  bash koi-finance.sh reporte"
        ;;
esac
