#!/usr/bin/env ruby

# The outcome line is written by an at_exit handler, so it goes in before anything
# that can fail to load. outcome.rb is core Ruby only for the same reason.
require_relative 'scripts/outcome'
Outcome.install

# dependencies
# A release sets $LOAD_PATH from its own generated file, no Bundler; dev uses bundle exec.
setup = File.expand_path('vendor/bundle/bundler/setup.rb', __dir__)
require setup if File.exist?(setup)
require 'dotenv/load'
require 'date'
require 'logger'
require 'httparty'
require 'nokogiri'
require 'json'
require 'tempfile'
require 'pstore' # https://ruby-doc.org/3.4.1/stdlibs/pstore/PStore.html

DEBUG = ENV.fetch('DEBUG', 'false') == 'true'

# api classes
require_relative './api/baseapi.rb'

# core scripts
Dir[File.join(__dir__, 'scripts', '*.rb')].each { |file| require file }

# State machine pipeline:
# :seen → :preorder/:ready → :queued → :downloaded → :unpacked

# Per-item failures don't stop a stage, so the run's counts are what changed in the
# store between here and the end. A store that can't be read costs the counts, not the run.
store = PStore.new('./store/collection_items.pstore')
before = Outcome.snapshot(store)

# add any new collection items to the db (:seen)
Outcome.stage = 'sync_collection'
SyncCollection.new.run

# enrich 'seen' items with metadata (:seen → :ready or :preorder)
Outcome.stage = 'enrich_items'
EnrichItems.new.run

# queue ready items for download (:ready → :queued, batch limited)
Outcome.stage = 'queue_items'
QueueItems.new.run

# download queued items (:queued → :downloaded, with freshness check)
Outcome.stage = 'download_items'
DownloadItems.new.run

# unpack downloaded items (:downloaded → :unpacked)
Outcome.stage = 'unpack_items'
UnpackItems.new.run

Outcome.succeed(Outcome.counts(before, Outcome.snapshot(store)))
