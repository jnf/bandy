#!/usr/bin/env ruby

# dependencies
require 'dotenv/load'
require 'date'
require 'logger'
require 'httparty'
require 'nokogiri'
require 'json'
require 'pstore' # https://ruby-doc.org/3.4.1/stdlibs/pstore/PStore.html
require 'pry'

DEBUG = true

# api classes
require_relative './api/baseapi.rb'

# core scripts
Dir[File.join(__dir__, 'scripts', '*.rb')].each { |file| require file }

# add any new collection items to the db
SyncCollection.new.run

# enrich any 'seen' items
EnrichItems.new.run

# check for new downloadables 
# DownloadItems.new.run
# could be either new collection items or pre-releases being released

# download new downloadables

# unpack new unpackables
