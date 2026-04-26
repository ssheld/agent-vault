#!/usr/bin/env bash

is_runtime_note_file() {
  local file_path="$1"

  case "$file_path" in
    agent-vault/context-log.md | agent-vault/open-questions.md | agent-vault/decision-log.md | agent-vault/lessons.md)
      return 0
      ;;
    agent-vault/daily/*.md)
      [[ "$file_path" != "agent-vault/daily/README.md" ]]
      return
      ;;
    agent-vault/design-log/*.md)
      [[ "$file_path" != "agent-vault/design-log/README.md" && "$file_path" != "agent-vault/design-log/bootstrap.md" ]]
      return
      ;;
    agent-vault/context/handoffs/*.md)
      [[ "$file_path" != "agent-vault/context/handoffs/README.md" ]]
      return
      ;;
    agent-vault/decisions/*.md)
      [[ "$file_path" != "agent-vault/decisions/README.md" ]]
      return
      ;;
    *)
      return 1
      ;;
  esac
}
