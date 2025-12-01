#!/bin/bash
set -euo pipefail

# --- Variables ---
ROOT_DOMAIN="chamssane.online"
FQDN="${ROOT_DOMAIN}"
GENERIC_TIMEZONE="Europe/Berlin"
SSL_EMAIL="chamssane.attoumani@live.fr"
SSH_USER="aha_admin"
SSH_PORT="2222"
ALLOWED_IPS=("88.122.144.169" "185.22.198.1")

# --- Vérifier root ---
if [ "$(id -u)" -ne 0 ]; then
  echo "Ce script doit être lancé en root"
  exit 1
fi

echo "[1/7] Nettoyage sources apt"
if [ -f /etc/apt/sources.list.d/ubuntu-mirrors.list ]; then
  echo "$(sort -u /etc/apt/sources.list.d/ubuntu-mirrors.list)" > /etc/apt/sources.list.d/ubuntu-mirrors.list
fi

echo "[2/7] Installation paquets de base"
apt-get update -qq
apt-get install -y ca-certificates curl gnupg ufw fail2ban

echo "[3/7] Docker & Compose"
if ! command -v docker >/dev/null 2>&1; then
  install -m 0755 -d /etc/apt/keyrings
  OS_ID=$( . /etc/os-release && echo "$ID" )
  OS_CODENAME=$( . /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}" )
  BASE_URL="https://download.docker.com/linux"
  case "$OS_ID" in
    debian)   DOCKER_URL="$BASE_URL/debian";;
    ubuntu)   DOCKER_URL="$BASE_URL/ubuntu";;
    *) echo "OS non supporté: $OS_ID"; exit 1;;
  esac
  curl -fsSL "$DOCKER_URL/gpg" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
$DOCKER_URL $OS_CODENAME stable" > /etc/apt/sources.list.d/docker.list

  apt-get update -qq
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
fi

echo "[4/7] Création utilisateur ${SSH_USER}"
if ! id -u "$SSH_USER" >/dev/null 2>&1; then
  adduser --disabled-password --gecos "" "$SSH_USER"
  usermod -aG sudo,docker "$SSH_USER"
  mkdir -p /home/$SSH_USER/.ssh
  if [ -f /root/.ssh/authorized_keys ]; then
    cat /root/.ssh/authorized_keys >> /home/$SSH_USER/.ssh/authorized_keys
  fi
  chown -R $SSH_USER:$SSH_USER /home/$SSH_USER/.ssh
  chmod 700 /home/$SSH_USER/.ssh
  chmod 600 /home/$SSH_USER/.ssh/authorized_keys || true
fi

echo "[5/7] Sécurisation SSH & UFW"
cfg="/etc/ssh/sshd_config"
sed -i -E \
  -e "s@^[# ]*Port .*@Port ${SSH_PORT}@g" \
  -e "s@^[# ]*PermitRootLogin .*@PermitRootLogin no@g" \
  -e "s@^[# ]*PasswordAuthentication .*@PasswordAuthentication no@g" \
  "$cfg"

ufw --force reset
ufw default deny incoming
ufw default allow outgoing
for ip in "${ALLOWED_IPS[@]}"; do
  ufw allow from "$ip" to any port "$SSH_PORT" proto tcp
done
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

systemctl reload sshd || systemctl restart ssh

echo "[6/7] Configuration Fail2Ban"
cat >/etc/fail2ban/jail.local <<EOF
[sshd]
enabled = true
port    = ${SSH_PORT}
filter  = sshd
logpath = /var/log/auth.log
maxretry = 4
EOF
systemctl enable --now fail2ban

echo "[7/7] Déploiement n8n + Traefik"
mkdir -p /opt/n8n-traefik
cd /opt/n8n-traefik

cat >.env <<EOF
ROOT_DOMAIN=${ROOT_DOMAIN}
FQDN=${FQDN}
GENERIC_TIMEZONE=${GENERIC_TIMEZONE}
SSL_EMAIL=${SSL_EMAIL}
N8N_ENCRYPTION_KEY=$(openssl rand -hex 32)
EOF

cat >docker-compose.yml <<'EOF'
services:
  traefik:
    image: "traefik:v3.1"
    restart: always
    command:
      - "--providers.docker=true"
      - "--providers.docker.exposedbydefault=false"
      - "--entrypoints.web.address=:80"
      - "--entrypoints.web.http.redirections.entrypoint.to=websecure"
      - "--entrypoints.web.http.redirections.entrypoint.scheme=https"
      - "--entrypoints.websecure.address=:443"
      - "--certificatesresolvers.mytlschallenge.acme.tlschallenge=true"
      - "--certificatesresolvers.mytlschallenge.acme.email=${SSL_EMAIL}"
      - "--certificatesresolvers.mytlschallenge.acme.storage=/letsencrypt/acme.json"
      - "--entrypoints.websecure.transport.respondingTimeouts.readTimeout=1h"
      - "--entrypoints.websecure.transport.respondingTimeouts.idleTimeout=1h"
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - traefik_data:/letsencrypt
      - /var/run/docker.sock:/var/run/docker.sock:ro

  n8n:
    image: docker.n8n.io/n8nio/n8n:1.114.2
    restart: always
    ports:
      - "127.0.0.1:5678:5678"
    labels:
      - traefik.enable=true
      - traefik.http.routers.n8n.rule=Host(`${FQDN}`)
      - traefik.http.routers.n8n.entrypoints=websecure
      - traefik.http.routers.n8n.tls=true
      - traefik.http.routers.n8n.tls.certresolver=mytlschallenge
      - traefik.http.routers.n8n.service=n8n
      - traefik.http.services.n8n.loadbalancer.server.port=5678
      # Headers sécurisés
      - traefik.http.middlewares.n8n-headers.headers.STSSeconds=315360000
      - traefik.http.middlewares.n8n-headers.headers.browserXSSFilter=true
      - traefik.http.middlewares.n8n-headers.headers.contentTypeNosniff=true
      - traefik.http.middlewares.n8n-headers.headers.forceSTSHeader=true
      - traefik.http.middlewares.n8n-headers.headers.STSIncludeSubdomains=true
      - traefik.http.middlewares.n8n-headers.headers.STSPreload=true
      - traefik.http.middlewares.n8n-headers.headers.referrerPolicy=no-referrer
      # Limitation requêtes
      - traefik.http.middlewares.n8n-rate.ratelimit.average=60
      - traefik.http.middlewares.n8n-rate.ratelimit.burst=120
      - traefik.http.middlewares.n8n-body.buffering.maxRequestBodyBytes=10485760
      # Restriction IP front web
      - traefik.http.middlewares.n8n-ip.ipallowlist.sourcerange=0.0.0.0/0,::/0
      - traefik.http.routers.n8n.middlewares=n8n-headers@docker,n8n-rate@docker,n8n-body@docker,n8n-ip@docker
    environment:
      - DB_SQLITE_POOL_SIZE=1
      - N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=true
      - N8N_ENCRYPTION_KEY=<32+ chars aléatoires>
      - N8N_RUNNERS_ENABLED=true
      - N8N_HOST=${FQDN}
      - N8N_PORT=5678
      - N8N_PROTOCOL=https
      - NODE_ENV=production
      - WEBHOOK_URL=https://${FQDN}/
      - GENERIC_TIMEZONE=${GENERIC_TIMEZONE}
    volumes:
      - n8n_data:/home/node/.n8n
      - /local-files:/files

volumes:
  traefik_data:
    external: true
  n8n_data:
    external: true
EOF

docker volume create traefik_data
docker run --rm -v traefik_data:/v alpine sh -c "touch /v/acme.json && chmod 600 /v/acme.json"
docker volume create n8n_data

docker compose up -d

echo "=== Déploiement terminé ==="
echo "→ SSH: ${SSH_USER}@<IP> port ${SSH_PORT}"
echo "→ HTTPS: https://${FQDN}"
