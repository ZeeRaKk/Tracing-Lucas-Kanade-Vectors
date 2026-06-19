# compose.yaml — boucle TOR temps réel sous Podman + crun (PREEMPT_RT)
#
# ⚠️ LANCER EN ROOTFUL :
#     sudo podman compose up --build        (1er run : build l'image)
#     sudo podman compose up                (runs suivants)
#   ou avec le wrapper Python :  sudo podman-compose up --build
#
# En rootless, CAP_SYS_NICE est namespacé => sched_setscheduler(SCHED_FIFO)
# échoue. Le RT exige donc root.
#
# Pré-requis HOST (compose NE peut PAS les faire — voir notes en bas) :
#   - noyau PREEMPT_RT, cœurs 2-7 isolés : isolcpus=2-7 nohz_full=2-7 rcu_nocbs=2-7 irqaffinity=0-1
#   - swap off, gouverneur performance, crun installé
#   - /dev/uio0 présent (driver uio_pci_generic ou driver vendeur)
#   - IRQ de la carte routée hors des cœurs RT (cf. notes)

services:
  rt-tor:
    build:
      context: .
      dockerfile: Containerfile      # le Containerfile multi-étapes du tuto
    image: localhost/rt-tor:latest
    pull_policy: never               # image locale / air-gap : jamais de pull

    runtime: crun                    # runtime OCI léger et déterministe

    # --- Affinité CPU : épingle sur les cœurs ISOLÉS au boot ---
    cpuset: "2-3"

    # --- Réseau coupé : pas de setup netavark, moins de bruit, OK air-gap ---
    network_mode: none

    # --- Capacités minimales (pas de --privileged) ---
    cap_add:
      - SYS_NICE                     # SCHED_FIFO (contourne le ulimit rtprio)
      - IPC_LOCK                     # mlockall sans plafond

    # --- Limites temps réel ---
    ulimits:
      rtprio: 99                     # priorité RT max autorisée
      memlock:
        soft: -1
        hard: -1                     # verrouillage mémoire illimité

    # --- Carte TOR exposée en UIO : mappe le nœud /dev + pose la règle cgroup ---
    devices:
      - "/dev/uio0:/dev/uio0:rw"

    # --- sysfs en lecture seule : adresse/taille des BAR pour le mmap ---
    volumes:
      - "/sys/class/uio/uio0:/sys/class/uio/uio0:ro"

    restart: unless-stopped

    # Si SELinux (Fedora/RHEL) bloque l'accès au device/sysfs, décommenter :
    # security_opt:
    #   - label=disable