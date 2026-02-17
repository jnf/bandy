#!/usr/bin/env ruby --yjit
Dir[File.join(__dir__, 'test_*.rb')].each { |f| require f }
