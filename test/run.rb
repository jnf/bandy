#!/usr/bin/env ruby
# A release sets $LOAD_PATH from its own generated file, no Bundler; dev uses bundle exec.
setup = File.expand_path('../vendor/bundle/bundler/setup.rb', __dir__)
require setup if File.exist?(setup)
Dir[File.join(__dir__, 'test_*.rb')].each { |f| require f }
