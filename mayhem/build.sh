#!/usr/bin/env bash
# mayhem/build.sh — build pbrt-v4 twice:
#   1) build-mayhem-test: upstream's normal build (Release) of pbrt_test + pbrt_exe, the
#      functional oracle that mayhem/test.sh runs. It also runs rgb2spec_opt to generate the
#      RGB->spectrum tables.
#   2) build-mayhem-fuzz: pbrt_lib and the vendored src/ext libraries compiled with
#      afl-clang-fast++ + $SANITIZER_FLAGS + $DEBUG_FLAGS, reusing the tables from (1)
#      (PBRT_USE_PREGENERATED_RGB_TO_SPECTRUM_TABLES), then one AFL file-input harness per
#      reader (mayhem/harnesses/pbrt_fuzz.cpp) linked against it -> /mayhem/pbrt_fuzz_<mode>
#      (image: one binary per extension, /mayhem/pbrt_fuzz_image_<ext>), plus upstream's own
#      cyhair2pbrt converter as /mayhem/pbrt_fuzz_cyhair.
# pbrt rejects bad input with ErrorExit() -> quick_exit(1), so the targets are AFL
# (fork per input) rather than libFuzzer; an AFL binary is its own reproducer.
# The submodules under src/ext come from the checkout (mayhem.yml checks out recursively).
set -euo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
: "${SRC:=/mayhem}"
cd "$SRC"

COMMON_CMAKE=(-G Ninja -DGLFW_BUILD_WAYLAND=OFF -DPBRT_BUILD_NATIVE_EXECUTABLE=OFF -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
  -DFETCHCONTENT_FULLY_DISCONNECTED=ON)

# 1) Test/oracle build, normal flags.
cmake -S . -B build-mayhem-test "${COMMON_CMAKE[@]}" -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS"
cmake --build build-mayhem-test -j"$MAYHEM_JOBS" --target pbrt_test pbrt_exe

# 2) Fuzz build: afl-clang-fast(++) by name, sanitizers on pbrt and its vendored libs.
mkdir -p build-mayhem-fuzz
for t in srgb dci_p3 rec2020 aces; do
  cmp -s build-mayhem-test/rgbspectrum_$t.cpp build-mayhem-fuzz/rgbspectrum_$t.cpp ||
    cp build-mayhem-test/rgbspectrum_$t.cpp build-mayhem-fuzz/rgbspectrum_$t.cpp
done
FUZZ_FLAGS="-O1 $SANITIZER_FLAGS $DEBUG_FLAGS"
CC=afl-clang-fast CXX=afl-clang-fast++ AFL_QUIET=1 \
cmake -S . -B build-mayhem-fuzz "${COMMON_CMAKE[@]}" -DCMAKE_BUILD_TYPE=Fuzz \
      -DPBRT_USE_PREGENERATED_RGB_TO_SPECTRUM_TABLES=ON \
      -DCMAKE_C_FLAGS="$FUZZ_FLAGS" -DCMAKE_CXX_FLAGS="$FUZZ_FLAGS"
AFL_QUIET=1 cmake --build build-mayhem-fuzz -j"$MAYHEM_JOBS" --target pbrt_lib imgtool

# Compile flags of a pbrt_lib TU (includes + defines), reused for the harness.
CXXINC=$(python3 - build-mayhem-fuzz/compile_commands.json <<'PY'
import json, shlex, sys
for e in json.load(open(sys.argv[1])):
    if e["file"].endswith("src/pbrt/scene.cpp"):
        args = shlex.split(e["command"])
        keep, i = [], 0
        while i < len(args):
            a = args[i]
            if a in ("-isystem", "-I", "-D", "-include"):
                keep += [a, args[i + 1]]; i += 2; continue
            if a.startswith(("-I", "-D", "-std=", "-isystem")):
                keep.append(a)
            i += 1
        print(shlex.join(keep)); break
PY
)
LIBS=$(find build-mayhem-fuzz -name '*.a' | sort | tr '\n' ' ')
AFL_QUIET=1 afl-clang-fast++ $SANITIZER_FLAGS $DEBUG_FLAGS -c mayhem/lsan_off.cc -o build-mayhem-fuzz/lsan_off.o
LINK_LIBS="-Wl,--start-group $LIBS -Wl,--end-group \
    -lImath-3_1 -ldeflate -lz -lGL -lX11 -lXrandr -lXinerama -lXcursor -lXi -lpthread -ldl -lm"
build_harness() { # <output name> <extra flags...>
  local out=$1; shift
  eval "AFL_QUIET=1 afl-clang-fast++ -O1 $SANITIZER_FLAGS $DEBUG_FLAGS $CXXINC $* \
    mayhem/harnesses/pbrt_fuzz.cpp build-mayhem-fuzz/lsan_off.o $LINK_LIBS -o /mayhem/$out"
}
for mode in format scene ply spectrum bsdf; do
  build_harness "pbrt_fuzz_$mode" "-DPBRT_FUZZ_$(echo "$mode" | tr a-z A-Z)"
done
# Image::Read picks the decoder from the extension: one binary per format.
for ext in pfm hdr qoi png exr tga; do
  build_harness "pbrt_fuzz_image_$ext" "-DPBRT_FUZZ_IMAGE '-DPBRT_FUZZ_EXT=\".$ext\"'"
done
# cyhair2pbrt: upstream's own standalone converter (no pbrt_lib), built as is.
AFL_QUIET=1 afl-clang-fast++ -O1 $SANITIZER_FLAGS $DEBUG_FLAGS -std=c++17 \
  src/pbrt/cmd/cyhair2pbrt.cpp build-mayhem-fuzz/lsan_off.o -o /mayhem/pbrt_fuzz_cyhair
ls -l /mayhem/pbrt_fuzz_*
