#!/bin/sh
# check-drift.sh — 品質ゲートのドリフト検査
# 引数で渡したディレクトリ配下のokamyujiリポジトリを走査し、次の違反を検出する。
# 違反はローカルのパスではなく <owner>/<repo>[/<リポジトリ内のパス>] で表示する。
#   NOT-UNIFIED        reusable-workflows@v1 を参照していないワークフロー保有リポジトリ
#   GITLEAKS-NO-TOKEN  gitleaks-action を直接使いながら GITHUB_TOKEN が無いワークフロー
# 既知の許容例外は tools/ci-skip-list.tsv（TSV: type<TAB>対象<TAB>理由）で除外する。
# 終了コード: 違反0件（skip後）なら0、違反ありなら1。依存は find / grep / git / awk のみ。
set -eu

BASE="${1:?usage: sh tools/check-drift.sh <directory containing repositories>}"
SKIP_LIST="$(dirname "$0")/ci-skip-list.tsv"

violations=$(
  find "$BASE" -maxdepth 4 -type d -name .github 2>/dev/null | while read -r ghd; do
    repo=$(dirname "$ghd")
    wfdir="$ghd/workflows"
    [ -d "$wfdir" ] || continue
    # GitHub上のokamyuji所有リポジトリのみ対象。それ以外のremoteはURLを出力に
    # 含めない（埋め込まれた認証情報を表示しないため）
    url=$(git -C "$repo" config --get remote.origin.url 2>/dev/null || echo "")
    printf '%s' "$url" | grep -Eq 'github\.com[:/]okamyuji/' || continue
    # 1つのGitHubリポジトリに.githubを持つサブディレクトリが複数ある場合があるため、
    # リポジトリ内のパスまで含めて識別する
    # 注: macOSの/bin/sh(bash 3.2)は $( ) 内のcaseパターンを誤解析するため、caseを使わない
    slug=${url#*github.com[:/]}
    slug=${slug%/}
    slug=${slug%.git}
    slug=${slug%/}
    prefix=$(git -C "$repo" rev-parse --show-prefix 2>/dev/null || echo "")
    id="$slug${prefix:+/${prefix%/}}"
    # 中央リポジトリ自身は対象外
    [ "$id" = "okamyuji/reusable-workflows" ] && continue
    if ! grep -rq "okamyuji/reusable-workflows/.github/workflows/.*@v1" "$wfdir"; then
      printf 'NOT-UNIFIED %s\n' "$id"
    fi
    for f in "$wfdir"/*.yml "$wfdir"/*.yaml; do
      [ -f "$f" ] || continue
      if grep -q "gitleaks/gitleaks-action@" "$f" && ! grep -q "GITHUB_TOKEN" "$f"; then
        printf 'GITLEAKS-NO-TOKEN %s\n' "$id/.github/workflows/${f##*/}"
      fi
    done
  done
)

# skip リストによる除外（TYPE 完全一致 + 対象の完全一致）
skipped=0
if [ -n "$violations" ] && [ -f "$SKIP_LIST" ]; then
  total=$(printf '%s\n' "$violations" | grep -c . || true)
  skips=$(awk -F '\t' '!/^#/ && NF >= 2 { print $1 " " $2 }' "$SKIP_LIST")
  # 空のパターンは全行に一致するため、許容リストが空なら除外しない
  if [ -n "$skips" ]; then
    violations=$(printf '%s\n' "$violations" | grep -vxF -e "$skips" || true)
  fi
  remaining=$(printf '%s\n' "$violations" | grep -c . || true)
  skipped=$((total - remaining))
fi

if [ -n "$violations" ]; then
  printf '%s\n' "$violations"
  count=$(printf '%s\n' "$violations" | grep -c .)
  echo "---"
  if [ "$skipped" -gt 0 ]; then echo "skipped (allowed): $skipped"; fi
  echo "violations: $count"
  exit 1
fi
if [ "$skipped" -gt 0 ]; then echo "skipped (allowed): $skipped"; fi
echo "no drift"
exit 0
