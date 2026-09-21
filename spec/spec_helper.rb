# frozen_string_literal: true

require "k8s-rails"

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.syntax = :expect
  end
  config.disable_monkey_patching!
  config.order = :random
  Dir[File.expand_path("support/**/*.rb", __dir__)].sort.each { |f| require f }
  Kernel.srand config.seed
end
