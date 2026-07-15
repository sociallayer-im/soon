ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

Dir[Rails.root.join("test/support/**/*.rb")].each { |f| require f }

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # No fixtures — soon/'s TSID string PKs are assigned by an ApplicationRecord
    # before_create callback that fixture loading (raw INSERT) bypasses. Use
    # FactoryHelpers instead (test/support/factory_helpers.rb).

    include FactoryHelpers
    include AuthHelper

    # Add more helper methods to be used by all tests here...
  end
end
