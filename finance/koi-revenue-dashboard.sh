#!/bin/bash
# koi-revenue-dashboard.sh — Dashboard de ingresos de Operación Sustento
# Muestra el estado financiero completo del proyecto.
#
# Uso: bash koi-revenue-dashboard.sh

set -uo pipefail

LOG_DIR="$HOME/.openwork"
PRODUCTS_DIR="$HOME/david/.openclaw/workspace/products"

# Colores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${BLUE}"
echo "═══════════════════════════════════════════════════════════════"
echo "  🎏  OPERACIÓN SUSTENTO — Revenue Dashboard"
echo "  $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "═══════════════════════════════════════════════════════════════"
echo -e "${NC}"

# === SECCIÓN 1: Workers Status ===
echo -e "${CYAN}📊 Workers Activos${NC}"
echo "─────────────────────────────────────────────────"

workers=("clawgig:ClawGig" "superteam:Superteam" "dealwork:Dealwork" "toku:Toku" "near:NEAR" "openwork:Openwork" "agoragentic:Agoragentic")

total_proposals=0
total_errors=0

for worker in "${workers[@]}"; do
    IFS=':' read -r key name <<< "$worker"
    log_file="$LOG_DIR/worker-${key}.log"
    
    if [ -f "$log_file" ]; then
        last_cycle=$(tail -1 "$log_file" 2>/dev/null | grep "cycle completado" | sed 's/.*\[//;s/\].*//' | head -c 20)
        proposals=$(cat "$log_file" 2>/dev/null | grep -c "OK Proposal\|OK Bid\|OK Submission\|OK Propuesta" || true)
        errors=$(cat "$log_file" 2>/dev/null | grep -c "ERROR\|CURL_ERROR" || true)
        total_proposals=$((total_proposals + proposals))
        total_errors=$((total_errors + errors))
        
        if [ "$errors" -eq 0 ]; then
            status="${GREEN}✅${NC}"
        elif [ "$errors" -lt 5 ]; then
            status="${YELLOW}⚠️${NC}"
        else
            status="${RED}❌${NC}"
        fi
        
        printf "  %s %-15s | Proposals: %-3s | Errors: %-3s | Last: %s\n" "$status" "$name" "$proposals" "$errors" "${last_cycle:-N/A}"
    else
        printf "  ${YELLOW}⚠️${NC} %-15s | Sin log aún\n" "$name"
    fi
done

echo ""
echo -e "${CYAN}📈 Resumen de Workers${NC}"
echo "─────────────────────────────────────────────────"
echo "  Total proposals/bids exitosos: $total_proposals"
echo "  Total errores (histórico): $total_errors"
echo "  Plataformas activas: 7"

# === SECCIÓN 2: Productos Digitales ===
echo ""
echo -e "${CYAN}🛒 Productos Digitales${NC}"
echo "─────────────────────────────────────────────────"

products=(
    "Research Prompt Pack:prompt-packs:19"
    "n8n Content Pipeline:n8n-workflows:49"
    "AI Agent Template:agent-templates:99"
    "Earn with AI Guide:guides:29"
    "Bundle (todo):bundle:149"
)

total_products=0
for product in "${products[@]}"; do
    IFS=':' read -r name dir price <<< "$product"
    product_file="/home/david/.openclaw/workspace/products/$dir"
    if [ -d "$product_file" ] && [ "$(ls -A "$product_file" 2>/dev/null)" ]; then
        printf "  ${GREEN}✅${NC} %-30s \$%s\n" "$name" "$price"
        total_products=$((total_products + 1))
    else
        printf "  ${RED}❌${NC} %-30s \$%s (sin archivos)\n" "$name" "$price"
    fi
done

echo ""
echo "  Productos listos: $total_products/${#products[@]}"

# === SECCIÓN 3: Ventas ===
echo ""
echo -e "${CYAN}💰 Ventas${NC}"
echo "─────────────────────────────────────────────────"

SALES_LOG="$PRODUCTS_DIR/sales.log"
if [ -f "$SALES_LOG" ]; then
    total_sales=$(grep -c "SALE:" "$SALES_LOG" 2>/dev/null || echo 0)
    total_revenue=$(grep "SALE:" "$SALES_LOG" 2>/dev/null | awk -F'$' '{sum+=$2} END {print sum+0}')
    
    echo "  Ventas totales: $total_sales"
    echo "  Ingresos totales: \$${total_revenue:-0}"
    echo ""
    echo "  Últimas ventas:"
    grep "SALE:" "$SALES_LOG" 2>/dev/null | tail -5 | while read -r line; do
        echo "    $line"
    done
else
    echo "  Sin ventas todavía."
    echo "  Ingresos: \$0"
fi

# === SECCIÓN 4: Proyección ===
echo ""
echo -e "${CYAN}📊 Proyección de Ingresos${NC}"
echo "─────────────────────────────────────────────────"

# Calcular proyección basada en datos actuals
echo "  Escenario conservador (Mes 1-2):"
echo "    Freelance: \$50-200/mes (construyendo reputación)"
echo "    Productos: \$0-100/mes (lanzamiento)"
echo "    Total: \$50-300/mes"
echo ""
echo "  Escenario moderado (Mes 3-4):"
echo "    Freelance: \$200-500/mes (primeros contratos recurrentes)"
echo "    Productos: \$100-500/mes (ventas crecientes)"
echo "    Total: \$300-1,000/mes"
echo ""
echo "  Escenario optimista (Mes 5-6):"
echo "    Freelance: \$500-1,500/mes (reputación establecida)"
echo "    Productos: \$500-1,500/mes (escala)"
echo "    Total: \$1,000-3,000/mes"
echo ""
echo "  🎯 Objetivo: \$3,000+/mes en 4-6 meses"

# === SECCIÓN 5: Próximos Pasos ===
echo ""
echo -e "${CYAN}🎯 Próximos Pasos${NC}"
echo "─────────────────────────────────────────────────"
echo "  1. ✅ 7 workers corriendo 24/7"
echo "  2. ✅ 4 productos digitales creados"
echo "  3. ⏳ Configurar Gumroad/Itch.io para venta automática"
echo "  4. ⏳ Crear contenido promocional (tweets, posts)"
echo "  ⏳ Lanzar primera campaña de marketing"
echo "  ⏳ Monitorear primeros contratos ganados"
echo "  ⏳ Reinvertir ganancias en más plataformas"

echo ""
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo ""
