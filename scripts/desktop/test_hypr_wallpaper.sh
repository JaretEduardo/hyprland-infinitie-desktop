#!/usr/bin/env bash
#
# test_hypr_wallpaper.sh — wallpaper-driven theming pipeline check.
#
# Runs entirely under a throwaway $HOME so it never touches the real
# ~/.config or ~/.cache. Covers:
#   1. wallust templates are well-formed and render to valid targets
#      (JSON parses, Lua compiles, fuzzel --check-config passes)
#   2. `hypr-wallpaper --seed` populates every target
#   3. Quickshell loads its config against a generated palette
#   4. with 3 synthetic wallpapers (pink / blue / green): the palette
#      actually changes, the panel background stays dark, the foreground
#      stays readable   — only runs the wallust half if wallust is installed
#
# No root. No network. Exit 0 = pass.
set -u

REPO="$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)"
PASS=0 FAIL=0 SKIP=0
ok()   { printf '  \033[32mok\033[0m   %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
skip() { printf '  \033[33mskip\033[0m %s\n' "$*"; SKIP=$((SKIP+1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP"
export XDG_CONFIG_HOME="$TMP/.config"
export XDG_CACHE_HOME="$TMP/.cache"
mkdir -p "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME"

# deploy the wallust config + templates the way install.sh dotfiles would
mkdir -p "$XDG_CONFIG_HOME/wallust/templates"
cp "$REPO/config/wallust/wallust.toml" "$XDG_CONFIG_HOME/wallust/"
cp "$REPO"/config/wallust/templates/* "$XDG_CONFIG_HOME/wallust/templates/"

SEED_JSON="$REPO/config/wallust/fallback/colors.json"

# --- 1. templates render to valid targets (stub filters ~ wallust) --------
echo "templates render to valid output"
render() {  # render <template> with a fake palette -> stdout
    python3 - "$1" <<'PY'
import sys, re
tpl = open(sys.argv[1]).read()
pal = {f"color{i}": f"#{(30+i*11)%256:02x}{(80+i*7)%256:02x}{(120+i*5)%256:02x}" for i in range(16)}
pal.update(background="#221820", foreground="#f0e6ee", cursor="#f0e6ee")
def filt(val, name, arg=None):
    v = val.lstrip("#")
    r,g,b = (int(v[0:2],16), int(v[2:4],16), int(v[4:6],16))
    if name in ("lighten","saturate"):
        f = float(arg); r,g,b = (min(255,int(c+(255-c)*f)) for c in (r,g,b))
    elif name == "darken":
        f = float(arg); r,g,b = (int(c*(1-f)) for c in (r,g,b))
    hexv = f"{r:02x}{g:02x}{b:02x}"
    return hexv if name == "strip" else "#"+hexv
def expand(expr):
    parts = [p.strip() for p in expr.split("|")]
    cur = pal.get(parts[0], parts[0].strip('"'))
    for p in parts[1:]:
        m = re.match(r'(\w+)(?:\(([^)]*)\))?', p)
        cur = filt(cur, m.group(1), m.group(2))
    return cur
out = re.sub(r'\{\{\s*(.*?)\s*\}\}', lambda m: expand(m.group(1)), tpl)
sys.stdout.write(out)
PY
}

T="$XDG_CONFIG_HOME/wallust/templates"
render "$T/quickshell-colors.json" > "$TMP/q.json" 2>"$TMP/err" \
    && python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$TMP/q.json" \
    && ok "quickshell-colors.json -> valid JSON" || { bad "quickshell-colors.json render"; cat "$TMP/err"; }

render "$T/hyprland-colors.lua" > "$TMP/h.lua" 2>"$TMP/err" \
    && luac -p "$TMP/h.lua" && ok "hyprland-colors.lua -> compiles" || { bad "hyprland-colors.lua render"; cat "$TMP/err"; }

for f in mako-colors.local fuzzel-colors.local.ini hyprlock-colors.local.conf; do
    render "$T/$f" > "$TMP/$f" 2>"$TMP/err" \
        && grep -q '#\|rgba\|[0-9a-f]\{6\}' "$TMP/$f" && ok "$f -> renders colour values" \
        || { bad "$f render"; cat "$TMP/err"; }
done

# --- 2. hypr-wallpaper --seed populates every target ---------------------
echo "hypr-wallpaper --seed"
if "$REPO/scripts/desktop/hypr-wallpaper" --seed >/dev/null 2>&1; then
    for f in "$XDG_CACHE_HOME/hyprland-infinitie-desktop/colors.json" \
             "$XDG_CONFIG_HOME/hypr/colors.local.lua" \
             "$XDG_CONFIG_HOME/mako/colors.local" \
             "$XDG_CONFIG_HOME/fuzzel/colors.local.ini" \
             "$XDG_CONFIG_HOME/hypr/hyprlock-colors.local.conf"; do
        [ -s "$f" ] && ok "seeded ${f#$TMP/}" || bad "not seeded: ${f#$TMP/}"
    done
    luac -p "$XDG_CONFIG_HOME/hypr/colors.local.lua" && ok "seeded colors.local.lua compiles" || bad "seeded colors.local.lua"
    python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$XDG_CACHE_HOME/hyprland-infinitie-desktop/colors.json" \
        && ok "seeded colors.json parses" || bad "seeded colors.json"
else
    bad "hypr-wallpaper --seed exited non-zero"
fi

# --- 3. fuzzel accepts the generated colours ---------------------------
echo "consumers accept generated colours"
if command -v fuzzel >/dev/null 2>&1; then
    mkdir -p "$XDG_CONFIG_HOME/fuzzel"
    cp "$REPO/config/fuzzel/fuzzel.ini" "$XDG_CONFIG_HOME/fuzzel/fuzzel.ini"
    if fuzzel --check-config >/dev/null 2>&1; then ok "fuzzel --check-config (with include)"; else bad "fuzzel --check-config"; fi
else
    skip "fuzzel not installed"
fi

# --- 4. Quickshell loads against a generated palette ------------------
echo "Quickshell loads"
if command -v qs >/dev/null 2>&1; then
    log="$TMP/qs.log"
    timeout 8 qs -p "$REPO/config/quickshell" -v >"$log" 2>&1
    if grep -q "Configuration Loaded" "$log" && ! grep -qiE "caused by|is not a type|non-existent|Row will not function" "$log"; then
        ok "qs: Configuration Loaded, no QML errors"
    else
        bad "qs load"; grep -iE "error|caused by|warn" "$log" | grep -v heldHiddenChanged | head
    fi
else
    skip "qs not installed"
fi

# --- 5. synthetic pink / blue / green wallpapers ----------------------
echo "3 synthetic wallpapers change the palette"
gen_img() {  # gen_img <name> <r> <g> <b>
    python3 - "$1" "$2" "$3" "$4" <<'PY'
import sys
from PIL import Image
name, r, g, b = sys.argv[1], *map(int, sys.argv[2:5])
im = Image.new("RGB", (320, 200))
px = im.load()
for y in range(200):
    for x in range(320):
        t = x / 320
        px[x, y] = (int(r*(0.35+0.65*t)), int(g*(0.35+0.65*t)), int(b*(0.35+0.65*t)))
for i in range(40):  # a few darker + lighter blobs so wallust has range
    im.paste((r//4, g//4, b//4), (i*7, i*3, i*7+30, i*3+30))
im.save(name)
PY
}
IMGDIR="$TMP/img"; mkdir -p "$IMGDIR"
gen_img "$IMGDIR/pink.png"  230 90  170
gen_img "$IMGDIR/blue.png"  70  120 230
gen_img "$IMGDIR/green.png" 80  200 110
[ -s "$IMGDIR/pink.png" ] && ok "generated 3 synthetic wallpapers" || bad "image generation"

luminance() {  # luminance <#rrggbb>  -> 0..255 (approx, integer)
    python3 -c "v='$1'.lstrip('#'); r,g,b=int(v[0:2],16),int(v[2:4],16),int(v[4:6],16); print(int(0.299*r+0.587*g+0.114*b))"
}
json_get() { python3 -c "import json,sys; print(json.load(open('$1'))['$2'])"; }

# If real wallust is not here, drop in a minimal stand-in so the FULL pipeline
# (hypr-wallpaper -> wallust -> templates -> targets -> consumers) is still
# exercised. The stand-in extracts a palette with PIL and renders the repo's
# own templates; it is NOT wallust, but it proves the plumbing + the token
# mapping + the contrast rules.
if ! command -v wallust >/dev/null 2>&1; then
    mkdir -p "$TMP/bin"
    cat > "$TMP/bin/wallust" <<PYEOF
#!/usr/bin/env python3
import sys, os, re, tomllib
if len(sys.argv) >= 2 and sys.argv[1] == "--version":
    print("wallust 0.0.0-test-stub"); sys.exit(0)
img = sys.argv[-1]
from PIL import Image
im = Image.open(img).convert("RGB").resize((160,100))
q = im.quantize(colors=16, method=Image.Quantize.FASTOCTREE).convert("RGB")
cols = sorted({q.getpixel((x,y)) for x in range(0,160,4) for y in range(0,100,4)},
              key=lambda c: 0.299*c[0]+0.587*c[1]+0.114*c[2])
def hx(c): return "#%02x%02x%02x" % c
bg = hx(tuple(int(v*0.5) for v in cols[0]))
fg = hx(tuple(min(255,int(v*1.1)) for v in cols[-1]))
# mid, saturated colours for the accent slots
mids = sorted(cols, key=lambda c: max(c)-min(c), reverse=True)[:6]
pal = {"background": bg, "foreground": fg, "cursor": fg}
for i,c in enumerate(mids): pal["color%d"%(i+1)] = hx(c)
for i in range(len(mids)+1, 16): pal["color%d"%i] = hx(cols[min(i,len(cols)-1)])
pal["color0"] = bg
def f(val, name, arg=None):
    v = val.lstrip("#"); r,g,b = int(v[0:2],16),int(v[2:4],16),int(v[4:6],16)
    if name in ("lighten","saturate"):
        k=float(arg); r,g,b=(min(255,int(c+(255-c)*k)) for c in (r,g,b))
    elif name=="darken":
        k=float(arg); r,g,b=(int(c*(1-k)) for c in (r,g,b))
    h="%02x%02x%02x"%(r,g,b); return h if name=="strip" else "#"+h
def ex(e):
    p=[s.strip() for s in e.split("|")]; cur=pal.get(p[0], p[0].strip('"'))
    for s in p[1:]:
        m=re.match(r'(\w+)(?:\(([^)]*)\))?', s); cur=f(cur, m.group(1), m.group(2))
    return cur
conf = tomllib.load(open(os.path.expanduser("~/.config/wallust/wallust.toml"),"rb"))
tdir = os.path.expanduser("~/.config/wallust/templates")
for name, spec in conf.get("templates", {}).items():
    src = open(os.path.join(tdir, spec["template"])).read()
    out = re.sub(r'\{\{\s*(.*?)\s*\}\}', lambda m: ex(m.group(1)), src)
    tgt = os.path.expanduser(spec["target"])
    os.makedirs(os.path.dirname(tgt), exist_ok=True)
    open(tgt,"w").write(out)
PYEOF
    chmod +x "$TMP/bin/wallust"
    export PATH="$TMP/bin:$PATH"
    printf '  \033[33mnote\033[0m using a PIL-based wallust stand-in (real x11-misc/wallust not installed)\n'
fi

if command -v wallust >/dev/null 2>&1; then
    declare -A ACCENTS
    for c in pink blue green; do
        "$REPO/scripts/desktop/hypr-wallpaper" "$IMGDIR/$c.png" >/dev/null 2>&1 || bad "hypr-wallpaper $c"
        j="$XDG_CACHE_HOME/hyprland-infinitie-desktop/colors.json"
        bg="$(json_get "$j" background)"; fg="$(json_get "$j" foreground)"; ac="$(json_get "$j" accent)"
        ACCENTS[$c]="$ac"
        lb="$(luminance "$bg")"; lf="$(luminance "$fg")"
        [ "$lb" -lt 110 ] && ok "$c: panel background stays dark (L=$lb)" || bad "$c: background too light (L=$lb)"
        [ $((lf - lb)) -gt 80 ] && ok "$c: foreground readable (ΔL=$((lf-lb)))" || bad "$c: low fg/bg contrast (ΔL=$((lf-lb)))"
    done
    if [ "${ACCENTS[pink]}" != "${ACCENTS[blue]}" ] && [ "${ACCENTS[blue]}" != "${ACCENTS[green]}" ]; then
        ok "accent changes per wallpaper (${ACCENTS[pink]} / ${ACCENTS[blue]} / ${ACCENTS[green]})"
    else
        bad "accent did not change between wallpapers"
    fi
else
    bad "no wallust and the stand-in failed to install"
fi

echo
printf 'pass %d  fail %d  skip %d\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
