#!/bin/bash
# Remove o Agente WRPdv deste PDV: para o serviço e apaga /opt/monitor-wrpdv
# (configuração, token e dados da coleta). O frente não é tocado.
# Uso: sudo bash desinstalar-pdv.sh
set -euo pipefail
SERVICO=agente-wrpdv
[ "$(id -u)" -eq 0 ] || { echo "rode como root: sudo bash $0" >&2; exit 1; }
systemctl disable --now "$SERVICO" 2>/dev/null || true
rm -f "/etc/systemd/system/$SERVICO.service"
systemctl daemon-reload
rm -rf /opt/monitor-wrpdv
echo "Agente removido deste PDV ($(hostname))."
