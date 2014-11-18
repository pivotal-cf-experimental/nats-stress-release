#!/usr/bin/env ruby

require 'dogapi'
require 'yaml'
require 'socket'
require 'thread'
require 'uri'

class Metrics
  def initialize(config)
    @name = config["name"]
    @population = config["population"]
    datadog_api_key = config["datadog_api_key"]
    @datadog = Dogapi::Client.new(datadog_api_key)
    @servers = config["nats_servers"]

    @client = case @name
              when /ruby/ then 'ruby'
              when /yagnats_og/ then 'yagnats-og'
              when /yagnats_apcera/ then 'yagnats-apcera'
              end

    @message_tally = {}
    @totals = {
      complete: 0,
      sent: 0,
      received: 0,
    }
    @counts = {
      complete: 0,
      sent: 0,
      received: 0,
    }
    @last_timestamp = Time.now
    @mutex = Mutex.new
  end

  def process(message)
    if message =~ /^received---received_publish--.*?--publish--#{@name}/
      original_msg = message[/^received---received_publish--(.*?)--(.*)/, 2]
      recepient = message[/^received---received_publish--(.*?)--(.*)/, 1]
      receipts = add_receipt(original_msg, recepient)
      if receipts.size == @population
        message_complete!(message)
      end
    elsif message =~ /^sent---publish--#{@name}/
      message_sent!
    elsif message =~ /^received---publish/
      message_received!
    end
  end

  def add_receipt(message, recepient)
    @mutex.synchronize do
      @message_tally[message] ||= []
      @message_tally[message] << recepient
      @message_tally[message].uniq!
    end
    @message_tally[message]
  end

  def incr!(bucket)
    @mutex.synchronize do
      @totals[bucket]  += 1
      @counts[bucket]  += 1
    end
  end

  def message_complete!(message)
    incr!(:complete)
    @mutex.synchronize do
      @message_tally.delete(message)
    end
  end

  def message_sent!
    incr!(:sent)
  end

  def message_received!
    incr!(:received)
  end

  def reset_messages_counter!
    @mutex.synchronize do
      @counts = {
        complete: 0,
        sent: 0,
        received: 0,
      }
    end
  end

  def seconds_passed
    Time.now - @last_timestamp
  end

  def rate(bucket)
    @counts[bucket] / seconds_passed
  end

  def total(bucket)
    @totals[bucket]
  end

  def upload
    nats_connection = `lsof -iTCP | grep 4222 | grep -v root`
    server = /(?<server>\d+\.\d+\.\d+\.\d+):4222/.match(nats_connection)[:server]
    @servers.each do |s|
      uri = URI(s)
      @datadog.emit_point("nats-stress.server-#{uri.host}", uri.host == server ? 1 : 0, host: @name, tags: ["client:#{@client}"])
    end

    @datadog.emit_point("nats-stress.msgs.complete", total(:complete), host: @name, tags: ["client:#{@client}"])
    @datadog.emit_point("nats-stress.msgs.complete_rate", rate(:complete), host: @name, tags: ["client:#{@client}"])

    @datadog.emit_point("nats-stress.msgs.sent", total(:sent), host: @name, tags: ["client:#{@client}"])
    @datadog.emit_point("nats-stress.msgs.send_rate", rate(:sent), host: @name, tags: ["client:#{@client}"])

    @datadog.emit_point("nats-stress.msgs.received", total(:received), host: @name, tags: ["client:#{@client}"])
    @datadog.emit_point("nats-stress.msgs.received_rate", rate(:received), host: @name, tags: ["client:#{@client}"])

    @last_timestamp = Time.now
    reset_messages_counter!
  rescue => e
    puts "can't upload: ", e
  end
end

conf = YAML.load_file(ARGV[0])
metrics = Metrics.new(conf)

threads = []

threads << Thread.new do
  loop do
    metrics.upload
    sleep 1
  end
end

file = conf['socket']
File.unlink(file) if File.exists?(file) && File.socket?(file)
server = UNIXServer.new(file)
loop do
  message = server.accept.read
  metrics.process(message)
end

threads.each(&:join)