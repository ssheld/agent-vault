#!/usr/bin/env bash

root_readme_valid_heading() {
  local LC_ALL=C
  [[ -n "$1" && "$1" != / && "$1" != *[[:cntrl:]]* ]]
}

# READMEs are project-owned: any matching name/type suppresses creation, even
# when several entries match. Policy-wrapper ambiguity has a separate contract.
root_readme_presence() {
  perl -e '
    use strict;
    use warnings;
    my $root = shift;
    opendir(my $dir, $root) or die "Error: cannot inspect root README entries: $!\n";
    my ($count, $name) = (0, "");
    $! = 0;
    while (defined(my $entry = readdir($dir))) {
      if ($entry =~ /\Areadme(?:\..*)?\z/is) {
        $count++;
        $name = $entry;
      }
      $! = 0;
    }
    die "Error: cannot enumerate root README entries: $!\n" if $!;
    closedir($dir) or die "Error: cannot close root README directory: $!\n";
    my $canonical = "$root/README.md";
    print $count == 0 ? "missing\n"
      : $count == 1 && $name eq "README.md" && !-l $canonical && -f $canonical
      ? "canonical\n" : "preserve\n";
  ' "$1"
}

root_readme_publish() (
  local source_path="$1" repo_root="$2" heading="$3" temp_path=""
  trap 'if [[ -n "$temp_path" ]]; then rm -f -- "$temp_path" || exit 1; fi' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  temp_path="$(mktemp "$repo_root/.agent-vault-readme.XXXXXX")" || return
  ROOT_README_PROJECT_NAME="$heading" perl -e '
    use strict;
    use warnings;
    open(my $source, "<", $ARGV[0]) or die "Error: cannot open root README template: $!\n";
    my $content = "";
    while (1) {
      my $read = read($source, my $chunk, 8192);
      defined($read) or die "Error: cannot read root README template: $!\n";
      last unless $read;
      $content .= $chunk;
    }
    close($source) or die "Error: cannot close root README template: $!\n";
    $content =~ s/__PROJECT_NAME__/$ENV{ROOT_README_PROJECT_NAME}/g;
    print $content or die "Error: cannot render root README: $!\n";
    close(STDOUT) or die "Error: cannot finish root README rendering: $!\n";
  ' "$source_path" >"$temp_path" || return

  # Unlike cp or plain ln, link() refuses every occupied final path, including
  # a directory or symlink that appeared after discovery. Keep the temp on the
  # same filesystem and publish only after rendering and closing it succeeded.
  perl -e '
    use strict;
    use warnings;
    chmod(0666 & ~umask(), $ARGV[0]) == 1
      or die "Error: cannot set root README permissions: $!\n";
    link($ARGV[0], $ARGV[1]) or die "Error: cannot publish root README (destination must remain absent): $!\n";
  ' "$temp_path" "$repo_root/README.md" || return
)

# Return an outcome on stdout for each caller to report using its own existing
# conventions. Errors propagate; callers supply their validate_write_path.
seed_root_readme() {
  local source_path="$1" repo_root="$2" heading="$3" dry_run_mode="${4:-false}"
  local presence path_status=0
  if ! declare -F validate_write_path >/dev/null; then
    echo 'Error: root-readme.sh requires the caller to define validate_write_path.' >&2
    return 1
  fi
  presence="$(root_readme_presence "$repo_root")" || return
  case "$presence" in
    canonical | preserve)
      printf '%s\n' "$presence"
      return
      ;;
    missing) ;;
    *)
      echo "Error: unexpected root README discovery result." >&2
      return 1
      ;;
  esac
  if ! root_readme_valid_heading "$heading"; then
    echo 'invalid-heading'
    return
  fi
  validate_write_path "$repo_root/README.md" || path_status=$?
  if [[ "$path_status" -eq 1 ]]; then
    echo 'symlink-path'
    return
  fi
  if [[ "$path_status" -ne 0 ]]; then
    echo 'Error: refusing to seed README outside the repository root.' >&2
    return 1
  fi
  if [[ "$dry_run_mode" != true ]]; then
    root_readme_publish "$source_path" "$repo_root" "$heading" || return
  fi
  echo 'seeded'
}
