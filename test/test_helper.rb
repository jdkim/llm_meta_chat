ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require "webmock/minitest"

# Block real HTTP — every meta-server call must stub_request explicitly.
WebMock.disable_net_connect!(allow_localhost: true)

# Pin the meta-server base URL so WebMock can match stubs cleanly regardless
# of what credentials would have resolved to.
Rails.application.config.llm_service_base_url = "https://meta-server.invalid"

module ActiveSupport
  class TestCase
    # Parallel runs interact badly with the per-process WebMock + Rails
    # config state; keep tests single-process for now.
    # parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Temporarily replaces a class/module method for the duration of the
    # block, then restores the original (or removes the override if none
    # existed). Minitest 6 dropped `Object#stub`, so this is a small
    # local stand-in. The block receives the captured args via `value`
    # which may be either a value or a callable.
    def with_stub(klass, method, value)
      had_method = klass.singleton_class.method_defined?(method) || klass.singleton_class.private_method_defined?(method)
      original = klass.method(method) if had_method
      klass.define_singleton_method(method) do |*args, **kw|
        # Only treat true callables (Proc/Lambda/Method) as dynamic — a stub
        # value that happens to respond to :call (e.g. a returned object with
        # its own #call method) is treated as an opaque return value.
        value.is_a?(Proc) || value.is_a?(Method) ? value.call(*args, **kw) : value
      end
      yield
    ensure
      klass.singleton_class.send(:remove_method, method)
      klass.define_singleton_method(method, original) if original
    end
  end
end
