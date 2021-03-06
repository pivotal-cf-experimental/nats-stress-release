require 'socket'
require "net/http"

class NATSStressor
  def initialize(client, logger, name, payload_size, population, api_key, storage_file)
    @client = client
    @logger = logger
    @name = name
    @payload_size = payload_size
    @send_counter = 0
    @recv_counter = 0
    @api_key = api_key
    @storage_file = storage_file
  end

  def start
    @client.subscribe(">") do |message, reply, subject|
      @recv_counter += 1
      # communicate_metric("received---" + message)
      # if message =~ /^publish--/
      #   # @client.publish("ruby.publish", "received_publish--#{@name}--#{message}")
      # end
    end
  end

  def perform_interactions
    publish_msg = "publish--#{@name}--#{@msg_counter}--" + "."*@payload_size

    @client.publish("ruby.publish", publish_msg)
    # communicate_metric("sent---" + publish_msg)

    # File.write(@storage_file, JSON.pretty_generate(@message_tally))
    @send_counter += 1
  end

  def communicate_metric(message)
      http = Net::HTTP.new('127.0.0.1', 4568)
      request = Net::HTTP::Post.new('/messages-new')
      recv_copy = @recv_counter.to_s
      @recv_counter = 0
      send_copy = @send_counter.to_s
      @send_counter = 0
      request.body = recv_copy + ", " + send_copy
      http.request(request)
  rescue Errno::ECONNREFUSED => e
    @logger.info("couldn't reach metrics")
    # puts e.backtrace
  end
end
