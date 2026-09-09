#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/agent-vault-readme-test.XXXXXX")"
tmp_root="$(cd "$tmp_root" && pwd -P)"
read_only_root=""
cleanup() {
  if [[ -n "$read_only_root" ]]; then
    chmod u+w "$read_only_root"
  fi
  rm -rf "$tmp_root"
}
trap cleanup EXIT
assertions=0
output=""

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_equal() {
  [[ "$1" == "$2" ]] || fail "$3: expected '$1', got '$2'"
  assertions=$((assertions + 1))
}

assert_contains() {
  [[ "$output" == *"$1"* ]] || fail "missing output '$1': $output"
  assertions=$((assertions + 1))
}

assert_not_contains() {
  [[ "$output" != *"$1"* ]] || fail "unexpected output '$1': $output"
  assertions=$((assertions + 1))
}

run() {
  local expected="$1" status=0
  shift
  output="$("$@" 2>&1)" || status=$?
  [[ "$status" -eq "$expected" ]] || fail "expected exit $expected, got $status: $output"
  assertions=$((assertions + 1))
}

init_repo() {
  mkdir -p "$1"
  git -C "$1" init -q
}

assert_absent() {
  [[ ! -e "$1" && ! -L "$1" ]] || fail "unexpected path: $1"
  assertions=$((assertions + 1))
}

# Snapshot names, types, permissions, file bytes and link targets, including
# Git config and untracked paths. Do not follow symlinks or split filenames.
snapshot() {
  perl -MFile::Find -MDigest::SHA=sha256_hex -e '
    my $root = shift;
    my @paths;
    find({ no_chdir => 1, wanted => sub { push @paths, $File::Find::name } }, $root);
    for my $path (sort @paths) {
      my @stat = lstat($path);
      @stat or die "lstat: $!";
      my $data = "";
      if (-l _) {
        $data = readlink($path);
        defined $data or die "readlink: $!";
      } elsif (-f _) {
        open my $fh, "<", $path or die "open: $!";
        local $/;
        $data = <$fh> // "";
        close $fh or die "close: $!";
      }
      print substr($path, length($root)), "\0", $stat[2], "\0", sha256_hex($data), "\0";
    }
  ' "$1"
}

assert_snapshot() {
  snapshot "$1" >"$tmp_root/after.snapshot"
  cmp -s "$2" "$tmp_root/after.snapshot" || fail "unexpected filesystem change in $1"
  assertions=$((assertions + 1))
}

assert_no_temps() {
  local found
  found="$(find "$1" -maxdepth 1 -name '.agent-vault-readme.*' -print)"
  [[ -z "$found" ]] || fail "README temporary file leaked: $found"
  assertions=$((assertions + 1))
}

# A caller must define the write-path validator, even when sourcing the library
# directly. Diagnose that contract error before attempting discovery or writes.
missing_validator="$tmp_root/missing-validator"
init_repo "$missing_validator"
snapshot "$missing_validator" >"$tmp_root/missing-validator.snapshot"
run 1 bash -c 'source "$1"; seed_root_readme "$2" "$3" Heading' _ "$repo_root/scripts/lib/root-readme.sh" "$repo_root/scaffold/root/README.md" "$missing_validator"
assert_contains 'root-readme.sh requires the caller to define validate_write_path'
assert_not_contains 'outside the repository root'
assert_not_contains 'command not found'
assert_snapshot "$missing_validator" "$tmp_root/missing-validator.snapshot"

# Fresh generation: exactly the project heading and two navigation links.
fresh="$tmp_root/fresh project"
init_repo "$fresh"
cp "$repo_root/scaffold/root/README.md" "$tmp_root/source-readme"
run 0 bash "$repo_root/scripts/new-project.sh" 'Example Project' "$fresh"
assert_contains 'Created: README.md'
printf '# Example Project\n\n- [Project home](agent-vault/README.md)\n- [Architecture and design](docs/design.md)\n' >"$tmp_root/expected-readme"
cmp -s "$tmp_root/expected-readme" "$fresh/README.md" || fail 'unexpected generated README'
[[ -f "$fresh/agent-vault/README.md" && -f "$fresh/docs/design.md" ]] || fail 'missing default link target'
git -C "$fresh" add README.md
git -C "$fresh" diff --cached --check -- README.md
assert_no_temps "$fresh"

# Names are data, including Markdown punctuation, backslashes, and shell syntax.
special="$tmp_root/special project"
init_repo "$special"
name='Project _*`[name]* & / \ $value $(touch '"$tmp_root/name-executed"')'
run 0 bash "$repo_root/scripts/new-project.sh" "$name" "$special"
assert_equal "# $name" "$(head -n 1 "$special/README.md")" 'literal root heading'
assert_equal "# $name" "$(sed -n '/^# /{p;q;}' "$special/agent-vault/README.md")" 'consistent vault heading'
assert_absent "$tmp_root/name-executed"

# Bootstrap rejects control characters before creating the vault or root files.
invalid="$tmp_root/invalid"
init_repo "$invalid"
snapshot "$invalid" >"$tmp_root/invalid.snapshot"
for name in $'bad\nname' $'bad\rname' $'bad\tname' $'bad\001name' $'bad\033name' $'bad\177name'; do
  run 1 bash "$repo_root/scripts/new-project.sh" "$name" "$invalid"
  assert_contains 'project name'
  assert_contains 'control characters'
  assert_snapshot "$invalid" "$tmp_root/invalid.snapshot"
done

# Project-owned entries of every relevant kind suppress creation. This runs on
# both filesystems; exact spelling must come from enumeration, not -e aliases.
for kind in canonical empty mixed extensionless markdown rst txt old newline-name link dangling directory-link directory fifo multiple; do
  target="$tmp_root/preserve-$kind"
  outside="$tmp_root/outside-$kind"
  init_repo "$target"
  mkdir "$outside"
  printf 'external owner data\n' >"$outside/owner"
  case "$kind" in
    canonical) printf 'custom README\n' >"$target/README.md" ;;
    empty) : >"$target/README.md" ;;
    mixed) printf 'mixed case\n' >"$target/rEaDmE.Md" ;;
    extensionless) printf 'plain README\n' >"$target/README" ;;
    markdown | rst | txt | old) printf 'alternate README\n' >"$target/README.$kind" ;;
    newline-name) printf 'newline filename\n' >"$target/"$'README.notes\nextra' ;;
    link) ln -s "$outside/owner" "$target/README.md" ;;
    dangling) ln -s "$outside/missing" "$target/README.md" ;;
    directory-link) ln -s "$outside" "$target/README.md" ;;
    directory) mkdir "$target/README.md" ;;
    fifo) mkfifo "$target/README.md" ;;
    multiple)
      printf 'first\n' >"$target/README.md"
      printf 'second\n' >"$target/readme.rst"
      ;;
  esac
  # Preserve a separate copy of the existing README entries for later comparison.
  mkdir "$tmp_root/entries-$kind"
  cp -RP "$target/"* "$tmp_root/entries-$kind/"
  snapshot "$outside" >"$tmp_root/outside.snapshot"
  run 0 bash "$repo_root/scripts/new-project.sh" 'Display Name' "$target" --migrate-existing-root-md
  assert_contains 'Notice: README'
  assert_not_contains 'Created: README.md'
  run 0 bash "$repo_root/scripts/update-project.sh" "$target"
  assert_not_contains 'Seeded: README.md'
  if [[ "$kind" == canonical || "$kind" == empty ]]; then
    assert_not_contains 'Skip: README.md'
    assert_contains '- skipped: 0'
  else
    assert_contains 'Skip: README.md'
    assert_contains '- skipped: 1'
  fi
  snapshot "$target" >"$tmp_root/preserve.snapshot"
  run 0 bash "$repo_root/scripts/update-project.sh" "$target" --dry-run --migrate-root --migrate-root-scripts --sync-templates --sync-coding-standards
  assert_not_contains 'Seed: README.md'
  assert_snapshot "$target" "$tmp_root/preserve.snapshot"
  run 0 bash "$repo_root/scripts/update-project.sh" "$target" --migrate-root --migrate-root-scripts --sync-templates --sync-coding-standards
  assert_not_contains 'Seeded: README.md'
  assert_snapshot "$outside" "$tmp_root/outside.snapshot"
  mkdir "$tmp_root/actual-$kind"
  cp -RP "$target/"[Rr][Ee][Aa][Dd][Mm][Ee]* "$tmp_root/actual-$kind/"
  snapshot "$tmp_root/entries-$kind" >"$tmp_root/entries.snapshot"
  assert_snapshot "$tmp_root/actual-$kind" "$tmp_root/entries.snapshot"
  assert_no_temps "$target"
done

# Restore a missing README during update, using the directory name, and preserve
# later edits. Dry runs include the planned count but do not alter any files.
legacy="$tmp_root/update directory"
init_repo "$legacy"
run 0 bash "$repo_root/scripts/new-project.sh" 'Different Display Name' "$legacy"
rm "$legacy/README.md"
snapshot "$legacy" >"$tmp_root/legacy.snapshot"
run 0 bash "$repo_root/scripts/update-project.sh" "$legacy" --dry-run
assert_contains 'Seed: README.md (new template; heading from directory name)'
assert_contains '- created: 1'
assert_snapshot "$legacy" "$tmp_root/legacy.snapshot"
run 0 bash "$repo_root/scripts/update-project.sh" "$legacy"
assert_contains 'Seeded: README.md (new template; heading from directory name)'
assert_contains '- created: 1'
assert_equal '# update directory' "$(head -n 1 "$legacy/README.md")" 'update title'
printf 'owner customization\n' >"$legacy/README.md"
run 0 bash "$repo_root/scripts/update-project.sh" "$legacy"
assert_equal 'owner customization' "$(cat "$legacy/README.md")" 'repeat update preservation'
assert_contains '- created: 0'
assert_not_contains 'Skip: README.md'

# The conventional docs link remains static when an existing symlink prevents
# safely seeding its target. No file may be written outside the project.
linked_docs="$tmp_root/linked-docs"
init_repo "$linked_docs"
mkdir "$tmp_root/external-docs"
ln -s "$tmp_root/external-docs" "$linked_docs/docs"
snapshot "$tmp_root/external-docs" >"$tmp_root/docs.snapshot"
run 0 bash "$repo_root/scripts/new-project.sh" 'Linked docs' "$linked_docs"
assert_contains 'docs/design.md has a symlinked path component'
assert_snapshot "$tmp_root/external-docs" "$tmp_root/docs.snapshot"
[[ "$(cat "$linked_docs/README.md")" == *'(docs/design.md)'* ]] || fail 'static design link missing'
rm "$linked_docs/README.md"
run 0 bash "$repo_root/scripts/update-project.sh" "$linked_docs"
assert_contains 'Skip: docs/design.md'
assert_contains 'Seeded: README.md'
assert_snapshot "$tmp_root/external-docs" "$tmp_root/docs.snapshot"

# A control character in a directory-derived heading only skips this cosmetic
# seed; the rest of the update still runs, in both real and dry-run modes.
invalid_update="$tmp_root/"$'bad\nupdate'
init_repo "$invalid_update"
run 0 bash "$repo_root/scripts/new-project.sh" 'Valid Display Name' "$invalid_update"
rm "$invalid_update/README.md" "$invalid_update/scripts/new-worktree.sh"
snapshot "$invalid_update" >"$tmp_root/update-invalid.snapshot"
run 0 bash "$repo_root/scripts/update-project.sh" "$invalid_update" --dry-run
assert_contains 'Skip: README.md (directory name is not a usable heading)'
assert_snapshot "$invalid_update" "$tmp_root/update-invalid.snapshot"
run 0 bash "$repo_root/scripts/update-project.sh" "$invalid_update"
assert_contains 'Skip: README.md (directory name is not a usable heading)'
[[ -f "$invalid_update/scripts/new-worktree.sh" ]] || fail 'invalid heading stopped unrelated update'
assert_absent "$invalid_update/README.md"

# Default bootstrap also preserves existing files and symlinks without migration.
for kind in file symlink; do
  target="$tmp_root/default-$kind"
  init_repo "$target"
  if [[ "$kind" == file ]]; then
    printf 'custom owner file\n' >"$target/README.md"
  else
    ln -s "$tmp_root/missing-default-target" "$target/README.md"
  fi
  run 0 bash "$repo_root/scripts/new-project.sh" 'Default' "$target"
  assert_contains 'Notice: README'
  assert_not_contains 'Created: README.md'
  if [[ "$kind" == file ]]; then
    assert_equal 'custom owner file' "$(cat "$target/README.md")" 'default file preservation'
  else
    assert_equal "$tmp_root/missing-default-target" "$(readlink "$target/README.md")" 'default symlink preservation'
    assert_absent "$tmp_root/missing-default-target"
  fi
done

# Case-only duplicates must be tested on a case-sensitive filesystem. Different
# extensions above exercise multiple matches on every supported platform.
case_repo="$tmp_root/case-duplicates"
init_repo "$case_repo"
printf 'upper\n' >"$case_repo/README.md"
if [[ ! -e "$case_repo/readme.md" ]]; then
  printf 'lower\n' >"$case_repo/readme.md"
  run 0 bash "$repo_root/scripts/new-project.sh" 'Case variants' "$case_repo"
  run 0 bash "$repo_root/scripts/update-project.sh" "$case_repo"
  assert_contains 'Skip: README.md'
  assert_equal upper "$(cat "$case_repo/README.md")" 'upper case duplicate preserved'
  assert_equal lower "$(cat "$case_repo/readme.md")" 'lower case duplicate preserved'
else
  echo 'Case-only duplicate fixture requires a case-sensitive filesystem; other multiple matches covered.'
fi

# The renderer obeys the caller umask rather than publishing mktemp mode 0600
# unconditionally. A project README must not become executable.
for mask in 022 077; do
  target="$tmp_root/umask-$mask"
  init_repo "$target"
  run 0 bash -c 'umask "$1"; bash "$2" Permissions "$3"' _ "$mask" "$repo_root/scripts/new-project.sh" "$target"
  mode="$(perl -e 'printf "%03o", (stat($ARGV[0]))[2] & 0777' "$target/README.md")"
  if [[ "$mask" == 022 ]]; then
    assert_equal 644 "$mode" 'default README permissions'
  else
    assert_equal 600 "$mode" 'restrictive README permissions'
  fi
done

# An unusable derived title can be exercised without treating / as a test repo.
empty_title="$tmp_root/empty-title"
init_repo "$empty_title"
for name in '' /; do
  run 0 bash -c 'source "$1"; validate_write_path() { return 0; }; seed_root_readme "$2" "$3" "$4" true' _ "$repo_root/scripts/lib/root-readme.sh" "$repo_root/scaffold/root/README.md" "$empty_title" "$name"
  assert_equal invalid-heading "$output" 'degenerate derived heading'
  assert_absent "$empty_title/README.md"
done

# Source preflight runs before bootstrap/update mutation, even in dry-run mode.
missing_source="$tmp_root/missing-source"
mkdir "$missing_source"
cp -R "$repo_root/scripts" "$repo_root/scaffold" "$missing_source/"
rm "$missing_source/scaffold/root/README.md"
missing_new="$tmp_root/missing-new"
init_repo "$missing_new"
snapshot "$missing_new" >"$tmp_root/missing-new.snapshot"
run 1 bash "$missing_source/scripts/new-project.sh" 'Missing source' "$missing_new"
assert_contains 'missing root scaffold file:'
assert_contains 'scaffold/root/README.md'
assert_snapshot "$missing_new" "$tmp_root/missing-new.snapshot"
snapshot "$legacy" >"$tmp_root/missing-update.snapshot"
for flag in '' --dry-run; do
  args=()
  [[ -z "$flag" ]] || args+=("$flag")
  run 1 bash "$missing_source/scripts/update-project.sh" "$legacy" "${args[@]}"
  assert_contains 'missing scaffold file:'
  assert_contains 'scaffold/root/README.md'
  assert_snapshot "$legacy" "$tmp_root/missing-update.snapshot"
done

# Real scenarios cover seeded/canonical/preserve/invalid-heading above and the
# symlink-path race below. Substitute the helper only for outcomes unreachable
# through current CLI inputs: bootstrap's invalid heading and unknown values.
outcome_source="$tmp_root/outcome-source"
mkdir "$outcome_source"
cp -R "$repo_root/scripts" "$repo_root/scaffold" "$outcome_source/"
cat >>"$outcome_source/scripts/lib/root-readme.sh" <<'SHIM'
seed_root_readme() {
  printf '%s\n' "$README_TEST_OUTCOME"
}
SHIM
for entrypoint in new update update-dry-run; do
  for outcome in invalid-heading unknown-outcome ''; do
    target="$tmp_root/outcome-$entrypoint-${outcome:-empty}"
    init_repo "$target"
    expected=1
    if [[ "$entrypoint" == new ]]; then
      command=(bash "$outcome_source/scripts/new-project.sh" 'Valid heading' "$target")
    else
      run 0 bash "$repo_root/scripts/new-project.sh" 'Outcome fixture' "$target"
      rm "$target/README.md"
      command=(bash "$outcome_source/scripts/update-project.sh" "$target")
      [[ "$outcome" != invalid-heading ]] || expected=0
      if [[ "$entrypoint" == update-dry-run ]]; then
        command+=(--dry-run)
        snapshot "$target" >"$tmp_root/outcome.snapshot"
      fi
    fi
    run "$expected" env README_TEST_OUTCOME="$outcome" "${command[@]}"
    if [[ "$outcome" == invalid-heading ]]; then
      if [[ "$entrypoint" == new ]]; then
        assert_contains 'Error: cannot seed README.md: project name is not a usable heading.'
      else
        assert_contains 'Skip: README.md (directory name is not a usable heading)'
        assert_contains '- skipped: 1'
        assert_contains '- created: 0'
      fi
    else
      assert_contains 'Error: unexpected root README seeding result.'
    fi
    assert_not_contains 'README entry already exists'
    assert_not_contains 'Created: README.md'
    assert_not_contains 'Seeded: README.md'
    assert_not_contains 'Seed: README.md'
    assert_absent "$target/README.md"
    assert_no_temps "$target"
    if [[ "$entrypoint" == update-dry-run ]]; then
      assert_snapshot "$target" "$tmp_root/outcome.snapshot"
    fi
  done
done

# The shim injects failures at the existing interpreter boundary, without
# adding test switches to production code. Other Perl hydration runs normally.
real_perl="$(command -v perl)"
mkdir "$tmp_root/bin"
cat >"$tmp_root/bin/perl" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == -e && "${2:-}" == *'opendir(my $dir'* && "${3:-}" == "$README_FAULT_REPO" ]]; then
  case "$README_FAULT" in
    enumeration)
      printf 'missing\n'
      echo 'injected README enumeration failure' >&2
      exit 71
      ;;
    validation-symlink)
      presence="$("$README_REAL_PERL" "$@")"
      ln -s "$README_FAULT_OUTSIDE" "$README_FAULT_REPO/README.md"
      printf '%s\n' "$presence"
      exit 0
      ;;
    read-only-root)
      # Earlier bootstrap seeds need a writable root. Remove write permission
      # at discovery so the real mktemp, before rendering/publication, fails.
      chmod a-w "$README_FAULT_REPO"
      ;;
  esac
fi
if [[ "${1:-}" == -e && "${2:-}" == *'read($source'* && "${3:-}" == "$README_FAULT_SOURCE" && "$README_FAULT" == render ]]; then
  printf '# partial rendered output\n'
  echo 'injected README rendering failure' >&2
  exit 73
fi
if [[ "${1:-}" == -e && "${2:-}" == *'link($ARGV[0]'* && "${4:-}" == "$README_FAULT_REPO/README.md" ]]; then
  case "$README_FAULT" in
    publication)
      echo 'injected README publication failure' >&2
      exit 74
      ;;
    file) printf 'late owner content\n' >"$4" ;;
    directory) mkdir "$4" ;;
    symlink) ln -s "$README_FAULT_OUTSIDE" "$4" ;;
    dangling) ln -s "$README_FAULT_OUTSIDE/missing" "$4" ;;
  esac
fi
exec "$README_REAL_PERL" "$@"
SHIM
chmod +x "$tmp_root/bin/perl"

for entrypoint in new update; do
  for fault in enumeration render publication file directory symlink dangling validation-symlink read-only-root; do
    if [[ "$fault" == read-only-root && "$EUID" -eq 0 ]]; then
      echo 'Read-only root fixture requires an unprivileged user; root bypasses write permissions.'
      continue
    fi
    target="$tmp_root/fault-$entrypoint-$fault"
    outside="$tmp_root/fault-outside-$entrypoint-$fault"
    init_repo "$target"
    mkdir "$outside"
    printf 'external marker\n' >"$outside/marker"
    snapshot "$outside" >"$tmp_root/fault-outside.snapshot"
    if [[ "$entrypoint" == update ]]; then
      run 0 bash "$repo_root/scripts/new-project.sh" 'Fault fixture' "$target"
      rm "$target/README.md"
      command=(bash "$repo_root/scripts/update-project.sh" "$target")
    else
      command=(bash "$repo_root/scripts/new-project.sh" 'Fault fixture' "$target")
    fi
    if [[ "$fault" == read-only-root ]]; then
      read_only_root="$target"
    fi
    status=0
    output="$(env LC_ALL=C PATH="$tmp_root/bin:$PATH" README_REAL_PERL="$real_perl" README_FAULT="$fault" README_FAULT_REPO="$target" README_FAULT_OUTSIDE="$outside" README_FAULT_SOURCE="$repo_root/scaffold/root/README.md" "${command[@]}" 2>&1)" || status=$?
    if [[ -n "$read_only_root" ]]; then
      chmod u+w "$read_only_root"
      read_only_root=""
    fi
    if [[ "$fault" == validation-symlink ]]; then
      assert_equal 0 "$status" 'symlink preservation exit status'
    else
      [[ "$status" -ne 0 ]] || fail "$entrypoint swallowed $fault failure: $output"
      assertions=$((assertions + 1))
    fi
    assert_not_contains 'Created: README.md'
    assert_not_contains 'Seeded: README.md'
    case "$fault" in
      enumeration)
        assert_equal 71 "$status" 'enumeration exit propagation despite partial output'
        assert_absent "$target/README.md"
        ;;
      render)
        assert_equal 73 "$status" 'render exit propagation'
        assert_absent "$target/README.md"
        ;;
      publication)
        assert_equal 74 "$status" 'publication exit propagation'
        assert_absent "$target/README.md"
        ;;
      file) assert_equal 'late owner content' "$(cat "$target/README.md")" 'late file preserved' ;;
      directory)
        [[ -d "$target/README.md" ]] || fail 'late directory replaced'
        assert_equal '' "$(ls -A "$target/README.md")" 'late directory untouched'
        ;;
      symlink) assert_equal "$outside" "$(readlink "$target/README.md")" 'late directory symlink preserved' ;;
      dangling) assert_equal "$outside/missing" "$(readlink "$target/README.md")" 'late dangling symlink preserved' ;;
      validation-symlink)
        assert_equal "$outside" "$(readlink "$target/README.md")" 'symlink found by path validation preserved'
        if [[ "$entrypoint" == new ]]; then
          assert_contains 'Notice: README.md has a symlinked path component; template seed skipped.'
        else
          assert_contains 'Skip: README.md (symlinked path component; preserved)'
          assert_contains '- skipped: 1'
          assert_contains '- created: 0'
        fi
        assert_not_contains 'another README name/type'
        ;;
      read-only-root)
        assert_contains 'mktemp:'
        assert_contains 'Permission denied'
        assert_not_contains 'cannot publish root README'
        assert_absent "$target/README.md"
        ;;
    esac
    assert_no_temps "$target"
    assert_snapshot "$outside" "$tmp_root/fault-outside.snapshot"
  done
done

# The clarification reaches generated and updated shared rules, with the
# canonical project home and default link contents retained.
for target in "$fresh" "$legacy"; do
  for rule in AGENTS.md shared-rules.md; do
    grep -qF 'A project-root `README.md` may introduce the project and link to canonical documentation' "$target/agent-vault/$rule" || fail "missing guidance in $rule"
  done
done

cmp -s "$tmp_root/source-readme" "$repo_root/scaffold/root/README.md" || fail 'source README changed'
echo "Root README seeding regression checks passed ($assertions assertions)."
