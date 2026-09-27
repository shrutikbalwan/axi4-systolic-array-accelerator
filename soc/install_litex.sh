#!/usr/bin/env bash
# Install the exact LiteX stack the SoC flow was validated with.
#
#   bash soc/install_litex.sh [DEST]      # default DEST=build/litex-deps
#
# Needs: git, python3 + pip, a RISC-V GCC (riscv64-unknown-elf-gcc), Verilator,
# libevent and json-c headers (Ubuntu: gcc-riscv64-unknown-elf libevent-dev
# libjson-c-dev). Packages are installed editable, without dependency
# resolution, because only this pinned subset of LiteX is needed.
set -euo pipefail
cd "$(dirname "$0")/.."
DEST=${1:-build/litex-deps}
PIP_FLAGS=${PIP_FLAGS:-}
mkdir -p "$DEST"

pins=(
  "m-labs/migen                          e19524c963a8342952840983047557707fbe0b6a"
  "enjoy-digital/litex                   b6ae9e0b227354aecffef5339d3e946f2395ac09"
  "litex-hub/pythondata-cpu-vexriscv     642ecfed1c84460555d6d803d660cc60cfc1ecb6"
  "litex-hub/pythondata-software-picolibc 6a13ccce7c575b32c102dd9dc52178505b81fe39"
  "litex-hub/pythondata-software-compiler_rt 6eb76609c9627bf26635e57c63fb22cda7115887"
  "litex-hub/pythondata-misc-tapcfg      a12c3f592c99f9c082fdc68c065b81cbd6e6b238"
)

for pin in "${pins[@]}"; do
  read -r repo sha <<<"$pin"
  dir="$DEST/$(basename "$repo")"
  if [ ! -d "$dir/.git" ]; then
    git init -q "$dir"
    git -C "$dir" remote add origin "https://github.com/$repo.git"
  fi
  git -C "$dir" fetch -q --depth 1 origin "$sha"
  git -C "$dir" checkout -q FETCH_HEAD
  git -C "$dir" submodule update -q --init --depth 1 --recursive
  python3 -m pip install -q $PIP_FLAGS --no-build-isolation --no-deps -e "$dir"
  echo "installed $repo @ ${sha:0:10}"
done
python3 -c "import litex, migen; print('LiteX stack ready')"
