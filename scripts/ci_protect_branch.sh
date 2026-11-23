#!/usr/bin/env bash
# Защита ветки main через GitHub CLI (нужны права администратора репозитория: gh auth login).
#   bash scripts/ci_protect_branch.sh                # один утверждающий
#   APPROVALS=2 bash scripts/ci_protect_branch.sh
# Что включается:
#   - слияние только через Pull Request и только после зелёных обязательных проверок CI;
#   - обязательный отзыв владельца (CODEOWNERS) для критических файлов;
#   - правила действуют и для администраторов, force push и удаление ветки запрещены.
# Требует публичный репозиторий или тариф GitHub с защитой веток для приватных.
set -euo pipefail
command -v gh >/dev/null || { echo "Установите GitHub CLI (gh)" >&2; exit 1; }
REPO="${REPO:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"
APPROVALS="${APPROVALS:-1}"

echo "Защита ветки main в $REPO (утверждающих: $APPROVALS)"
gh api -X PUT "repos/$REPO/branches/main/protection" --input - <<JSON >/dev/null
{
  "required_status_checks": {
    "strict": true,
    "contexts": ["guard", "style", "policy", "test", "migrations", "backup", "security", "container", "build"]
  },
  "enforce_admins": true,
  "required_pull_request_reviews": {
    "require_code_owner_reviews": true,
    "required_approving_review_count": $APPROVALS,
    "dismiss_stale_reviews": true
  },
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false
}
JSON

gh label create quality-waiver --color D93F0B \
  --description "Владелец разрешил осознанное ослабление проверок" --repo "$REPO" 2>/dev/null \
  || echo "Метка quality-waiver уже существует"

echo "Текущие правила:"
gh api "repos/$REPO/branches/main/protection" \
  --jq '{checks: .required_status_checks.contexts, code_owners: .required_pull_request_reviews.require_code_owner_reviews, approvals: .required_pull_request_reviews.required_approving_review_count, admins: .enforce_admins.enabled, force_push: .allow_force_pushes.enabled}'
