#!/usr/bin/env bash
# validate.sh — load-test guard for axRegistry
#
# For each .axreg in this repo, runs the axis binary with a trivial M1 probe
# source file and asserts exit 0 (the registry parses and loads cleanly).
#
# Required environment:
#   AXIS_LAB   — path to axis-lang (provides M1 surface configs)
#
# Optional environment:
#   AXIS_BIN   — path to axis binary (default: axis-lang/target/debug/axis)
#
# Example (from axis-lang root):
#   AXIS_LAB=. bash registry-pin/validate.sh

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -z "${AXIS_LAB:-}" ]]; then
    echo "ERROR: AXIS_LAB must point to axis-lang."
    echo "  Example: AXIS_LAB=/path/to/axis-lang bash validate.sh"
    exit 1
fi

AXIS_BIN="${AXIS_BIN:-$AXIS_LAB/target/debug/axis}"

if [[ ! -x "$AXIS_BIN" ]]; then
    echo "ERROR: axis binary not found or not executable at '$AXIS_BIN'."
    echo "  Build it with: cd \"$AXIS_LAB\" && cargo build"
    exit 1
fi

M1_LEXER="$AXIS_LAB/axis-surface-m1-config/m1-lexer.yaml"
M1_PARSER="$AXIS_LAB/axis-surface-m1-config/m1-parse.yaml"
M1_SCHEMA="$AXIS_LAB/axis-surface-m1-config/m1-ast.yaml"
M1_NORMALIZE="$AXIS_LAB/axis-surface-m1-config/m1-normalize.yaml"

for cfg in "$M1_LEXER" "$M1_PARSER" "$M1_SCHEMA" "$M1_NORMALIZE"; do
    if [[ ! -f "$cfg" ]]; then
        echo "ERROR: Surface config not found: $cfg"
        exit 1
    fi
done

# Trivial M1 probe: a single-arg identity function on Bool.
PROBE=$(mktemp /tmp/axis-validate-probe.XXXXXX.m1)
PROBE_OUT=$(mktemp /tmp/axis-validate-out.XXXXXX.coreir)
trap 'rm -f "$PROBE" "$PROBE_OUT"' EXIT
cat > "$PROBE" <<'M1'
fn identity(x: Bool) -> Bool {
  x
}
M1

ALL_PASS=true

# ─────────────────────────────────────────────────────────────────────────────
# THE CANONICAL SET
#
# There is no scripts/build.sh in this repo or in axis-lang, so
# this array is the machine-readable definition of the canonical --reg set.
# Consumers should read it from here rather than hardcoding a list.
#
# Order is irrelevant — the loader is flat and resolves the type graph
# order-independently — but it is listed types-first for readability.
# ─────────────────────────────────────────────────────────────────────────────
CANONICAL_SET=(
    "$REPO_DIR/axis-types.axreg"
    "$REPO_DIR/axis.axreg"
    "$REPO_DIR/axis-bridge.axreg"
    "$REPO_DIR/m1-builtins.axreg"
    "$REPO_DIR/gen-working.axreg"
)

# Files that are self-contained — they declare every type their own entries
# reference, so they load standalone. Everything else in the canonical set
# depends on axis-types.axreg for its type vocabulary and is only meaningful
# as part of the merged set.
SELF_CONTAINED=(
    "axis-types.axreg"
    "axis.axreg"
    "m1-builtins.axreg"
)

is_self_contained() {
    local n="$1"
    for s in "${SELF_CONTAINED[@]}"; do [[ "$s" == "$n" ]] && return 0; done
    return 1
}

# ── TEST 1: the canonical set loads with ZERO registry conflicts ─────────────
#
# THE RATCHET (AXREG_LAYERING_VALUE_OWNERSHIP_V1).
#
# This is the check whose absence let the ownership rule rot. The rule was
# written into README.md and asserted to be done, while axis.axreg and
# axis-bridge.axreg both went on declaring Unit/Bool/Int/Text/Value/Dec/
# ValueList/Fn — so the canonical set could not be loaded at all:
#
#   Registry conflict: duplicate type name 'Unit' —
#     declared in axis.axreg and axis-bridge.axreg
#
# Nothing tested the merged set, so nothing caught it. The per-file loop
# below cannot catch it either: a conflict only exists between files.
# Documentation is not a test.
echo "── canonical set ──"
reg_args=()
for f in "${CANONICAL_SET[@]}"; do
    if [[ ! -f "$f" ]]; then
        echo "FAIL  canonical set — missing member: $(basename "$f")"
        ALL_PASS=false
    fi
    reg_args+=(--reg "$f")
done

set +e
merged_out=$("$AXIS_BIN" \
    --file "$PROBE" \
    --lexer "$M1_LEXER" --parser "$M1_PARSER" \
    --schema "$M1_SCHEMA" --normalize "$M1_NORMALIZE" \
    "${reg_args[@]}" --out "$PROBE_OUT" 2>&1)
merged_rc=$?
set -e

if [[ $merged_rc -ne 0 ]]; then
    echo "FAIL  canonical set does not load"
    echo "      $(echo "$merged_out" | head -1)"
    ALL_PASS=false
elif grep -q "Registry conflict" <<<"$merged_out"; then
    echo "FAIL  canonical set has a registry conflict"
    echo "      $(grep 'Registry conflict' <<<"$merged_out" | head -1)"
    ALL_PASS=false
else
    echo "PASS  canonical set loads, zero conflicts (${#CANONICAL_SET[@]} files)"
fi

# ── TEST 2: axis-types.axreg owns the types and declares no fns ──────────────
#
# The split is the mechanism that keeps TEST 1 passing: one file owns every
# type name, so no two files can collide. If fns migrate into the types file
# the separation blurs and the next type added elsewhere silently re-collides.
types_file="$REPO_DIR/axis-types.axreg"
if [[ -f "$types_file" ]]; then
    stray_fns=$(grep -c '^fn ' "$types_file" || true)
    if [[ "$stray_fns" -ne 0 ]]; then
        echo "FAIL  axis-types.axreg declares $stray_fns fn(s) — it must declare types only"
        ALL_PASS=false
    else
        echo "PASS  axis-types.axreg declares types only (0 fns)"
    fi

    # No other canonical member may declare a type.
    for f in "${CANONICAL_SET[@]}"; do
        [[ "$f" == "$types_file" ]] && continue
        n=$(basename "$f")
        [[ -f "$f" ]] || continue
        stray_types=$(grep -c '^type ' "$f" || true)
        if [[ "$stray_types" -ne 0 ]]; then
            echo "FAIL  $n declares $stray_types type(s) — axis-types.axreg owns all types"
            ALL_PASS=false
        fi
    done
fi

# ── TEST 3: per-file load, for the files that are self-contained ─────────────
echo ""
echo "── individual registries ──"
shopt -s nullglob
for axreg in "$REPO_DIR"/*.axreg; do
    name=$(basename "$axreg")
    if ! is_self_contained "$name"; then
        echo "SKIP  $name (depends on axis-types.axreg; covered by the canonical-set test)"
        continue
    fi
    if "$AXIS_BIN" \
        --file "$PROBE" \
        --lexer "$M1_LEXER" \
        --parser "$M1_PARSER" \
        --schema "$M1_SCHEMA" \
        --normalize "$M1_NORMALIZE" \
        --reg "$axreg" \
        --out "$PROBE_OUT" \
        >/dev/null 2>&1; then
        echo "PASS  $name"
    else
        echo "FAIL  $name"
        ALL_PASS=false
    fi
done

# ── TEST 4: leaf facts are internally consistent ─────────────────────────────
#
# `effect pure` + `deterministic true` is load-bearing, not documentation. It
# is read by three gates: the compiler's hash-cons (CSE) gate, the bridge's
# EFFECT_ORDER_V1 sink, and the bridge's fault classification (a panic in a
# pure+deterministic leaf is a DEFECT, exit 4, never respawned). A leaf that
# claims it falsely gets merged with its twin, reordered past an effect, or
# turns a world failure into a program-bug kill. These rules catch the
# mechanical half of that. They cannot prove an impl pure, so each new pure
# leaf still needs its Rust body read.
#
#   R1  every leaf states effect, deterministic and idempotent. deterministic
#       silently defaults to false when absent, so an omission would pass as a
#       claim nobody made.
#   R2  pure => deterministic true. "No external state accessed" leaves nothing
#       for the result to depend on but the arguments.
#   R3  pure, no callback => idempotent true. idempotent means "safe to
#       re-execute" (Registry-WorkingDraft), and a pure leaf has nothing to
#       redo. A leaf WITH a callback is as retry-safe as its callback, which
#       the registry cannot know, so it is left to the author.
#   R4  a pure leaf may not carry a stateful family prefix. A new io_/fs_/tcp_/
#       cursor_/… leaf declared pure is almost certainly a copy-paste slip.
#
# R4_VERIFIED: pure leaves whose name matches a stateful prefix but whose Rust
# body was read and IS pure. Each entry says why; add one only after reading
# the impl.
R4_VERIFIED=(
    cursor_sort   # sorts its Text argument's lines; touches no cursor handle (runtime/cursor.rs cursor_sort)
)
echo ""
echo "── leaf facts ──"
facts_out=$(awk -v verified=" ${R4_VERIFIED[*]} " '
    function flush() {
        if (name == "" || kind != "leaf") return
        if (eff == "" || det == "" || idem == "") {
            printf "R1  %s (%s:%d): missing %s%s%s\n", name, FILENAME, line, \
                (eff == "" ? "effect " : ""), (det == "" ? "deterministic " : ""), (idem == "" ? "idempotent" : "")
            return
        }
        if (eff == "pure" && det != "true")
            printf "R2  %s (%s:%d): effect pure but deterministic %s\n", name, FILENAME, line, det
        if (eff == "pure" && cb == 0 && idem != "true")
            printf "R3  %s (%s:%d): effect pure, no callback, but idempotent %s\n", name, FILENAME, line, idem
        if (eff == "pure" && index(verified, " " name " ") == 0 && name ~ /^(io_|fs_|tcp_|pty_|tty_|proc_|cursor_|mmapseg_|logbuf_|hotblk_|hotmem_|slab_|wal|pg_|mem_|cell_|set_|map_|u32v_|qhm_|bindidx_|contentidx_|fieldidx_|pkidx_|oneshot_|bchan_|channel_|argv|now_|sleep)/)
            printf "R4  %s (%s:%d): stateful-family name declared pure\n", name, FILENAME, line
    }
    FNR == 1 { flush(); name = "" }
    /^fn /   { flush(); name = $2; line = FNR; kind = eff = det = idem = ""; cb = 0; next }
    /^end/   { flush(); name = ""; next }
    name != "" && $1 == "kind"          { kind = $2 }
    name != "" && $1 == "effect"        { eff  = $2 }
    name != "" && $1 == "deterministic" { det  = $2 }
    name != "" && $1 == "idempotent"    { idem = $2 }
    name != "" && $1 == "callback"      { cb++ }
    END { flush() }
' "${CANONICAL_SET[@]}")
if [[ -n "$facts_out" ]]; then
    echo "FAIL  $(wc -l <<<"$facts_out") inconsistent leaf fact(s):"
    sed 's|^|      |; s|'"$REPO_DIR"'/||' <<<"$facts_out"
    ALL_PASS=false
else
    echo "PASS  leaf facts consistent (R1 explicit, R2 pure=>det, R3 pure=>idempotent, R4 no stateful pure)"
fi

echo ""
if $ALL_PASS; then
    echo "All registries valid."
    exit 0
else
    echo "One or more registries failed to load."
    exit 1
fi
