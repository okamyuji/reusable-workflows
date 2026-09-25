#!/bin/sh
# check-drift.test.sh — check-drift.sh を実リポジトリのフィクスチャで検証する
# 使い方: sh tools/check-drift.test.sh（失敗があれば終了コード1）
set -eu

here=$(cd "$(dirname "$0")" && pwd)
base=$(mktemp -d)
trap 'rm -rf "$base"' EXIT

# 名前 $1 のリポジトリを作り、remote.origin.url を $2 にする。
# 中央を参照しないworkflowを置くので、対象なら NOT-UNIFIED として表示される
mkrepo() {
  mkdir -p "$base/$1/.github/workflows"
  git -C "$base/$1" init -q
  git -C "$base/$1" config remote.origin.url "$2"
  echo "name: x" > "$base/$1/.github/workflows/ci.yml"
}

nl='
'
mkrepo https-plain 'https://github.com/okamyuji/plain'
mkrepo https-git-slash 'https://tok@github.com/okamyuji/withgit.git/'
mkrepo scp 'git@github.com:okamyuji/scp.git'
mkrepo ssh 'ssh://git@github.com/okamyuji/ssh'
mkrepo query 'https://github.com/okamyuji/query?access_token=QSECRET'
mkrepo fragment 'https://github.com/okamyuji/frag.git#FSECRET'
mkrepo nl-first-ok "https://github.com/okamyuji/nlok${nl}https://NLSECRET1@evil.example/x"
mkrepo nl-first-evil "https://NLSECRET2@evil.example/x${nl}https://github.com/okamyuji/nlevil"
mkrepo extra-path 'https://github.com/okamyuji/extra/PATHSECRET'
mkrepo other-owner 'https://github.com/someone/else'

out=$(sh "$here/check-drift.sh" "$base" || true)

fail=0
# expect: 出力に $1 と完全に一致する行があること。部分一致では余分な文字の混入を見逃す
expect() { printf '%s\n' "$out" | grep -qxF "$1" || { echo "FAIL: missing line: $1"; fail=1; }; }
# reject: 出力のどこにも $1 が現れないこと。秘密値が行の一部に混ざる漏れも検出する
reject() { printf '%s\n' "$out" | grep -qF "$1" && { echo "FAIL: output contains: $1"; fail=1; } || true; }

expect 'NOT-UNIFIED okamyuji/plain'
expect 'NOT-UNIFIED okamyuji/withgit'
expect 'NOT-UNIFIED okamyuji/scp'
expect 'NOT-UNIFIED okamyuji/ssh'
expect 'NOT-UNIFIED okamyuji/query'
expect 'NOT-UNIFIED okamyuji/frag'
expect 'NOT-UNIFIED okamyuji/nlok'
for s in QSECRET FSECRET NLSECRET1 NLSECRET2 PATHSECRET evil.example nlevil someone; do reject "$s"; done
expect 'violations: 7'

[ "$fail" -eq 0 ] && echo "ok" || { printf -- '--- output\n%s\n' "$out"; exit 1; }
