require 'wreckem/entity_manager'

module Wreckem
  # The two storage backends that must behave identically.  SequelStore is the
  # production default (SQL/JDBC); MemoryStore is the in-memory implementation.
  ALL_BACKENDS = [Wreckem::SequelStore, Wreckem::MemoryStore].freeze

  # Which backend a *zero-argument* EntityManager.new should build.  The
  # existing specs all call `Wreckem::EntityManager.new` with no argument --
  # some of them inside example bodies, not just in a `before` hook -- so the
  # cleanest way to run every one of them against both backends without
  # touching their bodies is to make the no-arg default resolve to a value the
  # spec harness controls per-example.  Stored per-thread so nothing leaks
  # between examples.
  DEFAULT_BACKEND = Wreckem::SequelStore

  class << self
    def current_backend
      Thread.current[:wreckem_backend] || DEFAULT_BACKEND
    end

    def current_backend=(klass)
      Thread.current[:wreckem_backend] = klass
    end

    def reset_backend!
      Thread.current[:wreckem_backend] = DEFAULT_BACKEND
    end
  end

  class EntityManager
    # Preserve the real constructor and give the zero-arg form a harness-driven
    # default.  An explicitly supplied backend (used by the memory-only
    # persistence spec) still wins.
    alias_method :initialize_with_explicit_backend, :initialize

    def initialize(backend = Wreckem.current_backend.new)
      initialize_with_explicit_backend(backend)
    end
  end
end

# DSL helper made available inside every example group (see config.extend).
#
#   describe Thing do
#     for_each_backend do
#       before { @em = Wreckem::EntityManager.new }   # <- uses the selected backend
#       it "..." { ... }
#     end
#   end
#
# runs the wrapped examples once per backend, each in its own labelled
# sub-context so a failure names the backend it came from, e.g.
#   "Thing [MemoryStore] should ...".
module BackendParameterization
  def for_each_backend(&block)
    Wreckem::ALL_BACKENDS.each do |backend_class|
      short = backend_class.name.split('::').last
      context "[#{short}]" do
        # Registered before the wrapped body, so it runs before the body's own
        # `before { @em = EntityManager.new }` hook selects the backend.
        before { Wreckem.current_backend = backend_class }

        # Exposed for the rare example that needs to know which backend it is on.
        let(:current_backend_class) { backend_class }

        class_exec(&block)
      end
    end
  end
end

RSpec.configure do |config|
  # The existing specs freely mix `should` and `expect`; enable both explicitly
  # to silence the monkey-patch deprecation without changing any assertion.
  config.expect_with(:rspec) { |c| c.syntax = [:should, :expect] }

  config.extend BackendParameterization

  # Guarantee no backend selection leaks from a parameterized example into a
  # plain (non-parameterized) one such as state_machine_spec.
  config.before(:each) { Wreckem.reset_backend! }

  # SequelStore persists to a `db` file in the working directory.  `#destroy`
  # drops its tables at the end of every example, but a crashed process (or a
  # stray script) can leave a populated `db` behind that would silently
  # contaminate the FIRST SequelStore example of the next run.  Removing it
  # before the suite and before every example makes each SequelStore-backed
  # example start from a guaranteed-clean database.  MemoryStore examples do
  # not touch this file, and the memory persistence spec uses its own temp dir.
  def (Wreckem).remove_stale_db!
    File.delete('db') if File.exist?('db')
  end

  config.before(:suite) { Wreckem.remove_stale_db! }
  config.before(:each)  { Wreckem.remove_stale_db! }
  config.after(:suite)  { Wreckem.remove_stale_db! }
end
