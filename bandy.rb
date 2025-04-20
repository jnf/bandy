# dependencies
require 'dotenv/load'
require 'date'
require 'logger'
require 'httparty'
require 'nokogiri'
require 'json'
require 'pstore' # https://ruby-doc.org/3.4.1/stdlibs/pstore/PStore.html
require 'pry'

# api classes
require_relative './api/baseapi.rb'

# core scripts
Dir[File.join(__dir__, 'scripts', '*.rb')].each { |file| require file }

# add any new collection items to the db
SyncCollection.new(debug: true).run

# enrich any 'seen' items
EnrichItems.new(debug: true).run

# check for new downloadables 
# could be either new collection items or pre-releases being released

# download new downloadables

# unpack new unpackables
