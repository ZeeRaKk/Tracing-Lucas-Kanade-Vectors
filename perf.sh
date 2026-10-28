#!/usr/bin/env bash
# creer-kit.sh — recrée tous les fichiers du kit k3s airgap + temps réel.
#
# Usage : bash creer-kit.sh [DOSSIER]        (défaut : ./kit-k3s-rt)
#
# Contenu : scripts d'installation airgap, manifests Kubernetes, outil de mesure
# rtlat (source Rust + script de tracé). Voir LISEZMOI.md une fois le kit créé.
set -euo pipefail

DEST="${1:-./kit-k3s-rt}"
if [[ -e "$DEST" && -n "$(ls -A "$DEST" 2>/dev/null)" ]]; then
  echo "Le dossier $DEST existe et n'est pas vide : choisis-en un autre ou supprime-le." >&2
  exit 1
fi
mkdir -p "$DEST"
cd "$DEST"

ecrire() {  # ecrire <chemin> : lit le contenu sur l'entrée standard
  mkdir -p "$(dirname "$1")"
  cat > "$1"
  echo "  $1"
}

echo "Création du kit dans $(pwd) :"

ecrire 'LISEZMOI.md' <<'__FIN_FICHIER_00__'
# Kit k3s airgap + temps réel

## Contenu

```
k3s-airgap/
  telecharger-k3s-airgap.sh   machine CONNECTÉE : prépare le bundle pour la clé USB
  install-k3s-airgap.sh       nœud AIRGAP : installe k3s depuis la clé (serveur ou agent)
  images.txt                  images à embarquer (nom complet obligatoire)
  Containerfile.rt-base       image de base avec taskset/chrt (à construire avant le téléchargement)
manifests/
  nginx-deploy.yml            premier test : nginx + NodePort 30080
  monapp-deploy.yml           binaire fourni par l'hôte (/opt/monapp), lancement manuel
  monapp-pinned-deploy.yml    RT : affinité explicite par conteneur (taskset), cœurs 6-7 isolés
  variantes-cpu-manager/      alternatives avec le CPU Manager static (cœurs choisis par k3s)
    rt-app-deploy.yml
    monapp-rt-deploy.yml
rtlat/
  Cargo.toml, Cargo.lock, src/main.rs   outil de mesure (check, timer, pingpong, stall, load)
  rtlat_plot.py               tracés matplotlib à partir des JSON (--out)
  README.md                   utilisation et lecture des résultats
```

## Ordre d'utilisation

1. Machine connectée :
   ```bash
   cd k3s-airgap
   podman build -t registry.local/rt-base:9 -f Containerfile.rt-base .
   ./telecharger-k3s-airgap.sh          # ou K3S_VERSION=v1.xx.y+k3s1 ./telecharger-k3s-airgap.sh
   (cd ../rtlat && cargo build --release && cp target/release/rtlat ../k3s-airgap/k3s-airgap-bundle/)
   ```
   Copier `k3s-airgap/k3s-airgap-bundle/` et `manifests/` sur la clé.
2. Nœud airgap : `sudo bash <clé>/k3s-airgap-bundle/install-k3s-airgap.sh`
3. Noyau (isolation), puis reboot — voir l'en-tête de `manifests/monapp-pinned-deploy.yml`.
4. Binaires dans `/opt/monapp`, puis `kubectl apply -f manifests/monapp-pinned-deploy.yml`.
5. Mesure : `rtlat check --cpu 7`, puis `rtlat timer --cpu 7 --duration 3600 --out repos.json`.
6. Tracé (machine avec matplotlib) : `python3 rtlat/rtlat_plot.py repos.json`.
__FIN_FICHIER_00__

ecrire 'k3s-airgap/telecharger-k3s-airgap.sh' <<'__FIN_FICHIER_01__'
#!/usr/bin/env bash
# telecharger-k3s-airgap.sh — à lancer sur une machine CONNECTÉE.
# Prépare un bundle k3s airgap à copier tel quel sur la clé USB.
#
# Usage :
#   ./telecharger-k3s-airgap.sh                          # dernière stable, amd64
#   K3S_VERSION=v1.33.5+k3s1 ARCH=arm64 ./telecharger-k3s-airgap.sh
#
# Variables :
#   K3S_VERSION  version k3s (défaut : canal stable)
#   ARCH         amd64 | arm64 (défaut : amd64)
#   EL           version EL du RPM k3s-selinux ; EL= (vide) pour ne pas le prendre (défaut : 9)
#   OUT          dossier de sortie (défaut : ./k3s-airgap-bundle)
#   IMAGES_FILE  images supplémentaires, une par ligne (défaut : images.txt à côté du script)
#
# Placer install-k3s-airgap.sh à côté de ce script : il sera copié dans le bundle.
set -euo pipefail

ARCH="${ARCH:-amd64}"
EL="${EL-9}"
OUT="${OUT:-./k3s-airgap-bundle}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGES_FILE="${IMAGES_FILE:-$SCRIPT_DIR/images.txt}"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

for cmd in curl sha256sum awk; do
  command -v "$cmd" >/dev/null || die "commande manquante : $cmd"
done

case "$ARCH" in
  amd64) BIN_NAME=k3s ;;
  arm64) BIN_NAME=k3s-arm64 ;;
  *) die "ARCH non supportée : $ARCH (amd64 ou arm64)" ;;
esac

# --- Version ---------------------------------------------------------------
if [[ -z "${K3S_VERSION:-}" ]]; then
  log "Résolution de la dernière version stable…"
  K3S_VERSION="$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
      https://update.k3s.io/v1-release/channels/stable \
    | sed -e 's|.*/||' -e 's/%2B/+/')" \
    || die "update.k3s.io injoignable : fixe la version avec K3S_VERSION=v1.xx.y+k3s1"
  [[ "$K3S_VERSION" == v* ]] || die "version stable introuvable (obtenu : '$K3S_VERSION')"
fi
log "k3s $K3S_VERSION ($ARCH)"

BASE="https://github.com/k3s-io/k3s/releases/download/${K3S_VERSION/+/%2B}"
mkdir -p "$OUT"/{bin,images,rpms}
OUT="$(cd "$OUT" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fetch() { curl -fL --retry 3 --progress-bar -o "$2" "$1"; }

verify() { # verify <fichier local> <nom dans sha256sum-ARCH.txt>
  local expected actual
  expected="$(awk -v f="$2" '$2 == f {print $1}' "$TMP/sums")"
  [[ -n "$expected" ]] || die "pas de somme de contrôle pour $2"
  actual="$(sha256sum "$1" | cut -d' ' -f1)"
  [[ "$expected" == "$actual" ]] || die "somme de contrôle invalide : $2"
}

# --- k3s : binaire + images système -----------------------------------------
log "Téléchargement du binaire et des images système"
fetch "$BASE/sha256sum-$ARCH.txt" "$TMP/sums"
fetch "$BASE/$BIN_NAME" "$OUT/bin/$BIN_NAME"
fetch "$BASE/k3s-airgap-images-$ARCH.tar.zst" "$OUT/images/k3s-airgap-images-$ARCH.tar.zst"
verify "$OUT/bin/$BIN_NAME" "$BIN_NAME"
verify "$OUT/images/k3s-airgap-images-$ARCH.tar.zst" "k3s-airgap-images-$ARCH.tar.zst"
log "Sommes de contrôle officielles OK"

log "Téléchargement du script d'installation officiel"
fetch https://get.k3s.io "$OUT/k3s-install.sh"

# --- RPM k3s-selinux (OL/RHEL avec SELinux actif) ---------------------------
if [[ -n "$EL" ]]; then
  log "Recherche du RPM k3s-selinux (el$EL)"
  rpm_url="$(curl -fsSL https://api.github.com/repos/k3s-io/k3s-selinux/releases/latest \
    | grep -o "\"browser_download_url\": *\"[^\"]*\.el${EL}\.noarch\.rpm\"" \
    | sed 's/.*"\(https[^"]*\)"$/\1/' | head -n1 || true)"
  if [[ -n "$rpm_url" ]]; then
    fetch "$rpm_url" "$OUT/rpms/${rpm_url##*/}"
  else
    warn "RPM k3s-selinux el$EL introuvable : à récupérer à la main dans rpms/"
  fi
fi

# --- Images supplémentaires -------------------------------------------------
if [[ -f "$IMAGES_FILE" ]]; then
  command -v podman >/dev/null || die "podman requis pour traiter $IMAGES_FILE"
  log "Images supplémentaires depuis $IMAGES_FILE"
  while IFS= read -r -u 3 img || [[ -n "$img" ]]; do
    img="${img%%#*}"                                   # retire les commentaires
    img="${img#"${img%%[![:space:]]*}"}"               # trim gauche
    img="${img%"${img##*[![:space:]]}"}"               # trim droite
    [[ -z "$img" ]] && continue

    first="${img%%/*}"
    if [[ "$img" != */* || ( "$first" != *.* && "$first" != *:* && "$first" != localhost ) ]]; then
      die "nom non qualifié : '$img' (ex : docker.io/library/nginx:alpine)"
    fi

    if podman image exists "$img"; then
      log "  locale : $img"
    else
      log "  pull   : $img"
      podman pull --arch "$ARCH" "$img"
    fi
    file="$OUT/images/$(tr '/:@' '___' <<<"$img").tar"
    rm -f "$file"
    podman save --format docker-archive -o "$file" "$img"
  done 3< "$IMAGES_FILE"
else
  log "Pas de $IMAGES_FILE : aucune image supplémentaire"
fi

# --- Script d'installation + métadonnées -------------------------------------
if [[ -f "$SCRIPT_DIR/install-k3s-airgap.sh" ]]; then
  cp "$SCRIPT_DIR/install-k3s-airgap.sh" "$OUT/"
else
  warn "install-k3s-airgap.sh absent à côté de ce script : copie-le dans le bundle à la main"
fi

cat > "$OUT/bundle.env" <<EOF
K3S_VERSION=$K3S_VERSION
ARCH=$ARCH
EOF

# Sommes de tout le bundle, pour détecter une copie USB corrompue.
# config.yaml et le script d'install sont exclus pour pouvoir les éditer.
log "Calcul des sommes de contrôle du bundle"
(cd "$OUT" && find . -type f ! -name SHA256SUMS ! -name config.yaml \
    ! -name install-k3s-airgap.sh -print0 | sort -z | xargs -0 sha256sum > "$TMP/sums.all")
mv "$TMP/sums.all" "$OUT/SHA256SUMS"

log "Bundle prêt : $OUT ($(du -sh "$OUT" | cut -f1))"
echo
echo "Copie le DOSSIER sur la clé, puis sur le nœud airgap :"
echo "  sudo bash /run/media/\$USER/<CLE>/$(basename "$OUT")/install-k3s-airgap.sh"
__FIN_FICHIER_01__
chmod +x 'k3s-airgap/telecharger-k3s-airgap.sh'

ecrire 'k3s-airgap/install-k3s-airgap.sh' <<'__FIN_FICHIER_02__'
#!/usr/bin/env bash
# install-k3s-airgap.sh — à lancer en root sur le nœud AIRGAP, depuis la clé USB.
#
#   sudo bash /chemin/cle/k3s-airgap-bundle/install-k3s-airgap.sh            # serveur
#   sudo bash /chemin/cle/k3s-airgap-bundle/install-k3s-airgap.sh agent \
#        --url https://<IP_SERVEUR>:6443 --token <TOKEN>                     # agent
#
# Options :
#   --no-firewall   ne touche pas à firewalld
#   --skip-verify   saute la vérification SHA256 du bundle
#
# Un config.yaml optionnel placé à côté de ce script est copié dans
# /etc/rancher/k3s/config.yaml (ex : write-kubeconfig-mode, node-name, tls-san…).
set -euo pipefail

BUNDLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGES_DST=/var/lib/rancher/k3s/agent/images
K3S=/usr/local/bin/k3s
# Plages par défaut de k3s ; à adapter si tu changes cluster-cidr / service-cidr.
POD_CIDR=10.42.0.0/16
SVC_CIDR=10.43.0.0/16

ROLE=server SERVER_URL="" TOKEN="" DO_FW=1 DO_VERIFY=1

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }
usage() { grep '^#' "$0" | sed -e '1d' -e 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    server|agent)  ROLE="$1" ;;
    --url)         SERVER_URL="${2:?--url attend une valeur}"; shift ;;
    --token)       TOKEN="${2:?--token attend une valeur}"; shift ;;
    --no-firewall) DO_FW=0 ;;
    --skip-verify) DO_VERIFY=0 ;;
    -h|--help)     usage 0 ;;
    *)             warn "argument inconnu : $1"; usage 1 ;;
  esac
  shift
done

# --- 1. Vérifications ---------------------------------------------------------
[[ $EUID -eq 0 ]] || die "à lancer en root : sudo bash $0"
[[ -f "$BUNDLE_DIR/bundle.env" ]] || die "bundle.env introuvable dans $BUNDLE_DIR"
# shellcheck source=/dev/null
source "$BUNDLE_DIR/bundle.env"

if [[ "$ROLE" == agent && ( -z "$SERVER_URL" || -z "$TOKEN" ) ]]; then
  die "un agent a besoin de --url et --token"
fi

case "$(uname -m)" in
  x86_64)  HOST_ARCH=amd64 ;;
  aarch64) HOST_ARCH=arm64 ;;
  *)       HOST_ARCH="$(uname -m)" ;;
esac
[[ "$HOST_ARCH" == "$ARCH" ]] || die "bundle $ARCH mais machine $HOST_ARCH"

if [[ $DO_VERIFY -eq 1 ]]; then
  log "Vérification de l'intégrité du bundle"
  (cd "$BUNDLE_DIR" && sha256sum -c --quiet SHA256SUMS) \
    || die "bundle corrompu : recopie la clé (ou --skip-verify à tes risques)"
fi

ip route show default | grep -q . \
  || die "aucune route par défaut, k3s en a besoin. Ex : nmcli con mod <con> ipv4.gateway <IP> && nmcli con up <con>"

log "Installation k3s $K3S_VERSION ($ARCH) en mode $ROLE"

# --- 2. SELinux ---------------------------------------------------------------
if command -v getenforce >/dev/null && [[ "$(getenforce)" != Disabled ]]; then
  if rpm -q k3s-selinux >/dev/null 2>&1; then
    log "k3s-selinux déjà installé"
  else
    shopt -s nullglob
    rpms=("$BUNDLE_DIR"/rpms/*.rpm)
    shopt -u nullglob
    (( ${#rpms[@]} )) || die "SELinux actif mais aucun RPM dans rpms/"
    log "Installation de k3s-selinux"
    dnf install -y --disablerepo='*' "${rpms[@]}" \
      || die "échec RPM : container-selinux manquant ? Installe-le depuis l'ISO OL9 (AppStream) ou ajoute son RPM dans rpms/"
  fi
fi

# --- 3. Binaire + images -------------------------------------------------------
bin_src="$BUNDLE_DIR/bin/k3s"
[[ "$ARCH" == arm64 ]] && bin_src="$BUNDLE_DIR/bin/k3s-arm64"
install -m 0755 "$bin_src" "$K3S"

log "Copie des images vers $IMAGES_DST"
install -d -m 0755 "$IMAGES_DST"
cp -f "$BUNDLE_DIR"/images/* "$IMAGES_DST"/
if command -v restorecon >/dev/null; then restorecon -R /var/lib/rancher; fi

# --- 4. Config optionnelle ----------------------------------------------------
if [[ -f "$BUNDLE_DIR/config.yaml" ]]; then
  log "Copie de config.yaml"
  install -d -m 0755 /etc/rancher/k3s
  install -m 0600 "$BUNDLE_DIR/config.yaml" /etc/rancher/k3s/config.yaml
fi

# --- 5. Firewall --------------------------------------------------------------
if [[ $DO_FW -eq 1 ]] && systemctl is-active --quiet firewalld; then
  log "Ouverture des ports dans firewalld"
  # 30000-32767 : plage NodePort, nécessaire pour joindre un Service NodePort depuis l'extérieur
  ports=(10250/tcp 8472/udp 30000-32767/tcp)
  [[ "$ROLE" == server ]] && ports+=(6443/tcp)
  for p in "${ports[@]}"; do firewall-cmd -q --permanent --add-port="$p"; done
  firewall-cmd -q --permanent --zone=trusted --add-source="$POD_CIDR"
  firewall-cmd -q --permanent --zone=trusted --add-source="$SVC_CIDR"
  firewall-cmd -q --reload
fi

# --- 6. Installation k3s ------------------------------------------------------
export INSTALL_K3S_SKIP_DOWNLOAD=true INSTALL_K3S_SKIP_SELINUX_RPM=true
if [[ "$ROLE" == agent ]]; then
  K3S_URL="$SERVER_URL" K3S_TOKEN="$TOKEN" sh "$BUNDLE_DIR/k3s-install.sh"
  log "Agent installé. Vérifie depuis le serveur : kubectl get nodes"
  exit 0
fi
sh "$BUNDLE_DIR/k3s-install.sh"

# --- 7. Post-install serveur --------------------------------------------------
log "Attente du nœud Ready (3 min max)…"
ready=0
for _ in $(seq 90); do
  if "$K3S" kubectl get nodes --no-headers 2>/dev/null | grep -qw Ready; then ready=1; break; fi
  sleep 2
done
[[ $ready -eq 1 ]] || warn "nœud pas encore Ready : journalctl -u k3s -f"
"$K3S" kubectl get nodes -o wide || true

# kubeconfig pour l'utilisateur qui a lancé sudo
if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != root ]]; then
  home="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
  grp="$(id -gn "$SUDO_USER")"
  install -d -m 0700 -o "$SUDO_USER" -g "$grp" "$home/.kube"
  install -m 0600 -o "$SUDO_USER" -g "$grp" /etc/rancher/k3s/k3s.yaml "$home/.kube/config"
  if [[ -f "$home/.bashrc" ]] && ! grep -q 'KUBECONFIG=' "$home/.bashrc"; then
    # shellcheck disable=SC2016
    echo 'export KUBECONFIG="$HOME/.kube/config"' >> "$home/.bashrc"
  fi
  log "kubeconfig installé pour $SUDO_USER (nouveau terminal, puis : kubectl get nodes)"
fi

ip_srv="$(hostname -I | awk '{print $1}')"
echo
log "Serveur prêt. Pour ajouter un agent :"
echo "  sudo bash <bundle>/install-k3s-airgap.sh agent \\"
echo "       --url https://$ip_srv:6443 --token $(cat /var/lib/rancher/k3s/server/node-token)"
__FIN_FICHIER_02__
chmod +x 'k3s-airgap/install-k3s-airgap.sh'

ecrire 'k3s-airgap/images.txt' <<'__FIN_FICHIER_03__'
# Images supplémentaires à embarquer dans le bundle, une par ligne.
# Nom complet obligatoire (registry/chemin:tag). Les images locales
# (podman build -t registry.local/monapp:1.0 .) sont prises telles quelles.
docker.io/library/nginx:alpine
docker.io/library/oraclelinux:9-slim
# Image construite localement (podman build -t registry.local/rt-base:9 -f Containerfile.rt-base .)
registry.local/rt-base:9
__FIN_FICHIER_03__

ecrire 'k3s-airgap/Containerfile.rt-base' <<'__FIN_FICHIER_04__'
# Containerfile.rt-base — image de base avec taskset et chrt (util-linux)
# oraclelinux:9-slim ne garantit pas leur présence : on les ajoute.
#
# À construire sur la machine CONNECTÉE, AVANT de lancer telecharger-k3s-airgap.sh :
#   podman build -t registry.local/rt-base:9 -f Containerfile.rt-base .
#   podman run --rm registry.local/rt-base:9 sh -c 'command -v taskset chrt'
FROM docker.io/library/oraclelinux:9-slim
RUN microdnf install -y util-linux && microdnf clean all
__FIN_FICHIER_04__

ecrire 'manifests/nginx-deploy.yml' <<'__FIN_FICHIER_05__'
# nginx-deploy.yml — nginx sur k3s airgap
# Appliquer :  kubectl apply -f nginx-deploy.yml
# Tester    :  curl http://<IP_NOEUD>:30080
# Supprimer :  kubectl delete -f nginx-deploy.yml
---
apiVersion: v1
kind: Namespace
metadata:
  name: demo
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx
  namespace: demo
  labels:
    app: nginx
spec:
  replicas: 2
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      containers:
        - name: nginx
          # Nom EXACT de l'image dans le tarball (vérifier : sudo /usr/local/bin/k3s crictl images)
          image: docker.io/library/nginx:alpine
          # Airgap : jamais de pull. Image absente => ErrImageNeverPull immédiat et explicite.
          imagePullPolicy: Never
          ports:
            - name: http
              containerPort: 80
          resources:
            requests:
              cpu: 50m
              memory: 32Mi
            limits:
              memory: 128Mi
          readinessProbe:
            httpGet:
              path: /
              port: http
            initialDelaySeconds: 2
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /
              port: http
            initialDelaySeconds: 10
            periodSeconds: 10
---
apiVersion: v1
kind: Service
metadata:
  name: nginx
  namespace: demo
spec:
  type: NodePort
  selector:
    app: nginx
  ports:
    - name: http
      port: 80
      targetPort: http
      nodePort: 30080   # plage autorisée : 30000-32767
__FIN_FICHIER_05__

ecrire 'manifests/monapp-deploy.yml' <<'__FIN_FICHIER_06__'
# monapp-deploy.yml — binaire fourni par un dossier de l'hôte, pas embarqué dans l'image
#
# Sur le nœud :
#   sudo mkdir -p /opt/monapp
#   sudo cp monapp /opt/monapp/monapp.new && sudo chmod 755 /opt/monapp/monapp.new
#   sudo mv /opt/monapp/monapp.new /opt/monapp/monapp     # remplacement atomique
#   sudo semanage fcontext -a -t container_file_t '/opt/monapp(/.*)?'   # SELinux
#   sudo restorecon -Rv /opt/monapp
#
# Appliquer        :  kubectl apply -f monapp-deploy.yml
# Nouveau binaire  :  (cp + mv comme ci-dessus) puis kubectl -n monapp rollout restart deploy/monapp
# Logs             :  kubectl -n monapp logs -f deploy/monapp
---
apiVersion: v1
kind: Namespace
metadata:
  name: monapp
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: monapp
  namespace: monapp
  labels:
    app: monapp
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: monapp
  template:
    metadata:
      labels:
        app: monapp
    spec:
      # hostPath = dossier local au nœud. Avec plusieurs nœuds, soit le binaire est
      # copié sur chacun, soit on épingle le pod sur le nœud qui l'a :
      # nodeSelector:
      #   kubernetes.io/hostname: <nom-du-noeud>
      containers:
        - name: monapp
          # Image de base seulement : fournit la glibc d'OL9, compatible avec un
          # binaire compilé sur la VM. Binaire statique (musl) : n'importe quelle image.
          image: docker.io/library/oraclelinux:9-slim
          imagePullPolicy: Never
          # Mode manuel : le conteneur reste en vie sans rien lancer, tu entres dedans
          # (kubectl -n monapp exec -it deploy/monapp -- bash) et tu lances le binaire toi-même.
          command: ["sleep", "infinity"]
          # Mode automatique : le pod lance directement le binaire.
          # command: ["/opt/monapp/monapp"]
          # args: ["--config", "/opt/monapp/config.toml"]
          securityContext:
            runAsUser: 0
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
              add: ["SYS_NICE", "IPC_LOCK"]   # pour SCHED_FIFO et mlockall ; retirer si inutile
          resources:
            requests:
              cpu: 100m
              memory: 64Mi
            limits:
              memory: 256Mi
          volumeMounts:
            - name: monapp-bin
              mountPath: /opt/monapp
              readOnly: true
      volumes:
        - name: monapp-bin
          hostPath:
            path: /opt/monapp
            type: Directory     # erreur explicite au démarrage si le dossier n'existe pas
__FIN_FICHIER_06__

ecrire 'manifests/monapp-pinned-deploy.yml' <<'__FIN_FICHIER_07__'
# monapp-pinned-deploy.yml — affinité CPU explicite, conteneur par conteneur
#
# Plan des cœurs (Xeon W-1290E : 10 cœurs, pas de SMT, 1 nœud NUMA) :
#   cœurs 0-5 : système, k3s, IRQ ; annexe sur 1-5   non isolés
#   cœur 6    : rt-a + rt-b (partagé)                ISOLÉ
#   cœur 7    : rt-c (seul)                          ISOLÉ
#   cœurs 8-9 : réserve pour de futurs conteneurs RT ISOLÉS (inutilisés pour l'instant)
#
# ---- Prérequis nœud -------------------------------------------------------
# 1. Noyau puis reboot :
#      grubby --update-kernel=ALL \
#        --args="isolcpus=managed_irq,domain,6-9 nohz_full=6-9 rcu_nocbs=6-9 irqaffinity=0-5"
#      cat /sys/devices/system/cpu/isolated          # -> 6-9
# 2. k3s SANS CPU Manager static (politique par défaut "none") : retirer
#    cpu-manager-policy / reserved-cpus de /etc/rancher/k3s/config.yaml, puis
#      sudo systemctl stop k3s && sudo rm -f /var/lib/kubelet/cpu_manager_state \
#        && sudo systemctl start k3s
#    (avec "none", chaque conteneur voit tous les cœurs : c'est taskset qui choisit)
# 3. Image registry.local/rt-base:9 importée (voir Containerfile.rt-base)
#
# ---- Vérifier --------------------------------------------------------------
#   for c in rt-a rt-b rt-c annexe; do echo -n "$c: "
#     kubectl -n monapp exec deploy/monapp -c $c -- grep Cpus_allowed_list /proc/1/status; done
#   ps -eLo pid,tid,psr,cls,rtprio,comm | grep -E 'app[1-4]'    # psr = cœur réel
---
apiVersion: v1
kind: Namespace
metadata:
  name: monapp
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: monapp
  namespace: monapp
  labels:
    app: monapp
spec:
  replicas: 1
  strategy:
    type: Recreate        # jamais deux instances sur les mêmes cœurs
  selector:
    matchLabels:
      app: monapp
  template:
    metadata:
      labels:
        app: monapp
    spec:
      containers:
        # --- Cœur 6 (isolé), partagé par rt-a et rt-b ------------------------
        # Même cœur => règles RT du noyau : rt-a (40) passe toujours avant rt-b (30),
        # rt-b ne tourne que quand rt-a se bloque. Pour un partage équitable :
        # même priorité et "chrt -r" (SCHED_RR) pour les deux.
        - name: rt-a
          image: registry.local/rt-base:9
          imagePullPolicy: Never
          command: ["taskset", "-c", "6", "chrt", "-f", "40", "/opt/monapp/app1"]
          securityContext: &rt-security
            runAsUser: 0
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
              add: ["SYS_NICE", "IPC_LOCK"]
          resources: &rt-resources
            # Pas de limits.cpu : le quota CFS n'a pas de sens pour un conteneur
            # épinglé et peut brider la partie non-RT du process.
            requests: { cpu: 100m, memory: 128Mi }
            limits:   { memory: 128Mi }
          volumeMounts: &bin-mount
            - name: monapp-bin
              mountPath: /opt/monapp
              readOnly: true

        - name: rt-b
          image: registry.local/rt-base:9
          imagePullPolicy: Never
          command: ["taskset", "-c", "6", "chrt", "-f", "30", "/opt/monapp/app2"]
          securityContext: *rt-security
          resources: *rt-resources
          volumeMounts: *bin-mount

        # --- Cœur 7 (isolé), rt-c seul ---------------------------------------
        - name: rt-c
          image: registry.local/rt-base:9
          imagePullPolicy: Never
          command: ["taskset", "-c", "7", "chrt", "-f", "40", "/opt/monapp/app3"]
          securityContext: *rt-security
          resources: *rt-resources
          volumeMounts: *bin-mount

        # --- Cœurs 1-5 (non isolés), pas de RT -------------------------------
        - name: annexe
          image: registry.local/rt-base:9
          imagePullPolicy: Never
          # taskset explicite : sans lui, le process resterait en pratique sur 0-5
          # (le noyau ne répartit jamais vers un cœur isolé), mais ce n'est pas garanti.
          # Cœur 0 laissé au système (timers, IRQ résiduelles).
          command: ["taskset", "-c", "1-5", "/opt/monapp/app4"]
          securityContext:
            runAsUser: 0
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]       # aucun droit RT
          resources:
            requests: { cpu: 250m, memory: 64Mi }
            limits:   { memory: 128Mi }
          volumeMounts: *bin-mount

      volumes:
        - name: monapp-bin
          hostPath:
            path: /opt/monapp
            type: Directory
__FIN_FICHIER_07__

ecrire 'manifests/variantes-cpu-manager/rt-app-deploy.yml' <<'__FIN_FICHIER_08__'
# rt-app-deploy.yml — application temps réel (SCHED_FIFO) sur k3s
#
# Prérequis nœud (/etc/rancher/k3s/config.yaml) pour des cœurs exclusifs :
#   kubelet-arg:
#     - "cpu-manager-policy=static"
#     - "reserved-cpus=0"
# puis : systemctl stop k3s && rm -f /var/lib/kubelet/cpu_manager_state && systemctl start k3s
#
# Appliquer :  kubectl apply -f rt-app-deploy.yml
# Vérifier  :  ps -eLo pid,tid,cls,rtprio,psr,comm | grep monapp   (cls=FF, psr fixe)
---
apiVersion: v1
kind: Namespace
metadata:
  name: rt
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: monapp
  namespace: rt
  labels:
    app: monapp
spec:
  replicas: 1
  # Recreate : l'ancien pod libère ses cœurs exclusifs avant que le nouveau démarre.
  # En RollingUpdate, il faudrait des cœurs libres en plus pendant la transition.
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: monapp
  template:
    metadata:
      labels:
        app: monapp
    spec:
      # nodeSelector:
      #   kubernetes.io/hostname: <noeud-rt>     # épingler sur le nœud préparé pour le RT
      securityContext:
        seccompProfile:
          type: RuntimeDefault        # autorise sched_setscheduler et mlockall
      containers:
        - name: monapp
          image: registry.local/monapp:1.0
          imagePullPolicy: Never

          # Option A (recommandée) : l'appli fixe elle-même sa politique et sa priorité
          # (sched_setscheduler / pthread_setschedparam + mlockall au démarrage).
          env:
            - name: RT_PRIORITY
              value: "40"             # 2-49 : appli classique, OK pour un thread qui calcule.
                                      # 51-98 : seulement pour un thread périodique qui dort
                                      # la plupart du temps. Éviter 99 (migration/watchdog).
          # Option B : priorité imposée de l'extérieur (nécessite chrt dans l'image).
          # command: ["chrt", "-f", "40", "/usr/local/bin/monapp"]

          securityContext:
            # Root obligatoire : un UID non-root ne reçoit PAS les capabilities ajoutées
            # (pas d'ambient caps dans Kubernetes). Alternative non-root :
            # setcap cap_sys_nice,cap_ipc_lock+ep sur le binaire dans l'image,
            # runAsNonRoot: true, et allowPrivilegeEscalation: true (sinon no_new_privs
            # bloque les file capabilities).
            runAsUser: 0
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
              add:
                - SYS_NICE            # SCHED_FIFO / SCHED_RR
                - IPC_LOCK            # mlockall sans limite RLIMIT_MEMLOCK

          # QoS Guaranteed (requests == limits) + CPU entier => cœurs exclusifs
          # avec cpu-manager-policy=static. Sans static, le pod tourne mais sans pinning.
          resources:
            requests:
              cpu: "1"
              memory: 256Mi
            limits:
              cpu: "1"
              memory: 256Mi           # doit couvrir toute la mémoire verrouillée par mlockall
__FIN_FICHIER_08__

ecrire 'manifests/variantes-cpu-manager/monapp-rt-deploy.yml' <<'__FIN_FICHIER_09__'
# monapp-rt-deploy.yml — 2 conteneurs, chacun sur son propre cœur isolé exclusif
#
# Rien dans ce fichier ne désigne « les cœurs isolés » : c'est la config du nœud
# qui fait que les cœurs exclusifs ne peuvent venir QUE des cœurs isolés.
#
# Prérequis nœud (exemple 4 cœurs : 0-1 système, 2-3 isolés) :
#   1. noyau : isolcpus=2,3 nohz_full=2,3 rcu_nocbs=2,3      (grubby + reboot)
#   2. /etc/rancher/k3s/config.yaml :
#        kubelet-arg:
#          - "cpu-manager-policy=static"
#          - "reserved-cpus=0,1"          # = exactement les cœurs NON isolés
#   3. systemctl stop k3s && rm -f /var/lib/kubelet/cpu_manager_state && systemctl start k3s
#
# Vérifier :
#   kubectl -n monapp get pod -o jsonpath='{.items[0].status.qosClass}'      -> Guaranteed
#   kubectl -n monapp exec deploy/monapp -c rt  -- grep Cpus_allowed_list /proc/1/status
#   kubectl -n monapp exec deploy/monapp -c rt2 -- grep Cpus_allowed_list /proc/1/status
#   -> l'un sur 2, l'autre sur 3 (k3s choisit lequel, pas toi)
---
apiVersion: v1
kind: Namespace
metadata:
  name: monapp
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: monapp
  namespace: monapp
  labels:
    app: monapp
spec:
  replicas: 1
  # Recreate obligatoire : les 2 cœurs isolés sont tous pris par ce pod, un
  # RollingUpdate ne trouverait aucun cœur libre pour le nouveau pod.
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: monapp
  template:
    metadata:
      labels:
        app: monapp
    spec:
      containers:
        # --- Conteneur RT n°1 : 1 cœur isolé exclusif -------------------------
        - name: rt
          image: docker.io/library/oraclelinux:9-slim
          imagePullPolicy: Never
          command: ["sleep", "infinity"]          # mode manuel (exec + lancement à la main)
          # command: ["chrt", "-f", "40", "/opt/monapp/app1"]
          securityContext:
            runAsUser: 0
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
              add: ["SYS_NICE", "IPC_LOCK"]
          resources:                              # entier + requests == limits
            requests: { cpu: "1", memory: 256Mi }
            limits:   { cpu: "1", memory: 256Mi }
          volumeMounts:
            - name: monapp-bin
              mountPath: /opt/monapp
              readOnly: true

        # --- Conteneur RT n°2 : 1 autre cœur isolé exclusif -------------------
        - name: rt2
          image: docker.io/library/oraclelinux:9-slim
          imagePullPolicy: Never
          command: ["sleep", "infinity"]
          # command: ["chrt", "-f", "40", "/opt/monapp/app2"]
          securityContext:
            runAsUser: 0
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
              add: ["SYS_NICE", "IPC_LOCK"]       # à retirer si rt2 ne fait pas de RT
          resources:
            requests: { cpu: "1", memory: 128Mi }
            limits:   { cpu: "1", memory: 128Mi }
          volumeMounts:
            - name: monapp-bin
              mountPath: /opt/monapp
              readOnly: true

        # --- Exemple de conteneur NON isolé (reste sur 0-1) -------------------
        # - name: annexe
        #   image: docker.io/library/oraclelinux:9-slim
        #   imagePullPolicy: Never
        #   command: ["sleep", "infinity"]
        #   resources:                            # fractionnaire => pool partagé
        #     requests: { cpu: "500m", memory: 64Mi }
        #     limits:   { cpu: "500m", memory: 64Mi }

      volumes:
        - name: monapp-bin
          hostPath:
            path: /opt/monapp
            type: Directory
__FIN_FICHIER_09__

ecrire 'rtlat/Cargo.toml' <<'__FIN_FICHIER_10__'
[package]
name = "rtlat"
version = "0.1.0"
edition = "2021"
description = "Vérification de la config temps réel et mesure de latence (timer, ping-pong, interruptions)"

[dependencies]
libc = "0.2"

[profile.release]
opt-level = 3
lto = true
codegen-units = 1
panic = "abort"
debug = false
__FIN_FICHIER_10__

ecrire 'rtlat/Cargo.lock' <<'__FIN_FICHIER_11__'
# This file is automatically @generated by Cargo.
# It is not intended for manual editing.
version = 4

[[package]]
name = "libc"
version = "0.2.191"
source = "registry+https://github.com/rust-lang/crates.io-index"
checksum = "65cd87c9a6d60536580b316ad985726104730a5151c99845f2490428ef91240a"

[[package]]
name = "rtlat"
version = "0.1.0"
dependencies = [
 "libc",
]
__FIN_FICHIER_11__

ecrire 'rtlat/src/main.rs' <<'__FIN_FICHIER_12__'
//! rtlat — vérifie la configuration temps réel et mesure la latence au plus près.
//!
//! Modes :
//!   check     état de la config RT (noyau, isolation, C-states, droits…) + diagnostic
//!   timer     latence de réveil sur timer périodique (même principe que cyclictest)
//!   pingpong  aller-retour entre deux threads (pipe, socket unix, ou spin mémoire)
//!   stall     boucle qui lit l'horloge en continu : chaque « trou » = le cœur a été
//!             pris par autre chose (IRQ, tick, SMI, bridage RT…)
//!
//! Pour chaque mesure : histogramme (10 ns jusqu'à 100 µs, 1 µs jusqu'à 100 ms),
//! percentiles, pires échantillons datés, défauts de page et préemptions du thread,
//! et interruptions reçues par le cœur pendant la mesure.

use std::collections::BTreeMap;
use std::ffi::CStr;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::fd::FromRawFd;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Barrier, Mutex};
use std::thread;

// ============================================================================
// Temps
// ============================================================================

#[inline(always)]
fn now_ns() -> u64 {
    let mut ts: libc::timespec = unsafe { std::mem::zeroed() };
    unsafe { libc::clock_gettime(libc::CLOCK_MONOTONIC, &mut ts) };
    ts.tv_sec as u64 * 1_000_000_000 + ts.tv_nsec as u64
}

fn sleep_until_ns(t: u64) {
    let mut ts: libc::timespec = unsafe { std::mem::zeroed() };
    ts.tv_sec = (t / 1_000_000_000) as _;
    ts.tv_nsec = (t % 1_000_000_000) as _;
    loop {
        let r = unsafe {
            libc::clock_nanosleep(libc::CLOCK_MONOTONIC, libc::TIMER_ABSTIME, &ts, std::ptr::null_mut())
        };
        if r != libc::EINTR {
            break;
        }
    }
}

fn fmt_ns(ns: u64) -> String {
    if ns >= 1_000_000 {
        format!("{:.3} ms", ns as f64 / 1e6)
    } else {
        format!("{:.2} µs", ns as f64 / 1e3)
    }
}

// ============================================================================
// Ordonnancement, affinité, mémoire
// ============================================================================

#[derive(Clone, Copy, PartialEq, Debug)]
enum Policy {
    Other,
    Fifo,
    Rr,
}

impl Policy {
    fn parse(s: &str) -> Result<Self, String> {
        match s {
            "other" => Ok(Policy::Other),
            "fifo" => Ok(Policy::Fifo),
            "rr" => Ok(Policy::Rr),
            _ => Err(format!("politique inconnue : {s} (fifo, rr, other)")),
        }
    }
    fn raw(self) -> i32 {
        match self {
            Policy::Other => libc::SCHED_OTHER,
            Policy::Fifo => libc::SCHED_FIFO,
            Policy::Rr => libc::SCHED_RR,
        }
    }
    fn is_rt(self) -> bool {
        self != Policy::Other
    }
}

fn policy_name(raw: i32) -> &'static str {
    match raw {
        libc::SCHED_OTHER => "SCHED_OTHER",
        libc::SCHED_FIFO => "SCHED_FIFO",
        libc::SCHED_RR => "SCHED_RR",
        libc::SCHED_BATCH => "SCHED_BATCH",
        libc::SCHED_IDLE => "SCHED_IDLE",
        _ => "inconnue",
    }
}

#[derive(Clone, Copy)]
struct ThreadCfg {
    cpu: Option<usize>,
    policy: Policy,
    prio: i32,
}

fn set_affinity(cpu: usize) -> Result<(), String> {
    unsafe {
        let mut set: libc::cpu_set_t = std::mem::zeroed();
        libc::CPU_ZERO(&mut set);
        libc::CPU_SET(cpu, &mut set);
        if libc::sched_setaffinity(0, std::mem::size_of::<libc::cpu_set_t>(), &set) != 0 {
            return Err(format!("sched_setaffinity(CPU {cpu}) : {}", io::Error::last_os_error()));
        }
    }
    Ok(())
}

fn get_affinity() -> Vec<usize> {
    let mut out = Vec::new();
    unsafe {
        let mut set: libc::cpu_set_t = std::mem::zeroed();
        if libc::sched_getaffinity(0, std::mem::size_of::<libc::cpu_set_t>(), &mut set) == 0 {
            for c in 0..libc::CPU_SETSIZE as usize {
                if libc::CPU_ISSET(c, &set) {
                    out.push(c);
                }
            }
        }
    }
    out
}

fn set_sched(p: Policy, prio: i32) -> Result<(), String> {
    let mut param: libc::sched_param = unsafe { std::mem::zeroed() };
    param.sched_priority = if p.is_rt() { prio } else { 0 };
    // pid 0 = thread appelant
    if unsafe { libc::sched_setscheduler(0, p.raw(), &param) } != 0 {
        return Err(format!(
            "sched_setscheduler({p:?}, {prio}) : {} (CAP_SYS_NICE manquant ?)",
            io::Error::last_os_error()
        ));
    }
    Ok(())
}

fn current_sched() -> (i32, i32) {
    let pol = unsafe { libc::sched_getscheduler(0) };
    let mut param: libc::sched_param = unsafe { std::mem::zeroed() };
    unsafe { libc::sched_getparam(0, &mut param) };
    (pol, param.sched_priority)
}

fn current_cpu() -> i32 {
    unsafe { libc::sched_getcpu() }
}

fn lock_memory() -> Result<(), String> {
    if unsafe { libc::mlockall(libc::MCL_CURRENT | libc::MCL_FUTURE) } != 0 {
        return Err(format!("mlockall : {} (CAP_IPC_LOCK ou ulimit -l ?)", io::Error::last_os_error()));
    }
    Ok(())
}

/// Touche la pile pour qu'aucun défaut de page n'arrive pendant la mesure.
#[inline(never)]
fn prefault_stack() {
    let mut buf = [0u8; 256 * 1024];
    for i in (0..buf.len()).step_by(4096) {
        unsafe { std::ptr::write_volatile(&mut buf[i], 1) };
    }
    std::hint::black_box(&buf);
}

/// Ordre important : affinité d'abord (pour ne jamais tourner en RT sur le mauvais cœur).
fn setup_thread(c: &ThreadCfg) -> Result<(), String> {
    if let Some(cpu) = c.cpu {
        set_affinity(cpu)?;
    }
    set_sched(c.policy, c.prio)?;
    prefault_stack();
    // premiers appels hors mesure (page vDSO de l'horloge, etc.)
    let _ = (now_ns(), thread_usage(), current_cpu(), get_affinity());
    Ok(())
}

#[derive(Default, Clone, Copy)]
struct Usage {
    minflt: i64,
    majflt: i64,
    nvcsw: i64,
    nivcsw: i64,
}

fn thread_usage() -> Usage {
    let mut ru: libc::rusage = unsafe { std::mem::zeroed() };
    unsafe { libc::getrusage(libc::RUSAGE_THREAD, &mut ru) };
    Usage {
        minflt: ru.ru_minflt as i64,
        majflt: ru.ru_majflt as i64,
        nvcsw: ru.ru_nvcsw as i64,
        nivcsw: ru.ru_nivcsw as i64,
    }
}

// ============================================================================
// Lecture du système
// ============================================================================

fn read_trim(path: &str) -> Option<String> {
    fs::read_to_string(path).ok().map(|s| s.trim().to_string())
}

fn parse_cpulist(s: &str) -> Vec<usize> {
    let mut out = Vec::new();
    for part in s.split(',').map(str::trim).filter(|p| !p.is_empty()) {
        if let Some((a, b)) = part.split_once('-') {
            if let (Ok(a), Ok(b)) = (a.parse::<usize>(), b.parse::<usize>()) {
                out.extend(a..=b);
            }
        } else if let Ok(v) = part.parse() {
            out.push(v);
        }
    }
    out
}

fn status_field(name: &str) -> Option<String> {
    let txt = fs::read_to_string("/proc/self/status").ok()?;
    txt.lines()
        .find(|l| l.starts_with(name))
        .map(|l| l[name.len()..].trim().to_string())
}

/// Compteurs d'interruptions d'un CPU : libellé -> (valeur, description)
type IrqMap = BTreeMap<String, (u64, String)>;

fn irq_snapshot(cpu: usize) -> Option<IrqMap> {
    let txt = fs::read_to_string("/proc/interrupts").ok()?;
    let mut lines = txt.lines();
    let cols: Vec<&str> = lines.next()?.split_whitespace().collect();
    let idx = cols.iter().position(|c| *c == format!("CPU{cpu}"))?;
    let ncpu = cols.len();
    let mut map = IrqMap::new();
    for l in lines {
        let mut it = l.split_whitespace();
        let Some(label) = it.next() else { continue };
        let rest: Vec<&str> = it.collect();
        if rest.len() < ncpu || !rest[..ncpu].iter().all(|s| s.parse::<u64>().is_ok()) {
            continue; // lignes ERR:/MIS: sans colonne par CPU
        }
        let v: u64 = rest[idx].parse().unwrap_or(0);
        map.insert(label.trim_end_matches(':').to_string(), (v, rest[ncpu..].join(" ")));
    }
    Some(map)
}

fn irq_diff(before: &IrqMap, after: &IrqMap) -> Vec<(String, u64, String)> {
    let mut out: Vec<(String, u64, String)> = after
        .iter()
        .filter_map(|(k, (v, d))| {
            let b = before.get(k).map(|x| x.0).unwrap_or(0);
            (*v > b).then(|| (k.clone(), v - b, d.clone()))
        })
        .collect();
    out.sort_by_key(|x| std::cmp::Reverse(x.1));
    out
}

// ============================================================================
// Statistiques : histogramme à deux résolutions + pires échantillons
// ============================================================================

const FINE_LIMIT: u64 = 100_000; // 100 µs, pas de 10 ns
const FINE_STEP: u64 = 10;
const COARSE_LIMIT: u64 = 100_000_000; // 100 ms, pas de 1 µs
const COARSE_STEP: u64 = 1_000;
const FINE_N: usize = (FINE_LIMIT / FINE_STEP) as usize;
const COARSE_N: usize = ((COARSE_LIMIT - FINE_LIMIT) / COARSE_STEP) as usize;
const NBUCKETS: usize = FINE_N + COARSE_N + 1; // dernier = débordement (> 100 ms)

#[inline(always)]
fn bucket_of(ns: u64) -> usize {
    if ns < FINE_LIMIT {
        (ns / FINE_STEP) as usize
    } else if ns < COARSE_LIMIT {
        FINE_N + ((ns - FINE_LIMIT) / COARSE_STEP) as usize
    } else {
        NBUCKETS - 1
    }
}

fn bucket_low(i: usize) -> u64 {
    if i < FINE_N {
        i as u64 * FINE_STEP
    } else if i < NBUCKETS - 1 {
        FINE_LIMIT + (i - FINE_N) as u64 * COARSE_STEP
    } else {
        COARSE_LIMIT
    }
}

fn bucket_high(i: usize) -> u64 {
    if i < FINE_N {
        (i as u64 + 1) * FINE_STEP
    } else if i < NBUCKETS - 1 {
        FINE_LIMIT + (i - FINE_N + 1) as u64 * COARSE_STEP
    } else {
        u64::MAX
    }
}

#[derive(Clone, Copy)]
struct Sample {
    ns: u64,
    idx: u64,
    t: u64, // depuis le début de la mesure
}

struct Stats {
    hist: Vec<u64>,
    count: u64,
    sum: u128,
    min: u64,
    max: u64,
    top: Vec<Sample>, // trié croissant, top[0] = le plus petit des pires
    top_n: usize,
    // série temporelle : NWIN fenêtres sur la durée de la mesure
    win_ns: u64,
    wcount: Vec<u64>,
    wsum: Vec<u64>,
    wmin: Vec<u64>,
    wmax: Vec<u64>,
}

const NWIN: usize = 2000;

fn json_str(s: &str) -> String {
    format!("\"{}\"", s.replace('\\', "\\\\").replace('"', "\\\""))
}

impl Stats {
    fn new(top_n: usize, duration_ns: u64) -> Self {
        let mut hist = vec![0u64; NBUCKETS];
        // calloc renvoie des pages paresseuses : on les touche maintenant
        for i in (0..hist.len()).step_by(512) {
            unsafe { std::ptr::write_volatile(&mut hist[i], 0) };
        }
        // idem pour le tableau des pires échantillons
        let mut top = Vec::with_capacity(top_n + 1);
        top.resize(top_n + 1, Sample { ns: 0, idx: 0, t: 0 });
        top.clear();
        Stats {
            hist,
            count: 0,
            sum: 0,
            min: u64::MAX,
            max: 0,
            top,
            top_n,
            win_ns: (duration_ns / NWIN as u64).max(1),
            wcount: vec![0; NWIN],
            wsum: vec![0; NWIN],
            wmin: vec![u64::MAX; NWIN],
            wmax: vec![0; NWIN],
        }
    }

    #[inline(always)]
    fn record(&mut self, ns: u64, idx: u64, t: u64) {
        self.hist[bucket_of(ns)] += 1;
        self.count += 1;
        self.sum += ns as u128;
        if ns < self.min {
            self.min = ns;
        }
        if ns > self.max {
            self.max = ns;
        }
        let w = ((t / self.win_ns) as usize).min(NWIN - 1);
        self.wcount[w] += 1;
        self.wsum[w] += ns;
        if ns < self.wmin[w] {
            self.wmin[w] = ns;
        }
        if ns > self.wmax[w] {
            self.wmax[w] = ns;
        }
        if self.top.len() < self.top_n {
            self.top.push(Sample { ns, idx, t });
            self.top.sort_unstable_by_key(|s| s.ns);
        } else if self.top_n > 0 && ns > self.top[0].ns {
            self.top[0] = Sample { ns, idx, t };
            self.top.sort_unstable_by_key(|s| s.ns);
        }
    }

    fn percentile(&self, p: f64) -> u64 {
        if self.count == 0 {
            return 0;
        }
        let target = ((p * self.count as f64).ceil() as u64).max(1);
        let mut acc = 0;
        for (i, &c) in self.hist.iter().enumerate() {
            acc += c;
            if acc >= target {
                return bucket_high(i).min(self.max); // borne haute du seau : estimation prudente
            }
        }
        self.max
    }

    fn count_at_least(&self, ns: u64) -> u64 {
        self.hist.iter().enumerate().filter(|(i, _)| bucket_low(*i) >= ns).map(|(_, c)| c).sum()
    }

    fn write_csv(&self, path: &str) -> io::Result<()> {
        let mut f = File::create(path)?;
        writeln!(f, "borne_basse_ns,borne_haute_ns,nombre")?;
        for (i, &c) in self.hist.iter().enumerate().filter(|(_, c)| **c > 0) {
            let hi = if i == NBUCKETS - 1 { self.max } else { bucket_high(i) };
            writeln!(f, "{},{},{}", bucket_low(i), hi, c)?;
        }
        Ok(())
    }

    /// Résultat complet pour rtlat_plot.py
    fn write_json(&self, path: &str, meta: &[(&str, String)]) -> io::Result<()> {
        let mut o = String::from("{\n  \"meta\": {");
        o += &meta.iter().map(|(k, v)| format!("{}: {}", json_str(k), json_str(v))).collect::<Vec<_>>().join(", ");
        let avg = if self.count > 0 { (self.sum / self.count as u128) as u64 } else { 0 };
        let min = if self.count > 0 { self.min } else { 0 };
        o += &format!(
            "}},\n  \"count\": {}, \"sum_ns\": {}, \"min_ns\": {min}, \"avg_ns\": {avg}, \"max_ns\": {},\n",
            self.count, self.sum, self.max
        );
        let pcts: Vec<String> = [(0.5, "50"), (0.9, "90"), (0.99, "99"), (0.999, "99.9"), (0.9999, "99.99"), (0.99999, "99.999")]
            .iter()
            .map(|(p, k)| format!("\"{k}\": {}", self.percentile(*p)))
            .collect();
        o += &format!("  \"percentiles\": {{{}}},\n", pcts.join(", "));
        let hist: Vec<String> = self
            .hist
            .iter()
            .enumerate()
            .filter(|(_, c)| **c > 0)
            .map(|(i, c)| {
                let hi = if i == NBUCKETS - 1 { self.max } else { bucket_high(i) };
                format!("[{},{},{}]", bucket_low(i), hi, c)
            })
            .collect();
        o += &format!("  \"hist\": [{}],\n", hist.join(","));
        let wins: Vec<String> = (0..NWIN)
            .filter(|&w| self.wcount[w] > 0)
            .map(|w| {
                format!(
                    "[{},{},{},{},{}]",
                    w,
                    self.wcount[w],
                    self.wmin[w],
                    self.wsum[w] / self.wcount[w],
                    self.wmax[w]
                )
            })
            .collect();
        o += &format!("  \"window_ns\": {},\n  \"windows\": [{}],\n", self.win_ns, wins.join(","));
        let top: Vec<String> = self.top.iter().rev().map(|s| format!("[{},{},{}]", s.ns, s.idx, s.t)).collect();
        o += &format!("  \"top\": [{}]\n}}\n", top.join(","));
        fs::write(path, o)
    }
}

// ============================================================================
// Configuration en ligne de commande
// ============================================================================

#[derive(Clone, Copy, PartialEq, Debug)]
enum Transport {
    Pipe,
    Unix,
    Spin,
}

struct Cfg {
    mode: String,
    cpu: Option<usize>,
    cpu2: Option<usize>,
    policy: Option<Policy>,
    prio: i32,
    duration_ns: u64,
    interval_us: u64,
    transport: Transport,
    threshold_ns: u64,
    warmup: Option<u64>,
    top: usize,
    dma_latency: Option<i32>,
    csv: Option<String>,
    out: Option<String>,
    mlock: bool,
    load_cpus: Vec<usize>,
    load_kind: LoadKind,
}

#[derive(Clone, Copy, PartialEq, Debug)]
enum LoadKind {
    Memcpy,
    Cpu,
    Mixed,
}

impl LoadKind {
    fn name(self) -> &'static str {
        match self {
            LoadKind::Memcpy => "memcpy",
            LoadKind::Cpu => "cpu",
            LoadKind::Mixed => "mixed",
        }
    }
}

const USAGE: &str = "\
rtlat — vérification RT et mesure de latence

USAGE : rtlat <check|timer|pingpong|stall|load> [options]

  check      état de la config temps réel + diagnostic (avec --cpu : détail du cœur)
  timer      latence de réveil d'un timer périodique (comme cyclictest)
  pingpong   aller-retour entre deux threads (--transport pipe|unix|spin)
  stall      détecte chaque interruption du cœur (IRQ, tick, SMI, bridage RT)
  load       charge parasite seule (--load-cpus, --load-kind, --duration)

OPTIONS
  --cpu N            cœur du thread mesuré (recommandé)
  --cpu2 N           cœur du thread écho en pingpong (défaut : --cpu)
  --policy P         fifo | rr | other   (défaut : fifo ; other pour stall et spin)
  --prio N           priorité RT 1-99 (défaut : 80)
  --duration S       durée en secondes (défaut : 10)
  --interval US      période du timer en µs (défaut : 1000)
  --transport T      pipe | unix | spin (défaut : unix)
  --threshold NS     seuil de détection pour stall, en ns (défaut : 1000)
  --warmup N         premiers échantillons ignorés
                     (défaut : timer 100, pingpong 1000, stall 0)
  --top N            nombre de pires échantillons affichés (défaut : 10)
  --dma-latency US   maintient /dev/cpu_dma_latency pendant la mesure
                     (0 = interdit les C-states profonds, sur TOUTE la machine)
  --csv FICHIER      écrit l'histogramme en CSV
  --out FICHIER      écrit le résultat complet en JSON (pour rtlat_plot.py)
  --load-cpus LISTE  charge parasite pendant la mesure sur ces cœurs (ex : 0-5)
  --load-kind K      memcpy (mémoire + cache L3, défaut) | cpu | mixed
  --no-mlock         ne pas verrouiller la mémoire (pour comparer)

EXEMPLES
  rtlat check --cpu 7
  rtlat timer --cpu 7 --prio 80 --interval 1000 --duration 60
  rtlat pingpong --cpu 7 --cpu2 8 --transport unix --duration 30
  rtlat stall --cpu 7 --duration 30 --threshold 2000
  rtlat timer --cpu 7 --duration 3600 --load-cpus 0-5 --out timer-charge.json
";

fn parse_args() -> Result<Cfg, String> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.is_empty() || args.iter().any(|a| a == "-h" || a == "--help") {
        print!("{USAGE}");
        std::process::exit(0);
    }
    let mut c = Cfg {
        mode: args[0].clone(),
        cpu: None,
        cpu2: None,
        policy: None,
        prio: 80,
        duration_ns: 10_000_000_000,
        interval_us: 1000,
        transport: Transport::Unix,
        threshold_ns: 1000,
        warmup: None,
        top: 10,
        dma_latency: None,
        csv: None,
        out: None,
        load_cpus: Vec::new(),
        load_kind: LoadKind::Memcpy,
        mlock: true,
    };
    let mut i = 1;
    while i < args.len() {
        let flag = args[i].as_str();
        if flag == "--no-mlock" {
            c.mlock = false;
            i += 1;
            continue;
        }
        let val = args.get(i + 1).ok_or(format!("valeur manquante pour {flag}"))?;
        let num = |v: &str| v.parse::<u64>().map_err(|_| format!("valeur invalide pour {flag} : {v}"));
        match flag {
            "--cpu" => c.cpu = Some(num(val)? as usize),
            "--cpu2" => c.cpu2 = Some(num(val)? as usize),
            "--policy" => c.policy = Some(Policy::parse(val)?),
            "--prio" => c.prio = num(val)? as i32,
            "--duration" => {
                let s: f64 = val.parse().map_err(|_| format!("durée invalide : {val}"))?;
                c.duration_ns = (s * 1e9) as u64;
            }
            "--interval" => c.interval_us = num(val)?.max(1),
            "--transport" => {
                c.transport = match val.as_str() {
                    "pipe" => Transport::Pipe,
                    "unix" => Transport::Unix,
                    "spin" => Transport::Spin,
                    _ => return Err(format!("transport inconnu : {val}")),
                }
            }
            "--threshold" => c.threshold_ns = num(val)?,
            "--warmup" => c.warmup = Some(num(val)?),
            "--top" => c.top = num(val)? as usize,
            "--dma-latency" => c.dma_latency = Some(num(val)? as i32),
            "--csv" => c.csv = Some(val.clone()),
            "--out" => c.out = Some(val.clone()),
            "--load-cpus" => {
                c.load_cpus = parse_cpulist(val);
                if c.load_cpus.is_empty() {
                    return Err(format!("liste de CPU invalide : {val}"));
                }
            }
            "--load-kind" => {
                c.load_kind = match val.as_str() {
                    "memcpy" => LoadKind::Memcpy,
                    "cpu" => LoadKind::Cpu,
                    "mixed" => LoadKind::Mixed,
                    _ => return Err(format!("type de charge inconnu : {val}")),
                }
            }
            _ => return Err(format!("option inconnue : {flag}")),
        }
        i += 2;
    }
    if !(1..=99).contains(&c.prio) {
        return Err("--prio doit être entre 1 et 99".into());
    }
    Ok(c)
}

impl Cfg {
    fn effective_policy(&self) -> Policy {
        self.policy.unwrap_or(match (self.mode.as_str(), self.transport) {
            ("stall", _) | ("pingpong", Transport::Spin) => Policy::Other,
            _ => Policy::Fifo,
        })
    }
    fn warmup(&self) -> u64 {
        self.warmup.unwrap_or(match self.mode.as_str() {
            "timer" => 100,
            "stall" => 0,
            _ => 1000,
        })
    }
    fn tcfg(&self, cpu: Option<usize>) -> ThreadCfg {
        ThreadCfg { cpu, policy: self.effective_policy(), prio: self.prio }
    }
}

// ============================================================================
// Résultat d'une mesure et rapport
// ============================================================================

struct Measure {
    st: Stats,
    u0: Usage,
    u1: Usage,
    cpu_start: i32,
    cpu_end: i32,
    sched: (i32, i32),
    affinity: Vec<usize>,
    extra: Vec<String>,
}

fn report(cfg: &Cfg, title: &str, m: &Measure, irq: Option<Vec<(String, u64, String)>>) {
    let st = &m.st;
    println!("\n=== {title} ===");
    println!(
        "thread mesuré : {} prio {} | CPU début/fin : {}/{} | affinité : {:?}",
        policy_name(m.sched.0),
        m.sched.1,
        m.cpu_start,
        m.cpu_end,
        m.affinity
    );
    if let Some(cpu) = cfg.cpu {
        let iso = parse_cpulist(&read_trim("/sys/devices/system/cpu/isolated").unwrap_or_default());
        let nohz = parse_cpulist(&read_trim("/sys/devices/system/cpu/nohz_full").unwrap_or_default());
        println!(
            "CPU {cpu} : isolé = {} | nohz_full = {} | mémoire verrouillée = {}",
            if iso.contains(&cpu) { "oui" } else { "NON" },
            if nohz.contains(&cpu) { "oui" } else { "non" },
            if cfg.mlock { "oui" } else { "non" }
        );
    }
    if !cfg.load_cpus.is_empty() {
        println!("charge parasite : {} sur CPU {:?}", cfg.load_kind.name(), cfg.load_cpus);
    }
    for e in &m.extra {
        println!("{e}");
    }
    if st.count == 0 {
        println!("aucun échantillon enregistré (durée trop courte par rapport à --warmup {} ?)", cfg.warmup());
        return;
    }
    let avg = (st.sum / st.count as u128) as u64;
    println!("\néchantillons : {} ({} ignorés en échauffement)", st.count, cfg.warmup());
    println!("min / moy / max : {} / {} / {}", fmt_ns(st.min), fmt_ns(avg), fmt_ns(st.max));
    println!(
        "p50 {} | p99 {} | p99.9 {} | p99.99 {} | p99.999 {}",
        fmt_ns(st.percentile(0.50)),
        fmt_ns(st.percentile(0.99)),
        fmt_ns(st.percentile(0.999)),
        fmt_ns(st.percentile(0.9999)),
        fmt_ns(st.percentile(0.99999))
    );
    print!("au-delà de :");
    for (thr, label) in [
        (10_000u64, "10 µs"),
        (20_000, "20 µs"),
        (50_000, "50 µs"),
        (100_000, "100 µs"),
        (1_000_000, "1 ms"),
        (10_000_000, "10 ms"),
    ] {
        print!("  {label}: {}", st.count_at_least(thr));
    }
    println!();

    if !st.top.is_empty() {
        println!("\npires échantillons :");
        for (rank, s) in st.top.iter().rev().enumerate() {
            println!(
                "  #{:<2} {:>12}   à t = {:>10.3} s   (échantillon n° {})",
                rank + 1,
                fmt_ns(s.ns),
                s.t as f64 / 1e9,
                s.idx
            );
        }
        // Dans l'ordre chronologique : un écart régulier trahit une cause périodique
        let mut chrono = st.top.clone();
        chrono.sort_by_key(|s| s.t);
        let gaps: Vec<String> =
            chrono.windows(2).map(|w| format!("{:.3}", (w[1].t - w[0].t) as f64 / 1e9)).collect();
        if !gaps.is_empty() {
            println!("  écarts entre eux (ordre chronologique, s) : {}", gaps.join(" "));
        }
    }

    let d = |a: i64, b: i64| b - a;
    let (minf, majf) = (d(m.u0.minflt, m.u1.minflt), d(m.u0.majflt, m.u1.majflt));
    let (vcs, ivcs) = (d(m.u0.nvcsw, m.u1.nvcsw), d(m.u0.nivcsw, m.u1.nivcsw));
    println!("\nthread mesuré pendant la mesure :");
    println!("  défauts de page mineurs / majeurs : {minf} / {majf}");
    println!("  changements de contexte volontaires / involontaires : {vcs} / {ivcs}");

    if let (Some(cpu), Some(list)) = (cfg.cpu, irq) {
        println!("\ninterruptions reçues par le CPU {cpu} pendant la mesure :");
        if list.is_empty() {
            println!("  aucune");
        }
        for (k, n, desc) in list.iter().take(12) {
            println!("  {k:>6} {n:>10}  {desc}");
        }
    }

    // ---- Diagnostic -------------------------------------------------------
    let mut diag = Vec::new();
    if m.cpu_start != m.cpu_end {
        diag.push("le thread a changé de cœur pendant la mesure : affinité non appliquée ?".to_string());
    }
    if minf > 0 || majf > 0 {
        diag.push(format!("{} défaut(s) de page pendant la mesure : mémoire non verrouillée ?", minf + majf));
    }
    if ivcs > 0 {
        diag.push(format!(
            "thread préempté {ivcs} fois : une tâche plus prioritaire (ou le bridage RT) a pris le cœur"
        ));
    }
    if cfg.effective_policy().is_rt() && st.max >= 10_000_000 {
        let rt = read_trim("/proc/sys/kernel/sched_rt_runtime_us").unwrap_or_default();
        if rt != "-1" {
            diag.push(format!(
                "pause de {} en RT avec sched_rt_runtime_us = {rt} : signature du bridage RT \
                 (le cœur a été occupé à 100 % en RT pendant ~1 s)",
                fmt_ns(st.max)
            ));
        }
    }
    if !diag.is_empty() {
        println!("\ndiagnostic :");
        for d in diag {
            println!("  - {d}");
        }
    }

    if let Some(path) = &cfg.out {
        let mut u: libc::utsname = unsafe { std::mem::zeroed() };
        unsafe { libc::uname(&mut u) };
        let epoch = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        let opt = |v: Option<usize>| v.map(|c| c.to_string()).unwrap_or_default();
        let meta = [
            ("title", title.to_string()),
            ("mode", cfg.mode.clone()),
            ("cpu", opt(cfg.cpu)),
            ("cpu2", opt(cfg.cpu2.or(cfg.cpu))),
            ("policy", policy_name(m.sched.0).to_string()),
            ("prio", m.sched.1.to_string()),
            ("duration_s", format!("{}", cfg.duration_ns as f64 / 1e9)),
            ("interval_us", cfg.interval_us.to_string()),
            ("transport", format!("{:?}", cfg.transport).to_lowercase()),
            ("threshold_ns", cfg.threshold_ns.to_string()),
            ("warmup", cfg.warmup().to_string()),
            ("load", if cfg.load_cpus.is_empty() { "aucune".into() } else { format!("{} sur {:?}", cfg.load_kind.name(), cfg.load_cpus) }),
            ("kernel", uname_field(&u.release)),
            ("host", uname_field(&u.nodename)),
            ("epoch", epoch.to_string()),
        ];
        match st.write_json(path, &meta) {
            Ok(()) => println!("\nrésultat complet écrit dans {path} (tracé : python3 rtlat_plot.py {path})"),
            Err(e) => eprintln!("écriture JSON impossible ({path}) : {e}"),
        }
    }
    if let Some(path) = &cfg.csv {
        match st.write_csv(path) {
            Ok(()) => println!("\nhistogramme écrit dans {path}"),
            Err(e) => eprintln!("écriture CSV impossible ({path}) : {e}"),
        }
    }
}

fn warn_busy_rt(cfg: &Cfg) {
    if cfg.effective_policy().is_rt() {
        let rt = read_trim("/proc/sys/kernel/sched_rt_runtime_us").unwrap_or_default();
        if rt != "-1" {
            eprintln!(
                "attention : boucle active en {:?} avec sched_rt_runtime_us = {rt} : attendez-vous \
                 à des pauses de quelques dizaines de ms chaque seconde (bridage RT). \
                 Utilisez --policy other pour mesurer sans ce bridage.",
                cfg.effective_policy()
            );
        }
    }
}

// ============================================================================
// Mode timer
// ============================================================================

fn run_timer(cfg: &Cfg) -> Result<(), String> {
    let interval = cfg.interval_us * 1000;
    let (tc, warmup, dur, top) = (cfg.tcfg(cfg.cpu), cfg.warmup(), cfg.duration_ns, cfg.top);
    let irq0 = cfg.cpu.and_then(irq_snapshot);

    let h = thread::Builder::new()
        .name("rtlat-timer".into())
        .stack_size(4 << 20)
        .spawn(move || -> Result<Measure, String> {
            setup_thread(&tc)?;
            let mut st = Stats::new(top, dur);
            let (cpu_start, affinity, u0) = (current_cpu(), get_affinity(), thread_usage());
            let start = now_ns() + interval;
            let end = start + dur;
            let (mut next, mut i, mut overruns) = (start, 0u64, 0u64);
            while next < end {
                sleep_until_ns(next);
                let t = now_ns();
                if i >= warmup {
                    st.record(t.saturating_sub(next), i, t - start);
                }
                i += 1;
                next += interval;
                if t >= next {
                    // on a raté une ou plusieurs périodes
                    let missed = (t - next) / interval + 1;
                    overruns += missed;
                    next += missed * interval;
                }
            }
            let u1 = thread_usage();
            Ok(Measure {
                st,
                u0,
                u1,
                cpu_start,
                cpu_end: current_cpu(),
                sched: current_sched(),
                affinity,
                extra: vec![format!("période : {} µs | périodes ratées : {overruns}", interval / 1000)],
            })
        })
        .map_err(|e| format!("création du thread : {e}"))?;

    let m = h.join().map_err(|_| "le thread de mesure a paniqué".to_string())??;
    let irq = match (irq0, cfg.cpu.and_then(irq_snapshot)) {
        (Some(a), Some(b)) => Some(irq_diff(&a, &b)),
        _ => None,
    };
    report(cfg, "latence de réveil du timer (retard sur l'échéance)", &m, irq);
    Ok(())
}

// ============================================================================
// Mode pingpong
// ============================================================================

#[repr(align(128))] // une ligne de cache (et sa voisine prefetchée) par variable
struct Line(AtomicU64);

struct SpinShared {
    ping: Line,
    pong: Line,
}

/// (lecture, écriture) pour un côté de l'échange
type Chan = (File, File);

fn make_channel(t: Transport) -> Result<(Chan, Chan), String> {
    let err = |what: &str| format!("{what} : {}", io::Error::last_os_error());
    unsafe {
        match t {
            Transport::Pipe => {
                let (mut a, mut b) = ([0i32; 2], [0i32; 2]);
                if libc::pipe2(a.as_mut_ptr(), libc::O_CLOEXEC) != 0 || libc::pipe2(b.as_mut_ptr(), libc::O_CLOEXEC) != 0 {
                    return Err(err("pipe2"));
                }
                // côté mesure : écrit dans a, lit dans b ; côté écho : l'inverse
                Ok((
                    (File::from_raw_fd(b[0]), File::from_raw_fd(a[1])),
                    (File::from_raw_fd(a[0]), File::from_raw_fd(b[1])),
                ))
            }
            Transport::Unix => {
                let mut s = [0i32; 2];
                if libc::socketpair(libc::AF_UNIX, libc::SOCK_STREAM | libc::SOCK_CLOEXEC, 0, s.as_mut_ptr()) != 0 {
                    return Err(err("socketpair"));
                }
                let (d0, d1) = (libc::dup(s[0]), libc::dup(s[1]));
                if d0 < 0 || d1 < 0 {
                    return Err(err("dup"));
                }
                Ok((
                    (File::from_raw_fd(s[0]), File::from_raw_fd(d0)),
                    (File::from_raw_fd(s[1]), File::from_raw_fd(d1)),
                ))
            }
            Transport::Spin => unreachable!(),
        }
    }
}

fn run_pingpong(cfg: &Cfg) -> Result<(), String> {
    let cpu2 = cfg.cpu2.or(cfg.cpu);
    if cfg.transport == Transport::Spin {
        match (cfg.cpu, cpu2) {
            (Some(a), Some(b)) if a != b => {}
            _ => return Err("--transport spin exige --cpu et --cpu2 différents (attente active)".into()),
        }
        warn_busy_rt(cfg);
    }
    let (tc_a, tc_b) = (cfg.tcfg(cfg.cpu), cfg.tcfg(cpu2));
    let (warmup, dur, top, transport) = (cfg.warmup(), cfg.duration_ns, cfg.top, cfg.transport);
    let barrier = Arc::new(Barrier::new(2));
    let errors = Arc::new(Mutex::new(Vec::<String>::new()));
    let spin = Arc::new(SpinShared { ping: Line(AtomicU64::new(0)), pong: Line(AtomicU64::new(0)) });
    let chans = if transport == Transport::Spin { None } else { Some(make_channel(transport)?) };
    let (side_a, side_b) = match chans {
        Some((a, b)) => (Some(a), Some(b)),
        None => (None, None),
    };
    let irq0 = cfg.cpu.and_then(irq_snapshot);

    // ---- thread écho --------------------------------------------------------
    let (bb, eb, sb) = (barrier.clone(), errors.clone(), spin.clone());
    let echo = thread::Builder::new()
        .name("rtlat-echo".into())
        .stack_size(4 << 20)
        .spawn(move || {
            if let Err(e) = setup_thread(&tc_b) {
                eb.lock().unwrap().push(format!("thread écho : {e}"));
            }
            bb.wait();
            if !eb.lock().unwrap().is_empty() {
                return;
            }
            match side_b {
                Some((mut rx, mut tx)) => {
                    let mut buf = [0u8; 8];
                    loop {
                        if rx.read_exact(&mut buf).is_err() || u64::from_ne_bytes(buf) == u64::MAX {
                            return;
                        }
                        if tx.write_all(&buf).is_err() {
                            return;
                        }
                    }
                }
                None => {
                    let mut last = 0;
                    loop {
                        let v = sb.ping.0.load(Ordering::Acquire);
                        if v == last {
                            std::hint::spin_loop();
                            continue;
                        }
                        if v == u64::MAX {
                            return;
                        }
                        sb.pong.0.store(v, Ordering::Release);
                        last = v;
                    }
                }
            }
        })
        .map_err(|e| format!("création du thread écho : {e}"))?;

    // ---- thread de mesure -----------------------------------------------------
    let (ba, ea, sa) = (barrier.clone(), errors.clone(), spin.clone());
    let meas = thread::Builder::new()
        .name("rtlat-ping".into())
        .stack_size(4 << 20)
        .spawn(move || -> Result<Measure, String> {
            let setup = setup_thread(&tc_a);
            if let Err(e) = &setup {
                ea.lock().unwrap().push(format!("thread de mesure : {e}"));
            }
            let mut st = Stats::new(top, dur);
            ba.wait();
            if let Some(e) = ea.lock().unwrap().first() {
                return Err(e.clone());
            }
            let (cpu_start, affinity, u0) = (current_cpu(), get_affinity(), thread_usage());
            let start = now_ns();
            let end = start + dur;
            let mut i = 0u64;
            match side_a {
                Some((mut rx, mut tx)) => {
                    let mut buf = [0u8; 8];
                    loop {
                        let t0 = now_ns();
                        if t0 >= end {
                            break;
                        }
                        tx.write_all(&t0.to_ne_bytes()).map_err(|e| format!("écriture : {e}"))?;
                        rx.read_exact(&mut buf).map_err(|e| format!("lecture : {e}"))?;
                        let t1 = now_ns();
                        if i >= warmup {
                            st.record(t1 - t0, i, t0 - start);
                        }
                        i += 1;
                    }
                    let _ = tx.write_all(&u64::MAX.to_ne_bytes());
                }
                None => {
                    loop {
                        let t0 = now_ns();
                        if t0 >= end {
                            break;
                        }
                        let seq = i + 1;
                        sa.ping.0.store(seq, Ordering::Release);
                        while sa.pong.0.load(Ordering::Acquire) != seq {
                            std::hint::spin_loop();
                        }
                        let t1 = now_ns();
                        if i >= warmup {
                            st.record(t1 - t0, i, t0 - start);
                        }
                        i += 1;
                    }
                    sa.ping.0.store(u64::MAX, Ordering::Release);
                }
            }
            let u1 = thread_usage();
            Ok(Measure {
                st,
                u0,
                u1,
                cpu_start,
                cpu_end: current_cpu(),
                sched: current_sched(),
                affinity,
                extra: vec![format!(
                    "transport : {transport:?} | thread écho sur CPU {} | aller simple ≈ aller-retour / 2",
                    tc_b.cpu.map(|c| c.to_string()).unwrap_or("libre".into())
                )],
            })
        })
        .map_err(|e| format!("création du thread de mesure : {e}"))?;

    let res = meas.join().map_err(|_| "le thread de mesure a paniqué".to_string())?;
    if res.is_err() {
        // débloque l'écho s'il attend encore
        spin.ping.0.store(u64::MAX, Ordering::Release);
    }
    let _ = echo.join();
    let m = res?;
    let irq = match (irq0, cfg.cpu.and_then(irq_snapshot)) {
        (Some(a), Some(b)) => Some(irq_diff(&a, &b)),
        _ => None,
    };
    report(cfg, "aller-retour entre deux threads", &m, irq);
    Ok(())
}

// ============================================================================
// Mode stall
// ============================================================================

fn run_stall(cfg: &Cfg) -> Result<(), String> {
    warn_busy_rt(cfg);
    let (tc, warmup, dur, top, thr) = (cfg.tcfg(cfg.cpu), cfg.warmup(), cfg.duration_ns, cfg.top, cfg.threshold_ns);
    let irq0 = cfg.cpu.and_then(irq_snapshot);

    let h = thread::Builder::new()
        .name("rtlat-stall".into())
        .stack_size(4 << 20)
        .spawn(move || -> Result<Measure, String> {
            setup_thread(&tc)?;
            let mut st = Stats::new(top, dur);
            let (cpu_start, affinity, u0) = (current_cpu(), get_affinity(), thread_usage());
            let start = now_ns();
            let end = start + dur;
            let (mut prev, mut iters) = (start, 0u64);
            loop {
                let t = now_ns();
                let gap = t - prev;
                if gap > thr && iters >= warmup {
                    st.record(gap, iters, t - start);
                }
                prev = t;
                iters += 1;
                if iters & 1023 == 0 && t >= end {
                    break;
                }
            }
            let elapsed = prev - start;
            let u1 = thread_usage();
            Ok(Measure {
                cpu_end: current_cpu(),
                sched: current_sched(),
                extra: vec![
                    format!(
                        "seuil : {} | itérations : {iters} | lecture d'horloge : {:.1} ns en moyenne",
                        fmt_ns(thr),
                        elapsed as f64 / iters as f64
                    ),
                    format!(
                        "temps volé au thread : {} sur {:.3} s ({:.4} %)",
                        fmt_ns(st.sum as u64),
                        elapsed as f64 / 1e9,
                        st.sum as f64 / elapsed as f64 * 100.0
                    ),
                ],
                st,
                u0,
                u1,
                cpu_start,
                affinity,
            })
        })
        .map_err(|e| format!("création du thread : {e}"))?;

    let m = h.join().map_err(|_| "le thread de mesure a paniqué".to_string())??;
    let irq = match (irq0, cfg.cpu.and_then(irq_snapshot)) {
        (Some(a), Some(b)) => Some(irq_diff(&a, &b)),
        _ => None,
    };
    report(cfg, "interruptions du thread (durée de chaque trou)", &m, irq);
    Ok(())
}

// ============================================================================
// Mode check
// ============================================================================

fn uname_field(f: &[libc::c_char]) -> String {
    unsafe { CStr::from_ptr(f.as_ptr()) }.to_string_lossy().into_owned()
}

fn rlimit_str(res: i32) -> String {
    let mut r: libc::rlimit = unsafe { std::mem::zeroed() };
    if unsafe { libc::getrlimit(res as _, &mut r) } != 0 {
        return "?".into();
    }
    let f = |v: libc::rlim_t| if v == libc::RLIM_INFINITY { "illimité".to_string() } else { v.to_string() };
    format!("{} (max {})", f(r.rlim_cur), f(r.rlim_max))
}

fn run_check(cfg: &Cfg) -> Result<(), String> {
    let mut warn: Vec<String> = Vec::new();
    let get = |p: &str| read_trim(p).unwrap_or_else(|| "absent".into());

    println!("=== Système ===");
    let mut u: libc::utsname = unsafe { std::mem::zeroed() };
    unsafe { libc::uname(&mut u) };
    let version = uname_field(&u.version);
    println!("noyau            : {} {}", uname_field(&u.release), version);
    let preempt_rt = std::path::Path::new("/sys/kernel/realtime").exists() || version.contains("PREEMPT_RT");
    println!("PREEMPT_RT       : {}", if preempt_rt { "oui" } else { "non (noyau standard)" });
    println!("ligne de commande: {}", get("/proc/cmdline"));
    let isolated = get("/sys/devices/system/cpu/isolated");
    let nohz = get("/sys/devices/system/cpu/nohz_full");
    println!("cœurs isolés     : {}", if isolated.is_empty() { "aucun" } else { &isolated });
    println!("nohz_full        : {}", if nohz.is_empty() || nohz == "(null)" { "aucun" } else { &nohz });
    let rt_runtime = get("/proc/sys/kernel/sched_rt_runtime_us");
    println!(
        "bridage RT       : sched_rt_runtime_us = {rt_runtime} / sched_rt_period_us = {}",
        get("/proc/sys/kernel/sched_rt_period_us")
    );
    let thp = get("/sys/kernel/mm/transparent_hugepage/enabled");
    println!("THP              : {thp}");
    if thp.contains("[always]") {
        warn.push("THP en mode always : compactage mémoire possible pendant un défaut de page (pics de latence)".into());
    }
    if rt_runtime != "-1" && rt_runtime != "absent" {
        warn.push(format!(
            "bridage RT actif ({rt_runtime} µs/s) : une tâche RT à 100 % sera suspendue jusqu'à ~50 ms par seconde"
        ));
    }

    println!("\n=== Ce process ===");
    println!("CPU autorisés    : {}", status_field("Cpus_allowed_list:").unwrap_or("?".into()));
    let capeff = status_field("CapEff:").unwrap_or_default();
    let caps = u64::from_str_radix(&capeff, 16).unwrap_or(0);
    let has = |bit: u32| caps & (1u64 << bit) != 0;
    println!(
        "capabilities     : CapEff={capeff} | SYS_NICE={} IPC_LOCK={} SYS_ADMIN={}",
        if has(23) { "oui" } else { "non" },
        if has(14) { "oui" } else { "non" },
        if has(21) { "oui" } else { "non" }
    );
    println!("RLIMIT_RTPRIO    : {}", rlimit_str(libc::RLIMIT_RTPRIO as i32));
    println!("RLIMIT_MEMLOCK   : {}", rlimit_str(libc::RLIMIT_MEMLOCK as i32));
    let cg = fs::read_to_string("/proc/self/cgroup").unwrap_or_default();
    println!("cgroup           : {}", cg.lines().next().unwrap_or("?"));
    if !has(23) {
        warn.push("pas de CAP_SYS_NICE : impossible de passer en SCHED_FIFO/RR".into());
    }

    if let Some(cpu) = cfg.cpu {
        println!("\n=== CPU {cpu} ===");
        let base = format!("/sys/devices/system/cpu/cpu{cpu}");
        let iso = parse_cpulist(&isolated);
        if !iso.contains(&cpu) {
            warn.push(format!("CPU {cpu} n'est pas isolé (isolcpus)"));
        }
        if !parse_cpulist(&nohz).contains(&cpu) {
            warn.push(format!("CPU {cpu} n'est pas en nohz_full : le tick noyau continue"));
        }
        let gov = get(&format!("{base}/cpufreq/scaling_governor"));
        println!(
            "fréquence        : gouverneur {gov} | actuelle {} kHz | min {} | max {}",
            get(&format!("{base}/cpufreq/scaling_cur_freq")),
            get(&format!("{base}/cpufreq/scaling_min_freq")),
            get(&format!("{base}/cpufreq/scaling_max_freq"))
        );
        if gov != "performance" && gov != "absent" {
            warn.push(format!("gouverneur CPU {cpu} = {gov} : la fréquence varie (cpupower frequency-set -g performance)"));
        }
        println!("pilote cpuidle   : {}", get("/sys/devices/system/cpu/cpuidle/current_driver"));
        println!("états de veille  :");
        let mut deep_enabled = Vec::new();
        for s in 0..16 {
            let p = format!("{base}/cpuidle/state{s}");
            let Some(name) = read_trim(&format!("{p}/name")) else { break };
            let lat: u64 = read_trim(&format!("{p}/latency")).and_then(|v| v.parse().ok()).unwrap_or(0);
            let dis = read_trim(&format!("{p}/disable")).unwrap_or_default();
            let usage = read_trim(&format!("{p}/usage")).unwrap_or_default();
            println!(
                "  state{s:<2} {name:<10} sortie {lat:>4} µs  {}  utilisé {usage} fois",
                if dis == "1" { "désactivé" } else { "actif    " }
            );
            if dis != "1" && lat > 10 {
                deep_enabled.push(format!("{name} ({lat} µs)"));
            }
        }
        if !deep_enabled.is_empty() {
            warn.push(format!(
                "états de veille lents actifs sur CPU {cpu} : {} (cpupower -c {cpu} idle-set -D 10)",
                deep_enabled.join(", ")
            ));
        }
        if let Some(irq) = irq_snapshot(cpu) {
            let mut v: Vec<_> = irq.iter().filter(|(_, (n, _))| *n > 0).collect();
            v.sort_by_key(|x| std::cmp::Reverse(x.1 .0));
            println!("interruptions cumulées depuis le boot (top 8) :");
            for (k, (n, d)) in v.iter().take(8) {
                println!("  {k:>6} {n:>12}  {d}");
            }
        }
    }

    println!("\n=== Tests ===");
    match lock_memory() {
        Ok(()) => println!("mlockall         : OK"),
        Err(e) => {
            println!("mlockall         : ÉCHEC — {e}");
            warn.push("mlockall impossible : défauts de page possibles pendant l'exécution RT".into());
        }
    }
    if let Some(cpu) = cfg.cpu {
        match set_affinity(cpu) {
            Ok(()) => println!("affinité CPU {cpu}   : OK (exécution sur CPU {})", current_cpu()),
            Err(e) => {
                println!("affinité CPU {cpu}   : ÉCHEC — {e}");
                warn.push(format!("impossible de s'épingler sur CPU {cpu} (cpuset du conteneur ?)"));
            }
        }
    }
    match set_sched(Policy::Fifo, cfg.prio) {
        Ok(()) => {
            let (p, pr) = current_sched();
            println!("SCHED_FIFO {:<5} : OK ({} {pr})", cfg.prio, policy_name(p));
            let _ = set_sched(Policy::Other, 0);
        }
        Err(e) => {
            println!("SCHED_FIFO {:<5} : ÉCHEC — {e}", cfg.prio);
            warn.push("passage en SCHED_FIFO refusé".into());
        }
    }

    println!("\n=== Diagnostic ===");
    if warn.is_empty() {
        println!("rien à signaler");
    }
    for w in warn {
        println!("  - {w}");
    }
    Ok(())
}

// ============================================================================
// Charge parasite (« voisin bruyant »)
// ============================================================================

fn run_load(cfg: &Cfg) -> Result<(), String> {
    if cfg.load_cpus.is_empty() {
        return Err("le mode load exige --load-cpus".into());
    }
    let stop = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let mut handles = Vec::new();
    for (n, &cpu) in cfg.load_cpus.iter().enumerate() {
        let stop = stop.clone();
        let kind = match cfg.load_kind {
            LoadKind::Mixed if n % 2 == 1 => LoadKind::Cpu,
            LoadKind::Mixed => LoadKind::Memcpy,
            k => k,
        };
        handles.push(thread::spawn(move || {
            if let Err(e) = set_affinity(cpu) {
                eprintln!("charge : {e}");
                return;
            }
            match kind {
                LoadKind::Memcpy => {
                    // 2 × 32 Mo : bien plus que le L3, on sature cache et bande passante mémoire
                    let mut a = vec![1u8; 32 << 20];
                    let mut b = vec![2u8; 32 << 20];
                    while !stop.load(Ordering::Relaxed) {
                        b.copy_from_slice(&a);
                        std::mem::swap(&mut a, &mut b);
                        std::hint::black_box(&b);
                    }
                }
                _ => {
                    let mut x = 1u64;
                    while !stop.load(Ordering::Relaxed) {
                        for _ in 0..1_000_000 {
                            x = x.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
                        }
                        std::hint::black_box(x);
                    }
                }
            }
        }));
    }
    eprintln!("charge {} sur CPU {:?} pendant {:.0} s", cfg.load_kind.name(), cfg.load_cpus, cfg.duration_ns as f64 / 1e9);
    thread::sleep(std::time::Duration::from_nanos(cfg.duration_ns));
    stop.store(true, Ordering::Relaxed);
    for h in handles {
        let _ = h.join();
    }
    Ok(())
}

/// Lance la charge dans un process séparé (sa mémoire n'est pas verrouillée par mlockall).
/// posix_spawn plutôt que std::process::Command : ce dernier fait dépendre le binaire
/// de symboles glibc récents (2.39), alors qu'OL9 a la glibc 2.34.
fn spawn_load(cfg: &Cfg) -> Option<libc::pid_t> {
    if cfg.load_cpus.is_empty() || cfg.mode == "load" || cfg.mode == "check" {
        return None;
    }
    if let Some(cpu) = cfg.cpu {
        if cfg.load_cpus.contains(&cpu) {
            eprintln!("attention : la charge tourne aussi sur le CPU mesuré ({cpu})");
        }
    }
    extern "C" {
        static environ: *const *mut libc::c_char;
    }
    let exe = std::env::current_exe().ok()?.into_os_string().into_string().ok()?;
    let list = cfg.load_cpus.iter().map(|c| c.to_string()).collect::<Vec<_>>().join(",");
    let secs = format!("{}", cfg.duration_ns as f64 / 1e9 + 10.0);
    let args = [exe.as_str(), "load", "--load-cpus", &list, "--load-kind", cfg.load_kind.name(), "--duration", &secs];
    let cargs: Vec<std::ffi::CString> = args.iter().map(|a| std::ffi::CString::new(*a).unwrap()).collect();
    let mut argv: Vec<*mut libc::c_char> = cargs.iter().map(|c| c.as_ptr() as *mut libc::c_char).collect();
    argv.push(std::ptr::null_mut());
    let mut pid: libc::pid_t = 0;
    let r = unsafe {
        libc::posix_spawn(&mut pid, cargs[0].as_ptr(), std::ptr::null(), std::ptr::null(), argv.as_ptr(), environ)
    };
    if r != 0 {
        eprintln!("attention : impossible de lancer la charge : {}", io::Error::from_raw_os_error(r));
        return None;
    }
    thread::sleep(std::time::Duration::from_secs(1)); // laisse la charge monter
    Some(pid)
}

fn stop_load(pid: libc::pid_t) {
    unsafe {
        libc::kill(pid, libc::SIGTERM);
        libc::waitpid(pid, std::ptr::null_mut(), 0);
    }
}

// ============================================================================

fn main() {
    let cfg = match parse_args() {
        Ok(c) => c,
        Err(e) => {
            eprintln!("erreur : {e}\n\n{USAGE}");
            std::process::exit(2);
        }
    };

    // Gardé ouvert jusqu'à la fin : la contrainte cesse à la fermeture du fichier.
    let _dma = match cfg.dma_latency {
        Some(us) => match OpenOptions::new().write(true).open("/dev/cpu_dma_latency") {
            Ok(mut f) => {
                let _ = f.write_all(&us.to_ne_bytes());
                eprintln!("/dev/cpu_dma_latency = {us} µs pendant la mesure (toute la machine)");
                Some(f)
            }
            Err(e) => {
                eprintln!("erreur : /dev/cpu_dma_latency : {e}");
                std::process::exit(1);
            }
        },
        None => None,
    };

    if cfg.mlock && cfg.mode != "check" && cfg.mode != "load" {
        if let Err(e) = lock_memory() {
            eprintln!("attention : {e}");
        }
    }

    let child = spawn_load(&cfg);
    let res = match cfg.mode.as_str() {
        "check" => run_check(&cfg),
        "timer" => run_timer(&cfg),
        "pingpong" => run_pingpong(&cfg),
        "stall" => run_stall(&cfg),
        "load" => run_load(&cfg),
        m => Err(format!("mode inconnu : {m}\n\n{USAGE}")),
    };
    if let Some(pid) = child {
        stop_load(pid);
    }
    if let Err(e) = res {
        eprintln!("erreur : {e}");
        std::process::exit(1);
    }
}
__FIN_FICHIER_12__

ecrire 'rtlat/README.md' <<'__FIN_FICHIER_13__'
# rtlat — vérification temps réel et mesure de latence

Un seul binaire, une seule dépendance (`libc`), plus un script de tracé Python. Cinq modes :

| Mode | Ce qu'il mesure | Politique par défaut |
|---|---|---|
| `check` | config RT : noyau, isolcpus, nohz_full, bridage RT, THP, C-states, fréquence, droits, + tests | — |
| `timer` | retard de réveil d'un timer périodique (principe de `cyclictest`) | FIFO 80 |
| `pingpong` | aller-retour entre deux threads : `unix` (≈ ZeroMQ ipc), `pipe`, `spin` (mémoire partagée) | FIFO 80, `other` pour `spin` |
| `stall` | chaque « trou » pendant lequel le cœur a été pris (IRQ, tick, SMI, bridage RT) | `other` |
| `load` | charge parasite seule (memcpy / cpu), aussi intégrable à une mesure via `--load-cpus` | — |

Chaque mesure affiche : min/moy/max, p50 → p99.999, nombre d'échantillons au-delà de
10 µs … 10 ms, les pires échantillons **datés** (et l'écart entre eux, pour repérer une
cause périodique), les défauts de page et préemptions du thread, les interruptions
reçues par le cœur pendant la mesure, et un diagnostic.

## Compiler

```bash
cargo build --release                 # binaire : target/release/rtlat
```

Le binaire glibc demande au plus GLIBC 2.34 : il tourne sur OL9 et dans `oraclelinux:9-slim`.

Pour un binaire statique qui tourne dans n'importe quelle image :
```bash
rustup target add x86_64-unknown-linux-musl
cargo build --release --target x86_64-unknown-linux-musl
```

En airgap, sur la machine connectée : `cargo vendor` puis suivre les instructions
affichées (bloc à copier dans `.cargo/config.toml`), et transférer le dossier entier.

## Utilisation conseillée (dans l'ordre)

```bash
# 1. La config est-elle bonne ?
rtlat check --cpu 7

# 2. La plateforme seule : latence de réveil sur le cœur RT
rtlat timer --cpu 7 --prio 80 --interval 1000 --duration 300

# 3. Qui vole du temps au cœur ? (SCHED_OTHER : pas de bridage RT)
rtlat stall --cpu 7 --duration 60 --threshold 2000

# 4. Communication entre threads, comme tes applis
rtlat pingpong --cpu 7 --cpu2 8 --transport unix --duration 60   # deux cœurs
rtlat pingpong --cpu 7 --transport unix --duration 60            # même cœur
rtlat pingpong --cpu 7 --cpu2 8 --transport spin --duration 30   # plancher matériel
```

Options utiles : `--dma-latency 0` (interdit les C-states profonds pendant la mesure,
sur toute la machine, pour comparer), `--no-mlock` (pour voir l'effet du verrouillage
mémoire), `--csv histo.csv` (histogramme pour tracer).

Droits nécessaires : `CAP_SYS_NICE` (RT), `CAP_IPC_LOCK` (mlockall), root pour
`--dma-latency`. Dans le pod : les capabilities du manifest suffisent.

## Mesurer comme les références (méthodologie)

Ce que font OSADL, Canonical, Intel ECI et le wiki RT de la Linux Foundation :

1. **Sous charge représentative** : une mesure au repos sous-estime le pire cas.
   `--load-cpus 0-5 --load-kind memcpy` lance un « voisin bruyant » qui sature le cache L3
   partagé et la bande passante mémoire sur les cœurs non isolés (ou `stress-ng` si disponible).
2. **Longtemps** : les événements rares ne sortent qu'en heures (Intel ECI : 24 h par
   configuration). 10 s sert à valider, pas à qualifier.
3. **Histogramme en échelle log**, max affiché, une configuration par courbe.
4. **Comparer en ne changeant qu'un réglage à la fois** (C-states, nohz_full, priorité…).

```bash
rtlat timer --cpu 7 --duration 3600 --out repos.json
rtlat timer --cpu 7 --duration 3600 --load-cpus 0-5 --out charge.json
python3 rtlat_plot.py repos.json charge.json --labels "repos,charge" --deadline 50
```

Outils de référence complémentaires (paquets à embarquer en airgap) :
`cyclictest` / `hwlatdetect` (rt-tests) pour des chiffres comparables aux publications,
`rtla timerlat` / `rtla osnoise` (outils du noyau) pour trouver la **cause** d'un pic :
`rtla timerlat top -a 50` arrête la trace au premier dépassement de 50 µs et dit qui
(IRQ, thread, softirq) a retardé le réveil.

## Tracés

`rtlat_plot.py` (matplotlib) lit un ou plusieurs JSON `--out` et produit une figure :

- **répartition des latences**, axe Y log (style OSADL). `--gauss` superpose une gaussienne
  ajustée sur le cœur : une distribution de latence n'est **jamais** gaussienne — bornée à
  gauche par le minimum matériel, souvent multimodale, avec une longue queue à droite ;
- **latence par percentile** (style HdrHistogram) : lecture directe de p99, p99.99… et du max ;
- **évolution dans le temps** (max et moyenne par fenêtre) : un pic régulier = une cause
  périodique (ex. bridage RT toutes les 1,000 s).

Options : `-o fig.png|svg|pdf`, `--labels`, `--deadline US` (budget + nombre de
dépassements), `--logx` (toute la plage, pics compris), `--xmax US`.
À lancer sur n'importe quelle machine avec Python 3 + matplotlib : le JSON est petit.

## Lire les résultats

| Symptôme | Cause probable |
|---|---|
| pires échantillons espacés de **1,000 s**, 30-50 ms chacun, en RT | bridage RT (`sched_rt_runtime_us`) : le cœur est à 100 % en RT |
| `LOC` élevé dans les interruptions du cœur | le tick noyau tourne : `nohz_full` absent, ou plus d'une tâche sur le cœur |
| `CAL` / `TLB` | appels inter-cœurs / invalidations TLB causés par d'autres process (munmap, mprotect…) |
| `RES` | réveils inter-cœurs (rescheduling IPI) |
| trous de 50-200 µs sans aucune interruption visible | SMI (BIOS) — invisibles pour l'OS |
| défauts de page > 0 | mémoire non verrouillée, ou allocations pendant la boucle |
| préemptions involontaires > 0 | une tâche plus prioritaire, ou le bridage RT, a pris le cœur |
| `timer` : max qui baisse avec `--dma-latency 0` | C-states profonds en cause |

Note : le mode `stall` en `--policy fifo` reproduit volontairement le bridage RT
(boucle active à 100 %) — utile pour le voir, à éviter pour mesurer le reste.
__FIN_FICHIER_13__

ecrire 'rtlat/rtlat_plot.py' <<'__FIN_FICHIER_14__'
#!/usr/bin/env python3
"""rtlat_plot.py — tracés de latence à partir des JSON produits par `rtlat ... --out`.

Trois vues, les mêmes que dans les outils de référence :
  1. histogramme en échelle log (style OSADL / cyclictest) : la forme de la distribution
     et sa queue ; une gaussienne y apparaîtrait comme une parabole symétrique ;
  2. distribution par percentile (style HdrHistogram) : la latence en fonction de
     « 1 échantillon sur 10, 100, 1000… », lecture directe du pire cas probable ;
  3. série temporelle (max et moyenne par fenêtre) : quand surviennent les pics,
     et s'ils sont périodiques (ex. bridage RT toutes les 1,000 s).

Plusieurs fichiers = courbes superposées (ex. avant/après réglage, repos/charge).

Usage :
  python3 rtlat_plot.py resultat.json
  python3 rtlat_plot.py repos.json charge.json --labels "repos,sous charge" -o comparaison.png
  python3 rtlat_plot.py timer.json --deadline 50 --gauss
Options :
  -o FICHIER        sortie (.png, .svg, .pdf) ; défaut : <premier fichier>.png
  --labels A,B      noms des courbes
  --logx            histogramme sur axe x logarithmique (toute la plage, pics compris)
  --xmax US         borne droite de l'histogramme linéaire, en µs
  --deadline US     budget de latence : ligne rouge + nombre de dépassements
  --gauss           superpose une gaussienne ajustée sur le cœur (médiane, MAD) :
                    montre tout ce que la queue réelle a de plus qu'une loi normale
  --title TEXTE     titre de la figure
Dépendances : matplotlib (et numpy, qu'il installe).
"""

import argparse
import json
import math
import os
import sys

import matplotlib

matplotlib.use("Agg")  # pas besoin d'écran
import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402

PCT_KEYS = ["50", "90", "99", "99.9", "99.99", "99.999"]


def fmt_us(us):
    if us >= 1000:
        return f"{us / 1000:.2f} ms"
    if us >= 10:
        return f"{us:.1f} µs"
    return f"{us:.2f} µs"


def load(path):
    with open(path) as f:
        d = json.load(f)
    h = np.array(d["hist"], dtype=float) if d["hist"] else np.zeros((0, 3))
    d["_lo"] = h[:, 0] / 1000.0  # µs
    d["_hi"] = h[:, 1] / 1000.0
    d["_n"] = h[:, 2]
    d["_mid"] = (d["_lo"] + d["_hi"]) / 2.0
    d["_path"] = path
    return d


def default_label(d):
    m = d["meta"]
    parts = [m.get("mode", "?")]
    if m.get("mode") == "pingpong":
        parts.append(m.get("transport", ""))
    if m.get("cpu"):
        parts.append(f"CPU{m['cpu']}")
    pol = m.get("policy", "").replace("SCHED_", "")
    parts.append(f"{pol}{m.get('prio', '') if pol in ('FIFO', 'RR') else ''}")
    if m.get("load", "aucune") != "aucune":
        parts.append(f"charge {m['load'].split(' ')[0]}")
    return " ".join(p for p in parts if p)


def x_label(runs):
    modes = {r["meta"].get("mode") for r in runs}
    if modes == {"pingpong"}:
        return "aller-retour (µs)"
    if modes == {"stall"}:
        return "durée de l'interruption (µs)"
    if modes == {"timer"}:
        return "retard de réveil (µs)"
    return "latence (µs)"


def latency_at(d, q):
    """Latence (µs) au quantile q, à partir de l'histogramme (borne haute du seau)."""
    if d["count"] == 0:
        return 0.0
    cum = np.cumsum(d["_n"]) / d["count"]
    i = int(np.searchsorted(cum, q, side="left"))
    i = min(i, len(cum) - 1)
    return min(d["_hi"][i], d["max_ns"] / 1000.0)


def weighted_median(values, weights):
    order = np.argsort(values)
    v, w = values[order], weights[order]
    cum = np.cumsum(w)
    return float(v[int(np.searchsorted(cum, cum[-1] / 2.0))])


# --------------------------------------------------------------------------
# 1. Histogramme
# --------------------------------------------------------------------------
def plot_hist(ax, runs, labels, colors, args):
    all_min = min(r["min_ns"] for r in runs) / 1000.0
    all_max = max(r["max_ns"] for r in runs) / 1000.0
    p99 =max(r["percentiles"]["99"] for r in runs) / 1000.0

    if args.logx:
        edges = np.geomspace(max(all_min * 0.9, 0.01), all_max * 1.1, 300)
    else:
        # cadre sur le corps de la distribution ; la queue est comptée « hors cadre »
        # et visible en entier avec --logx et sur les deux autres vues
        xmax = args.xmax or min(all_max * 1.05, max(p99 * 4, all_min * 3))
        xmin = max(0.0, all_min - (xmax - all_min) * 0.02)
        edges = np.linspace(xmin, xmax, 400)

    for d, lab, c in zip(runs, labels, colors):
        counts, _ = np.histogram(d["_mid"], bins=edges, weights=d["_n"])
        ax.stairs(counts, edges, color=c, linewidth=1.2, label=lab)
        outside = d["_n"][d["_mid"] > edges[-1]].sum()
        mx = d["max_ns"] / 1000.0
        if mx <= edges[-1]:
            ax.axvline(mx, color=c, linestyle=":", linewidth=1)
        if outside > 0:
            ax.annotate(
                f"{int(outside)} hors cadre → max {fmt_us(mx)}",
                xy=(0.99, 0.72 - 0.06 * runs.index(d)),
                xycoords="axes fraction",
                ha="right",
                va="top",
                color=c,
                fontsize=8,
            )
        if args.gauss and not args.logx and d["count"] > 1:
            # Ajustement robuste sur le cœur de la distribution (médiane, MAD) : la moyenne
            # et l'écart-type classiques sont écrasés par la queue et ne décrivent rien.
            mu = weighted_median(d["_mid"], d["_n"])
            sigma = 1.4826 * weighted_median(np.abs(d["_mid"] - mu), d["_n"])
            if sigma > 0:
                xs = np.linspace(edges[0], edges[-1], 2000)
                bw = edges[1] - edges[0]
                pdf = d["count"] * bw * np.exp(-0.5 * ((xs - mu) / sigma) ** 2) / (sigma * math.sqrt(2 * math.pi))
                ax.plot(xs, np.where(pdf >= 0.5, pdf, np.nan), color=c, linestyle="--", linewidth=1, alpha=0.8,
                        label=f"gaussienne ajustée sur le cœur (médiane {fmt_us(mu)}, σ≈{fmt_us(sigma)})")

    if args.deadline:
        ax.axvline(args.deadline, color="red", linewidth=1.5, label=f"budget {fmt_us(args.deadline)}")
    ax.set_yscale("log")
    ax.set_ylim(bottom=0.8)
    if args.logx:
        ax.set_xscale("log")
    ax.set_xlabel(x_label(runs))
    ax.set_ylabel("nombre d'échantillons (échelle log)")
    ax.set_title("Répartition des latences")
    ax.grid(True, which="both", alpha=0.25)
    ax.legend(fontsize=8, loc="upper right")


# --------------------------------------------------------------------------
# 2. Distribution par percentile (HdrHistogram)
# --------------------------------------------------------------------------
def plot_percentiles(ax, runs, labels, colors, args):
    max_nines = 0
    for d, lab, c in zip(runs, labels, colors):
        if d["count"] == 0:
            continue
        nines = math.log10(d["count"])  # au-delà, plus aucun échantillon
        max_nines = max(max_nines, nines)
        xs = np.linspace(0, nines, 600)
        qs = 1 - 10.0 ** (-xs)
        ys = [latency_at(d, q) for q in qs]
        ax.plot(xs, ys, color=c, linewidth=1.5, label=lab)
        ax.plot([nines], [d["max_ns"] / 1000.0], marker="o", color=c, markersize=4)
    ticks = list(range(0, int(math.ceil(max_nines)) + 1))
    names = ["0 %", "90 %", "99 %", "99,9 %", "99,99 %", "99,999 %", "99,9999 %", "99,99999 %", "99,999999 %"]
    ax.set_xticks(ticks)
    ax.set_xticklabels([names[t] if t < len(names) else f"{t} neufs" for t in ticks], rotation=30, fontsize=8)
    if args.deadline:
        ax.axhline(args.deadline, color="red", linewidth=1.5, label=f"budget {fmt_us(args.deadline)}")
    ax.set_yscale("log")
    ax.set_xlabel("percentile  (● = maximum observé)")
    ax.set_ylabel(x_label(runs))
    ax.set_title("Latence par percentile")
    ax.grid(True, which="both", alpha=0.25)
    ax.legend(fontsize=8, loc="upper left")


# --------------------------------------------------------------------------
# 3. Série temporelle
# --------------------------------------------------------------------------
def plot_timeseries(ax, runs, labels, colors, args):
    for d, lab, c in zip(runs, labels, colors):
        if not d["windows"]:
            continue
        w = np.array(d["windows"], dtype=float)
        t = (w[:, 0] + 0.5) * d["window_ns"] / 1e9
        ax.plot(t, w[:, 4] / 1000.0, color=c, linewidth=0.8, label=f"{lab} — max par fenêtre")
        ax.plot(t, w[:, 3] / 1000.0, color=c, linewidth=0.6, alpha=0.45, linestyle="-",
                label=f"{lab} — moyenne par fenêtre")
        for s in d["top"][:5]:
            ax.plot(s[2] / 1e9, s[0] / 1000.0, marker="v", color=c, markersize=5)
    if args.deadline:
        ax.axhline(args.deadline, color="red", linewidth=1.5)
    ax.set_yscale("log")
    win = runs[0]["window_ns"] / 1e6
    ax.set_xlabel(f"temps depuis le début de la mesure (s) — fenêtres de {win:.2f} ms, ▼ = 5 pires échantillons")
    ax.set_ylabel(x_label(runs))
    ax.set_title("Évolution dans le temps (un pic régulier = une cause périodique)")
    ax.grid(True, which="both", alpha=0.25)
    ax.legend(fontsize=7, ncol=2, loc="upper right")


# --------------------------------------------------------------------------
def summary_line(d, lab, deadline):
    p = d["percentiles"]
    s = (f"{lab}: n={d['count']}  min {fmt_us(d['min_ns'] / 1000)}  moy {fmt_us(d['avg_ns'] / 1000)}  "
         f"p99 {fmt_us(p['99'] / 1000)}  p99.99 {fmt_us(p['99.99'] / 1000)}  max {fmt_us(d['max_ns'] / 1000)}")
    if deadline:
        over = d["_n"][d["_lo"] >= deadline].sum()
        s += f"  > budget : {int(over)} ({over / max(d['count'], 1) * 100:.4f} %)"
    return s


def main():
    ap = argparse.ArgumentParser(description="Tracés de latence pour les JSON de rtlat")
    ap.add_argument("files", nargs="+")
    ap.add_argument("-o", "--output")
    ap.add_argument("--labels")
    ap.add_argument("--logx", action="store_true")
    ap.add_argument("--xmax", type=float)
    ap.add_argument("--deadline", type=float)
    ap.add_argument("--gauss", action="store_true")
    ap.add_argument("--title")
    args = ap.parse_args()

    runs = [load(f) for f in args.files]
    runs = [r for r in runs if r["count"] > 0]
    if not runs:
        sys.exit("aucun échantillon dans les fichiers fournis")
    labels = args.labels.split(",") if args.labels else [default_label(r) for r in runs]
    if len(labels) != len(runs):
        sys.exit("--labels : il faut autant de noms que de fichiers")
    colors = plt.rcParams["axes.prop_cycle"].by_key()["color"]
    colors = [colors[i % len(colors)] for i in range(len(runs))]

    fig = plt.figure(figsize=(15, 10), constrained_layout=True)
    gs = fig.add_gridspec(2, 2, height_ratios=[1.15, 1])
    plot_hist(fig.add_subplot(gs[0, 0]), runs, labels, colors, args)
    plot_percentiles(fig.add_subplot(gs[0, 1]), runs, labels, colors, args)
    plot_timeseries(fig.add_subplot(gs[1, :]), runs, labels, colors, args)

    m = runs[0]["meta"]
    title = args.title or f"rtlat — {m.get('title', '')}"
    sub = (f"{m.get('host', '')} | noyau {m.get('kernel', '')} | durée {float(m.get('duration_s', 0)):.0f} s"
           + (f" | période {m.get('interval_us')} µs" if m.get("mode") == "timer" else ""))
    lines = [summary_line(r, lab, args.deadline) for r, lab in zip(runs, labels)]
    fig.suptitle(title + "\n" + sub + "\n" + "\n".join(lines), fontsize=9, x=0.01, ha="left")

    out = args.output or os.path.splitext(args.files[0])[0] + ".png"
    fig.savefig(out, dpi=140)
    print("\n".join(lines))
    print(f"figure écrite : {out}")


if __name__ == "__main__":
    main()
__FIN_FICHIER_14__
chmod +x 'rtlat/rtlat_plot.py'

echo
echo "Kit créé. Étapes suivantes : voir $(pwd)/LISEZMOI.md"
