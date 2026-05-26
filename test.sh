#!/usr/bin/env bash
###############################################################################
#
#   raid-check-repair.sh
#   ---------------------------------------------------------------------------
#   Vérification et réparation d'un RAID1 logiciel (mdadm) sur sda et sdb.
#   Tables de partition : GPT. À exécuter en root.
#
#   Arbre de décision :
#     - Un des deux disques absent ........................ exit, rien à faire
#     - Tailles des disques différentes ................... exit, rien à faire
#     - Resync/recovery en cours .......................... exit, on laisse finir
#     - GPT invalide sur un seul disque ................... on restaure depuis l'autre
#     - GPT invalide sur les deux disques ................. exit, intervention manuelle
#     - Array dégradé / superblock manquant / faulty ...... on répare
#     - mismatch_cnt > 0 .................................. on lance un repair
#     - Tout va bien ...................................... exit, rien à faire
#
#   Options :
#     --dry-run    Affiche les actions sans les exécuter
#     --help       Aide
#
###############################################################################

set -euo pipefail


# =============================================================================
# 1. CONFIGURATION
# =============================================================================

readonly DISK_A="/dev/sda"
readonly DISK_B="/dev/sdb"
readonly LOCK_FILE="/var/run/raid-check-repair.lock"
readonly GPT_BACKUP="/tmp/raid-gpt-source.bin"

# Codes de sortie explicites pour le supervisor.
readonly EXIT_OK=0
readonly EXIT_USAGE=1
readonly EXIT_DISK_MISSING=2
readonly EXIT_SIZE_MISMATCH=3
readonly EXIT_BOTH_GPT_INVALID=4
readonly EXIT_LOCK_HELD=5
readonly EXIT_NOT_ROOT=6
readonly EXIT_MISSING_TOOL=7

DRY_RUN=0


# =============================================================================
# 2. HELPERS GÉNÉRIQUES (logs, exécution, prérequis)
# =============================================================================

log()  { echo "[INFO]  $*"; }
warn() { echo "[WARN]  $*"; }
err()  { echo "[ERROR] $*" >&2; }

section() {
    echo ""
    echo "==> $*"
}

# Exécute la commande passée, ou l'affiche seulement en mode --dry-run.
run() {
    if (( DRY_RUN )); then
        echo "[DRY-RUN] $*"
        return 0
    fi
    "$@"
}

usage() {
    cat <<EOF
Usage: $0 [--dry-run] [--help]

Vérifie et répare un RAID1 logiciel monté sur ${DISK_A} et ${DISK_B}.

Options :
  --dry-run    Affiche les actions sans rien modifier sur les disques
  --help, -h   Affiche cette aide
EOF
}

ensure_root() {
    if (( EUID != 0 )); then
        err "Ce script doit être exécuté en root."
        exit $EXIT_NOT_ROOT
    fi
}

ensure_tools_available() {
    local missing=()
    local tool
    for tool in mdadm sgdisk lsblk blkid awk grep partprobe blockdev flock; do
        command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
    done

    if (( ${#missing[@]} > 0 )); then
        err "Outils manquants : ${missing[*]}"
        exit $EXIT_MISSING_TOOL
    fi
}

# Empêche deux instances de tourner en parallèle (boot + cron par exemple).
acquire_lock() {
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        err "Une autre instance est déjà en cours ($LOCK_FILE)."
        exit $EXIT_LOCK_HELD
    fi
}


# =============================================================================
# 3. VÉRIFICATIONS PRÉALABLES
# =============================================================================

# Vérifie que les deux disques sont visibles par le kernel.
check_both_disks_present() {
    section "Présence des disques"

    local missing=0
    local disk
    for disk in "$DISK_A" "$DISK_B"; do
        if [[ -b "$disk" ]]; then
            log "  $disk présent"
        else
            err "  $disk absent"
            missing=1
        fi
    done

    if (( missing )); then
        err "Un disque manque, aucune action ne sera tentée."
        exit $EXIT_DISK_MISSING
    fi
}

# Refuse d'agir si les deux disques n'ont pas exactement la même taille,
# car un disque plus petit corromprait l'array, et un disque plus gros
# indique probablement une erreur de remplacement.
check_disks_same_size() {
    section "Taille des disques"

    local size_a size_b
    size_a=$(blockdev --getsize64 "$DISK_A")
    size_b=$(blockdev --getsize64 "$DISK_B")

    log "  $DISK_A : $size_a octets"
    log "  $DISK_B : $size_b octets"

    if [[ "$size_a" != "$size_b" ]]; then
        err "Les deux disques n'ont pas la même taille."
        err "Refus d'agir pour ne pas corrompre l'array."
        exit $EXIT_SIZE_MISMATCH
    fi
}

# Si une synchro est en cours, on ne touche à rien : la couper laisserait
# l'array dans un état pire qu'avant.
check_no_sync_in_progress() {
    section "Resync / recovery en cours ?"

    if grep -qE 'resync|recovery|reshape|check' /proc/mdstat; then
        warn "Opération mdadm détectée, on laisse finir :"
        grep -E 'resync|recovery|reshape|check' /proc/mdstat || true
        exit $EXIT_OK
    fi

    log "  Aucune synchro en cours."
}


# =============================================================================
# 4. GESTION DE LA TABLE DE PARTITION (GPT)
# =============================================================================

# Vrai (0) si le disque a une GPT lisible, faux sinon.
disk_has_valid_gpt() {
    sgdisk --print "$1" >/dev/null 2>&1
}

# Copie la GPT du disque source sur le disque cible, puis génère un nouveau
# GUID pour éviter toute collision (deux disques avec le même GUID = chaos).
restore_partition_table_from() {
    local src="$1"
    local dst="$2"

    warn "Restauration de la GPT : $src --> $dst"
    run sgdisk --backup="$GPT_BACKUP" "$src"
    run sgdisk --load-backup="$GPT_BACKUP" "$dst"
    run sgdisk -G "$dst"
    run partprobe "$dst"
    log "  GPT restaurée sur $dst."
}

# Évalue l'état GPT des deux disques et restaure si exactement un est KO.
# Sort en erreur si les deux sont KO (cas désespéré, intervention manuelle).
check_and_repair_partition_tables() {
    section "État des tables GPT"

    local a_ok=0 b_ok=0
    disk_has_valid_gpt "$DISK_A" && a_ok=1
    disk_has_valid_gpt "$DISK_B" && b_ok=1

    log "  $DISK_A : $( (( a_ok )) && echo OK || echo INVALIDE)"
    log "  $DISK_B : $( (( b_ok )) && echo OK || echo INVALIDE)"

    if (( ! a_ok && ! b_ok )); then
        err "Aucune table GPT valide sur les deux disques."
        err "Intervention manuelle requise."
        exit $EXIT_BOTH_GPT_INVALID
    fi

    if (( ! a_ok )); then
        restore_partition_table_from "$DISK_B" "$DISK_A"
    elif (( ! b_ok )); then
        restore_partition_table_from "$DISK_A" "$DISK_B"
    fi
}


# =============================================================================
# 5. INTROSPECTION DES ARRAYS RAID
# =============================================================================

# Liste les arrays md actifs (ex: "md0 md1 md2").
list_active_md_arrays() {
    awk '/^md[0-9]+ :/ {print $1}' /proc/mdstat
}

# Pour un array donné, liste les noms de partitions membres (sans flags).
list_array_member_partitions() {
    local md="$1"
    awk -v md="$md" '
        $1 == md ":" {
            for (i = 5; i <= NF; i++) {
                gsub(/\[[0-9]+\]/, "", $i)   # retire [0], [1]...
                gsub(/\(F\)/,     "", $i)    # retire le flag faulty
                gsub(/\(S\)/,     "", $i)    # retire le flag spare
                print $i
            }
        }
    ' /proc/mdstat
}

# Vrai si l'array n'est pas dans un état clean/active.
array_is_degraded() {
    local md="$1"
    local state
    state=$(cat "/sys/block/$md/md/array_state" 2>/dev/null || echo unknown)

    case "$state" in
        clean|active) return 1 ;;
        *)            return 0 ;;
    esac
}

# Liste les devices marqués "faulty" dans l'array (sortie : "/dev/sda1", etc.).
list_faulty_devices_in_array() {
    local md="$1"
    mdadm --detail "/dev/$md" 2>/dev/null | awk '/faulty/ {print $NF}'
}

# Compteur de mismatchs entre les deux miroirs (devrait toujours être 0).
get_array_mismatch_count() {
    local md="$1"
    cat "/sys/block/$md/md/mismatch_cnt" 2>/dev/null || echo 0
}

# Vrai si la partition possède un superblock mdadm valide.
partition_has_md_superblock() {
    mdadm --examine "/dev/$1" >/dev/null 2>&1
}

# Détermine quelles partitions (sda<N> et sdb<N>) appartiennent à cet array.
# Stratégie :
#   1. on regarde un membre actuel pour en extraire le numéro N
#   2. fallback : on cherche par UUID d'array via mdadm --examine
expected_partitions_for_array() {
    local md="$1"
    local part_num=""

    # Étape 1 : déduire N depuis un membre actuel.
    local m
    for m in $(list_array_member_partitions "$md"); do
        if [[ "$m" =~ ^sd[ab]([0-9]+)$ ]]; then
            part_num="${BASH_REMATCH[1]}"
            break
        fi
    done

    # Étape 2 : si aucun membre n'est resté en place, on croise les UUIDs.
    if [[ -z "$part_num" ]]; then
        local array_uuid part_uuid p
        array_uuid=$(mdadm --detail "/dev/$md" 2>/dev/null \
            | awk -F: '/UUID/ {gsub(/ /,"",$2); print $2; exit}')

        for p in $(lsblk -ln -o NAME "$DISK_A" "$DISK_B" 2>/dev/null \
                    | grep -E '^sd[ab][0-9]+$'); do
            part_uuid=$(mdadm --examine "/dev/$p" 2>/dev/null \
                | awk -F: '/Array UUID/ {gsub(/ /,"",$2); print $2; exit}')

            if [[ -n "$array_uuid" && "$array_uuid" == "$part_uuid" ]]; then
                if [[ "$p" =~ ^sd[ab]([0-9]+)$ ]]; then
                    part_num="${BASH_REMATCH[1]}"
                    break
                fi
            fi
        done
    fi

    if [[ -n "$part_num" ]]; then
        echo "sda${part_num} sdb${part_num}"
    fi
}


# =============================================================================
# 6. RÉPARATION DES ARRAYS
# =============================================================================

# Sort les devices faulty de l'array (les laisser dedans empêche tout re-add).
remove_faulty_devices_from() {
    local md="$1"
    local dev
    for dev in $(list_faulty_devices_in_array "$md"); do
        warn "  $dev marqué faulty, retrait de /dev/$md"
        run mdadm --manage "/dev/$md" --remove "$dev" || true
    done
}

# (Ré)ajoute une partition à un array, en wipant le superblock s'il est KO.
readd_partition_to_array() {
    local md="$1"
    local part="$2"

    if ! partition_has_md_superblock "$part"; then
        warn "  Superblock mdadm absent/corrompu sur /dev/$part, on le réinitialise."
        run mdadm --zero-superblock --force "/dev/$part" || true
    fi

    log "  Ajout de /dev/$part dans /dev/$md"
    run mdadm --manage "/dev/$md" --add "/dev/$part"
}

# Pipeline complet de réparation d'un array : faulty, manquants, mismatch.
repair_single_array() {
    local md="$1"
    section "Réparation de /dev/$md"

    local state
    state=$(cat "/sys/block/$md/md/array_state" 2>/dev/null || echo unknown)
    log "  État actuel : $state"

    # 1. Retirer les devices faulty.
    remove_faulty_devices_from "$md"

    # 2. Identifier ce qui devrait être là vs ce qui y est.
    local expected current
    expected=$(expected_partitions_for_array "$md")
    current=$(list_array_member_partitions "$md")

    log "  Membres attendus : ${expected:-<inconnu>}"
    log "  Membres présents : ${current:-<aucun>}"

    if [[ -z "$expected" ]]; then
        warn "  Impossible de déterminer les partitions attendues, on passe."
        return 0
    fi

    # 3. Pour chaque partition manquante, on tente le re-add.
    local part
    for part in $expected; do
        if echo "$current" | grep -qw "$part"; then
            continue
        fi
        if [[ -b "/dev/$part" ]]; then
            readd_partition_to_array "$md" "$part"
        else
            err "  Partition /dev/$part attendue mais introuvable."
        fi
    done

    # 4. Mismatch entre miroirs ? On lance un repair.
    local mismatch
    mismatch=$(get_array_mismatch_count "$md")
    if (( mismatch > 0 )); then
        warn "  mismatch_cnt=$mismatch sur /dev/$md, lancement d'un repair."
        run bash -c "echo repair > /sys/block/$md/md/sync_action"
    fi
}

# Vrai si au moins un array a un problème détectable (dégradé ou mismatch).
any_array_needs_repair() {
    local md
    for md in $(list_active_md_arrays); do
        if array_is_degraded "$md"; then
            return 0
        fi
        if (( $(get_array_mismatch_count "$md") > 0 )); then
            return 0
        fi
    done
    return 1
}


# =============================================================================
# 7. PARSING DES ARGUMENTS
# =============================================================================

parse_arguments() {
    while (( $# > 0 )); do
        case "$1" in
            --dry-run) DRY_RUN=1; shift ;;
            --help|-h) usage; exit $EXIT_OK ;;
            *)         err "Argument inconnu : $1"
                       usage
                       exit $EXIT_USAGE ;;
        esac
    done
}


# =============================================================================
# 8. PIPELINE PRINCIPAL
# =============================================================================

main() {
    parse_arguments "$@"
    ensure_root
    ensure_tools_available
    acquire_lock

    section "Démarrage vérification RAID1 ($DISK_A + $DISK_B)"
    (( DRY_RUN )) && warn "Mode DRY-RUN : aucune écriture réelle."

    # --- Étape 1 : conditions de sortie immédiate ---
    check_both_disks_present      # sort si un disque manque
    check_disks_same_size         # sort si tailles différentes
    check_no_sync_in_progress     # sort si resync en cours

    # --- Étape 2 : réparation éventuelle des tables GPT ---
    check_and_repair_partition_tables

    # --- Étape 3 : si tout est sain, on s'arrête ici ---
    if ! any_array_needs_repair; then
        section "RAID sain, aucune action nécessaire."
        exit $EXIT_OK
    fi

    # --- Étape 4 : réparation de chaque array dégradé ---
    local md
    for md in $(list_active_md_arrays); do
        repair_single_array "$md"
    done

    # --- Étape 5 : état final pour le log ---
    section "État final"
    cat /proc/mdstat
}

main "$@"
