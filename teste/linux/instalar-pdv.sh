#!/bin/bash
# ==========================================================================
#  Instala o Agente WRPdv neste PDV (Ubuntu), como serviço do systemd.
#
#  - copia o agente para /opt/monitor-wrpdv (o agente.toml que já existir fica)
#  - pergunta o token da LOJA (painel da central, "Token de loja")
#  - acha a pasta do frente pelo processo aberto (ou usa /home/rpdv/frente)
#  - o agente só observa: não mexe no frente, nos .ini nem nos bancos
#
#  Uso, como root:
#    sudo bash instalar-pdv.sh
#  Em lote (WinSCP em modo script, SSH), sem perguntas:
#    sudo TOKEN=wrpdv_... bash instalar-pdv.sh
#  Opcionais: CANAL=teste (versões de teste), PASTA_FRENTE=/home/rpdv/frente,
#             NOME=pdv103 (nome na central, se o do computador for genérico)
# ==========================================================================
set -euo pipefail

DESTINO=/opt/monitor-wrpdv
SERVICO=agente-wrpdv
BASE=https://raw.githubusercontent.com/FireC4io/monitor-wrpdv-versoes/main
CENTRAL=https://monitorallapp.duckdns.org/api/v1/envio
CANAL=${CANAL:-atual}

falha() { echo "ERRO: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || falha "rode como root: sudo bash $0"
[ "$(uname -m)" = x86_64 ] || falha "este agente é para PDV de 64 bits (x86_64); este é $(uname -m)"
command -v systemctl >/dev/null || falha "este Linux não tem systemd"
case "$CANAL" in atual|teste) ;; *) falha "CANAL deve ser atual ou teste" ;; esac

baixar() { # url destino
    if command -v curl >/dev/null; then curl -fsSL --retry 3 -o "$2" "$1"
    elif command -v wget >/dev/null; then wget -q -O "$2" "$1"
    else falha "sem curl nem wget para baixar o agente"; fi
}

# 1. o agente: ao lado deste script (pacote do Actions) ou baixado do canal
TEMP=$(mktemp -d)
trap 'rm -rf "$TEMP"' EXIT
AQUI=$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" && pwd)
if [ -f "$AQUI/agente-wrpdv" ]; then
    BIN="$AQUI/agente-wrpdv"
    echo "Usando o agente desta pasta: $BIN"
else
    echo "Baixando o agente (canal $CANAL)..."
    baixar "$BASE/$CANAL/linux/manifesto.json" "$TEMP/manifesto.json"
    url=$(sed -n 's/.*"url": *"\([^"]*\)".*/\1/p' "$TEMP/manifesto.json")
    sha=$(sed -n 's/.*"sha256": *"\([0-9a-fA-F]\{64\}\)".*/\1/p' "$TEMP/manifesto.json")
    if [ -z "$url" ] || [ -z "$sha" ]; then falha "manifesto do canal $CANAL sem url ou sha256"; fi
    # só do repositório de versões, por HTTPS (as atualizações seguintes conferem a assinatura)
    case "$url" in "$BASE/"*) ;; *) falha "endereço inesperado no manifesto: $url" ;; esac
    baixar "$url" "$TEMP/agente-wrpdv"
    echo "$sha  $TEMP/agente-wrpdv" | sha256sum -c --quiet - || falha "o agente baixado não confere com o manifesto"
    BIN="$TEMP/agente-wrpdv"
fi
chmod 755 "$BIN"
"$BIN" --versao >/dev/null || falha "o agente não roda neste PDV"

# 2. pasta do frente: a do processo aberto vale mais que a padrão
if [ -z "${PASTA_FRENTE:-}" ]; then
    pid=$(pgrep -x frente | head -1 || true)
    if [ -n "$pid" ] && [ -e "/proc/$pid/exe" ]; then
        PASTA_FRENTE=$(dirname "$(readlink "/proc/$pid/exe")")
    else
        PASTA_FRENTE=/home/rpdv/frente
    fi
fi
[[ "$PASTA_FRENTE" =~ ^/[A-Za-z0-9/_.-]+$ ]] || falha "pasta do frente com caracteres inesperados: $PASTA_FRENTE"
[ -d "$PASTA_FRENTE/Cm" ] || echo "Aviso: não achei $PASTA_FRENTE/Cm (o log do frente vai aparecer como não encontrado)"

# 3. token da loja (Enter = mantém o que já estiver no agente.toml)
TOKEN=${TOKEN:-}
if [ -z "$TOKEN" ] && [ -e /dev/tty ] && ! grep -qs '^token = "wrpdv_' "$DESTINO/agente.toml"; then
    read -r -p "Token da loja (painel da central, \"Token de loja\"): " TOKEN </dev/tty || true
fi

# 4. instalar
systemctl stop "$SERVICO" 2>/dev/null || true
install -d -m 755 "$DESTINO"
install -m 755 "$BIN" "$DESTINO/agente-wrpdv"
TOML="$DESTINO/agente.toml"
novo=0
[ -f "$TOML" ] || novo=1
AGENTE_TOKEN="$TOKEN" AGENTE_CENTRAL="$CENTRAL" AGENTE_NOME="${NOME:-}" "$DESTINO/agente-wrpdv" --config "$TOML" --configurar
if [ "$novo" = 1 ]; then
    sed -i "s#^frente = { pasta = \"[^\"]*\"#frente = { pasta = \"$PASTA_FRENTE/Cm\"#" "$TOML"
fi
if [ "$CANAL" = teste ]; then
    sed -i "s#^url_manifesto = .*#url_manifesto = \"$BASE/teste/linux/manifesto.json\"#" "$TOML"
fi
chmod 600 "$TOML" # tem o token

cat > "/etc/systemd/system/$SERVICO.service" <<FIM
[Unit]
Description=Agente Monitor WRPdv (PDV): só observa o frente, a rede e o disco
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=$DESTINO/agente-wrpdv --config $TOML
WorkingDirectory=$DESTINO
# a atualização automática troca o binário e sai: o systemd abre a versão nova
Restart=always
RestartSec=10
# leve: o PDV tem 1 núcleo e o caixa vem primeiro
Nice=10
IOSchedulingClass=idle
CPUQuota=20%
MemoryMax=150M
# só grava na própria pasta; o resto do sistema (e o /home do frente) é só leitura
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=$DESTINO
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
FIM

systemctl daemon-reload
systemctl enable --now "$SERVICO" >/dev/null
sleep 5
if systemctl is-active --quiet "$SERVICO"; then
    echo
    echo "Agente $("$DESTINO/agente-wrpdv" --versao) instalado e rodando neste PDV ($(hostname))."
    echo "Frente em $PASTA_FRENTE | configuração em $TOML"
    echo "Ver o que ele está fazendo: journalctl -u $SERVICO -f"
else
    journalctl -u "$SERVICO" -n 20 --no-pager || true
    falha "o serviço não ficou de pé (veja acima)"
fi
