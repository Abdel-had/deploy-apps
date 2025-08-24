#!/usr/bin/env bash
# setup-n8n-traefik.sh
# Usage: sudo bash setup-n8n-traefik.sh
set -euo pipefail

# Variables
PROJECT_DIR="${PROJECT_DIR:-/opt/n8n-traefik}"
SSH_PORT="${SSH_PORT:-2222}"
ADMIN_USER="${ADMIN_USER:-aha_admin}"
ALLOW_IPS=("88.122.144.169" "185.22.198.1")

# 1) Prérequis
require_root(){ [[ $EUID -eq 0 ]] || { echo "Exécute en root"; exit 1; }; }
pkg_install_if_missing(){ command -v "$1" >/dev/null 2>&1 || apt-get install -y "$2"; }

install_base(){
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  pkg_install_if_missing curl curl
  pkg_install_if_missing ufw ufw
  pkg_install_if_missing sudo sudo
  pkg_install_if_missing gpg gpg
  pkg_install_if_missing lsb_release lsb-release
  pkg_install_if_missing ca-certificates ca-certificates
}

# 2) Docker si absent
install_docker_if_needed(){
  if ! command -v docker >/dev/null 2>&1; then
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release; echo ${UBUNTU_CODENAME:-$(lsb_release -cs)}) stable" > /etc/apt/sources.list.d/docker.list
    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker
  fi
  docker compose version >/dev/null 2>&1 || apt-get install -y docker-compose-plugin
}

# 3) Utilisateur
ensure_admin_user(){
  id -u "$ADMIN_USER" >/dev/null 2>&1 || adduser --disabled-password --gecos "" "$ADMIN_USER"
  usermod -aG sudo "$ADMIN_USER"
  usermod -aG docker "$ADMIN_USER"
  mkdir -p /home/"$ADMIN_USER"/.ssh
  chmod 700 /home/"$ADMIN_USER"/.ssh
  touch /home/"$ADMIN_USER"/.ssh/authorized_keys
  chmod 600 /home/"$ADMIN_USER"/.ssh/authorized_keys
  chown -R "$ADMIN_USER":"$ADMIN_USER" /home/"$ADMIN_USER"/.ssh
}

# 4) SSH et UFW
configure_sshd_and_ufw(){
  local cfg="/etc/ssh/sshd_config"
  [[ -f ${cfg}.bak ]] || cp -a "$cfg" ${cfg}.bak

  sed -i -E \
    -e "s@^[# ]*Port .*@Port ${SSH_PORT}@g" \
    -e "s@^[# ]*PermitRootLogin .*@PermitRootLogin no@g" \
    -e "s@^[# ]*PasswordAuthentication .*@PasswordAuthentication no@g" \
    "$cfg"

  if grep -qE "^[# ]*AllowUsers " "$cfg"; then
    sed -i -E "s@^[# ]*AllowUsers .*@AllowUsers ${ADMIN_USER}@g" "$cfg"
  else
    echo "AllowUsers ${ADMIN_USER}" >> "$cfg"
  fi

  ufw default deny incoming || true
  ufw default allow outgoing || true
  ufw delete allow 22/tcp 2>/dev/null || true
  ufw delete allow "${SSH_PORT}"/tcp 2>/dev/null || true
  for ip in "${ALLOW_IPS[@]}"; do
    ufw allow from "$ip" to any port "${SSH_PORT}" proto tcp
  done
  ufw allow 80/tcp
  ufw allow 443/tcp
  yes | ufw enable >/dev/null 2>&1 || true

  sshd -t
  systemctl daemon-reload
  systemctl is-active ssh.socket >/dev/null 2>&1 && systemctl restart ssh.socket || systemctl restart ssh
}

# 5) Fichiers
write_files(){
  mkdir -p "${PROJECT_DIR}"
  cd "${PROJECT_DIR}"

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

  cat > .env <<'ENV'
# The top level domain to serve from
DOMAIN_NAME=chamssan8n.online

# The subdomain to serve from
# SUBDOMAIN=n8n

# Optional timezone
GENERIC_TIMEZONE=Europe/Berlin

# The email address to use for the SSL certificate creation
SSL_EMAIL=chamssane.attoumani@live.fr
ENV
}

# 6) Volumes et déploiement
deploy_stack(){
  cd "${PROJECT_DIR}"

  # Création volumes + acme.json
  docker volume create traefik_data || true
  docker run --rm -v traefik_data:/v alpine sh -c "touch /v/acme.json && chmod 600 /v/acme.json"
  docker volume create n8n_data || true

  docker compose pull
  docker compose up -d
}

main(){
  require_root
  install_base
  install_docker_if_needed
  ensure_admin_user
  configure_sshd_and_ufw
  write_files
  deploy_stack
  echo "Stack déployée. Vérifie: docker compose logs -f traefik"
}
main
