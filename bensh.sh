#!/usr/bin/env bash
set -euo pipefail

OUT_DIR="portage_tachyon_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUT_DIR"/{traces,flamegraphs,heatmaps,summaries}

PYTHONPATH=/usr/lib/python3.14/site-packages 
uv run python -m profiling.sampling run --flamegraph -o results/seach_new_file.html \
  /usr/lib/python-exec/python3.14/emerge -pvuDN chrome

# 1. Locate the actual Python emerge script (not the C python-exec2 symlink at /usr/bin/emerge)
EMERGE_SCRIPT="$(find /usr/lib/python-exec -maxdepth 2 -type f -name emerge | sort -V | tail -n 1)"
if [[ -z "${EMERGE_SCRIPT}" || ! -f "${EMERGE_SCRIPT}" ]]; then
    echo "Error: Could not find Python emerge script under /usr/lib/python-exec/" >&2
    exit 1
fi

echo "==> Output directory : $OUT_DIR"
echo "==> Emerge script    : $EMERGE_SCRIPT"
echo "==> Python runtime   : $(uv run python -V)"

# 2. Capture environment, Portage config, and .pyc bytecode status
{
    echo "=== DATE ==="
    date -u
    echo -e "\n=== PYTHON ==="
    uv run python -VV
    echo -e "\n=== EMERGE VERSION ==="
    emerge --version || true
    echo -e "\n=== PORTAGE CONFIG (SYNC / FEATURES / BINHOST) ==="
    emerge --info 2>/dev/null | grep -E '^(PORTAGE_BINHOST|FEATURES|EMERGE_DEFAULT_OPTS|ACCEPT_KEYWORDS|PYTHON_TARGETS)' || true
    echo -e "\n=== BYTECODE CACHE CHECK ==="
    find /usr/lib/python*/site-packages/portage -name "*.cpython-315*.pyc" 2>/dev/null | head -n 5 || echo "No Python 3.15 .pyc files found"
} > "$OUT_DIR/env_info.txt"

# Helper: record binary trace once, then replay into Wall, CPU, GIL, Heatmap, and Text views
profile_workload() {
    local name="$1"
    local rate="$2"
    shift 2
    local bin_file="$OUT_DIR/traces/${name}.bin"

    echo "==> Profiling [$name] at $rate: $EMERGE_SCRIPT $*"
    local start_ts end_ts elapsed
    start_ts=$(date +%s.%N)

    uv run python -m profiling.sampling run \
        --binary \
        --native \
        -r "$rate" \
        -o "$bin_file" \
        "$EMERGE_SCRIPT" "$@" >/dev/null

    end_ts=$(date +%s.%N)
    elapsed=$(awk "BEGIN {printf \"%.3f\", $end_ts - $start_ts}")
    echo "$name: ${elapsed}s" >> "$OUT_DIR/timings.txt"

    # Replay into multiple analytical views from the exact same capture
    uv run python -m profiling.sampling replay --mode wall --flamegraph \
        -o "$OUT_DIR/flamegraphs/${name}_wall.html" "$bin_file" >/dev/null

    uv run python -m profiling.sampling replay --mode cpu --flamegraph \
        -o "$OUT_DIR/flamegraphs/${name}_cpu.html" "$bin_file" >/dev/null

    uv run python -m profiling.sampling replay --mode gil --flamegraph \
        -o "$OUT_DIR/flamegraphs/${name}_gil.html" "$bin_file" >/dev/null

    uv run python -m profiling.sampling replay --heatmap \
        -o "$OUT_DIR/heatmaps/${name}_heatmap" "$bin_file" >/dev/null

    # Plain-text top functions summary (wall + cpu)
    {
        echo "=== WALL-CLOCK TOP FUNCTIONS ($name - ${elapsed}s) ==="
        uv run python -m profiling.sampling replay --mode wall "$bin_file"
        echo -e "\n=== ON-CPU TOP FUNCTIONS ($name) ==="
        uv run python -m profiling.sampling replay --mode cpu "$bin_file"
    } > "$OUT_DIR/summaries/${name}_top.txt"
}

# 3. Run the 4 core Portage workload profiles (all read-only / pretend)
# Workload A: Pure Python startup, imports, and config parsing
profile_workload "01_startup_version" "2khz" --version

# Workload B: Read-only package tree search (warm cache)
profile_workload "02_search_firefox" "2khz" --color=n --search firefox

# Workload C: Single-package dependency resolution (fast reproducible micro-benchmark)
profile_workload "03_depgraph_single" "2khz" -pv --color=n dev-lang/python

# Workload D: Full @world dependency graph & USE/slot backtracking solver (heaviest CPU workload)
profile_workload "04_depgraph_world" "1khz" -pvuDN --color=n @world

# 4. Zero-code-change A/B test: Python 3.15 native Lazy Imports (-X lazy_imports=all)
echo "==> Running Python 3.15 lazy_imports=all A/B benchmark..."
{
    echo "=== LAZY IMPORTS EXPERIMENT (-X lazy_imports=all) ==="
    for cmd in "--version" "--color=n --search firefox"; do
        t0=$(date +%s.%N)
        # shellcheck disable=SC2086
        uv run python -X lazy_imports=all "$EMERGE_SCRIPT" $cmd >/dev/null
        t1=$(date +%s.%N)
        dt=$(awk "BEGIN {printf \"%.3f\", $t1 - $t0}")
        echo "lazy_imports=all [$cmd]: ${dt}s"
    done
} >> "$OUT_DIR/timings.txt"

# 5. Bundle everything into a single archive
ARCHIVE="${OUT_DIR}.tar.gz"
tar -czf "$ARCHIVE" "$OUT_DIR"

echo ""
echo "========================================================"
echo " Done! Summary of wall times:"
cat "$OUT_DIR/timings.txt"
echo "========================================================"
echo " Artifacts archived at: $ARCHIVE"
echo " - Plain-text summaries : $OUT_DIR/summaries/*.txt"
echo " - CPU vs Wall flames   : $OUT_DIR/flamegraphs/*_cpu.html"
echo " - Line-level heatmaps  : $OUT_DIR/heatmaps/"
