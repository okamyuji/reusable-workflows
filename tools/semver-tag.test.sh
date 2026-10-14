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
run() { (cd "$base/work" && DEFAULT_BRANCH=main sh "$base/semver-tag.sh" >/dev/null); }
remote_tag_of() { git -C "$base/remote.git" tag --points-at "$1" | grep -E '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' || true; }
sha_of() { git -C "$base/work" rev-parse "$1"; }

# 1. 前のタグからの commit すべてを見て、いちばん大きい上げ幅で先頭にだけ付ける
setup
commit "feat: init"
git -C "$base/work" tag -a v0.1.0 -m v0.1.0
commit "fix: a";  a1=$(sha_of HEAD)
commit "feat: b"
commit "docs: c"; a3=$(sha_of HEAD)
git -C "$base/work" push -q origin HEAD:main v0.1.0
run
check "feat を含む範囲は minor で先頭に付く" v0.2.0 "$(remote_tag_of "$a3")"
check "途中の commit には付けない"           ""     "$(remote_tag_of "$a1")"
commit "fix: d"
commit "docs: e"; b2=$(sha_of HEAD)
git -C "$base/work" push -q origin HEAD:main
run
check "fix と docs だけの範囲は patch" v0.2.1 "$(remote_tag_of "$b2")"
commit "fix: f"
commit "feat(core)!: g"
commit "feat: h"; c3=$(sha_of HEAD)
git -C "$base/work" push -q origin HEAD:main
run
check "! 付きを含む範囲は major" v1.0.0 "$(remote_tag_of "$c3")"
commit "chore: i

BREAKING CHANGE: x"; d1=$(sha_of HEAD)
git -C "$base/work" push -q origin HEAD:main
run
check "本文の BREAKING CHANGE は major" v2.0.0 "$(remote_tag_of "$d1")"

# 2. もう一度動かしても新しいタグは付かない
before=$(git -C "$base/remote.git" tag | wc -l)
run
check "再実行でタグが増えない" "$before" "$(git -C "$base/remote.git" tag | wc -l)"

# 3. タグが1つも無いリポジトリは 0.0.0 から数える
setup
commit "feat: first"
commit "fix: second"; t2=$(sha_of HEAD)
git -C "$base/work" push -q origin HEAD:main
run
check "タグ無しで feat を含む範囲" v0.1.0 "$(remote_tag_of "$t2")"
setup
commit "fix: only"; t3=$(sha_of HEAD)
git -C "$base/work" push -q origin HEAD:main
run
check "タグ無しで fix だけの範囲" v0.0.1 "$(remote_tag_of "$t3")"

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
commit "fix: x"
git -C "$base/work" tag -a v1.2.3-rc1 -m rc
commit "fix: y"; r2=$(sha_of HEAD)
git -C "$base/work" push -q origin HEAD:main v1.0.0 v1.2.3-rc1
run
check "rc タグを無視して v1.0.0 の続きを付ける" v1.0.1 "$(remote_tag_of "$r2")"

# 6. 先頭が 0 の版番号のタグ（v1.0.08）は基準に使わない（8進数として算術式が止まるため）
setup
commit "feat: base"
git -C "$base/work" tag -a v1.0.0 -m v1.0.0
commit "fix: x"; z1=$(sha_of HEAD)
git -C "$base/work" tag -a v1.0.08 -m bad
git -C "$base/work" push -q origin HEAD:main v1.0.0 v1.0.08
run
check "先頭0のタグを無視して付ける" v1.0.1 "$(remote_tag_of "$z1")"

# 7. merge で入った分岐の commit も上げ幅に数え、merge commit に付ける
setup
commit "feat: base"
git -C "$base/work" tag -a v1.0.0 -m v1.0.0
git -C "$base/work" switch -q -c side
commit "feat: on a branch"
git -C "$base/work" switch -q -
commit "fix: on main"
git -C "$base/work" merge -q --no-ff -m "Merge pull request #1" side; m1=$(sha_of HEAD)
git -C "$base/work" push -q origin HEAD:main v1.0.0
run
check "分岐の feat を数えて merge commit に付ける" v1.1.0 "$(remote_tag_of "$m1")"

# 8. 既定ブランチが先へ進んでいたら付けない（後の push の実行がまとめて付ける）
setup
commit "feat: base"
git -C "$base/work" tag -a v1.0.0 -m v1.0.0
commit "fix: older push"; n1=$(sha_of HEAD)
commit "fix: newer push"
git -C "$base/work" push -q origin HEAD:main v1.0.0
git -C "$base/work" checkout -q "$n1"
run
check "先へ進んだ main の古い commit には付けない" "" "$(remote_tag_of "$n1")"
check "タグを1つも増やさない" 1 "$(git -C "$base/remote.git" tag | wc -l | tr -d ' ')"

# 9. 既定ブランチの先頭を読めないときは、付けずに成功とせず失敗する
setup
commit "fix: unreachable"
git -C "$base/work" push -q origin HEAD:main
git -C "$base/work" remote set-url origin "$base/missing.git"
check "リモートを読めなければ失敗する" failed "$(run 2>/dev/null && echo succeeded || echo failed)"

exit $fail
