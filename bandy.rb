#!/usr/bin/env ruby --yjit

# dependencies
require 'dotenv/load'
require 'date'
require 'logger'
require 'httparty'
require 'nokogiri'
require 'json'
require 'tempfile'
require 'pstore' # https://ruby-doc.org/3.4.1/stdlibs/pstore/PStore.html

DEBUG = true

# api classes
require_relative './api/baseapi.rb'

# core scripts
Dir[File.join(__dir__, 'scripts', '*.rb')].each { |file| require file }

# State machine pipeline:
# :seen → :preorder/:ready → :queued → :downloaded → :unpacked

# add any new collection items to the db (:seen)
SyncCollection.new.run

# enrich 'seen' items with metadata (:seen → :ready or :preorder)
EnrichItems.new.run

# queue ready items for download (:ready → :queued, batch limited)
QueueItems.new.run

# download queued items (:queued → :downloaded, with freshness check)
DownloadItems.new.run

# unpack downloaded items (:downloaded → :unpacked)
UnpackItems.new.run
