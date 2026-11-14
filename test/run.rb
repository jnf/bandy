#!/usr/bin/env ruby
require 'bundler/setup'
Dir[File.join(__dir__, 'test_*.rb')].each { |f| require f }
