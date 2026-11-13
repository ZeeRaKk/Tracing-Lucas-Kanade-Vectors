# Usage : PASSWORD="..." luks_tpm /home /var ...
# Variable optionnelle : CRYPTTAB_OUT (défaut /tmp/crypttab.new)
luks_tpm() {
    local mnt dev fs name out="${CRYPTTAB_OUT:-/tmp/crypttab.new}"
    [ -n "${PASSWORD:-}" ] || { echo "PASSWORD non défini" >&2; return 1; }
    export PASSWORD   # lue par systemd-cryptenroll

    for mnt in "$@"; do
        dev=$(findmnt -no SOURCE "$mnt") || return 1
        fs=$(findmnt -no FSTYPE "$mnt")
        name=$(basename "$mnt")

        umount "$mnt" || return 1
        printf %s "$PASSWORD" | cryptsetup luksFormat --batch-mode --key-file=- "$dev" || return 1
        systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7 "$dev" || return 1
        printf %s "$PASSWORD" | cryptsetup open --key-file=- "$dev" "$name" || return 1
        mkfs."$fs" "/dev/mapper/$name" || return 1

        echo "$name UUID=$(blkid -s UUID -o value "$dev") none tpm2-device=auto" >> "$out"
    done
}