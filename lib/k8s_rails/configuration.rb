# frozen_string_literal: true

module K8sRails
  # Settings held by `K8sRails.configure` (design §5.1).
  #
  #   K8sRails.configure do |config|
  #     config.namespace = ENV.fetch("K8S_NAMESPACE", "default")
  #   end
  #
  # This class is pure data: it never touches the network or kruby.
  class Configuration
    # CRD 宣言が namespace 未指定時のデフォルト。
    attr_accessor :namespace

    # Kubernetes::Configuration インスタンス。省略時は default_config の自動
    # 検出（kruby 1.36.x の実装順: KUBECONFIG → ~/.kube/config → in-cluster。
    # kruby 更新時にこの順序が変更されていないか loader を再確認すること）。
    # 認証を上書きする場合に指定する。
    attr_accessor :connection

    # テスト専用（§5.1）。CustomObjectsApi と同型の 8 メソッド
    # （namespaced 4 メソッド `get_namespaced_custom_object` 等 ＋ cluster 4
    # メソッド `get_cluster_custom_object` 等）を実装した素の
    # オブジェクトを指定すると、Client.build は接続解決をスキープしてこれを
    # 内部トランスポートとして使う（namespaced 宣言だけを使う場合は
    # namespaced 4 メソッドのみの実装で足りる）。
    attr_accessor :api_client

    # ActiveSupport::Notifications での計測の ON/OFF（§8。M3 で実装）。
    attr_accessor :instrumentation

    def initialize
      @namespace = "default"
      @connection = nil
      @api_client = nil
      @instrumentation = true
    end
  end
end
