#!/usr/bin/env bash
# Shared assertions and Git fault injection for the worktree regression suites.
# Suites may use modern Bash; WORKTREE_HELPER_BASH selects the generated helpers'
# interpreter independently so macOS can enforce their Bash 3.2 contract.
# Consumed by each sourcing suite.
# shellcheck disable=SC2034
helper_bash="${WORKTREE_HELPER_BASH:-bash}"

assert_equal() {
  local expected="$1" actual="$2" label="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "PASS: $label"
    passed=$((passed + 1))
  else
    echo "FAIL: $label (expected $expected, got $actual)" >&2
    failed=$((failed + 1))
  fi
}

snapshot_worktree_state() {
  local working="$1" prefix="$2"
  git -C "$working" worktree list --porcelain -z >"$prefix.registry"
  git -C "$working" for-each-ref --format='%(refname) %(objectname)' refs/heads >"$prefix.branches"
  git -C "$working" status --porcelain=v1 --untracked-files=all >"$prefix.status"
}

assert_worktree_state_unchanged() {
  local working="$1" before="$2" label="$3" surface
  snapshot_worktree_state "$working" "$before.after"
  for surface in registry branches status; do
    if cmp -s "$before.$surface" "$before.after.$surface"; then
      echo "PASS: $label preserves $surface"
      passed=$((passed + 1))
    else
      echo "FAIL: $label changed $surface" >&2
      failed=$((failed + 1))
    fi
  done
}

install_git_probe() {
  local destination="$1"
  mkdir -p "$destination"
  WORKTREE_TEST_REAL_GIT="$(command -v git)"
  export WORKTREE_TEST_REAL_GIT
  cat >"$destination/git" <<'EOF'
#!/bin/sh
if [ "${1-}" = --version ] && [ -n "${WORKTREE_TEST_GIT_VERSION-}" ]; then
  printf '%s\n' "$WORKTREE_TEST_GIT_VERSION"
  exit 0
fi
if [ "${3-}" = worktree ] && [ "${4-}" = list ] && [ "${WORKTREE_TEST_FAIL_LIST-}" = 1 ]; then
  echo 'injected registry failure' >&2
  exit 128
fi
if [ "${3-}" = symbolic-ref ] && [ "${WORKTREE_TEST_FAIL_SYMBOLIC-}" = 1 ]; then
  echo 'injected symbolic-ref failure' >&2
  exit 128
fi
exec "$WORKTREE_TEST_REAL_GIT" "$@"
EOF
  chmod +x "$destination/git"
}
