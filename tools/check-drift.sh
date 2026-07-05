#!/bin/sh
# check-drift.sh — 品質ゲートのドリフト検査
# ~/devs 配下のokamyujiリポジトリを走査し、次の違反を検出する。
#   NOT-UNIFIED        reusable-workflows@v1 を参照していないワークフロー保有リポジトリ
#   GITLEAKS-NO-TOKEN  gitleaks-action を直接使いながら GITHUB_TOKEN が無いワークフロー
# 終了コード: 違反0件なら0、違反ありなら1。依存は find / grep / git のみ。
set -eu

BASE="${1:-$HOME/devs}"

violations=$(
  find "$BASE" -maxdepth 4 -type d -name .github 2>/dev/null | while read -r ghd; do
    repo=$(dirname "$ghd")
    wfdir="$ghd/workflows"
    [ -d "$wfdir" ] || continue
    # 中央リポジトリ自身は対象外
    case "$repo" in */reusable-workflows) continue ;; esac
    # okamyuji所有リポジトリのみ対象（サードパーティのクローンは除外）
    url=$(git -C "$repo" config --get remote.origin.url 2>/dev/null || echo "")
    case "$url" in
      *okamyuji*) ;;
      *) continue ;;
    esac
    if ! grep -rq "okamyuji/reusable-workflows/.github/workflows/.*@v1" "$wfdir"; then
      echo "NOT-UNIFIED $repo"
    fi
    for f in "$wfdir"/*.yml "$wfdir"/*.yaml; do
      [ -f "$f" ] || continue
      if grep -q "gitleaks/gitleaks-action@" "$f" && ! grep -q "GITHUB_TOKEN" "$f"; then
        echo "GITLEAKS-NO-TOKEN $f"
      fi
    done
  done
)

if [ -n "$violations" ]; then
  echo "$violations"
  count=$(printf '%s\n' "$violations" | grep -c .)
  echo "---"
  echo "violations: $count"
  exit 1
fi
echo "no drift"
exit 0
