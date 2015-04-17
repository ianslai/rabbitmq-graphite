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
  :queues => false,                # Whether to report detailed metrics for each queue/exchange
  :auto_delete_queues => false,    # Whether to include queues that are configured as auto-delete
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
      when :queues, :auto_delete_queues
        value = (value == true) || (value.to_s.downcase == "true")
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
    node = overview['node']

    object_totals(overview)
    message_stats(overview)
    queue_totals(overview)
    system(node)
  end

  def object_totals(overview)
    prefix = "#{@options[:prefix]}.overview.object_totals"
    totals = overview['object_totals']

    extract_stats(totals, prefix, ['channels', 'connections', 'consumers', 'exchanges', 'queues'])
  end

  def message_stats(overview)
    prefix = "#{@options[:prefix]}.overview.message_stats"
    stats = overview['message_stats']
    keys = [
      'publish',
      'publish_in',
      'publish_out',
      'confirm',
      'deliver',
      'deliver_noack',
      'get',
      'get_noack',
      'deliver_get',
      'redeliver',
      'return',
    ]
    extract_details(stats, prefix, keys)
  end

  def queue_totals(overview)
    prefix = "#{@options[:prefix]}.overview.queue_totals"
    stats = overview['queue_totals']
    keys = [
      'messages',
      'messages_ready',
      'messages_unacknowledged',
    ]
    extract_details(stats, prefix, keys)
  end

  def queues()
    queues = @admin.get("queues")
    queues.each do |queue|
      next unless queue.key?('name')
      next if (queue['auto_delete'] && !@options[:auto_delete_queues])
      prefix = object_prefix("queues", queue['name'])

      summary = [
        'active_consumers',
        'consumers',
        'memory',
        'messages',
        'messages_ready',
        'messages_unacknowledged',
      ]
      extract_stats(queue, prefix, summary)

      backing_queue_status = queue['backing_queue_status']
      if backing_queue_status
        extract_stats(backing_queue_status, prefix, ['avg_egress_rate', 'avg_ingress_rate'])
      end

      message_stats = queue['message_stats']
      if message_stats
        extract_details(message_stats, prefix, ['ack', 'deliver_get', 'deliver', 'publish'])
      end
    end
  end

  def exchanges()
    exchanges = @admin.get("exchanges")
    exchanges.each do |exchange|
      next unless exchange.key?('name')
      prefix = object_prefix("exchanges", exchange['name'])

      message_stats = exchange['message_stats']
      if message_stats
        extract_details(message_stats, prefix, ['confirm', 'publish_in', 'publish_out'])
      end
    end
  end

  def send()
    @graphite.send
  end

  private

  def object_prefix(type, name)
    name = name.empty? ? '_default' : name.gsub('.', '_')
    "#{@options[:prefix]}.#{type}.#{name}"
  end

  def extract_stats(stats, prefix, keys)
    keys.each do |stat|
      @graphite.add("#{prefix}.#{stat}", stats[stat] || 0)
    end
  end

  def extract_details(stats, prefix, keys)
    keys.each do |stat|
      count = stats[stat] || 0
      details = "#{stat}_details"
      rate = (stats[details] ? stats[details]['rate'] : nil) || 0

      @graphite.add("#{prefix}.#{stat}.count", count)
      @graphite.add("#{prefix}.#{stat}.rate", rate)
    end
  end

  def system(node)
    system = @admin.get("nodes/#{node}")
    prefix = "#{@options[:prefix]}.system"

    keys = [
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
    ]
    extract_stats(system, prefix, keys)
  end

  # Wrap each set of stats in a begin/rescue so we can safely skip those with errors
  # In particular, system stats requires not just "management" permissions, but also
  # "monitoring" or above.
  def self.wrap_error_handling(*method_names)
    method_names.each do |method_name|
      old_method = instance_method(method_name)
      define_method(method_name) do |*args|
        begin
          old_method.bind(self).call(*args)
        rescue
          puts $!, $@
        end
      end
    end
  end

  wrap_error_handling :overview, :object_totals, :message_stats, :queues, :system
  wrap_error_handling :send
end

################################################################################
STDOUT.sync = true # don't buffer STDOUT

dumper = Dumper.new(options)

loop do
  begin
    dumper.overview
    if options[:queues]
      dumper.queues
      dumper.exchanges
    end
    dumper.send
  rescue
    puts $!, $@
  end

  sleep options[:interval]
end
