#!/bin/bash
# SCRIPT PARA INSTALAR E CONFIGURAR SERV DE FTP (VFSTPD) NO CentOS 10 STREAM
#COM PASTAS SEPARADAS PARA UPLOAD E DOWNLOAD A USAR AS PORTAS 20 / 21 NA FIREWALL


set -euo pipefail	# FAZ O SCRIPT PARAR AO DAR ALGUM ERRO


# VERIFICA SE O USER É ROOT, SENÃO DÁ MENSAGEM DE ERRO
if [[ "${EUID}" -ne 0 ]]; then
  echo "[ERRO] ESTE SCRIPT TEM DE SER CORRIDO EM ROOT"
  exit 1
fi

# VARIÁVEIS CONFIGURADAS
FTP_USER="${FTP_USER:-ftpuser}"				#  NOME DE UTILIZADOR
FTP_PASSWORD="${FTP_PASSWORD:-P@ssw0rd123!}"		# PASSWORD
FTP_ROOT="${FTP_ROOT:-/srv/ftp}"        		# PASTA RAIZ DO FTP
UPLOAD_DIR="${UPLOAD_DIR:-${FTP_ROOT}/upload}"   	# PASTA PARA UPLOADS
DOWNLOAD_DIR="${DOWNLOAD_DIR:-${FTP_ROOT}/download}"	# PASTA PARA DOWNLOADS
VSFTPD_CONF="/etc/vsftpd/vsftpd.conf"			# FICHEIRO PRINCIPAL DE CONFIG DO FTPD
USERLIST_FILE="/etc/vsftpd/user_list"   		# FICHEIRO PARA EXCLUIR USERS NÃO PERMITIDOS


# FUNCÃO PARA FAZER BACKUP AO FICHEIRO ORIGINAL ANTES DE O ALTERAR
backup_once() {
  local file="$1"
  if [[ -f "${file}" && ! -f "${file}.bak" ]]; then
    cp -a "${file}" "${file}.bak"          		#COPIA O FICHEIRO O ADICIONA .bak
    echo "[OK] BACKUP CRIADO: ${file}.bak"
  fi
}

# FUNÇÃO PARA GARANTIR QUE TODOS OS COMANDOS EXISTEM ANTES DE AVANÇAR
ensure_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "[ERRO] COMANDO NÃO ENCONTRADO: $1"; exit 1; }
}


# VERIFICA SE OS COMANDOS DA FIREWALL ESTAO DISPONIVEIS
ensure_cmd firewall-cmd
ensure_cmd systemctl


# VERIFICA SE O vsftpd JÁ ESTÁ INSTALADO
if rpm -q vsftpd >/dev/null 2>&1; then
  echo "[OK] PACOTE 'vsftpd' JÁ INSTALADO."
else
  echo "[INFO] A INSTALAR 'vsftpd'..."
  dnf -y install vsftpd                     #INSTALA O vsftpd SEM PEDIR CONFIRMAÇÃO
fi



# CRIA OS CAMINHOS DE PASTAS QUE PRECISAMOS PARA DOWNLOAD E UPLOAD
echo "[INFO] A CRIAR DIRETORIOS EM ${FTP_ROOT}..."
mkdir -p "${UPLOAD_DIR}" "${DOWNLOAD_DIR}"



#VERIFICA SE O USER  FTP JÁ EXISTE
if id -u "${FTP_USER}" >/dev/null 2>&1; then
  echo "[OK] USER '${FTP_USER}' JÁ EXISTE."


 # ATUALIZA A PASTA HOME DO USER E DESATIVA A LOGIN POR SHELL POR SEGURANÇA
  usermod -d "${FTP_ROOT}" -s /sbin/nologin "${FTP_USER}" || true
else
  echo "[INFO] A CRIAR USER '${FTP_USER}' COM HOME ${FTP_ROOT}..."
  useradd -d "${FTP_ROOT}" -s /sbin/nologin "${FTP_USER}"	# CRIA USER DE SISTEMA SEM SHELL INTERATIVA
  echo "${FTP_USER}:${FTP_PASSWORD}" | chpasswd			# DEFINE A PASS DO USER
fi

# PERMISSOES PARA O USER FTP TER ACESSO ÁS PASTAS
chown -R "${FTP_USER}:${FTP_USER}" "${FTP_ROOT}"	# OWNER E GROUP DO FTP_ROOT PARA USER FTP
chmod 755 "${FTP_ROOT}"					# PERMISSÕES PADRAO
chmod 755 "${DOWNLOAD_DIR}"
chmod 755 "${UPLOAD_DIR}"

#BACKUP DA CONFIG ATUAL ANTES DE ALTERAR
backup_once "${VSFTPD_CONF}"

# Escreve uma nova configuração base para vsftpd (moda ativo, utilizadores locais com chroot)
echo "[INFO] A ESCREVER CONFIG EM ${VSFTPD_CONF}..."
cat > "${VSFTPD_CONF}.tmp" <<'EOF'
# DESATIVAR LOGIN ANONIMO
anonymous_enable=NO
# PERMITIR USERS LOCAIS
local_enable=YES
# PERMITIR ESCRITA
write_enable=YES
# Máscara para novos ficheiros criados
local_umask=022
# Modo escuta com systemd e IPv6 (modo standalone desativado)
listen=NO
listen_ipv6=YES
# Forçar portas de dados no porto 20 (FTP ativo)
connect_from_port_20=YES
# Proteger o diretório raiz do utilizador com chroot
chroot_local_user=YES
# Permitir escrita dentro do chroot (vsftpd tem restrição por padrão)
allow_writeable_chroot=YES
# Diretório raiz do FTP
local_root=/srv/ftp
# Logs detalhados de transferência
xferlog_enable=YES
xferlog_std_format=YES
use_localtime=YES
# Mensagem exibida ao conectar
ftpd_banner=FTP pronto (vsftpd).
# Só permitir utilizadores listados no ficheiro user_list
userlist_enable=YES
userlist_deny=NO
userlist_file=/etc/vsftpd/user_list
# Autenticação PAM padrão
pam_service_name=vsftpd
# Desativa sandbox seccomp para evitar erros em algumas setups
seccomp_sandbox=NO
EOF

# Substitui o ficheiro de configuração original pelo novo (com permissões adequadas)
install -o root -g root -m 0644 "${VSFTPD_CONF}.tmp" "${VSFTPD_CONF}"
rm -f "${VSFTPD_CONF}.tmp"  # Remove o ficheiro temporário

# Define que só o utilizador FTP terá acesso, lista no user_list
echo "${FTP_USER}" > "${USERLIST_FILE}"
chmod 600 "${USERLIST_FILE}"  # Permissões restritas no ficheiro da lista

# Caso SELinux esteja ativo em enforcing, ativa o boolean básico para permitir escrita FTP
if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce)" == "Enforcing" ]]; then
  echo "[INFO] SELinux em Enforcing: a ajustar boolean ftpd_full_access (básico para escrita)..."
  setsebool -P ftpd_full_access on || true
fi

# Ativa e inicia o serviço vsftpd para arrancar automaticamente no boot
echo "[INFO] A ativar serviço vsftpd no arranque..."
systemctl enable --now vsftpd

# Abre as portas 20 (dados) e 21 (controlo) do FTP na firewall para conexões externas
echo "[INFO] A abrir portas 20 e 21/TCP na firewall..."
firewall-cmd --add-service=ftp || true
firewall-cmd --add-port=20/tcp || true
firewall-cmd --add-port=21/tcp || true
firewall-cmd --runtime-to-permanent  # Persiste as mudanças no firewall
firewall-cmd --reload                # Recarrega a config do firewall

# MOSTRA O ESTADO DO SERVIªO PARA TERMOS A CERTEZA QUE ESTÁ A CORRER OK
systemctl --no-pager --full status vsftpd || true

echo "[SUCESSO] Servidor FTP (vsftpd) configurado e ativo."
echo "[INFO] Utilize as pastas: download (leitura) e upload (escrita) conforme permissões do utilizador."
