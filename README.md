# kuberails

Rails アプリが Kubernetes API・CRD を扱う際の**接続・CRD アクセス・障害処理の規約層**を
gem として提供する。（設計書: [docs/design.md](docs/design.md), KBR-DESIGN-001）

> **M0（gem 骨子）段階**。設定・CRD 宣言・Resource の API は M1–M3 で実装予定です。

## 利用方法（M0 では `require "kuberails"` ができるのみ）

```ruby
require "kuberails"
KubeRails::VERSION # => "0.1.0"
```

## 開発

```
bundle install
bundle exec rake   # rspec + rubocop
```

- Ruby: >= 3.2（.ruby-version で 3.3.8、immerse と同一）
- kruby: `~> 1.36.0`（`~> 1.36` 形式は 1.37 以降を許容するため使用しない、design.md §6）

## License

MIT（[LICENSE](LICENSE)）
