# reusable-workflows

okamyujiの全リポジトリで共有する再利用可能なGitHub Actionsワークフロー集です。品質ゲート定義（CI、セキュリティスキャン）をこのリポジトリへ一元化し、各リポジトリは呼び出しだけを持ちます。修正はここへの1コミットで全リポジトリへ伝播します。

## タグ運用ルール

- 呼び出し側は`@v1`のメジャータグで参照します。`@main`参照は作りません（作業中コミットが即座に全リポジトリへ波及するため）
- 非破壊的な修正をリリースするたびに、`v1`タグを最新コミットへ付け替えます（GitHub Actions公式アクションと同じメジャータグ慣行です）

```bash
git tag -f v1 && git push -f origin v1
```

- 破壊的変更（inputsの削除・意味変更など）のときだけ`v2`を新設し、呼び出し側を段階移行します

## 提供ワークフロー

### go-ci.yml

go vet、go build、go testを実行します。Goバージョンは未指定ならgo.modから解決します。

```yaml
name: CI
on:
  push:
    branches: [main]
  pull_request:
jobs:
  ci:
    uses: okamyuji/reusable-workflows/.github/workflows/go-ci.yml@v1
  security:
    uses: okamyuji/reusable-workflows/.github/workflows/security-scan.yml@v1
```

### rails-ci.yml

brakeman＋bundler-audit、rubocop、railsテスト、Gemfile.lock整合性検証を実行します。MySQLサービスコンテナが必要な場合は`with-mysql: true`を渡します。

lockfileジョブはGemfile.lockを`bundle lock`で再生成して差分が出たら失敗します（不要な場合は`lockfile-check: false`でオプトアウト）。不整合の主因は、Dependabot PRのGemfile.lock競合をWebエディタで手動解消した際にmain側の古いCHECKSUMSブロックが残ることです。gitはCHECKSUMSを再計算しないので、Dependabot PRの競合は手で解消せず`@dependabot recreate`をコメントしてください。

`dependabot-recreate: true`を渡すと、Dependabot PRで不整合を検出したときにlockfileジョブがそのコメントを自動投稿します（同一headへの二重投稿はしません）。呼び出し側jobに`pull-requests: write`が必要です。

```yaml
jobs:
  ci:
    permissions:
      contents: read
      pull-requests: write
    uses: okamyuji/reusable-workflows/.github/workflows/rails-ci.yml@v1
    with:
      dependabot-recreate: true
```

```yaml
jobs:
  ci:
    uses: okamyuji/reusable-workflows/.github/workflows/rails-ci.yml@v1
    with:
      with-mysql: true
      test-command: "bin/rails db:setup test test:system"
```

lint・テスト・セキュリティスキャンを自前のジョブで持つリポジトリでも、`run-lint`/`security-scan`/`run-tests`をfalseにするとlockfileガードだけを消費できます。

```yaml
jobs:
  lockfile:
    uses: okamyuji/reusable-workflows/.github/workflows/rails-ci.yml@v1
    with:
      run-lint: false
      security-scan: false
      run-tests: false
```

### node-ci.yml

パッケージマネージャ（pnpm/npm）をロックファイルから自動判定し、install、lint、typecheck、testを実行します。コマンドはpackage.jsonのscriptsに存在するものだけが走ります（`--if-present`）。

```yaml
jobs:
  ci:
    uses: okamyuji/reusable-workflows/.github/workflows/node-ci.yml@v1
    with:
      node-version: "22"
```

### rust-ci.yml

`cargo fmt --check`、`cargo clippy --all-targets -- -D warnings`、テストを順に実行するワークフローです。ツールチェーンには最新の`stable`を使います。clippyは`--locked`で実行するため、`Cargo.lock`をコミットしておく必要があります。テストコマンドの既定値は`cargo test --all-targets`です。TestcontainersなどDockerを使うテストも、`ubuntu-latest`ランナーのDockerでそのまま動きます。

```yaml
jobs:
  ci:
    uses: okamyuji/reusable-workflows/.github/workflows/rust-ci.yml@v1
  security:
    permissions:
      contents: read
      pull-requests: write
    uses: okamyuji/reusable-workflows/.github/workflows/security-scan.yml@v1
```

### dotnet-ci.yml

書式（`dotnet format`）、ビルド、ユニットテストと行カバレッジ、CRAP値、変異テスト（Stryker.NET）、文書の機械検査（`tools/doclint.sh`）、Godot本体でのE2E主要導線の走破を実行します。`Core`（Godotに依存しないC#クラスライブラリ）と`tests/Core.Tests`、`tools/doclint.sh`、`tests/e2e/`を持つ構成を前提にします。

Godot本体はGitHub Releasesの公式zipをダウンロードし、呼び出し側が渡す`godot-sha512`（そのリリースの`SHA512-SUMS.txt`に載る値）で検証してから使う仕組みです。E2Eジョブは`run-e2e: false`で止められます。

変異テストはStryker.NETの`--since`機能を使いますが、差分にC#以外のファイルが1つでも含まれると、Strykerは安全側に倒れて`Core`の全変異を対象にします。ほぼ毎回の差分にドキュメントやJSON、ワークフローファイルが混じるため、実質は`Core`全体の変異スコアに対するゲートです。閾値は`mutation-score-threshold`（既定60）で呼び出し側から調整します。

```yaml
jobs:
  ci:
    uses: okamyuji/reusable-workflows/.github/workflows/dotnet-ci.yml@v1
    with:
      godot-sha512: "1855960b27ee3ef5e66e5e228cced69d55637b24334a7411162687dcd077d8f9f645348cdb8eae984bec8135d49ed855a1e3a16476786b8bce60774fd8402d13"
  security:
    permissions:
      contents: read
      pull-requests: write
    uses: okamyuji/reusable-workflows/.github/workflows/security-scan.yml@v1
```

### security-scan.yml

gitleaksによる秘密情報スキャンです。PRでは、gitleaks CLIがPRの全コミット（`base.sha..head.sha`）を検査します。gitleaks-action@v3はPRのコミット一覧をページングせずに取得するため、31件目以降のコミットを検査できません。push起点の実行はgitleaks-action@v3を使い、必要なGITHUB_TOKENの受け渡しもこのワークフローが内蔵しています。呼び出し側で設定を忘れる心配はありません。

呼び出し側ジョブには次のpermissionsを付けます。PR起点の実行はCLIで検査するため、GitHub APIを呼びません。

```yaml
jobs:
  security:
    permissions:
      contents: read
      pull-requests: write
    uses: okamyuji/reusable-workflows/.github/workflows/security-scan.yml@v1
```

## リポジトリ固有ジョブの扱い

共通化率100%は目標ではありません。リポジトリ固有の要件（特殊なスキャン、E2E、デプロイ）はinputsで吸収しきれない場合、各リポジトリの固有ジョブとして残してください。

## ドリフト検査

`tools/check-drift.sh`が、`~/devs`配下のリポジトリがこのリポジトリの`@v1`参照を使っているか、gitleaks直接使用でGITHUB_TOKENが漏れていないかを検査します。
