#!/usr/bin/env bash
#
# mayhem/test.sh — RUN this repo's OWN functional test suite (already built by mayhem/build.sh).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

# EDIT: RUN the test runner that mayhem/build.sh produced, then map its output to counts.
#   ctest:        (cd build-tests && ctest) ; parse "<P> tests passed, <F> failed out of <T>"
#   gtest binary: ./build-tests/<prog> ; parse "[==========] N ... ran." / "[  PASSED  ] P" / "[ SKIPPED ] S"
#   make/minunit: ./out/<runner> ; parse its pass/fail/total
# Do NOT compile here — if the runner is absent, fail (build.sh should have produced it).

# Runs upstream's gtest suite (pbrt_test, built by build.sh with normal flags) over the
# parser, image I/O, colour/spectrum and file tests, plus a known-answer check of
# `pbrt --upgrade --format` on a fixed scene.
TB="$SRC/build-mayhem-test"
[ -x "$TB/pbrt_test" ] && [ -x "$TB/pbrt" ] || { echo "test binaries missing — run mayhem/build.sh" >&2; emit_ctrf "gtest" 0 1; exit 1; }
WD=$(mktemp -d); trap 'rm -rf "$WD"' EXIT
cd "$WD"
passed=0; failed=0
"$TB/pbrt_test" --gtest_filter='Parser.*:Image.*:ImageIO.*:Spectrum.*:RGB*.*:sRGB.*:File.*' > gtest.log 2>&1
cat gtest.log | tail -n 30
gp=$(sed -nE 's/^\[  PASSED  \] ([0-9]+) tests?.*/\1/p' gtest.log | tail -1)
gf=$(sed -nE 's/^\[  FAILED  \] ([0-9]+) tests?, listed below.*/\1/p' gtest.log | tail -1)
passed=$((passed + ${gp:-0})); failed=$((failed + ${gf:-0}))
[ -n "$gp" ] || failed=$((failed + 1))   # suite did not report: count as a failure

# Known answer: the formatter must reproduce the directives and normalise numbers.
cat > scene.pbrt <<'SCENE'
LookAt 0 0 5  0 0 0   0 1 0
Camera "perspective" "float fov" [ 45 ]
Film "rgb" "integer xresolution" 16 "integer yresolution" [16] "string filename" "out.exr"
WorldBegin
LightSource "point" "rgb I" [ 1 0.5 0.25 ]
Material "diffuse" "rgb reflectance" [0.5 0.5 0.5]
Shape "sphere" "float radius" 2.5
SCENE
"$TB/pbrt" --upgrade --format scene.pbrt > formatted.txt 2>&1 || true
cat formatted.txt
if grep -q '^Camera "perspective"' formatted.txt && grep -q '"float fov" \[ 45 \]' formatted.txt \
   && grep -q '"integer xresolution" \[ 16 \]' formatted.txt \
   && grep -q 'Shape "sphere"' formatted.txt && grep -q '"float radius" \[ 2.5 \]' formatted.txt \
   && grep -q '^WorldBegin' formatted.txt; then
  passed=$((passed + 1)); echo "PASS pbrt --format known answer"
else
  failed=$((failed + 1)); echo "FAIL pbrt --format known answer"
fi
cd "$SRC"
emit_ctrf "gtest" "$passed" "$failed"
