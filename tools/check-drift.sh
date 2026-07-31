#!/bin/sh
# check-drift.sh — 品質ゲートのドリフト検査
# ~/devs 配下のokamyujiリポジトリを走査し、次の違反を検出する。
#   NOT-UNIFIED        reusable-workflows@v1 を参照していないワークフロー保有リポジトリ
#   GITLEAKS-NO-TOKEN  gitleaks-action を直接使いながら GITHUB_TOKEN が無いワークフロー
# 既知の許容例外は tools/ci-skip-list.tsv（TSV: type<TAB>path末尾<TAB>理由）で除外する。
# 終了コード: 違反0件（skip後）なら0、違反ありなら1。依存は find / grep / git / awk のみ。
set -eu

BASE="${1:-$HOME/devs}"
SKIP_LIST="$(dirname "$0")/ci-skip-list.tsv"

violations=$(
  find "$BASE" -maxdepth 4 -type d -name .github 2>/dev/null | while read -r ghd; do
    repo=$(dirname "$ghd")
    wfdir="$ghd/workflows"
    [ -d "$wfdir" ] || continue
    # 中央リポジトリ自身は対象外
    # 注: macOSの/bin/sh(bash 3.2)は $( ) 内のcaseパターンを誤解析するため、caseを使わない
    [ "${repo##*/}" = "reusable-workflows" ] && continue
    # okamyuji所有リポジトリのみ対象（サードパーティのクローンは除外）
    url=$(git -C "$repo" config --get remote.origin.url 2>/dev/null || echo "")
    printf '%s' "$url" | grep -q "okamyuji" || continue
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

# skip リストによる除外（TYPE 完全一致 + パス末尾一致）
skipped=0
if [ -n "$violations" ] && [ -f "$SKIP_LIST" ]; then
  total=$(printf '%s\n' "$violations" | grep -c . || true)
  violations=$(printf '%s\n' "$violations" | awk -v skipfile="$SKIP_LIST" '
    BEGIN {
      n = 0
      while ((getline line < skipfile) > 0) {
        if (line ~ /^#/ || line ~ /^[ \t]*$/) continue
        split(line, f, "\t")
        n++; stype[n] = f[1]; spath[n] = f[2]
      }
      close(skipfile)
    }
    {
      vtype = $1; vpath = $2
      skip = 0
      for (i = 1; i <= n; i++) {
        if (vtype != stype[i]) continue
        plen = length(spath[i]); vlen = length(vpath)
        if (vpath == spath[i]) { skip = 1; break }
        if (vlen > plen && substr(vpath, vlen - plen, plen + 1) == "/" spath[i]) { skip = 1; break }
      }
      if (!skip) print
    }')
  remaining=$(printf '%s\n' "$violations" | grep -c . || true)
  skipped=$((total - remaining))
fi

if [ -n "$violations" ]; then
  echo "$violations"
  count=$(printf '%s\n' "$violations" | grep -c .)
  echo "---"
  if [ "$skipped" -gt 0 ]; then echo "skipped (allowed): $skipped"; fi
  echo "violations: $count"
  exit 1
fi
if [ "$skipped" -gt 0 ]; then echo "skipped (allowed): $skipped"; fi
echo "no drift"
exit 0
