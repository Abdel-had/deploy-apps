#!/bin/bash
set -euo pipefail

# === Params ===
PROJECT_DIR="${PROJECT_DIR:-/opt/n8n-traefik}"
SSH_PORT="${SSH_PORT:-2222}"
ADMIN_USER="${ADMIN_USER:-aha_admin}"
ALLOW_IPS=("88.122.144.169" "185.22.198.1")

# === Helpers ===
require_root(){ [[ $EUID -eq 0 ]] || { echo "Exécute en root"; exit 1; }; }
have(){ command -v "$1" >/dev/null 2>&1; }

# === APT base + nettoyage doublons ===
apt_prep(){
  if [[ -f /etc/apt/sources.list.d/ubuntu-mirrors.list ]]; then
    sort -u /etc/apt/sources.list.d/ubuntu-mirrors.list -o /etc/apt/sources.list.d/ubuntu-mirrors.list || true
  fi
  apt-get update -y
  apt-get install -y ca-certificates curl ufw jq gpg lsb-release
}

# === Docker/Compose si absents ===
install_docker_if_needed(){
  if ! have docker; then
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(
      . /etc/os-release; echo ${UBUNTU_CODENAME:-$(lsb_release -cs)}
    ) stable" > /etc/apt/sources.list.d/docker.list
    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker
  fi
  have docker && docker compose version >/dev/null 2>&1 || apt-get install -y docker-compose-plugin
}

# === Utilisateur admin ===
ensure_admin_user(){
  id -u "$ADMIN_USER" >/dev/null 2>&1 || adduser --disabled-password --gecos "" "$ADMIN_USER"
  usermod -aG sudo "$ADMIN_USER" || true
  usermod -aG docker "$ADMIN_USER" || true
  mkdir -p /home/"$ADMIN_USER"/.ssh
  chmod 700 /home/"$ADMIN_USER"/.ssh
  touch /home/"$ADMIN_USER"/.ssh/authorized_keys
  chmod 600 /home/"$ADMIN_USER"/.ssh/authorized_keys
  chown -R "$ADMIN_USER":"$ADMIN_USER" /home/"$ADMIN_USER"/.ssh
}

# === SSH + UFW (idempotent) ===
lockdown_ssh_ufw(){
  local cfg="/etc/ssh/sshd_config"
  [[ -f ${cfg}.bak ]] || cp -a "$cfg" "${cfg}.bak"

  # Port, root et mot de passe
  sed -i -E \
    -e "s@^[# ]*Port .*@Port ${SSH_PORT}@g" \
    -e "s@^[# ]*PermitRootLogin .*@PermitRootLogin no@g" \
    -e "s@^[# ]*PasswordAuthentication .*@PasswordAuthentication no@g" \
    "$cfg"

  # AllowUsers
  if grep -qE "^[# ]*AllowUsers " "$cfg"; then
    sed -i -E "s@^[# ]*AllowUsers .*@AllowUsers ${ADMIN_USER}@g" "$cfg"
  else
    echo "AllowUsers ${ADMIN_USER}" >> "$cfg"
  fi

  # UFW sans reset complet
  ufw default deny incoming || true
  ufw default allow outgoing || true
  # Nettoyage règles SSH existantes
  ufw deny "${SSH_PORT}"/tcp >/dev/null 2>&1 || true
  ufw delete allow "${SSH_PORT}"/tcp >/dev/null 2>&1 || true
  ufw delete allow 22/tcp >/dev/null 2>&1 || true
  # Ajout règles IP sources autorisées
  for ip in "${ALLOW_IPS[@]}"; do
    ufw allow from "$ip" to any port "${SSH_PORT}" proto tcp || true
  done
  # Web
  ufw allow 80/tcp || true
  ufw allow 443/tcp || true
  yes | ufw enable >/dev/null 2>&1 || true

  # Valide et restart ssh
  sshd -t
  systemctl daemon-reload
  systemctl is-active ssh.socket >/dev/null 2>&1 && systemctl restart ssh.socket || systemctl restart ssh
}

# === Fichiers docker ===
write_files(){
  mkdir -p "${PROJECT_DIR}"
  cd "${PROJECT_DIR}"

  # docker-compose.yml (exact demandé)
  cat > docker-compose.yml <<'YAML'
services:
  traefik:
    image: "traefik"
    restart: always
    command:
      - "--api=true"
      - "--providers.docker=true"
      - "--providers.docker.exposedbydefault=false"
      - "--entrypoints.web.address=:80"
      - "--entrypoints.web.http.redirections.entryPoint.to=websecure"
      - "--entrypoints.web.http.redirections.entrypoint.scheme=https"
      - "--entrypoints.websecure.address=:443"
      - "--certificatesresolvers.mytlschallenge.acme.tlschallenge=true"
      - "--certificatesresolvers.mytlschallenge.acme.email=${SSL_EMAIL}"
      - "--certificatesresolvers.mytlschallenge.acme.storage=/letsencrypt/acme.json"
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - traefik_data:/letsencrypt
      - /var/run/docker.sock:/var/run/docker.sock:ro

  n8n:
    image: docker.n8n.io/n8nio/n8n
    restart: always
    ports:
      - "127.0.0.1:5678:5678"
    labels:
      - traefik.enable=true
      - traefik.http.routers.n8n.rule=Host(`${DOMAIN_NAME}`)
      - traefik.http.routers.n8n.tls=true
      - traefik.http.routers.n8n.entrypoints=web,websecure
      - traefik.http.routers.n8n.tls.certresolver=mytlschallenge
      - traefik.http.middlewares.n8n.headers.SSLRedirect=true
      - traefik.http.middlewares.n8n.headers.STSSeconds=315360000
      - traefik.http.middlewares.n8n.headers.browserXSSFilter=true
      - traefik.http.middlewares.n8n.headers.contentTypeNosniff=true
      - traefik.http.middlewares.n8n.headers.forceSTSHeader=true
      - traefik.http.middlewares.n8n.headers.SSLHost=${DOMAIN_NAME}
      - traefik.http.middlewares.n8n.headers.STSIncludeSubdomains=true
      - traefik.http.middlewares.n8n.headers.STSPreload=true
      - traefik.http.routers.n8n.middlewares=n8n@docker
    environment:
      - N8N_HOST=${DOMAIN_NAME}
      - N8N_PORT=5678
      - N8N_PROTOCOL=https
      - NODE_ENV=production
      - WEBHOOK_URL=https://${DOMAIN_NAME}/
      - GENERIC_TIMEZONE=${GENERIC_TIMEZONE}
    volumes:
      - n8n_data:/home/node/.n8n
      - /local-files:/files

volumes:
  traefik_data:
    external: true
  n8n_data:
    external: true
YAML

  # .env (exact demandé)
  cat > .env <<'ENV'
# The top level domain to serve from
DOMAIN_NAME=chamssan8n.online

# The subdomain to serve from
# SUBDOMAIN=n8n

# DOMAIN_NAME and SUBDOMAIN combined decide where n8n will be reachable from
# above example would result in: https://n8n.srv972555.hstgr.cloud

# Optional timezone to set which gets used by Cron-Node by default
# If not set New York time will be used
GENERIC_TIMEZONE=Europe/Berlin

# The email address to use for the SSL certificate creation
SSL_EMAIL=chamssane.attoumani@live.fr
ENV
}

# === Volumes + stack (idempotent) ===
deploy_stack(){
  cd "${PROJECT_DIR}"
  docker volume inspect traefik_data >/dev/null 2>&1 || docker volume create traefik_data
  docker run --rm -v traefik_data:/v alpine:latest sh -c "touch /v/acme.json && chmod 600 /v/acme.json"
  docker volume inspect n8n_data >/dev/null 2>&1 || docker volume create n8n_data
  docker compose pull
  docker compose up -d
}

# === Main ===
require_root
apt_prep
install_docker_if_needed
ensure_admin_user
lockdown_ssh_ufw
write_files
deploy_stack

echo "OK. Fichiers dans ${PROJECT_DIR}. SSH ${SSH_PORT} uniquement ${ADMIN_USER} depuis ${ALLOW_IPS[*]}."
echo "Commande utile: cd ${PROJECT_DIR} && docker compose logs -f traefik"
