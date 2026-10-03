#!/bin/sh
# semver-tag.test.sh — semver-tag.yml の run ブロックを取り出し、使い捨ての git リポジトリで検証する
# 使い方: sh tools/semver-tag.test.sh（失敗があれば終了コード1）
set -eu

here=$(cd "$(dirname "$0")" && pwd)
workflow="$here/../.github/workflows/semver-tag.yml"
base=$(mktemp -d)
trap 'rm -rf "$base"' EXIT

# workflow の run ブロックのうち、印の行に挟まれた部分を実行可能なスクリプトにする
sed -n '/# >>> semver-tag/,/# <<< semver-tag/p' "$workflow" | sed 's/^          //' > "$base/semver-tag.sh"
[ -s "$base/semver-tag.sh" ] || { echo "FAIL: semver-tag.yml から本体を取り出せない"; exit 1; }

fail=0
check() { # $1 説明 $2 期待 $3 実際
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected [$2] got [$3]"; fail=1; fi
}

# bare の remote と、それを clone した作業コピーを作る
setup() {
  rm -rf "$base/remote.git" "$base/work"
  git init -q --bare "$base/remote.git"
  git clone -q "$base/remote.git" "$base/work" 2>/dev/null
  git -C "$base/work" config user.name test
  git -C "$base/work" config user.email test@example.com
  git -C "$base/work" config tag.gpgSign false
  git -C "$base/work" config commit.gpgSign false
}
commit() { git -C "$base/work" commit -q --allow-empty -m "$1"; }
run() { (cd "$base/work" && sh "$base/semver-tag.sh" >/dev/null); }
remote_tag_of() { git -C "$base/remote.git" tag --points-at "$1" | grep -E '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' || true; }
sha_of() { git -C "$base/work" rev-parse "$1"; }

# 1. 既存タグから、commit ごとに種類に応じて上げる
setup
commit "feat: init"
git -C "$base/work" tag -a v0.1.0 -m v0.1.0
commit "fix: a";      s1=$(sha_of HEAD)
commit "feat: b";     s2=$(sha_of HEAD)
commit "docs: c";     s3=$(sha_of HEAD)
commit "feat(core)!: d"; s4=$(sha_of HEAD)
commit "chore: e

BREAKING CHANGE: x"; s5=$(sha_of HEAD)
git -C "$base/work" push -q origin HEAD:main v0.1.0
run
check "fix は patch"                  v0.1.1 "$(remote_tag_of "$s1")"
check "feat は minor"                 v0.2.0 "$(remote_tag_of "$s2")"
check "それ以外は patch"              v0.2.1 "$(remote_tag_of "$s3")"
check "! 付きは major"                v1.0.0 "$(remote_tag_of "$s4")"
check "BREAKING CHANGE は major"      v2.0.0 "$(remote_tag_of "$s5")"

# 2. もう一度動かしても新しいタグは付かない
before=$(git -C "$base/remote.git" tag | wc -l)
run
check "再実行でタグが増えない" "$before" "$(git -C "$base/remote.git" tag | wc -l)"

# 3. タグが1つも無いリポジトリは 0.0.0 から数える
setup
commit "feat: first"; t1=$(sha_of HEAD)
commit "fix: second"; t2=$(sha_of HEAD)
git -C "$base/work" push -q origin HEAD:main
run
check "タグ無しの最初の feat" v0.1.0 "$(remote_tag_of "$t1")"
check "続く fix"              v0.1.1 "$(remote_tag_of "$t2")"

# 4. commit メッセージの中身はコマンドとして実行されない
setup
commit "feat: base"
git -C "$base/work" tag -a v1.0.0 -m v1.0.0
# shellcheck disable=SC2016
commit 'fix: $(touch pwned) `touch pwned2`'; u1=$(sha_of HEAD)
git -C "$base/work" push -q origin HEAD:main v1.0.0
run
check "メッセージ由来のコマンドを実行しない" "no" "$( [ -e "$base/work/pwned" ] || [ -e "$base/work/pwned2" ] && echo yes || echo no)"
check "そのcommitも patch で付く" v1.0.1 "$(remote_tag_of "$u1")"

# 5. vX.Y.Z の形でないタグ（rc など）は基準に使わない
setup
commit "feat: base"
git -C "$base/work" tag -a v1.0.0 -m v1.0.0
commit "fix: x"; r1=$(sha_of HEAD)
git -C "$base/work" tag -a v1.2.3-rc1 -m rc
commit "fix: y"; r2=$(sha_of HEAD)
git -C "$base/work" push -q origin HEAD:main v1.0.0 v1.2.3-rc1
run
check "rc タグを無視して続きを付ける" v1.0.1 "$(remote_tag_of "$r1")"
check "その次も続けて付ける"           v1.0.2 "$(remote_tag_of "$r2")"

# 6. 先頭が 0 の版番号のタグ（v1.0.08）は基準に使わない（8進数として算術式が止まるため）
setup
commit "feat: base"
git -C "$base/work" tag -a v1.0.0 -m v1.0.0
commit "fix: x"; z1=$(sha_of HEAD)
git -C "$base/work" tag -a v1.0.08 -m bad
git -C "$base/work" push -q origin HEAD:main v1.0.0 v1.0.08
run
check "先頭0のタグを無視して付ける" v1.0.1 "$(remote_tag_of "$z1")"

# 7. 日付が前後した分岐とマージでも、祖先から順に付ける
setup
commit "feat: base"
git -C "$base/work" tag -a v1.0.0 -m v1.0.0
git -C "$base/work" switch -q -c side
GIT_COMMITTER_DATE='2030-01-01T00:00:00Z' git -C "$base/work" commit -q --allow-empty -m "fix: parent"; o1=$(sha_of HEAD)
GIT_COMMITTER_DATE='2020-01-01T00:00:00Z' git -C "$base/work" commit -q --allow-empty -m "fix: child"; o2=$(sha_of HEAD)
git -C "$base/work" switch -q -
GIT_COMMITTER_DATE='2025-01-01T00:00:00Z' git -C "$base/work" commit -q --allow-empty -m "fix: main"
git -C "$base/work" merge -q --no-ff -m "chore: merge" side
git -C "$base/work" push -q origin HEAD:main v1.0.0
run
p=$(remote_tag_of "$o1" | sed 's/^v1\.0\.//'); c=$(remote_tag_of "$o2" | sed 's/^v1\.0\.//')
check "祖先の番号が子より小さい" yes "$( [ -n "$p" ] && [ -n "$c" ] && [ "$p" -lt "$c" ] && echo yes || echo no)"

exit $fail
