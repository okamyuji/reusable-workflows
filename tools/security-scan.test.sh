#!/bin/sh
# security-scan.test.sh — security-scan.yml の PR 走査の手順が、マージコミットだけに入った秘密を見つけるかを検証する
# 使い方: sh tools/security-scan.test.sh（失敗があれば終了コード1）
set -eu

here=$(cd "$(dirname "$0")" && pwd)
workflow="$here/../.github/workflows/security-scan.yml"
base=$(mktemp -d)
trap 'rm -rf "$base"' EXIT

# PR 走査の手順の run をそのまま取り出す（1 行の run と、run: | の塊の両方を読む）
step="$base/pr-step.sh"
awk '
  /- name: Pull request scan/ { in_step = 1; next }
  in_step && /^      - / { exit }
  in_step && /^ *run: \|$/ { block = 1; next }
  in_step && /^ *run: / { sub(/^ *run: /, ""); print; exit }
  block { sub(/^          /, ""); print }
' "$workflow" > "$step"
grep -q gitleaks "$step" || { echo "FAIL: security-scan.yml から PR 走査の run を取り出せない"; exit 1; }

# CI では security-scan.yml と同じ版を、同じ checksum で確かめて入れる
gitleaks=$(command -v gitleaks || true)
if [ -z "$gitleaks" ]; then
  ver=$(sed -n 's/.*GITLEAKS_VERSION: *\([0-9.]*\).*/\1/p' "$workflow" | head -1)
  sum=$(sed -n 's/.*GITLEAKS_SHA256: *\([0-9a-f]*\).*/\1/p' "$workflow" | head -1)
  archive="gitleaks_${ver}_linux_x64.tar.gz"
  curl -sSfL --retry 5 -o "$base/$archive" "https://github.com/gitleaks/gitleaks/releases/download/v${ver}/${archive}"
  (cd "$base" && echo "${sum}  ${archive}" | sha256sum -c - >/dev/null && tar -xzf "$archive" gitleaks)
  gitleaks="$base/gitleaks"
fi

fail=0
check() { # $1 説明 $2 期待 $3 実際
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected [$2] got [$3]"; fail=1; fi
}

# 作業用のリポジトリで、feat に main をマージする。PR と同じく main の先端から feat の先端までを走査する。
# $1 は main 側で f に書く内容、$2 は競合の解消で f に書く内容、$3 はリポジトリ名
scenario() {
  repo="$base/repo-$3"
  git init -q -b main "$repo"
  g() { git -C "$repo" -c user.name=t -c user.email=t@example.invalid -c commit.gpgSign=false "$@"; }
  echo a > "$repo/f" && g add f && g commit -qm base
  g switch -qc feat && echo feat > "$repo/f" && g commit -qam feat
  g switch -q main && printf '%s\n' "$1" > "$repo/f" && g commit -qam main
  b=$(g rev-parse HEAD)
  g switch -q feat && { g merge -q main >/dev/null 2>&1 || true; }
  printf '%s\n' "$2" > "$repo/f" && g add f && g commit -qm "merge main"
  h=$(g rev-parse HEAD)
  run_step "$repo" "$b" "$h"
}

# CI と同じく、作業用のリポジトリを今の場所にし、./gitleaks を置いて PR 走査の run を動かす
run_step() { # $1 リポジトリ $2 BASE_SHA $3 HEAD_SHA
  ln -sf "$gitleaks" "$1/gitleaks"
  code=0
  (cd "$1" && BASE_SHA=$2 HEAD_SHA=$3 sh -e "$step") >/dev/null 2>&1 || code=$?
  echo "$code"
}

# 3 つの枝を一度にまとめる octopus マージで、マージコミットだけに秘密を入れる。git は親が 3 つ以上の
# マージに remerge の差分を出さないので、gitleaks は見つけられない。走査は失敗（終了コード 1）にする
octopus() {
  repo="$base/repo-octopus"
  git init -q -b main "$repo"
  g() { git -C "$repo" -c user.name=t -c user.email=t@example.invalid -c commit.gpgSign=false "$@"; }
  echo a > "$repo/f" && g add f && g commit -qm base
  b=$(g rev-parse HEAD)
  for br in x y; do g switch -qc "$br" main && echo "$br" > "$repo/$br" && g add "$br" && g commit -qm "$br"; done
  g switch -qc feat main && echo feat > "$repo/feat" && g add feat && g commit -qm feat
  g merge -q --no-commit x y >/dev/null 2>&1
  key > "$repo/creds" && g add creds && g commit -qm "octopus"
  run_step "$repo" "$b" "$(g rev-parse HEAD)"
}

# 秘密の形の値は実行時に作る（固定の値を置かない）
key() { echo "aws_access_key_id = AKIA$(LC_ALL=C tr -dc 'A-Z2-7' </dev/urandom | head -c 16)"; }
check "競合の解消だけで入った秘密を見つける" 2 "$(scenario main "$(key)" secret)"
check "秘密のないマージは通す" 0 "$(scenario main resolved clean)"
# main で検査済みの内容を取り込むだけのマージは検査し直さない（main 側で許可した検出が PR で再び出ないように）
main_line=$(key)
check "main の既存の内容を取り込むだけのマージは通す" 0 "$(scenario "$main_line" "$main_line" inherited)"
check "octopus マージを含む PR は走査を失敗にする" 1 "$(octopus)"

exit "$fail"
