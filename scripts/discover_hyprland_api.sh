#!/usr/bin/env bash


set -uo pipefail

echo "== Version de Hyprland =="
hyprctl version | head -3
echo

echo "== Metodos disponibles en hl.dsp.window.* =="
hyprctl repl 'local t={} for k,v in pairs(hl.dsp.window) do table.insert(t,k) end table.sort(t) return table.concat(t, ", ")'
echo "   (si no aparece 'resize' en esta lista, moveactive/resizewindowpixel"
echo "    puede que vivan en otro sub-namespace, o que 'move' haga ambas cosas)"
echo

ADDR=$(hyprctl activewindow -j 2>/dev/null | python3 -c 'import json,sys
try:
    print(json.load(sys.stdin)["address"])
except Exception:
    print("")' )

if [ -z "$ADDR" ]; then
    echo "No hay ventana activa detectada. Abri/enfoca una ventana flotante y corre de nuevo."
    exit 1
fi

echo "== Ventana activa: $ADDR =="
echo

echo "== Probando mover a (100, 100) con la sintaxis que usa hypr_ipc.py =="
OUT=$(hyprctl dispatch "hl.dsp.window.move({ window = \"address:$ADDR\", coords = { 100, 100 }, mode = \"exact\" })" 2>&1)
echo "$OUT"
if echo "$OUT" | grep -qi "error"; then
    echo
    echo "-> Fallo. Probá estas variantes a mano y fijate cual no da error:"
    echo "   hyprctl dispatch 'hl.dsp.window.move({ window = \"address:$ADDR\", x = 100, y = 100 })'"
    echo "   hyprctl dispatch 'hl.dsp.window.move({ window = \"address:$ADDR\", coords = {x=100, y=100} })'"
    echo "   hyprctl dispatch 'hl.dsp.window.move({ window = \"address:$ADDR\", position = {100, 100} })'"
else
    echo "-> OK. Revisá visualmente que la ventana se haya movido a (100,100)."
    echo "   Si NO se movió pero no dio error (esto pasó antes con resizewindowpixel"
    echo "   en versiones viejas), el campo se está aceptando pero ignorando: probá"
    echo "   las variantes de arriba igual."
fi
echo

echo "== Probando redimensionar a 800x600 =="
OUT=$(hyprctl dispatch "hl.dsp.window.resize({ window = \"address:$ADDR\", size = { 800, 600 }, mode = \"exact\" })" 2>&1)
echo "$OUT"
if echo "$OUT" | grep -qi "error"; then
    echo
    echo "-> Fallo. 'resize' puede no existir como dispatcher separado. Mirá la"
    echo "   lista de arriba (hl.dsp.window.*) y probá si 'move' acepta también"
    echo "   un campo 'size' en la misma llamada, ej.:"
    echo "   hyprctl dispatch 'hl.dsp.window.move({ window = \"address:$ADDR\", size = {800,600} })'"
else
    echo "-> OK. Revisá visualmente que la ventana ahora mida 800x600."
fi

echo
echo "== Cuando confirmes los nombres correctos, editá SOLO estas dos funciones"
echo "   en hypr_ipc.py: move_window_exact_lua() y resize_window_exact_lua()"
