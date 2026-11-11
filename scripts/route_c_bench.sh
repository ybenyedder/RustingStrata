#!/usr/bin/env bash
# Suite automatisée de benchmarks et de vérification d'exactitude — Projet "Route C" (Radeon 890M / gfx1150)
# Usage: ./scripts/route_c_bench.sh

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${REPO_DIR}/target/release/rustingstrata"
BLOB="${BLOB:-/var/lib/ollama/blobs/sha256-0dae47840f8115d894e74c5cd1a6aca27e01feaa4f07890a50bdcf7db4c56227}"
WORK_DIR="/tmp/opencode/wp7_suite"
mkdir -p "${WORK_DIR}"

echo "================================================================================"
echo " PROJET ROUTE C — SUITE D'EXACTITUDE & BENCHMARKS AUTOMATISÉS (gfx1150)"
echo " Date    : $(date -Is)"
echo " Binaire : ${BIN}"
echo " Modèle  : ${BLOB}"
echo "================================================================================"

# 0. Vérification d'exclusivité GPU (aucun service concurrent)
if systemctl --user is-active --quiet qwen-ngram 2>/dev/null; then
    echo "[!] Arrêt de qwen-ngram.service pour garantir l'exclusivité GPU..."
    systemctl --user stop qwen-ngram
fi
if systemctl --user is-active --quiet strata-route-c 2>/dev/null; then
    echo "[!] Arrêt temporaire de strata-route-c.service pendant le benchmark..."
    systemctl --user stop strata-route-c
    RESTART_ROUTE_C=1
else
    RESTART_ROUTE_C=0
fi

cleanup() {
    if [[ "${RESTART_ROUTE_C}" -eq 1 ]]; then
        systemctl --user start strata-route-c || true
    fi
}
trap cleanup EXIT

# Préparation des prompts de test reproductibles
python3 - "${WORK_DIR}" <<'PY'
import sys, pathlib
w = pathlib.Path(sys.argv[1])

novel_prompt = (
    "<|im_start|>user\n"
    "Write a detailed technical essay on the physics of extreme ultraviolet lithography (EUV), "
    "including laser-produced tin plasma, Mo/Si Bragg reflectors, stochastic photon shot noise, "
    "and high-NA anamorphic optics.<|im_end|>\n"
    "<|im_start|>assistant\n<think>\n\n</think>\n\n"
)
(w / "novel_prompt.txt").write_text(novel_prompt)

snippet = (
    "def process_batch(items, workers=4):\n"
    "    results = []\n"
    "    for chunk in chunks(items, workers):\n"
    "        for item in chunk:\n"
    "            if item is None: continue\n"
    "            try: results.append(transform(item))\n"
    "            except ValueError as e: log.warning('skip %s', e)\n"
)
raw_copy = snippet * 30
(w / "repro_raw.txt").write_text(raw_copy)

chat_copy = (
    "<|im_start|>user\n"
    "Reproduce the following Python block verbatim without any modification:\n\n"
    + raw_copy +
    "<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n"
)
(w / "repro_chat.txt").write_text(chat_copy)

turn1 = (
    "<|im_start|>system\nYou are an autonomous Rust/Vulkan systems engineering agent.<|im_end|>\n"
    "<|im_start|>user\nHere is the codebase context:\n"
    + raw_copy + "\n" + raw_copy +
    "\nSummarize the architecture of process_batch in 3 bullet points.<|im_end|>\n"
    "<|im_start|>assistant\n<think>\n\n</think>\n\n"
)
turn2 = (
    turn1 +
    "- Splits input items into chunks.\n"
    "- Skips None entries.\n"
    "- Logs ValueError warnings.\n"
    "<|im_end|>\n<|im_start|>user\n"
    "Reproduce the exact `def process_batch` implementation above verbatim for the test harness:\n"
    "<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n"
)
(w / "agentic_turn1.txt").write_text(turn1)
(w / "agentic_turn2.txt").write_text(turn2)
PY

echo ""
echo "--------------------------------------------------------------------------------"
echo " CLASSE 1 : TEXTE NEUF TECHNIQUE (128 tokens, greedy temp=0)"
echo "--------------------------------------------------------------------------------"
"${BIN}" generate --model "${BLOB}" --gpu --backend vulkan --ctx 4096 --kv f16 \
    -n 128 --temp 0 --seed 42 --spec-type none \
    --prompt - < "${WORK_DIR}/novel_prompt.txt" \
    > "${WORK_DIR}/novel_none.out" 2> "${WORK_DIR}/novel_none.err"
grep -E "prompt .* tok/s | gen .* tok/s|speculative|expert hit rate" "${WORK_DIR}/novel_none.err"

"${BIN}" generate --model "${BLOB}" --gpu --backend vulkan --ctx 4096 --kv f16 \
    -n 128 --temp 0 --seed 42 --spec-type ngram-simple --spec-draft-n-max 16 \
    --prompt - < "${WORK_DIR}/novel_prompt.txt" \
    > "${WORK_DIR}/novel_ngram.out" 2> "${WORK_DIR}/novel_ngram.err"
grep -E "prompt .* tok/s | gen .* tok/s|speculative|expert hit rate" "${WORK_DIR}/novel_ngram.err"

echo ""
echo "--------------------------------------------------------------------------------"
echo " CLASSE 2 : COPIE / RÉÉCRITURE DE CODE (500 tokens, greedy temp=0)"
echo "--------------------------------------------------------------------------------"
"${BIN}" generate --model "${BLOB}" --gpu --backend vulkan --ctx 4096 --kv f16 \
    -n 500 --temp 0 --seed 42 --spec-type none \
    --prompt - < "${WORK_DIR}/repro_chat.txt" \
    > "${WORK_DIR}/copy_none.out" 2> "${WORK_DIR}/copy_none.err"
grep -E "prompt .* tok/s | gen .* tok/s|speculative|expert hit rate" "${WORK_DIR}/copy_none.err"

"${BIN}" generate --model "${BLOB}" --gpu --backend vulkan --ctx 4096 --kv f16 \
    -n 500 --temp 0 --seed 42 --spec-type ngram-simple --spec-draft-n-max 16 \
    --prompt - < "${WORK_DIR}/repro_chat.txt" \
    > "${WORK_DIR}/copy_ngram.out" 2> "${WORK_DIR}/copy_ngram.err"
grep -E "prompt .* tok/s | gen .* tok/s|speculative|expert hit rate" "${WORK_DIR}/copy_ngram.err"

"${BIN}" generate --model "${BLOB}" --gpu --backend vulkan --ctx 4096 --kv f16 \
    -n 500 --temp 0 --seed 42 --spec-type ngram-map-k --spec-draft-n-max 16 \
    --lookup-cache-static "${WORK_DIR}/repro_raw.txt" \
    --lookup-cache-dynamic "${WORK_DIR}/dyn_cache.bin" \
    --prompt - < "${WORK_DIR}/repro_raw.txt" \
    > "${WORK_DIR}/copy_mapk.out" 2> "${WORK_DIR}/copy_mapk.err"
grep -E "prompt .* tok/s | gen .* tok/s|speculative|expert hit rate" "${WORK_DIR}/copy_mapk.err"

echo ""
echo "--------------------------------------------------------------------------------"
echo " CLASSE 3 : SESSION AGENTIQUE MULTI-TOURS (Warm Start + Speculative Lookup)"
echo "--------------------------------------------------------------------------------"
rm -f "${WORK_DIR}/agentic.pcache"

echo "[Tour 1 - Cold Start : préfill complet ~3100 tokens + sauvegarde disque]"
"${BIN}" generate --model "${BLOB}" --gpu --backend vulkan --ctx 4096 --kv f16 \
    -n 64 --temp 0 --seed 42 --spec-type ngram-simple --spec-draft-n-max 16 \
    --prompt-cache "${WORK_DIR}/agentic.pcache" \
    --prompt - < "${WORK_DIR}/agentic_turn1.txt" \
    > "${WORK_DIR}/turn1_cold.out" 2> "${WORK_DIR}/turn1_cold.err"
grep -E "warm start|prompt .* tok/s | gen .* tok/s|speculative" "${WORK_DIR}/turn1_cold.err"

echo "[Tour 1 - Warm Start Reprise : chargement disque + préfill delta 1 token]"
"${BIN}" generate --model "${BLOB}" --gpu --backend vulkan --ctx 4096 --kv f16 \
    -n 64 --temp 0 --seed 42 --spec-type ngram-simple --spec-draft-n-max 16 \
    --prompt-cache "${WORK_DIR}/agentic.pcache" \
    --prompt - < "${WORK_DIR}/agentic_turn1.txt" \
    > "${WORK_DIR}/turn1_warm.out" 2> "${WORK_DIR}/turn1_warm.err"
grep -E "warm start|prompt .* tok/s | gen .* tok/s|speculative" "${WORK_DIR}/turn1_warm.err"

echo "[Tour 2 - Warm Start Multi-Tour : réutilisation préfixe Tour 1 + génération spéculative]"
"${BIN}" generate --model "${BLOB}" --gpu --backend vulkan --ctx 4096 --kv f16 \
    -n 256 --temp 0 --seed 42 --spec-type ngram-simple --spec-draft-n-max 16 \
    --prompt-cache "${WORK_DIR}/agentic.pcache" \
    --prompt - < "${WORK_DIR}/agentic_turn2.txt" \
    > "${WORK_DIR}/turn2_warm.out" 2> "${WORK_DIR}/turn2_warm.err"
grep -E "warm start|prompt .* tok/s | gen .* tok/s|speculative" "${WORK_DIR}/turn2_warm.err"

echo ""
echo "--------------------------------------------------------------------------------"
echo " RAPPORT D'EXACTITUDE GREEDY (Cible : >= 99.0% d'accord)"
echo "--------------------------------------------------------------------------------"
python3 - "${WORK_DIR}" <<'PY'
import sys, pathlib, difflib

w = pathlib.Path(sys.argv[1])
pairs = [
    ("Classe 1 : Texte neuf (none vs ngram-simple)", "novel_none.out", "novel_ngram.out"),
    ("Classe 2 : Copie/Réécriture (none vs ngram-simple)", "copy_none.out", "copy_ngram.out"),
    ("Classe 3 : Session Agentique (Cold Start vs Warm Start)", "turn1_cold.out", "turn1_warm.out"),
]
all_ok = True
for label, f1, f2 in pairs:
    s1 = (w / f1).read_text()
    s2 = (w / f2).read_text()
    ratio = difflib.SequenceMatcher(None, s1, s2).ratio() * 100.0
    exact = (s1 == s2)
    status = "PASS (100.0% bit-for-bit identical)" if exact else f"{'PASS' if ratio >= 99.0 else 'FAIL'} ({ratio:.2f}%)"
    print(f" - {label}: {status}")
    if ratio < 99.0:
        all_ok = False
if not all_ok:
    sys.exit(1)
PY
echo "================================================================================"
echo " SUITE TERMINÉE AVEC SUCCÈS"
echo "================================================================================"
