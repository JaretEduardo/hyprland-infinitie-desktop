# lib/profile.sh — read-only machine-profile detection and validation.
#
# A "profile" is a small declarative data file (profiles/<id>/profile.conf,
# plain "key=value" lines — no shell logic, never sourced/executed) that
# separates common workstation defaults from decisions specific to one real
# machine. This library only reads that data and cross-checks it against
# lib/hardware.sh; it never writes anything, never picks a profile by
# hostname, and never applies anything on its own — see install/cmd/profile.sh
# and docs/PROFILES.md.
#
# Sourced by install/common.sh consumers (profile, check, doctor, first-run).
# Depends on lib/hardware.sh already being sourced (for hw::gpus / hw::net /
# hw::cpu / hw::has_battery / hw::backlights).
#
# Run directly for a report:  bash lib/profile.sh [detect|current|validate]

[ -n "${_LIB_PROFILE_SH:-}" ] && return 0
_LIB_PROFILE_SH=1

# --- location ----------------------------------------------------------------

# profile::_dir -> the directory holding one subdirectory per profile.
# PROFILE_TEST_DIR is a TESTING-ONLY override (this command is read-only —
# pointing it at a fixture has no real-world effect either way).
profile::_dir() {
    if [ -n "${PROFILE_TEST_DIR:-}" ]; then
        printf '%s' "$PROFILE_TEST_DIR"
        return 0
    fi
    if [ -n "${INSTALL_REPO_DIR:-}" ]; then
        printf '%s/profiles' "$INSTALL_REPO_DIR"
    else
        printf '%s/profiles' "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    fi
}

# profile::_dmi <field> -> one /sys/class/dmi/id/<field> value, "" if
# unreadable. PROFILE_DMI_DIR is a TESTING-ONLY override, same reasoning as
# PROFILE_TEST_DIR above.
profile::_dmi() {
    local dir f v
    dir="${PROFILE_DMI_DIR:-/sys/class/dmi/id}"
    f="$dir/$1"
    [ -r "$f" ] || return 0
    IFS= read -r v < "$f" 2>/dev/null || true
    printf '%s' "$v"
}

# --- data loading (no shell evaluation of profile.conf, ever) ---------------

# profile::_read <id> -> raw "key=value" lines from profiles/<id>/profile.conf,
# comments and blank lines stripped. Never sources the file.
profile::_read() {
    local f; f="$(profile::_dir)/$1/profile.conf"
    [ -r "$f" ] || return 0
    grep -Ev '^[[:space:]]*(#|$)' "$f"
}

# profile::_field <block> <key> -> value of one "key=value" line, or ""
profile::_field() {
    awk -F= -v k="$2" 'index($0,k"=")==1{print substr($0,length(k)+2);exit}' <<<"${1:-}"
}

# profile::ids -> every profile id under profiles/ that has a profile.conf.
# "common" first if present, then the rest alphabetically.
profile::ids() {
    local d id
    d="$(profile::_dir)"
    [ -r "$d/common/profile.conf" ] && printf 'common\n'
    for id in "$d"/*/; do
        [ -e "$id" ] || continue
        id="${id%/}"; id="${id##*/}"
        [ "$id" = common ] && continue
        [ -r "$d/$id/profile.conf" ] && printf '%s\n' "$id"
    done
}

# --- matching ----------------------------------------------------------------

# profile::_matches <id> -> exit 0 iff every match.* field in this profile
# agrees with the real DMI data. A profile with zero match.* fields never
# matches here — that is precisely how "common" stays the fallback rather
# than a machine match. DMI only, never the hostname.
profile::_matches() {
    local id="$1" block matched_any=0 k v cur
    block="$(profile::_read "$id")"
    while IFS='=' read -r k v; do
        case "$k" in
            match.sys_vendor)      matched_any=1; cur="$(profile::_dmi sys_vendor)" ;;
            match.product_name)    matched_any=1; cur="$(profile::_dmi product_name)" ;;
            match.product_version) matched_any=1; cur="$(profile::_dmi product_version)" ;;
            match.product_family)  matched_any=1; cur="$(profile::_dmi product_family)" ;;
            match.board_name)      matched_any=1; cur="$(profile::_dmi board_name)" ;;
            match.*)                matched_any=1; cur="__unknown_match_field__" ;;
            *) continue ;;
        esac
        [ "$cur" = "$v" ] || return 1
    done <<<"$block"
    [ "$matched_any" = 1 ]
}

# profile::detect -> id of the first specific (non-common) profile whose
# match.* fields all agree with this real machine; "common" if none do.
profile::detect() {
    local id
    for id in $(profile::ids); do
        [ "$id" = common ] && continue
        profile::_matches "$id" && { printf '%s' "$id"; return 0; }
    done
    printf 'common'
}

# profile::current -> same as detect; kept as its own name so call sites read
# as "what profile applies here" rather than "run detection logic".
profile::current() { profile::detect; }

# profile::block [id] -> raw key=value block for a profile (default: detected)
profile::block() {
    profile::_read "${1:-$(profile::detect)}"
}

# profile::get <key> [id] -> one field's value (default profile: detected)
profile::get() {
    profile::_field "$(profile::_read "${2:-$(profile::detect)}")" "$1"
}

# --- hardware validation -----------------------------------------------------

# _profile::pci_present <block> <gpu|net> <VVVV:DDDD> -> exit 0 if that PCI
# vendor:device id is present anywhere in the given hw::gpus/hw::net block.
# Never assumes a fixed bus address or enumeration order.
_profile::pci_present() {
    local block="$1" kind="$2" exp="$3" ev ed
    ev=$(printf '%s' "${exp%%:*}" | tr 'A-Z' 'a-z')
    ed=$(printf '%s' "${exp##*:}" | tr 'A-Z' 'a-z')
    case "$kind" in
        gpu)
            awk -F. -v ev="$ev" -v ed="$ed" '
                /\.vendor_id=/ { split($0,a,"="); v=a[2]; sub(/^0[xX]/,"",v); V[$2]=tolower(v) }
                /\.device_id=/ { split($0,a,"="); d=a[2]; sub(/^0[xX]/,"",d); D[$2]=tolower(d) }
                END { for (k in V) if (V[k]==ev && D[k]==ed) { print "y"; exit } }
            ' <<<"$block" | grep -q y
            ;;
        net)
            local i addr f vid did
            for i in $(awk -F. '/^net\.[0-9]+\.bus=pci:/{print $2}' <<<"$block"); do
                addr=$(awk -F= -v k="net.$i.bus" 'index($0,k"=")==1{print substr($0,length(k)+2)}' <<<"$block")
                addr=${addr#pci:}
                f="/sys/bus/pci/devices/$addr"
                [ -r "$f/vendor" ] || continue
                vid=$(cat "$f/vendor" 2>/dev/null); vid=${vid#0x}; vid=$(printf '%s' "$vid" | tr 'A-Z' 'a-z')
                did=$(cat "$f/device" 2>/dev/null); did=${did#0x}; did=$(printf '%s' "$did" | tr 'A-Z' 'a-z')
                if [ "$vid" = "$ev" ] && [ "$did" = "$ed" ]; then
                    return 0
                fi
            done
            return 1
            ;;
    esac
}

# profile::validate [id] -> read-only hardware-expectation check, as
# "validate.N.item=...\nvalidate.N.status=ok|warn\n[validate.N.detail=...]"
# lines. A profile with no expect.* fields (e.g. common) yields nothing. A
# mismatch is reported as "warn" — never fatal, hardware legitimately varies.
profile::validate() {
    local id="${1:-$(profile::detect)}" block gblk nblk i=0 v label cur
    block="$(profile::_read "$id")"
    gblk="$(hw::gpus)"
    nblk="$(hw::net)"

    _profile::emit() {
        printf 'validate.%d.item=%s\n'   "$i" "$1"
        printf 'validate.%d.status=%s\n' "$i" "$2"
        if [ -n "${3:-}" ]; then
            printf 'validate.%d.detail=%s\n' "$i" "$3"
        fi
        i=$((i + 1))
    }

    v=$(profile::_field "$block" expect.cpu_vendor)
    if [ -n "$v" ]; then
        cur=$(profile::_field "$(hw::cpu)" cpu.vendor)
        if [ "$cur" = "$v" ]; then _profile::emit "CPU vendor ($v)" ok
        else _profile::emit "CPU vendor ($v)" warn "detected: ${cur:-unknown}"; fi
    fi

    v=$(profile::_field "$block" expect.igpu_pci)
    if [ -n "$v" ]; then
        label=$(profile::_field "$block" expect.igpu_desc); label="${label:-$v}"
        if _profile::pci_present "$gblk" gpu "$v"; then _profile::emit "$label" ok
        else _profile::emit "$label" warn "PCI $v not detected"; fi
    fi

    v=$(profile::_field "$block" expect.dgpu_pci)
    if [ -n "$v" ]; then
        label=$(profile::_field "$block" expect.dgpu_desc); label="${label:-$v}"
        if _profile::pci_present "$gblk" gpu "$v"; then _profile::emit "$label" ok
        else _profile::emit "$label" warn "PCI $v not detected"; fi
    fi

    v=$(profile::_field "$block" expect.wifi_pci)
    if [ -n "$v" ]; then
        label=$(profile::_field "$block" expect.wifi_desc); label="${label:-$v}"
        if _profile::pci_present "$nblk" net "$v"; then _profile::emit "$label" ok
        else _profile::emit "$label" warn "PCI $v not detected"; fi
    fi

    v=$(profile::_field "$block" expect.eth_pci)
    if [ -n "$v" ]; then
        label=$(profile::_field "$block" expect.eth_desc); label="${label:-$v}"
        if _profile::pci_present "$nblk" net "$v"; then _profile::emit "$label" ok
        else _profile::emit "$label" warn "PCI $v not detected"; fi
    fi

    v=$(profile::_field "$block" expect.battery)
    if [ "$v" = 1 ]; then
        if hw::has_battery; then _profile::emit "battery" ok
        else _profile::emit "battery" warn "no battery reported"; fi
    fi

    v=$(profile::_field "$block" expect.backlight)
    if [ "$v" = 1 ]; then
        if [ -n "$(hw::backlights)" ]; then _profile::emit "backlight" ok
        else _profile::emit "backlight" warn "no backlight device exposed"; fi
    fi

    return 0
}

# --- direct execution --------------------------------------------------------

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    if [ -z "${_LIB_HARDWARE_SH:-}" ]; then
        # shellcheck source=lib/hardware.sh
        . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/hardware.sh"
    fi
    case "${1:-detect}" in
        detect|current) profile::detect; echo ;;
        validate)       profile::validate "${2:-}" ;;
        ids)            profile::ids ;;
        *)
            printf 'usage: %s [detect|validate [id]|ids]\n' "$0" >&2
            exit 2 ;;
    esac
fi
