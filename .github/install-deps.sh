#!/usr/bin/env bash
# .github/install-deps.sh — materialise the dependencies tests/smoke.lua
# resolves, in the two shapes it resolves them from: a
# `<workspace>/<plugin>/main` sibling, and the lazy dir.
#
# Extracted from the workflow because two jobs need it (`lua` pins auto-core,
# `drift` rides its default branch) and the ONLY thing that should differ
# between them is a ref. Two inlined copies is how they drift apart.
#
# Refs come from the environment. An EMPTY ref means "whatever the default
# branch is now" — that is the drift job's whole purpose, so it is a supported
# value and not a mistake:
#   AUTO_CORE_REF  PLENARY_REF  NVIM_DAP_REF
#
# DO NOT ADD gobugger.nvim HERE. smoke [33] ASSERTS it stays absent — auto-run
# replaced it (ADR-0048 Phase 4) and the cell exists so a reintroduction fails
# loudly rather than silently re-enabling a parity gate that iterates over
# nothing. It is named in the test tree because the suite checks for its
# ABSENCE, which is the exact inverse of a dependency: installing everything
# the tests mention turns that cell red.
set -euo pipefail

lazy="$HOME/.local/share/nvim/lazy"
mkdir -p "$lazy"

# smoke.lua derives `workspace` as fnamemodify(plugin_root, ":h:h"), which on a
# runner is dirname(dirname($GITHUB_WORKSPACE)) — the checkout lives at
# /home/runner/work/<repo>/<repo>.
siblings="$(dirname "$(dirname "$GITHUB_WORKSPACE")")"

clone_at() {
  local url="$1" dest="$2" ref="$3"
  git clone --filter=blob:none "$url" "$dest"
  if [ -n "$ref" ]; then
    git -C "$dest" checkout "$ref"
  fi
  printf '  %s -> %s\n' "$dest" "$(git -C "$dest" log --oneline -1)"
}

echo "dependencies:"
clone_at https://github.com/yongjohnlee80/auto-core.nvim \
         "$siblings/auto-core.nvim/main" "${AUTO_CORE_REF:-}"
clone_at https://github.com/nvim-lua/plenary.nvim \
         "$lazy/plenary.nvim" "${PLENARY_REF:-}"
# REAL nvim-dap, not a stub: the §9 breakpoint sections run the persistence and
# reconcile paths against the actual dap.breakpoints get/set surface. smoke.lua
# only prepends it `if isdirectory`, so omitting it would not fail the suite —
# it would quietly test less.
clone_at https://github.com/mfussenegger/nvim-dap \
         "$lazy/nvim-dap" "${NVIM_DAP_REF:-}"

# Assert the inverse dependency rather than trusting the comment above: if
# gobugger ever arrives on this runner, say so here instead of letting smoke
# [33] report it as a mysterious product regression.
if [ -e "$lazy/gobugger.nvim" ] || [ -e "$siblings/gobugger.nvim" ]; then
  echo "FATAL: gobugger.nvim is present; smoke [33] asserts its ABSENCE" >&2
  exit 1
fi
