#!/usr/bin/env bash
# =============================================================================
# PATCH-FPCHTTP-2 rev 2 — build + run the keepalive latency check on FPC.
#
# Builds Horse's own samples/lazarus/console server and the probe in this
# directory, runs three scenarios against it, and reports p50.
#
#   HORSE_SRC=/path/to/horse/src FPC=/path/to/fpc-trunk ./run-keepalive-test.sh
#
# Before the fix, scenario A's p50 is ~44 ms. After it, sub-millisecond.
# Exit code is non-zero if scenario A's p50 is still above the threshold.
# =============================================================================
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HORSE_SRC=${HORSE_SRC:-$(cd "$HERE/../../src" 2>/dev/null && pwd)}
HORSE_ROOT=${HORSE_ROOT:-$(cd "$HORSE_SRC/.." 2>/dev/null && pwd)}
SAMPLE=${SAMPLE:-$HORSE_ROOT/samples/lazarus/console/Console.lpr}
FPC=${FPC:-fpc}
PORT=${PORT:-9000}
# p50 above this (ms) means the stall is still present.
THRESHOLD_MS=${THRESHOLD_MS:-5}

# Separate build dirs. A .lpr compiled beside a stale Horse.ppu silently links
# the PREVIOUS build of the unit under test — the exact trap that made an
# earlier bench read as a disproof of the Nagle hypothesis.
WORK=$(mktemp -d)
SRVDIR="$WORK/srv"
PRBDIR="$WORK/prb"
mkdir -p "$SRVDIR" "$PRBDIR"

SRVPID=""
cleanup() {
  [[ -n "$SRVPID" ]] && kill "$SRVPID" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

echo "FPC       : $($FPC -iV 2>/dev/null || echo 'NOT FOUND')"
echo "Horse src : $HORSE_SRC"
echo "Sample    : $SAMPLE"

if ! command -v "$FPC" >/dev/null 2>&1; then
  echo "FAIL: fpc not on PATH. Set FPC=/path/to/fpc." >&2
  exit 1
fi

# The whole patched block is gated on FPC_FULLVERSION >= 30301. On an older
# compiler it is not merely untested — it is not compiled at all, so the run
# would report a pass that means nothing.
FPCVER=$($FPC -iV 2>/dev/null)
case "$FPCVER" in
  3.3.*|3.4.*|[4-9].*) ;;
  *)
    echo "FAIL: FPC $FPCVER is below 3.3.1." >&2
    echo "      Both keepalive and PATCH-FPCHTTP-2 are behind" >&2
    echo "      {\$IF FPC_FULLVERSION >= 30301} and would not be compiled in." >&2
    exit 1 ;;
esac

if [[ ! -f "$SAMPLE" ]]; then
  echo "FAIL: sample not found at $SAMPLE. Set SAMPLE=..." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Resolve the compiler's OWN unit tree.
#
# A trunk compiler installed beside a distro FPC still reads /etc/fpc.cfg,
# which points at the distro's units — the compiler then loads a .ppu built by
# the other version and dies with "PPU Invalid Version N expecting M". So skip
# the default config (-n) and pass the matching unit paths explicitly.
#
# Order: explicit config, then explicit unit dir, then derive from the
# compiler's own prefix. Honours the TRUNK_UNITS name already used elsewhere.
# ---------------------------------------------------------------------------
UNITFLAGS=()
FPC_PREFIX=$(cd "$(dirname "$FPC")/.." 2>/dev/null && pwd)
CPU=$($FPC -iTP 2>/dev/null)
TOS=$($FPC -iTO 2>/dev/null)

if [[ -n "${FPC_CFG:-}" ]]; then
  [[ -f "$FPC_CFG" ]] || { echo "FAIL: FPC_CFG=$FPC_CFG not found" >&2; exit 1; }
  UNITFLAGS=(-n "@$FPC_CFG")
  echo "Config    : $FPC_CFG (explicit)"
elif [[ -z "${TRUNK_UNITS:-}${FPC_UNITS:-}" ]] && \
     { OWNCFG=$(ls "$FPC_PREFIX/etc/fpc.cfg" \
                   "$FPC_PREFIX/lib/fpc/$FPCVER/etc/fpc.cfg" 2>/dev/null | head -1); \
       [[ -n "$OWNCFG" ]]; }; then
  # The trunk install ships its own config: prefer it. It carries the linker
  # and library paths that -n would otherwise discard.
  UNITFLAGS=(-n "@$OWNCFG")
  echo "Config    : $OWNCFG (compiler's own)"
else
  UNITS=${TRUNK_UNITS:-${FPC_UNITS:-}}
  if [[ -z "$UNITS" ]]; then
    for cand in \
      "$FPC_PREFIX/lib/fpc/$FPCVER/units/$CPU-$TOS" \
      "$FPC_PREFIX/units/$CPU-$TOS"; do
      [[ -d "$cand" ]] && { UNITS="$cand"; break; }
    done
  fi
  if [[ -z "$UNITS" || ! -d "$UNITS" ]]; then
    echo "FAIL: could not locate the unit tree for FPC $FPCVER ($CPU-$TOS)." >&2
    echo "      Tried:" >&2
    echo "        $FPC_PREFIX/lib/fpc/$FPCVER/units/$CPU-$TOS" >&2
    echo "        $FPC_PREFIX/units/$CPU-$TOS" >&2
    echo "      Set TRUNK_UNITS=/path/to/units/$CPU-$TOS, or FPC_CFG=/path/to/fpc.cfg." >&2
    exit 1
  fi
  if [[ ! -f "$UNITS/rtl/system.ppu" ]]; then
    echo "FAIL: $UNITS has no rtl/system.ppu — wrong unit tree." >&2
    exit 1
  fi
  # -Fu with a trailing /* adds every package subdirectory (rtl, fcl-web, ...).
  UNITFLAGS=(-n -Fu"$UNITS/*" -Fu"$UNITS")
  echo "Units     : $UNITS"
fi

# The guard this test exists to protect. Without the fix applied every scenario
# would be slow for the original reason and prove nothing about the patch.
if ! grep -q 'ApplyNoDelay' "$HORSE_SRC/Horse.Provider.FPC.HTTPApplication.pas" 2>/dev/null; then
  echo "FAIL: $HORSE_SRC/Horse.Provider.FPC.HTTPApplication.pas has no ApplyNoDelay." >&2
  echo "      This tree predates PATCH-FPCHTTP-2 rev 2 — copy the patch first." >&2
  exit 1
fi

# A server left over from a previous run keeps the port and the probe then
# measures the OLD binary — a pass or fail that says nothing about this build.
if (echo > "/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; then
  echo "FAIL: something is already listening on port $PORT." >&2
  echo "      Stop it first (pkill -f Console), or set PORT=... ." >&2
  exit 1
fi

echo
echo "── compiling ──────────────────────────────────────────────────────────"
# -B forces a full rebuild. A changed define does NOT invalidate a .ppu, and a
# cached one here would test the previous version of the unit under test.
# -dUseCThreads: the sample links cthreads only behind this define, and
# fphttpserver's keepalive is documented as threaded-server only.
if ! "$FPC" -MDelphi -B -O1 -dUseCThreads "${UNITFLAGS[@]}" \
      -Fu"$HORSE_SRC" \
      -FU"$SRVDIR" -FE"$SRVDIR" \
      "$SAMPLE" > "$WORK/srv-build.log" 2>&1; then
  echo "FAIL: server compilation failed"
  tail -30 "$WORK/srv-build.log" | sed 's/^/    | /'
  exit 1
fi
echo "  server compiled OK"

if ! "$FPC" -MDelphi -B -O1 "${UNITFLAGS[@]}" \
      -FU"$PRBDIR" -FE"$PRBDIR" \
      "$HERE/KeepAliveLatencyProbe.lpr" > "$WORK/prb-build.log" 2>&1; then
  echo "FAIL: probe compilation failed"
  tail -30 "$WORK/prb-build.log" | sed 's/^/    | /'
  exit 1
fi
echo "  probe compiled OK"

echo
echo "── running ────────────────────────────────────────────────────────────"
"$SRVDIR/Console" > "$WORK/srv.log" 2>&1 &
SRVPID=$!
sleep 1

if ! kill -0 "$SRVPID" 2>/dev/null; then
  echo "FAIL: server exited immediately"
  sed 's/^/    | /' "$WORK/srv.log"
  exit 1
fi

"$PRBDIR/KeepAliveLatencyProbe" 127.0.0.1 "$PORT" /ping 20 0 | tee "$WORK/probe.out"
RC=${PIPESTATUS[0]}

if [[ $RC -ne 0 ]]; then
  echo
  echo "FAIL: probe exited $RC"
  exit 1
fi

# Scenario A (sequential requests on one socket) is the one the fix targets.
# Match the DATA row, not the scenario banner — "── A 20 sequential ..." also
# contains the word and would win a bare grep, yielding an empty p50.
P50=$(grep -m1 -E '^[[:space:]]*sequential[[:space:]].*p50=' "$WORK/probe.out" \
      | sed -n 's/.*p50=\([0-9.]*\).*/\1/p')

echo
if [[ -z "$P50" ]]; then
  echo "RESULT: could not parse a sequential p50 from the probe output" >&2
  exit 1
fi

# awk, not bash — these are floating point.
if awk -v p="$P50" -v t="$THRESHOLD_MS" 'BEGIN{exit !(p<t)}'; then
  echo "RESULT: PASS — sequential p50 ${P50} ms (< ${THRESHOLD_MS} ms)"
  exit 0
else
  echo "RESULT: FAIL — sequential p50 ${P50} ms (>= ${THRESHOLD_MS} ms)"
  echo "        The Nagle stall is still present. Check that the server binary"
  echo "        was rebuilt (-B) from the patched source, and confirm with:"
  echo "          sudo -v && sudo tcpdump -i lo -n -ttt 'tcp port ${PORT}'"
  echo "        A ~40 ms gap before each 4-byte segment means TCP_NODELAY did"
  echo "        not take effect on the accepted socket."
  exit 1
fi
