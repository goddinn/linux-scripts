#!/bin/bash

set -euo pipefail

yum clean packages
yum -y update
yum -y upgrade
yum -y install kea

# Caminho do ficheiro de configuração do Kea
KEA_CONF="/etc/kea/kea-dhcp4.conf"

#Limpar consola antes da configuração pelo user
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

  # Validação simples: IP fixo fora do intervalo DHCP
  STATIC_IP_INT=$(ipv4_to_int "${STATIC_IP}")
  RANGE_START_INT=$(ipv4_to_int "${RANGE_START}")
  RANGE_END_INT=$(ipv4_to_int "${RANGE_END}")

# Aplicar IP estático com nmcli
if ! command -v nmcli >/dev/null 2>&1; then
  echo "[ERRO] Instalar o NetworkManager (yum -y install NetworkManager) e voltar a executar."
  exit 1
fi


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

#Ativar serviço e firewall
systemctl enable --now kea-dhcp4

firewall-cmd --add-service=dhcp || true
firewall-cmd --add-port=67/udp || true
firewall-cmd --runtime-to-permanent
firewall-cmd --reload

systemctl restart kea-dhcp4
