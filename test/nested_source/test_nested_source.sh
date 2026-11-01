#!/usr/bin/env bash
# Exercise this checkout's PPX in a real clone below an ancestor _build,
# with Dune's absolute build directory beside the source checkout.
set -Eeuo pipefail
trap 'printf "SETUP ERROR: line %s\n" "$LINENO" >&2; exit 2' ERR

if [[ $# != 1 ]]; then
  printf 'Usage: bash %s REPOSITORY_ROOT\n' "$0" >&2
  exit 2
fi
candidate=$(cd "$1" && pwd -P)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/ppx-forbid-nested-source.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
seed="$tmp/seed"
clone="$tmp/_build/scratch/ca-source"
build="$tmp/_build/scratch/ca-build"
files=(dune-project src/dune src/ppx_forbid.ml src/ppx_enforce.ml)
mkdir -p "$seed/src" "$seed/lib" "$(dirname "$clone")"
for file in "${files[@]}"; do
  cp "$candidate/$file" "$seed/$file"
done
cat >"$seed/.ppx_forbid" <<'CONFIG'
module Obj "nested-source-root Obj boundary"
exempt Obj lib/allowed.ml "the exact Obj boundary"
module Sys "nested-source-root Sys scope"
only Sys lib/scoped.ml
CONFIG
for name in setup allowed forbidden scoped outside; do
  cat >>"$seed/lib/dune" <<DUNE
(library
 (name $name)
 (modules $name)
 (preprocess (pps ppx_forbid))
 (preprocessor_deps ../.ppx_forbid))
DUNE
done
printf 'let value = 0\n' >"$seed/lib/setup.ml"
printf 'let value = Obj.repr 0\n' >"$seed/lib/allowed.ml"
cp "$seed/lib/allowed.ml" "$seed/lib/forbidden.ml"
printf 'let value = Sys.getenv_opt "PPX_FORBID_UNUSED"\n' >"$seed/lib/scoped.ml"
cp "$seed/lib/scoped.ml" "$seed/lib/outside.ml"
git init --quiet "$seed"
git -C "$seed" add -- "${files[@]}" .ppx_forbid lib
git -C "$seed" -c user.name=Regression -c user.email=regression@example.invalid \
  -c commit.gpgsign=false commit --quiet -m 'Candidate nested-source fixture'
git clone --quiet --no-hardlinks "$seed" "$clone"
for file in "${files[@]}"; do
  cmp "$candidate/$file" "$clone/$file"
done

run_dune() (
  # Dune runtest exports these for its own workspace. The inner Dune must
  # establish its own source root and context, without changing the switch.
  unset INSIDE_DUNE DUNE_SOURCEROOT DUNE_BUILD_DIR
  cd "$clone"
  OCAML_COLOR=never dune build --root "$clone" --build-dir "$build" "$@"
)
if ! run_dune src/ppx_forbid.cma lib/setup.cma >"$tmp/setup.log" 2>&1; then
  cat "$tmp/setup.log" >&2
  printf 'SETUP ERROR: candidate PPX prebuild failed\n' >&2
  exit 2
fi
printf 'PASS: committed clone contains candidate PPX; prebuild succeeded\n'

failures=0
check() {
  local name=$1 expected=$2 module=$3 reason=$4 status=0 log="$tmp/$1.log"
  run_dune "lib/$name.cma" >"$log" 2>&1 || status=$?
  if [[ $status != 0 ]] && ! grep -Fq 'Forbidden module:' "$log"; then
    cat "$log" >&2
    printf 'SETUP ERROR: building %s failed without a policy diagnostic\n' "$name" >&2
    exit 2
  fi
  if [[ $expected == accept && $status == 0 ]]; then
    printf 'PASS: lib/%s.ml accepted\n' "$name"
  elif [[ $expected == reject && $status != 0 ]] &&
    grep -Fq "File \"lib/$name.ml\"" "$log" &&
    grep -Fq "Forbidden module: $module is not allowed." "$log" &&
    grep -Fq "Reason: $reason" "$log"; then
    printf 'PASS: lib/%s.ml rejected with its config reason\n' "$name"
  else
    printf 'FAIL: lib/%s.ml should %s (Dune exit %s)\n' "$name" "$expected" "$status" >&2
    cat "$log" >&2
    failures=$((failures + 1))
  fi
}
check allowed accept Obj 'nested-source-root Obj boundary'
check forbidden reject Obj 'nested-source-root Obj boundary'
check scoped reject Sys 'nested-source-root Sys scope'
check outside accept Sys 'nested-source-root Sys scope'
if [[ $failures != 0 ]]; then
  printf 'FAIL: %s nested-source assertions\n' "$failures" >&2
  exit 1
fi
