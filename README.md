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

brakeman＋bundler-audit、rubocop、railsテストを実行します。MySQLサービスコンテナが必要な場合は`with-mysql: true`を渡します。

```yaml
jobs:
  ci:
    uses: okamyuji/reusable-workflows/.github/workflows/rails-ci.yml@v1
    with:
      with-mysql: true
      test-command: "bin/rails db:setup test test:system"
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

### security-scan.yml

gitleaks/gitleaks-action@v3による秘密情報スキャンです。PR起点の実行に必要なGITHUB_TOKENの受け渡しを内蔵しているため、呼び出し側での設定漏れが起きません。

呼び出し側ジョブには次のpermissionsが必要です。トークン権限が読み取り専用のリポジトリでは、これが無いとPRコミット一覧の取得が403（Resource not accessible by integration）で失敗します。

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
