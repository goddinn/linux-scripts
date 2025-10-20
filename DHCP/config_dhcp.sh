#!/bin/bash
# ===============================================================
# Script: config_dhcp.sh
# Descrição:
# Instala e configura servidor DHCP (kea-dhcp4) no CentOS Stream 10.
# Pede interativamente o estabelecimento de IP Fixo do servidor,
# configuração completa do ficheiro de DHCP com ranges de IP's,
# cria backups de configurações anteriores, valida configurações,
# ajusta firewall e SELinux.
# ===============================================================


set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "[ERRO] Este script deve ser executado como root (sudo)."
  exit 1
fi

echo "==== Instalação do Kea DHCP (pacote kea) ===="
if rpm -q kea &>/dev/null; then
  echo "[OK] Kea DHCP já instalado."
else
  echo "[INFO] A instalar Kea DHCP..."
  yum -y install kea
  echo "[OK] Kea DHCP instalado."
fi
sleep 1

# Caminho do ficheiro de configuração do Kea
KEA_CONF="/etc/kea/kea-dhcp4.conf"

# Backup do ficheiro de configuração antigo, se existir
if [[ -f "${KEA_CONF}" ]]; then
  echo "[INFO] Backup do ficheiro existente: ${KEA_CONF}.backup"
  cp -a "${KEA_CONF}" "${KEA_CONF}.backup"
else
  echo "[INFO] Nenhum ficheiro existente para backup."
fi

#Limpar consola antes de começar o setup
clear

# Função de input validado
request_input() {
  local var_name=$1
  local prompt_msg=$2
  local input_val=""
  while true; do
    read -rp "$prompt_msg: " input_val
    if [[ -n "$input_val" ]]; then
      printf -v "$var_name" '%s' "$input_val"
      echo "[OK] Valor definido para $var_name: ${!var_name}"
      break
    else
      echo "[ERRO] Entrada inválida; por favor insira um valor."
    fi
  done
}

# Conversão IPv4 -> inteiro para validação simples de intervalos
ipv4_to_int() {
  local IFS=.
  read -r o1 o2 o3 o4 <<<"$1"
  echo $(( (o1<<24) + (o2<<16) + (o3<<8) + o4 ))
}

# Loop principal: se não confirmar, volta ao início
while true; do
  echo "==== Configuração de IP estático ===="
  echo "Lista de Placas de Rede disponíveis:"
  ip -o -4 addr show | awk '{print $2}'
  request_input NIC "Nome da interface de rede"
  request_input STATIC_IP "IP fixo do servidor"
  request_input PREFIX "Máscara em prefixo (ex.: 24 para /24)"
  request_input GATEWAY "Gateway da rede"
  request_input DNS "DNS (um ou mais, separados por vírgula)"

    echo "=========================================================="
    echo "Resumo das configurações:"
    echo "- Interface:            $NIC"
    echo "- IP estático:          $STATIC_IP/$PREFIX"
    echo "- Gateway:              $GATEWAY"
    echo "- DNS:                  $DNS"
    echo "=========================================================="


  echo "==== Configuração DHCP Server ===="
  request_input SUBNET_CIDR "Sub-rede CIDR (ex.: 192.168.10.0/24)"
  request_input RANGE_START "Início do range DHCP (ex.: 192.168.10.100)"
  request_input RANGE_END "Fim do range DHCP (ex.: 192.168.10.200)"
  request_input DOMAIN "Nome de domínio (ex.: localdomain)"

  # Validação simples: IP fixo fora do intervalo DHCP
  STATIC_IP_INT=$(ipv4_to_int "${STATIC_IP}")
  RANGE_START_INT=$(ipv4_to_int "${RANGE_START}")
  RANGE_END_INT=$(ipv4_to_int "${RANGE_END}")

  if (( STATIC_IP_INT >= RANGE_START_INT && STATIC_IP_INT <= RANGE_END_INT )); then
    echo "[ERRO] O IP fixo ${STATIC_IP} está dentro do intervalo DHCP ${RANGE_START} - ${RANGE_END}."
    echo "Por favor, escolha um IP fixo fora desse intervalo."
    continue
  else
    echo "[OK] O IP fixo está fora do intervalo DHCP."
  fi

  echo "=========================================================="
  echo "Resumo das configurações:"
  echo "- Interface:            $NIC"
  echo "- IP estático:          $STATIC_IP/$PREFIX"
  echo "- Gateway:              $GATEWAY"
  echo "- DNS:                  $DNS"
  echo "- Sub-rede (CIDR):      $SUBNET_CIDR"
  echo "- Range DHCP:           $RANGE_START - $RANGE_END"
  echo "- Domínio:              $DOMAIN"
  echo "=========================================================="
  read -rp "Confirma as configurações acima? (s/n): " CONFIRM
  if [[ "$CONFIRM" == "s" || "$CONFIRM" == "S" ]]; then
    break
  else
    echo "[INFO] A configuração será repetida desde o início."
  fi
done

# Aplicar IP estático com nmcli
if ! command -v nmcli >/dev/null 2>&1; then
  echo "[ERRO] nmcli não encontrado. Instale o NetworkManager (yum -y install NetworkManager) e volte a executar."
  exit 1
fi

echo "[INFO] A aplicar IP estático na interface $NIC via nmcli..."
CONN_NAME="$(nmcli -t -f NAME,DEVICE connection show --active | awk -F: -v IF="$NIC" '$2==IF{print $1; exit}')"
if [[ -z "$CONN_NAME" ]]; then
  CONN_NAME="$(nmcli -t -f NAME,DEVICE connection show | awk -F: -v IF="$NIC" '$2==IF{print $1; exit}')"
fi
if [[ -z "$CONN_NAME" ]]; then
  echo "[ERRO] Não foi encontrada uma ligação para a interface $NIC no NetworkManager."
  exit 1
fi

nmcli connection modify "$CONN_NAME" \
  ipv4.addresses "$STATIC_IP/$PREFIX" \
  ipv4.gateway "$GATEWAY" \
  ipv4.dns "$DNS" \
  ipv4.method manual autoconnect yes
nmcli connection up "$CONN_NAME" || true
echo "[OK] IP estático configurado na interface $NIC."

# Preparar diretórios e log do Kea
echo "[INFO] A preparar diretórios e logs do Kea..."
mkdir -p /etc/kea /var/log/kea
touch /var/log/kea/kea-dhcp4.log

# Gerar configuração Kea DHCP
echo "[INFO] A escrever configuração em ${KEA_CONF}..."
cat > "${KEA_CONF}" <<EOF
{
  "Dhcp4": {
    "interfaces-config": {
      "interfaces": ["$NIC"]
    },
    "expired-leases-processing": {
      "reclaim-timer-wait-time": 10,
      "flush-reclaimed-timer-wait-time": 25,
      "hold-reclaimed-time": 3600,
      "max-reclaim-leases": 100,
      "max-reclaim-time": 250,
      "unwarned-reclaim-cycles": 5
    },
    "renew-timer": 900,
    "rebind-timer": 1800,
    "valid-lifetime": 3600,
    "option-data": [
      { "name": "domain-name-servers", "data": "$DNS" },
      { "name": "domain-name", "data": "$DOMAIN" }
    ],
    "subnet4": [
      {
        "id": 1,
        "subnet": "$SUBNET_CIDR",
        "pools": [ { "pool": "$RANGE_START - $RANGE_END" } ],
        "option-data": [
          { "name": "routers", "data": "$GATEWAY" }
        ]
      }
    ],
    "loggers": [
      {
        "name": "kea-dhcp4",
        "output-options": [ { "output": "/var/log/kea/kea-dhcp4.log" } ],
        "severity": "INFO",
        "debuglevel": 0
      }
    ]
  }
}
EOF
echo "[OK] Configuração do Kea DHCP escrita com sucesso."

# Ativar serviço e firewall
echo "[INFO] A ativar e iniciar serviço kea-dhcp4..."
systemctl enable --now kea-dhcp4
echo "[OK] Serviço kea-dhcp4 ativo."

echo "[INFO] A abrir porta 67/UDP na firewall..."
firewall-cmd --add-service=dhcp || true
firewall-cmd --add-port=67/udp || true
firewall-cmd --runtime-to-permanent
firewall-cmd --reload
echo "[OK] Porta 67/UDP aberta na firewall."

echo "==== Configuração DHCP concluída com sucesso! ===="

systemctl restart kea-dhcp4
systemctl status kea-dhcp4
