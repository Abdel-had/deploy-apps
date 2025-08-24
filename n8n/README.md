# Déploiement sécurisé de n8n avec Traefik sur VPS Ubuntu

## Fonctionnalités

- Installation automatique de Docker et Docker Compose (si absent)
- Création d’un utilisateur administrateur `aha_admin`
  - sudoer
  - membre du groupe `docker`
- Sécurisation SSH
  - Port déplacé sur **2222**
  - Accès root désactivé
  - Authentification par clé uniquement
  - Accès limité aux IP autorisées : `88.122.144.169`, `185.22.198.1`
- Firewall (UFW)
  - Blocage par défaut (incoming deny, outgoing allow)
  - Ports ouverts : `80`, `443`, `2222`
- Fail2Ban activé pour SSH
- Déploiement automatique de n8n derrière Traefik
  - HTTPS avec certificats Let’s Encrypt
  - Redirection automatique HTTP → HTTPS
  - Middlewares de sécurité (HSTS, XSS, nosniff, referrerPolicy)
  - Rate limiting et limite de taille de requêtes
  - Whitelist IP optionnelle

---

## Fichiers générés

### `docker-compose.yml`

Définit les services :
- **Traefik** : reverse proxy + HTTPS automatique
- **n8n** : workflow automation

### `.env`

Paramètres configurables :
```bash
DOMAIN_NAME=chamssan8n.online
GENERIC_TIMEZONE=Europe/Berlin
SSL_EMAIL=chamssane.attoumani@live.fr
```

---

## Installation

1. Cloner le dépôt ou copier le script :
   ```bash
   git clone <repo>
   cd <repo>
   ```

2. Lancer le script :
   ```bash
   sudo ./setup-n8n-traefik.sh
   ```

3. Vérifier les conteneurs :
   ```bash
   docker compose ps
   docker compose logs -f traefik
   docker compose logs -f n8n
   ```

---

## Accès

- Interface n8n : [https://chamssan8n.online](https://chamssan8n.online)  
- SSH :  
  ```bash
  ssh -p 2222 aha_admin@chamssan8n.online
  ```

---

## Sécurité

- Les clés SSH initiales sont déplacées de `/root/.ssh` vers `/home/aha_admin/.ssh/authorized_keys`
- Fail2Ban protège contre les attaques bruteforce SSH
- UFW limite les accès réseau aux services strictement nécessaires
- Traefik applique headers et limites
