#!/bin/bash
# ===============================================================
# Script: config_ftp.sh
# Descrição:
# Instala e configura servidor FTP (vsftpd) no CentOS Stream 10.
# Pergunta interativamente o nome de utilizador e password,
# cria diretórios de upload/download, ajusta firewall e SELinux,
# e garante que /sbin/nologin é aceite como shell válida no FTP.
# ===============================================================

# Faz o script parar se houver erro, variável não definida
# ou falha num pipeline (boa prática em scripts de sistema)
set -euo pipefail

# Verifica se o script está a ser executado como root
if [[ "${EUID}" -ne 0 ]]; then
  echo "[ERRO] Executar script como user root (sudo)."
  exit 1
fi

# Limpa consola antes de iniciar o programa
clear

echo "=================================================================="
echo "Bem-vindo ao script de instalcao e configuracao de servidor FTP"
echo "=================================================================="

# Pergunta o nome do utilizador FTP
read -rp "Indicar o nome do utilizador FTP a criar: " FTP_USER

# Pergunta a password de forma segura e confirma-a
while true; do
  read -rsp "Indique a password do utilizador FTP: " FTP_PASSWORD
  echo
  read -rsp "Repita a password: " FTP_PASSWORD2
  echo
  if [[ "$FTP_PASSWORD" == "$FTP_PASSWORD2" ]]; then
    break
  else
    echo "As passwords não coincidem. Tente novamente."
  fi
done

# Caminhos principais e definições
FTP_ROOT="/srv/ftp"                       # Diretório raiz do FTP
UPLOAD_DIR="${FTP_ROOT}/upload"           # Diretório de upload
DOWNLOAD_DIR="${FTP_ROOT}/download"       # Diretório de download
VSFTPD_CONF="/etc/vsftpd/vsftpd.conf"     # Ficheiro de configuração principal
USERLIST_FILE="/etc/vsftpd/user_list"     # Lista de utilizadores permitidos

# Função simples para criar um backup do ficheiro original
backup_once() {
  local file="$1"
  if [[ -f "${file}" && ! -f "${file}.bak" ]]; then
    cp -a "${file}" "${file}.bak"
    echo "[OK] Backup criado: ${file}.bak"
  fi
}

# Função para garantir que comandos essenciais estão disponíveis
ensure_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "[ERRO] Comando não encontrado: $1"; exit 1; }
	}

# Garante que os comandos utilizados estão disponíveis
ensure_cmd firewall-cmd
ensure_cmd systemctl

# Instala o vsftpd se ainda não estiver presente
if rpm -q vsftpd >/dev/null 2>&1; then
  echo "[OK] Pacote 'vsftpd' já instalado."
else
  echo "[INFO] A instalar pacote 'vsftpd'..."
  dnf -y install vsftpd
fi

# Cria os diretórios antes da configuração
echo "[INFO] A criar diretórios base em ${FTP_ROOT}..."
mkdir -p "${UPLOAD_DIR}" "${DOWNLOAD_DIR}"

# Cria o utilizador FTP se não existir
if id -u "${FTP_USER}" >/dev/null 2>&1; then
  echo "[OK] Utilizador '${FTP_USER}' já existe."
  usermod -d "${FTP_ROOT}" -s /sbin/nologin "${FTP_USER}" || true
else
  echo "[INFO] A criar utilizador '${FTP_USER}' com home ${FTP_ROOT} ..."
  useradd -d "${FTP_ROOT}" -s /sbin/nologin "${FTP_USER}"
  echo "${FTP_USER}:${FTP_PASSWORD}" | chpasswd
fi

# Ajusta permissões corretas nos diretórios
chown -R "${FTP_USER}:${FTP_USER}" "${FTP_ROOT}"
chmod 755 "${FTP_ROOT}" "${UPLOAD_DIR}" "${DOWNLOAD_DIR}"

# Corrige o problema "User has an invalid shell '/sbin/nologin'"
# Adicionando /sbin/nologin em /etc/shells se ainda não existir
if ! grep -Fxq "/sbin/nologin" /etc/shells; then
  echo "[INFO] A adicionar /sbin/nologin ao /etc/shells..."
  echo "/sbin/nologin" >> /etc/shells
else
  echo "[OK] /sbin/nologin já está listado em /etc/shells."
fi

# Cria ficheiro de configuração do vsftpd
backup_once "${VSFTPD_CONF}"

echo "[INFO] A escrever configuração em ${VSFTPD_CONF}..."
cat > "${VSFTPD_CONF}.tmp" <<'EOF'
# FTP básico configurado para utilizadores locais
anonymous_enable=NO
local_enable=YES
write_enable=YES
local_umask=022
listen=NO
listen_ipv6=YES
connect_from_port_20=YES
chroot_local_user=YES
allow_writeable_chroot=YES
local_root=/srv/ftp
xferlog_enable=YES
xferlog_std_format=YES
use_localtime=YES
ftpd_banner=FTP pronto (vsftpd).
userlist_enable=YES
userlist_deny=NO
userlist_file=/etc/vsftpd/user_list
pam_service_name=vsftpd
seccomp_sandbox=NO
EOF

install -o root -g root -m 0644 "${VSFTPD_CONF}.tmp" "${VSFTPD_CONF}"
rm -f "${VSFTPD_CONF}.tmp"

# Limita o acesso apenas ao utilizador criado
echo "${FTP_USER}" > "${USERLIST_FILE}"
chmod 600 "${USERLIST_FILE}"

# Ajuste de SELinux se estiver ativo
if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce)" == "Enforcing" ]]; then
  echo "[INFO] SELinux em Enforcing"
  setsebool -P ftpd_full_access on || true
fi

# Ativa e inicia o serviço vsftpd
echo "[INFO] A ativar serviço vsftpd no arranque..."
systemctl enable vsftpd

# Abre as portas necessárias (20 e 21)
echo "[INFO] A abrir portas 20 e 21/TCP na firewall..."
firewall-cmd --add-service=ftp || true
firewall-cmd --add-port=20/tcp || true
firewall-cmd --add-port=21/tcp || true
firewall-cmd --runtime-to-permanent
firewall-cmd --reload

# Mostra o estado final do serviço FTP e reinicia o servico 
systemctl restart vsftpd
systemctl start vsftpd
echo "[INFO] A obter estado do serviço vsftpd"
sleep 2
systemctl status vsftpd

# Criacao de variavel onde mostra o IP da primeira placa de rede onde foi instalado o servidor FTP (removido o CIDR pois criava erro)
HOST="$(ip -4 -o addr show ens160 | awk '/inet /{print $4; exit}' | cut -d/ -f1)"

# Mostra ao user a configuracao final
echo "[SUCESSO] Servidor FTP configurado e ativo!" 
echo "[INFO] Testar login via FileZilla ou outro client FTP:" 
echo "IP Servidor: $HOST"
echo "User: ${FTP_USER}"
echo "Password: (a que definiu)"
echo "Porta: 21"
