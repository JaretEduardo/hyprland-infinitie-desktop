#!/usr/bin/env bash
#
# im in love with-
#
set -euo pipefail

# Absolute path to the repository this script lives in, resolved from the
# script's own location (not the caller's working directory), so the installer
# works when run as ./install-... , /full/path/install-... or from any cwd.
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DEST="${HOME}/scripts"
HYPR_LUA="${HOME}/.config/hypr/hyprland.lua"
TMP_DIR="$(mktemp -d)"

C_RESET="\033[0m"; C_BOLD="\033[1m"; C_GREEN="\033[32m"; C_YELLOW="\033[33m"; C_RED="\033[31m"; C_CYAN="\033[36m"

log()  { echo -e "${C_CYAN}==>${C_RESET} $*"; }
ok()   { echo -e "${C_GREEN}[OK]${C_RESET} $*"; }
warn() { echo -e "${C_YELLOW}[WARNING]${C_RESET} $*"; }
err()  { echo -e "${C_RED}[ERROR]${C_RESET} $*" >&2; }

cleanup() { rm -rf "${TMP_DIR}"; }
trap cleanup EXIT

require_cmd() {
    command -v "$1" >/dev/null 2>&1
}

# sh1t over trash
install_packages() {
    log "Detecting distro and installing required packages (python, python-evdev, bash, jq)..."

    if [ -f /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        DISTRO_ID="${ID:-unknown}"
        DISTRO_LIKE="${ID_LIKE:-}"
    else
        DISTRO_ID="unknown"
        DISTRO_LIKE=""
    fi

    if [[ "$DISTRO_ID" == "arch" || "$DISTRO_LIKE" == *arch* ]]; then
        sudo pacman -S --needed --noconfirm python python-evdev bash jq
    elif [[ "$DISTRO_ID" == "fedora" || "$DISTRO_LIKE" == *fedora* ]]; then
        sudo dnf install -y python python-evdev bash jq
    elif [[ "$DISTRO_ID" == "ubuntu" || "$DISTRO_ID" == "debian" || "$DISTRO_LIKE" == *debian* ]]; then
        sudo apt update
        sudo apt install -y python3 python3-evdev bash jq
    else
        warn "Could not automatically recognize your distro (ID=$DISTRO_ID)."
        warn "Please install manually: python3, python-evdev, bash, jq"
    fi
    ok "Packages installed (or already present)."
}


# 2. "input" group membership (required by python-evdev and a lot of things)

setup_input_group() {
    log "Adding your user (${USER}) to the 'input' group..."
    if groups "$USER" | grep -qw input; then
        ok "Your user already belongs to the 'input' group."
    else
        sudo usermod -aG input "$USER"
        warn "User added to the 'input' group. You must LOG OUT (or reboot) for this to take effect."
        NEED_RELOGIN=1
    fi
}


# 3. Copy the Infinite Desktop scripts from this repository checkout

install_scripts() {
    local src="${REPO_DIR}/scripts"

    if [ ! -d "${src}" ]; then
        err "Could not find the 'scripts' folder in this repository (${src})."
        err "This installer must be executed from a complete repository checkout."
        exit 1
    fi

    log "Installing scripts from ${src} into ${SCRIPTS_DEST} ..."
    mkdir -p "${SCRIPTS_DEST}"

    # Copy every .py and .sh script that lives directly in scripts/
    find "${src}" -maxdepth 1 -type f \( -name "*.py" -o -name "*.sh" \) -print0 |
        while IFS= read -r -d '' f; do
            cp -f "$f" "${SCRIPTS_DEST}/"
            ok "Copied: $(basename "$f")"
        done

    log "Applying execute permissions..."
    chmod +x \
        "${SCRIPTS_DEST}/floating_tile_toggle.py" \
        "${SCRIPTS_DEST}/move_window_tiled.py" \
        "${SCRIPTS_DEST}/navigate_windows.py" \
        "${SCRIPTS_DEST}/resize_window.py" \
        "${SCRIPTS_DEST}/move_window.py" \
        "${SCRIPTS_DEST}/infinite_desktop_core.py" \
        2>/dev/null || true

    # discover_hyprland_api.sh is an optional diagnostic utility from the repo
    [ -f "${SCRIPTS_DEST}/discover_hyprland_api.sh" ] && chmod +x "${SCRIPTS_DEST}/discover_hyprland_api.sh"

    ok "Scripts installed in ${SCRIPTS_DEST}"
}

# 4.  Now patch hyprland.lua (autostart + binds, with conflict reassignment)

patch_hyprland_config() {
    log "Updating ${HYPR_LUA} (autostart + keybinds)..."
    mkdir -p "$(dirname "${HYPR_LUA}")"

    # 'set -e' would abort the script before we can read $? on any non-zero
    # exit, including the expected code 3. Capture it in the same command list
    # instead, without disabling errexit globally.
    local STATUS=0
    python3 "${TMP_DIR}/patch_hyprland.py" "${HYPR_LUA}" "${SCRIPTS_DEST}" || STATUS=$?

    if [ "$STATUS" -eq 3 ]; then
        warn "hyprland.lua was not modified (already installed before)."
    elif [ "$STATUS" -ne 0 ]; then
        err "Failed to patch hyprland.lua"
        exit 1
    fi
}

write_patch_script() {
cat > "${TMP_DIR}/patch_hyprland.py" << 'PYEOF'
#!/usr/bin/env python3
import re, sys, os, datetime

HYPR_LUA = os.path.expanduser(sys.argv[1]) if len(sys.argv) > 1 else os.path.expanduser("~/.config/hypr/hyprland.lua")

MARK_START = "-- >>> hyprland-infinite-desktop-v2 (auto-installed) START"
MARK_END   = "-- <<< hyprland-infinite-desktop-v2 (auto-installed) END"

# Alternative key ladders to try on collision (in order of preference).
# For arrow keys, if SUPER+arrow is already taken, fall back to vim-style keys.
FALLBACK = {
    "Z": ["Z", "COMMA", "MINUS", "F13"],
    "X": ["X", "PERIOD", "EQUAL", "F14"],
    "D": ["D", "F", "G", "B"],
    "left": ["left", "H"],
    "right": ["right", "L"],
    "up": ["up", "K"],
    "down": ["down", "J"],
}

def norm_key(k):
    return k.strip().upper()

BINDS = []

def add(id_, mods, basekey, action_tpl, desc):
    BINDS.append({"id": id_, "mods": mods, "basekey": basekey, "action_tpl": action_tpl, "desc": desc})

add("ws_prev", ["MOD"], "Z", '{mod} .. " + {key}", hl.dsp.focus({{ workspace = "-1" }})', "Previous workspace")
add("ws_next", ["MOD"], "X", '{mod} .. " + {key}", hl.dsp.focus({{ workspace = "+1" }})', "Next workspace")
add("ws_prev_move", ["MOD", "SHIFT"], "Z", '{mod} .. " + SHIFT + {key}", hl.dsp.window.move({{ workspace = "-1" }})', "Move window to previous workspace")
add("ws_next_move", ["MOD", "SHIFT"], "X", '{mod} .. " + SHIFT + {key}", hl.dsp.window.move({{ workspace = "+1" }})', "Move window to next workspace")
add("toggle_floating_all", ["MOD"], "D", '{mod} .. " + {key}", hl.dsp.exec_cmd("python3 ~/scripts/floating_tile_toggle.py")', "Toggle floating/tiled (all windows)")

for d in ["left", "right", "up", "down"]:
    add(f"nav_{d}", ["MOD"], d, '{mod} .. " + {key}", hl.dsp.exec_cmd("python3 ~/scripts/navigate_windows.py ' + d + '")', f"Navigate window ({d})")
    add(f"movetiled_{d}", ["MOD", "ALT"], d, '{mod} .. " + ALT + {key}", hl.dsp.exec_cmd("python3 ~/scripts/move_window_tiled.py ' + d + '")', f"Move tiled window ({d})")
    add(f"movefloat_{d}", ["MOD", "SHIFT"], d, '{mod} .. " + SHIFT + {key}", hl.dsp.exec_cmd("python3 ~/scripts/move_window.py ' + d + '"), {{ repeating = true }}', f"Move floating window ({d})")
    add(f"resize_{d}", ["MOD", "CTRL"], d, '{mod} .. " + CTRL + {key}", hl.dsp.exec_cmd("python3 ~/scripts/resize_window.py ' + d + '"), {{ repeating = true }}', f"Resize window ({d})")

def read_file(path):
    if not os.path.exists(path):
        return ""
    with open(path, "r", encoding="utf-8") as f:
        return f.read()

def detect_mainmod(content):
    m = re.search(r'local\s+mainMod\s*=\s*"([A-Za-z0-9_ +]+)"', content)
    if m:
        return m.group(1).strip().upper()
    return "SUPER"

def first_call_arg(line, call_idx_end):
    depth = 0
    buf = []
    i = call_idx_end
    while i < len(line):
        c = line[i]
        if c in "([{":
            depth += 1
        elif c in ")]}":
            if depth == 0:
                break
            depth -= 1
        elif c == "," and depth == 0:
            break
        buf.append(c)
        i += 1
    return "".join(buf)

def extract_existing_signatures(content):
    """
    Normalized signature (frozenset of mods+key) for every existing
    hl.bind()/bind() call, using only its first argument (the key
    combination). Assumes one bind() call per line (the usual pattern
    in hyprland.lua).
    """
    mainmod = detect_mainmod(content)
    sigs = {}
    for line in content.splitlines():
        m = re.search(r'\bbind\(', line)
        if not m:
            continue
        arg = first_call_arg(line, m.end())
        if "mainMod" not in arg and '"' not in arg:
            continue
        literals = re.findall(r'"([^"]*)"', arg)
        if not literals:
            continue
        joined = " ".join(literals)
        tokens = re.split(r'\+', joined)
        tokens = [norm_key(t) for t in tokens if t.strip() != ""]
        if "mainMod" in arg:
            tokens = [mainmod] + tokens
        if not tokens:
            continue
        sigs[frozenset(tokens)] = line.strip()
    return sigs, mainmod

def build_signature(mods, key, mainmod):
    resolved = [mainmod if m == "MOD" else m for m in mods]
    return frozenset([norm_key(x) for x in resolved] + [norm_key(key)])

def resolve_binds(content):
    existing_sigs, mainmod = extract_existing_signatures(content)
    chosen = {}
    used_sigs = set(existing_sigs.keys())
    remapped_report = []

    for b in BINDS:
        candidates = FALLBACK.get(b["basekey"], [b["basekey"]])
        picked = None
        picked_mods = b["mods"]
        for cand in candidates:
            sig = build_signature(b["mods"], cand, mainmod)
            if sig not in used_sigs:
                picked = cand
                used_sigs.add(sig)
                break
        if picked is None:
            for extra in ["ALT", "SHIFT", "CTRL"]:
                cand = candidates[0]
                sig = build_signature(b["mods"] + [extra], cand, mainmod)
                if sig not in used_sigs:
                    picked = cand
                    picked_mods = b["mods"] + [extra]
                    used_sigs.add(sig)
                    break
        if picked is None:
            picked = candidates[0]
        if norm_key(picked) != norm_key(b["basekey"]) or picked_mods != b["mods"]:
            remapped_report.append((b["id"], b["basekey"], picked))
        chosen[b["id"]] = (picked_mods, picked)

    return chosen, mainmod, remapped_report

def render_lines(chosen, mainmod):
    lines = []
    final_desc = []
    for b in BINDS:
        mods, key = chosen[b["id"]]
        mod_literal = f'"{mainmod}"'
        line = "hl.bind(" + b["action_tpl"].format(mod=mod_literal, key=key) + ")"
        lines.append(line)
        combo_parts = [mainmod if m == "MOD" else m for m in mods]
        combo_parts.append(norm_key(key))
        final_desc.append((" + ".join(combo_parts), b["desc"]))
    return lines, final_desc

def main():
    content = read_file(HYPR_LUA)
    os.makedirs(os.path.dirname(HYPR_LUA), exist_ok=True)

    if MARK_START in content:
        print("WARNING: a block installed previously by this script already exists in hyprland.lua.")
        print("The file was not modified. Remove the block manually if you want to reinstall.")
        sys.exit(3)

    backup = HYPR_LUA + ".bak." + datetime.datetime.now().strftime("%Y%m%d%H%M%S")
    if content:
        with open(backup, "w", encoding="utf-8") as f:
            f.write(content)

    chosen, mainmod, remapped = resolve_binds(content)
    bind_lines, final_desc = render_lines(chosen, mainmod)

    autostart_block = (
        '    hl.on("hyprland.start", function()\n'
        '        hl.exec_cmd("python3 ~/scripts/infinite_desktop_core.py 1.6 > /tmp/infinite-desktop.log 2>&1")\n'
        '    end)'
    )

    block = []
    block.append("")
    block.append(MARK_START)
    block.append(f'-- mainMod detected/used: "{mainmod}"')
    block.append(autostart_block)
    block.append("")
    block.append("-- Infinite desktop keybinds")
    block.extend(bind_lines)
    block.append(MARK_END)
    block.append("")

    new_content = content.rstrip("\n") + "\n" + "\n".join(block) + "\n"
    with open(HYPR_LUA, "w", encoding="utf-8") as f:
        f.write(new_content)

    print(f"OK: hyprland.lua updated (backup at {backup})")
    print(f"mainMod detected: {mainmod}")
    print("")
    if remapped:
        print("The following keys were remapped due to conflicts with existing binds:")
        for id_, orig, new in remapped:
            print(f"  - {id_}: {orig} -> {new}")
        print("")
    print("=== New binds added by hyprland-infinite-desktop-v2 ===")
    for combo, desc in final_desc:
        print(f"  {combo:<28} -> {desc}")

if __name__ == "__main__":
    main()
PYEOF
}

# main

NEED_RELOGIN=0

echo -e "${C_BOLD}hyprland-infinite-desktop-v2 installer${C_RESET}"
echo "Source: ${REPO_DIR}"
echo ""

install_packages
setup_input_group
install_scripts
write_patch_script
patch_hyprland_config

echo ""
ok "Installation complete."
echo ""
echo "Remember:"
echo "  - Reload Hyprland (hyprctl reload) or restart your session to apply the binds."
if [ "${NEED_RELOGIN:-0}" -eq 1 ]; then
    warn "  - You must log out / reboot for the 'input' group membership to take effect (required by python-evdev)."
fi
