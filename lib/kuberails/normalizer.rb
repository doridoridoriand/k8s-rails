# frozen_string_literal: true

module KubeRails
  # Pure-Ruby deep key stringification for API responses (K2, design §5.2).
  #
  # kruby deserializes JSON into Hash/Array with SYMBOL keys. Our public API
  # contract (and the apps that consume it) expect STRING keys, so every
  # response is passed through here before returning.
  #
  # This is deliberately NOT ActiveSupport's `deep_stringify_keys`: the gem
  # must also work in non-Rails environments (cron scripts, etc.) where
  # ActiveSupport is absent. No AS dependency.
  module Normalizer
    module_function

    # Return a copy of +value+ with all Hash keys converted to strings.
    # Non-Hash/Array values are returned unchanged (strings, numbers, nil,
    # Time objects, ...).
    def stringify(value)
      deep_stringify_keys(value)
    end

    def deep_stringify_keys(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, entry), acc|
          acc[key.to_s] = deep_stringify_keys(entry)
        end
      when Array
        value.map { |entry| deep_stringify_keys(entry) }
      else
        value
      end
    end
  end
end
