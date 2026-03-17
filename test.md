# Projet complet : Keycloak + Apache mod_auth_openidc

Chaque section ci-dessous correspond à un fichier.
Le chemin est indiqué en titre, il suffit de créer le fichier au bon endroit.

```
tuto-keycloak-apache/
├── docker-compose.yml
├── README.md
├── .gitignore
├── apache/
│   ├── Dockerfile
│   ├── openidc.conf
│   └── vhost.conf
└── apps/
    ├── app1/
    │   ├── Dockerfile
    │   └── server.py
    └── app2/
        ├── Dockerfile
        └── server.py
```

---

## `docker-compose.yml`

```yaml
version: "3.8"

services:
  # ============================================================
  # Keycloak - Identity Provider
  # ============================================================
  keycloak-db:
    image: postgres:16-alpine
    environment:
      POSTGRES_DB: keycloak
      POSTGRES_USER: keycloak
      POSTGRES_PASSWORD: keycloak_db_pass
    volumes:
      - keycloak_db_data:/var/lib/postgresql/data
    networks:
      - backend

  keycloak:
    image: quay.io/keycloak/keycloak:24.0
    command: start-dev
    environment:
      KC_DB: postgres
      KC_DB_URL: jdbc:postgresql://keycloak-db:5432/keycloak
      KC_DB_USERNAME: keycloak
      KC_DB_PASSWORD: keycloak_db_pass
      KEYCLOAK_ADMIN: admin
      KEYCLOAK_ADMIN_PASSWORD: admin
      KC_PROXY_HEADERS: xforwarded
      KC_HTTP_ENABLED: "true"
      KC_HOSTNAME_STRICT: "false"
    ports:
      - "8080:8080"
    depends_on:
      - keycloak-db
    networks:
      - backend

  # ============================================================
  # Apache - Reverse Proxy + mod_auth_openidc
  # ============================================================
  apache:
    build:
      context: ./apache
      dockerfile: Dockerfile
    ports:
      - "443:443"
      - "80:80"
    volumes:
      - ./apache/vhost.conf:/etc/apache2/sites-enabled/000-default.conf:ro
      - ./apache/openidc.conf:/etc/apache2/conf-enabled/openidc.conf:ro
    depends_on:
      - keycloak
      - app1
      - app2
    networks:
      - backend

  # ============================================================
  # Applications de démo
  # ============================================================
  app1:
    build:
      context: ./apps/app1
    networks:
      - backend

  app2:
    build:
      context: ./apps/app2
    networks:
      - backend

volumes:
  keycloak_db_data:

networks:
  backend:
    driver: bridge
```

---

## `apache/Dockerfile`

```dockerfile
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y \
    apache2 \
    libapache2-mod-auth-openidc \
    && rm -rf /var/lib/apt/lists/*

# Activer les modules nécessaires
RUN a2enmod auth_openidc proxy proxy_http headers rewrite ssl

# Désactiver le site par défaut (on le remplace)
RUN a2dissite 000-default || true

EXPOSE 80

CMD ["apachectl", "-D", "FOREGROUND"]
```

---

## `apache/openidc.conf`

```apache
# =============================================================
# mod_auth_openidc - Configuration globale
# =============================================================

# Point d'entrée OpenID Connect (Keycloak)
# IMPORTANT : Cette URL doit être accessible depuis le conteneur Apache
OIDCProviderMetadataURL http://keycloak:8080/realms/demo/.well-known/openid-configuration

# Identifiants du client OIDC (à créer dans Keycloak)
OIDCClientID apache-proxy
OIDCClientSecret changeme-secret-12345

# URI de callback - doit correspondre à un "Valid Redirect URI" dans Keycloak
# C'est l'URL où Keycloak redirige après authentification
OIDCRedirectURI http://localhost/redirect_uri

# Passphrase pour chiffrer les cookies de session
OIDCCryptoPassphrase une-passphrase-longue-et-aleatoire-a-changer

# ---- Sessions ----
# Stockage serveur (nécessaire pour le back-channel logout)
OIDCSessionType server-cache
OIDCSessionInactivityTimeout 3600
OIDCSessionMaxDuration 28800

# ---- Back-Channel Logout ----
# Keycloak enverra un POST ici pour invalider les sessions
OIDCBackChannelLogoutURL http://localhost/backchannel-logout

# ---- Claims et headers ----
# Injecter les claims du token dans les headers HTTP vers les apps
OIDCPassClaimsAs headers

# Scopes demandés à Keycloak
OIDCScope "openid email profile"

# ---- Sécurité ----
# Empêcher les clients de forger les headers OIDC
OIDCStripCookies mod_auth_openidc_session
```

---

## `apache/vhost.conf`

```apache
<VirtualHost *:80>
    ServerName localhost

    # ==========================================================
    # Sécurité : supprimer les headers OIDC forgés par le client
    # ==========================================================
    RequestHeader unset OIDC_CLAIM_preferred_username
    RequestHeader unset OIDC_CLAIM_email
    RequestHeader unset OIDC_CLAIM_name
    RequestHeader unset OIDC_CLAIM_sub
    RequestHeader unset OIDC_CLAIM_realm_access
    RequestHeader unset REMOTE_USER

    # ==========================================================
    # Page d'accueil (non protégée)
    # ==========================================================
    <Location />
        # Pas d'auth ici - page publique
        Require all granted
    </Location>

    # ==========================================================
    # App 1 - Accessible à tous les utilisateurs authentifiés
    # ==========================================================
    <Location /app1/>
        AuthType openid-connect
        Require valid-user

        ProxyPass         http://app1:3001/
        ProxyPassReverse  http://app1:3001/
    </Location>

    # ==========================================================
    # App 2 - Accessible uniquement aux utilisateurs avec le rôle "admin"
    # ==========================================================
    <Location /app2/>
        AuthType openid-connect
        Require claim realm_access.roles:admin

        ProxyPass         http://app2:3002/
        ProxyPassReverse  http://app2:3002/
    </Location>

    # ==========================================================
    # Endpoint de callback OIDC (ne pas toucher)
    # ==========================================================
    <Location /redirect_uri>
        AuthType openid-connect
        Require valid-user
    </Location>

    # ==========================================================
    # Endpoint de logout
    # ==========================================================
    <Location /logout>
        AuthType openid-connect
        Require valid-user
        # Redirige vers la déconnexion Keycloak puis retour à /
        OIDCUnAuthAction 302:/
    </Location>

    # ==========================================================
    # Infos de debug (à retirer en production)
    # ==========================================================
    <Location /userinfo>
        AuthType openid-connect
        Require valid-user

        ProxyPass         http://app1:3001/userinfo
        ProxyPassReverse  http://app1:3001/userinfo
    </Location>

    # Logs
    ErrorLog ${APACHE_LOG_DIR}/error.log
    CustomLog ${APACHE_LOG_DIR}/access.log combined
    LogLevel debug

</VirtualHost>
```

---

## `apps/app1/Dockerfile`

```dockerfile
FROM python:3.12-slim
WORKDIR /app
COPY server.py .
EXPOSE 3001
CMD ["python", "server.py"]
```

---

## `apps/app1/server.py`

```python
"""
App 1 - Démo : affiche les informations utilisateur reçues de mod_auth_openidc.
L'app ne gère aucune authentification elle-même.
Elle fait confiance aux headers injectés par Apache.
"""

from http.server import HTTPServer, BaseHTTPRequestHandler
import json

HTML_TEMPLATE = """<!DOCTYPE html>
<html lang="fr">
<head>
    <meta charset="utf-8">
    <title>App 1 - Dashboard</title>
    <style>
        body {{ font-family: system-ui, sans-serif; max-width: 800px; margin: 40px auto; padding: 0 20px; background: #f5f5f5; }}
        .card {{ background: white; border-radius: 8px; padding: 24px; margin: 16px 0; box-shadow: 0 1px 3px rgba(0,0,0,0.12); }}
        h1 {{ color: #2563eb; }}
        .user-badge {{ background: #dbeafe; color: #1e40af; padding: 4px 12px; border-radius: 16px; font-weight: 600; }}
        table {{ width: 100%; border-collapse: collapse; }}
        td {{ padding: 8px; border-bottom: 1px solid #e5e7eb; }}
        td:first-child {{ font-weight: 600; color: #6b7280; width: 40%; }}
        a.logout {{ color: #dc2626; text-decoration: none; font-weight: 600; }}
    </style>
</head>
<body>
    <div class="card">
        <h1>App 1 - Dashboard</h1>
        <p>Bonjour <span class="user-badge">{username}</span> !</p>
        <p><a class="logout" href="/logout">Se déconnecter</a></p>
    </div>
    <div class="card">
        <h2>Headers OIDC reçus</h2>
        <table>
            {rows}
        </table>
    </div>
</body>
</html>"""


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        # Extraire les headers OIDC injectés par mod_auth_openidc
        username = self.headers.get("OIDC_CLAIM_preferred_username", "inconnu")
        email = self.headers.get("OIDC_CLAIM_email", "")

        # Construire le tableau de tous les headers OIDC
        oidc_headers = {
            k: v for k, v in self.headers.items()
            if k.upper().startswith("OIDC_CLAIM") or k.upper() == "REMOTE_USER"
        }

        rows = ""
        for k, v in sorted(oidc_headers.items()):
            rows += f"<tr><td>{k}</td><td>{v}</td></tr>\n"

        if not rows:
            rows = "<tr><td colspan='2'>Aucun header OIDC reçu (accès direct ?)</td></tr>"

        # Si c'est /userinfo, renvoyer du JSON
        if self.path == "/userinfo":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(oidc_headers, indent=2).encode())
            return

        # Sinon, page HTML
        html = HTML_TEMPLATE.format(username=username, rows=rows)
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()
        self.wfile.write(html.encode())


if __name__ == "__main__":
    server = HTTPServer(("0.0.0.0", 3001), Handler)
    print("App 1 listening on :3001")
    server.serve_forever()
```

---

## `apps/app2/Dockerfile`

```dockerfile
FROM python:3.12-slim
WORKDIR /app
COPY server.py .
EXPOSE 3002
CMD ["python", "server.py"]
```

---

## `apps/app2/server.py`

```python
"""
App 2 - Zone Admin (accessible uniquement aux utilisateurs avec le rôle "admin").
L'autorisation est gérée par Apache via : Require claim realm_access.roles:admin
"""

from http.server import HTTPServer, BaseHTTPRequestHandler

HTML_TEMPLATE = """<!DOCTYPE html>
<html lang="fr">
<head>
    <meta charset="utf-8">
    <title>App 2 - Admin</title>
    <style>
        body {{ font-family: system-ui, sans-serif; max-width: 800px; margin: 40px auto; padding: 0 20px; background: #fef2f2; }}
        .card {{ background: white; border-radius: 8px; padding: 24px; margin: 16px 0; box-shadow: 0 1px 3px rgba(0,0,0,0.12); border-left: 4px solid #dc2626; }}
        h1 {{ color: #dc2626; }}
        .admin-badge {{ background: #fecaca; color: #991b1b; padding: 4px 12px; border-radius: 16px; font-weight: 600; }}
        a.logout {{ color: #dc2626; text-decoration: none; font-weight: 600; }}
    </style>
</head>
<body>
    <div class="card">
        <h1>App 2 - Panneau Admin</h1>
        <p>Bienvenue <span class="admin-badge">{username}</span> (rôle admin vérifié par Apache)</p>
        <p>Email : {email}</p>
        <p><a class="logout" href="/logout">Se déconnecter</a></p>
    </div>
    <div class="card">
        <h2>Cette page est protégée</h2>
        <p>Seuls les utilisateurs ayant le rôle <code>admin</code> dans Keycloak
        peuvent accéder à <code>/app2/</code>.</p>
        <p>Apache vérifie automatiquement le claim <code>realm_access.roles</code>
        dans le token OIDC.</p>
    </div>
</body>
</html>"""


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        username = self.headers.get("OIDC_CLAIM_preferred_username", "inconnu")
        email = self.headers.get("OIDC_CLAIM_email", "N/A")

        html = HTML_TEMPLATE.format(username=username, email=email)
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()
        self.wfile.write(html.encode())


if __name__ == "__main__":
    server = HTTPServer(("0.0.0.0", 3002), Handler)
    print("App 2 listening on :3002")
    server.serve_forever()
```

---

## `.gitignore`

```gitignore
# Secrets
apache/openidc.conf.local

# Docker
.env

# OS
.DS_Store
Thumbs.db

# Logs
*.log
```

---

## Tuto rapide

### 1. Lancer

```bash
docker compose up -d --build
```

### 2. Configurer Keycloak (`http://localhost:8080`, login `admin`/`admin`)

1. Créer realm **demo**
2. Créer client **apache-proxy** (Client authentication: ON)
   - Valid redirect URIs : `http://localhost/*`
   - Backchannel logout URL : `http://apache/backchannel-logout`
3. Copier le Client Secret → le coller dans `apache/openidc.conf` → `docker compose restart apache`
4. Créer user **testuser** (password: `test1234`)
5. Créer user **adminuser** (password: `admin1234`) + lui assigner le realm role **admin**

### 3. Tester

- `http://localhost/app1/` → login → dashboard (tous les users)
- `http://localhost/app2/` → admin uniquement
- `http://localhost/userinfo` → JSON des headers OIDC
- Keycloak → Users → Sessions → **Sign out** → recharger la page → redirect login
