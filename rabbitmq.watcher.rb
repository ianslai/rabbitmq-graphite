#!/usr/bin/env ruby
#
# Author: Jeff Vier <jeff@jeffvier.com>
# Revised extensively by Ian Lai

require 'rubygems'
require 'digest'
require 'find'
require 'json'
require 'socket'
require 'resolv'
require 'net/http'

require 'optparse'

options = {
  :prefix => Socket.gethostname,
  :interval => 10,
  :host => '127.0.0.1',
  :port => 2003,
  :queues => false,
  :rmquser => 'guest',
  :rmqpass => 'guest',
  :rmqhost => '127.0.0.1',
  :rmqport => 15672
}
OptionParser.new do |opts|
  opts.banner = "Usage: #{$0} [options]"

  opts.on('-P', '--prefix [STATSD_PREFIX]', "metric prefix (default: #{options[:prefix]})")     { |prefix|   options[:prefix] = "#{prefix}" }
  opts.on('-i', '--interval [SEC]',"reporting interval (default: #{options[:interval]})")       { |interval| options[:interval] = interval.to_i }
  opts.on('-h', '--host [HOST]',   "carbon host (default: #{options[:host]})")                  { |host|     options[:host] = host }
  opts.on('-p', '--port [PORT]',   "carbon port (default: #{options[:port]})")                  { |port|     options[:port] = port.to_i }
  opts.on('-u', '--rmquser [RABBITMQ_USER]',   "rabbitmq user (default: #{options[:rmquser]})") { |rmquser|  options[:rmquser] = rmquser }
  opts.on('-s', '--rmqpass [RABBITMQ_PASS]',   "rabbitmq pass (default: #{options[:rmqpass]})") { |rmqpass|  options[:rmqpass] = rmqpass }
  opts.on('-r', '--rmqhost [RABBITMQ_HOST]',   "rabbitmq host (default: #{options[:rmqhost]})") { |rmqhost|  options[:rmqhost] = rmqhost }
  opts.on('-b', '--rmqport [RABBITMQ_PORT]',   "rabbitmq port (default: #{options[:rmqport]})") { |rmqport|  options[:rmqport] = rmqport.to_i }
  opts.on('-q', '--[no-]queues',   "report queue metrics (default: #{options[:queues]})")       { |queues|   options[:queues] = queues }
  opts.on('-c', '--config [CONFIG_FILE]',      "optional configuration file (in JSON format)")  { |config_file|
    JSON.parse(File.read(config_file)).each do |key, value|
      key = key.to_sym

      case key
      when :interval, :port, :rmqport
        value = value.to_i
      when :queues
        value = (value.downcase == "true")
      end

      options[key] = value
    end
  }
end.parse!

################################################################################
class Graphite
  def initialize(host, port)
    @host = host
    @port = port
    @metrics = []
  end

  def add(metric, value)
    @metrics.push [metric, value]
  end

  def send()
    begin
      sock = TCPSocket.new(@host, @port)
      time = Time.now.to_i
      @metrics.each do |metric, value|
        line = ""
        sock.write("#{metric} #{value} #{time}\n")
      end
      @metrics = []
    rescue => e
      puts "TCPSocket error: #{e}"
    ensure
      sock.close if sock
    end
  end
end

################################################################################
class RabbitMqAdmin
  def initialize(options)
    @options = options
  end

  def get(uri)
    Net::HTTP.start(@options[:rmqhost], @options[:rmqport]) do |http|
      req = Net::HTTP::Get.new("/api/#{uri}")
      req.basic_auth @options[:rmquser], @options[:rmqpass]
      response = http.request(req)
      if response.kind_of? Net::HTTPSuccess
        return JSON.parse(response.body)
      else
        raise "Could not connect to RabbitMQ management API: #{response.code} #{response.message}"
      end
    end
  end
end

################################################################################
class Dumper
  def initialize(options)
    @options = options
    @admin = RabbitMqAdmin.new(options)
    @graphite = Graphite.new(options[:host], options[:port])
  end

  def overview()
    overview = @admin.get("overview")
    prefix = "#{@options[:prefix]}.overview.object_totals"
    totals = overview['object_totals']
    node = overview['node']
    @graphite.add("#{prefix}.channels", totals['channels'])
    @graphite.add("#{prefix}.connections", totals['connections'])
    @graphite.add("#{prefix}.consumers", totals['consumers'])
    @graphite.add("#{prefix}.exchanges", totals['exchanges'])
    @graphite.add("#{prefix}.queues", totals['queues'])

    system(node)
  end

  def queues()
    queues = @admin.get("queues")
    queues.each do |queue|
      if queue.key?('name')
        queue_name = queue['name'].gsub('.', '_')
        prefix = "#{@options[:prefix]}.queues.#{queue_name}"
        @graphite.add("#{prefix}.active_consumers", queue['active_consumers'])
        @graphite.add("#{prefix}.consumers", queue['consumers'])
        @graphite.add("#{prefix}.memory", queue['memory'])
        @graphite.add("#{prefix}.messages", queue['messages'])
        @graphite.add("#{prefix}.messages_ready", queue['messages_ready'])
        @graphite.add("#{prefix}.messages_unacknowledged", queue['messages_unacknowledged'])
        @graphite.add("#{prefix}.avg_egress_rate", queue['backing_queue_status']['avg_egress_rate'])   if queue['backing_queue_status']
        @graphite.add("#{prefix}.avg_ingress_rate", queue['backing_queue_status']['avg_ingress_rate']) if queue['backing_queue_status']
        if queue.key?('message_stats')
          @graphite.add("#{prefix}.ack_rate", queue['message_stats']['ack_details']['rate'])                  if queue['message_stats']['ack_details']
          @graphite.add("#{prefix}.deliver_rate", queue['message_stats']['deliver_details']['rate'])          if queue['message_stats']['deliver_details']
          @graphite.add("#{prefix}.deliver_get_rate", queue['message_stats']['deliver_get_details']['rate'])  if queue['message_stats']['deliver_get_details']
          @graphite.add("#{prefix}.publish_rate", queue['message_stats']['publish_details']['rate'])          if queue['message_stats']['publish_details']
        end
      end
    end
  end

  def send()
    @graphite.send
  end

  private
  def system(node)
    system = @admin.get("nodes/#{node}")
    prefix = "#{@options[:prefix]}.system"

    [
      'disk_free',
      'disk_free_limit',
      'fd_total',
      'fd_used',
      'mem_used',
      'mem_limit',
      'proc_total',
      'proc_used',
      'processors',
      'run_queue',
      'sockets_total',
      'sockets_used',
      'uptime',
    ].each do |stat|
      @graphite.add("#{prefix}.#{stat}", system[stat])
    end
  end
end

################################################################################
STDOUT.sync = true # don't buffer STDOUT

dumper = Dumper.new(options)

loop do
  begin
    dumper.overview
    if options[:queues]
      dumper.queues
    end
    dumper.send
  rescue
    puts $!, $@
  end

  sleep options[:interval]
end
