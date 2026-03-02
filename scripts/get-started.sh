#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

do_sync=1
do_gcc=1
do_llvm=1
do_spike=1
do_verilator=1
do_hw_checkout=1
do_hw_patches=1

usage() {
  cat <<'EOF'
Usage: ./scripts/get-started.sh [options]

Bootstrap AraXL in one command. By default this script will:
  1. Sync and update git submodules
  2. Disable the unsupported-host compiler-rt guard in riscv-llvm
  3. Build the GCC and LLVM RISC-V toolchains
  4. Build Spike
  5. Build Verilator
  6. Checkout hardware dependencies via Bender
  7. Apply hardware patches required for simulation

Options:
  --skip-sync         Skip git submodule sync/update
  --skip-gcc          Skip the GCC toolchain build
  --skip-llvm         Skip the LLVM toolchain build
  --skip-spike        Skip Spike build
  --skip-verilator    Skip Verilator build
  --skip-hw-checkout  Skip hardware dependency checkout
  --skip-hw-patches   Skip hardware patch application
  -h, --help          Show this help message

The script reuses the repository's existing make targets, so variables such as
INSTALL_PREFIX, CC, CXX, CLANG_CC, and CLANG_CXX can still be overridden:

  INSTALL_PREFIX=install ./scripts/get-started.sh
EOF
}

log() {
  printf '\n==> %s\n' "$*"
}

run_root() {
  log "$*"
  (
    cd "$ROOT_DIR"
    "$@"
  )
}

disable_compiler_rt_os_guard_if_needed() {
  local sanitizer_platform="$ROOT_DIR/toolchain/riscv-llvm/compiler-rt/lib/sanitizer_common/sanitizer_platform.h"
  local marker="codex: disabled unsupported OS guard for AraXL bootstrap"
  local tmp_file

  if [[ ! -f "$sanitizer_platform" ]]; then
    printf '%s\n' "Cannot patch compiler-rt: $sanitizer_platform is missing." >&2
    printf '%s\n' "Initialize the riscv-llvm submodule first, or run without --skip-sync." >&2
    exit 1
  fi

  if grep -Fq "$marker" "$sanitizer_platform"; then
    log "compiler-rt OS guard already disabled; skipping."
    return
  fi

  tmp_file="$(mktemp)"
  if ! awk -v marker="$marker" '
    BEGIN {
      in_block = 0
      patched = 0
    }
    {
      if (!patched && !in_block && $0 ~ /^#if !defined\(__linux__\) && !defined\(__FreeBSD__\) && !defined\(__NetBSD__\) &&/) {
        print "/* " marker " */"
        print "/*"
        print
        in_block = 1
        next
      }

      if (in_block) {
        print
        if ($0 == "#endif") {
          print "*/"
          in_block = 0
          patched = 1
        }
        next
      }

      print
    }
    END {
      if (in_block) {
        exit 2
      }
      if (!patched) {
        exit 3
      }
    }
  ' "$sanitizer_platform" > "$tmp_file"; then
    rm -f "$tmp_file"
    printf '%s\n' "Failed to patch $sanitizer_platform." >&2
    printf '%s\n' "The expected unsupported-OS guard was not found, or the file format changed." >&2
    exit 1
  fi

  mv "$tmp_file" "$sanitizer_platform"
  log "Disabled compiler-rt unsupported OS guard."
}

apply_hw_patches_if_needed() {
  local tech_cells_dir="$ROOT_DIR/hardware/deps/tech_cells_generic"
  local patch_file="$ROOT_DIR/hardware/patches/0001-tech-cells-generic-sram.patch"

  if [[ ! -d "$tech_cells_dir" ]]; then
    printf '%s\n' "Cannot apply hardware patches: $tech_cells_dir is missing." >&2
    printf '%s\n' "Run without --skip-hw-checkout, or checkout dependencies first." >&2
    exit 1
  fi

  if git -C "$tech_cells_dir" apply --check "$patch_file" >/dev/null 2>&1; then
    run_root make -C hardware apply-patches
    return
  fi

  if git -C "$tech_cells_dir" apply --reverse --check "$patch_file" >/dev/null 2>&1; then
    log "Hardware patches already applied; skipping."
    return
  fi

  printf '%s\n' "Cannot determine hardware patch state in $tech_cells_dir." >&2
  printf '%s\n' "The dependency may contain local changes or a conflicting version." >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-sync)
      do_sync=0
      ;;
    --skip-gcc)
      do_gcc=0
      ;;
    --skip-llvm)
      do_llvm=0
      ;;
    --skip-spike)
      do_spike=0
      ;;
    --skip-verilator)
      do_verilator=0
      ;;
    --skip-hw-checkout)
      do_hw_checkout=0
      ;;
    --skip-hw-patches)
      do_hw_patches=0
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown option: %s\n\n' "$1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

if [[ "$do_sync" -eq 1 ]]; then
  run_root git submodule sync --recursive
  run_root make git-submodules
fi

if [[ "$do_llvm" -eq 1 ]]; then
  disable_compiler_rt_os_guard_if_needed
fi

if [[ "$do_gcc" -eq 1 && "$do_llvm" -eq 1 ]]; then
  run_root make toolchains
else
  if [[ "$do_gcc" -eq 1 ]]; then
    run_root make toolchain-gcc
  fi
  if [[ "$do_llvm" -eq 1 ]]; then
    run_root make toolchain-llvm
  fi
fi

if [[ "$do_spike" -eq 1 ]]; then
  run_root make riscv-isa-sim
fi

if [[ "$do_verilator" -eq 1 ]]; then
  run_root make verilator
fi

if [[ "$do_hw_checkout" -eq 1 ]]; then
  run_root make -C hardware checkout
fi

if [[ "$do_hw_patches" -eq 1 ]]; then
  apply_hw_patches_if_needed
fi

log "AraXL bootstrap completed."
