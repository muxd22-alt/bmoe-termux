#!/usr/bin/env bash
# build.sh - native Termux build of the BigMoeOnEdge engine.
#
# No proot, no container, no cross-compiler: clang from Termux builds the
# engine and llama.cpp right here, on this phone, for this phone.
#
#   bash build.sh            build (detached logs in $AI_ROOT/logs/build.log)
#   BUILD_JOBS=2 bash build.sh
set -uo pipefail

AI_ROOT="${AI_ROOT:-$HOME/ai}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UPSTREAM="${BMOE_UPSTREAM:-$HERE/upstream}"
BUILD_DIR="${BMOE_BUILD_DIR:-$AI_ROOT/build}"
UPSTREAM_URL="${BMOE_UPSTREAM_URL:-https://github.com/Helldez/BigMoeOnEdge.git}"
PINNED_COMMIT="${BMOE_PINNED_COMMIT:-}"

say() { printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*"; }
die() { say "FATAL: $*"; exit 1; }

mkdir -p "$AI_ROOT/logs" "$BUILD_DIR"

# --- 1. toolchain ------------------------------------------------------------
missing=""
for t in cmake make clang git; do
  command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
done
[ -z "$missing" ] || die "missing build tools:$missing  -> pkg install cmake make clang git"

# --- 2. source ---------------------------------------------------------------
if [ ! -f "$UPSTREAM/CMakeLists.txt" ]; then
  say "cloning upstream into $UPSTREAM"
  rm -rf "$UPSTREAM"
  git clone --depth 1 --recurse-submodules --shallow-submodules --jobs 4 "$UPSTREAM_URL" "$UPSTREAM" \
    || die "clone failed"
fi
if [ ! -f "$UPSTREAM/third_party/llama.cpp/CMakeLists.txt" ]; then
  say "fetching the llama.cpp submodule"
  git -C "$UPSTREAM" submodule update --init --recursive --depth 1 \
    || die "submodule fetch failed"
fi
if [ -n "$PINNED_COMMIT" ]; then
  git -C "$UPSTREAM" fetch --depth 1 origin "$PINNED_COMMIT" 2>/dev/null \
    && git -C "$UPSTREAM" checkout -q "$PINNED_COMMIT" \
    || say "warning: could not pin $PINNED_COMMIT, staying on $UPSTREAM"
fi
say "upstream: $(git -C "$UPSTREAM" rev-parse --short HEAD 2>/dev/null || echo unknown)"

# --- 3. flags ----------------------------------------------------------------
# The phone is arm64. Tune for the CPU it actually has: test the flags, and
# fall back to the portable baseline when the silicon refuses them.
ARCH_FLAGS="-march=armv8.2-a+crc+fp16+dotprod"
TMPD="$(mktemp -d)"
printf 'int main(void){return 0;}\n' > "$TMPD/t.c"
if ! clang $ARCH_FLAGS -c "$TMPD/t.c" -o "$TMPD/t.o" 2>/dev/null; then
  say "this cpu does not take $ARCH_FLAGS - using the portable baseline"
  ARCH_FLAGS=""
fi
rm -rf "$TMPD"

# OpenMP makes the decode use every core; it needs libomp, which Termux
# installs as its own package. Without it the build uses plain threads.
OMP=OFF
if [ -f "$PREFIX/include/omp.h" ] || [ -f "/data/data/com.termux/files/usr/include/omp.h" ]; then
  OMP=ON
else
  say "libomp not found - install it for faster decode: pkg install libomp"
fi

# One CPU library, not one per instruction-set tier: on a phone the extra
# variants cost an hour of compile for a few percent of decode.
VARIANTS=OFF

# Jobs: the phone has few cores and less free memory than the build wants.
# Two is the sweet spot; the number of jobs is what makes the build die.
if [ -z "${BUILD_JOBS:-}" ]; then
  nproc="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)"
  avail_mb="$(awk '/^Mem:/{print $7}' /proc/meminfo 2>/dev/null || echo 2000)"
  jobs=$(( avail_mb / 1600 ))
  [ "$jobs" -lt 1 ] && jobs=1
  [ "$jobs" -gt "$nproc" ] && jobs="$nproc"
  BUILD_JOBS="$jobs"
fi
say "building with $BUILD_JOBS job(s), OpenMP=$OMP, arch='${ARCH_FLAGS:-baseline}'"

CMAKE_FLAGS=(
  -DCMAKE_BUILD_TYPE=Release
  -DBMOE_BUILD_TESTS=OFF
  -DBMOE_BUILD_TOOLS=OFF
  -DGGML_OPENMP="$OMP"
  -DGGML_CPU_ALL_VARIANTS="$VARIANTS"
)
if [ -n "$ARCH_FLAGS" ]; then
  CMAKE_FLAGS+=(-DCMAKE_C_FLAGS="$ARCH_FLAGS" -DCMAKE_CXX_FLAGS="$ARCH_FLAGS")
fi

# --- 4. configure ------------------------------------------------------------
say "configuring in $BUILD_DIR"
cmake -S "$UPSTREAM" -B "$BUILD_DIR" "${CMAKE_FLAGS[@]}" || die "cmake configure failed"

# --- 5. build ----------------------------------------------------------------
say "compiling (this is the long part)"
cmake --build "$BUILD_DIR" -j "$BUILD_JOBS" || die "compile failed"

say "built:"
ls -l "$BUILD_DIR/bin/bmoe-server" "$BUILD_DIR/bin/bmoe-cli" 2>/dev/null
"$BUILD_DIR/bin/bmoe-server" --version 2>/dev/null | head -2
say "done - start it with: ai go"
