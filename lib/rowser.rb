$:.unshift(File.dirname(__FILE__)) unless
  $:.include?(File.dirname(__FILE__)) || $:.include?(File.expand_path(File.dirname(__FILE__)))

require 'resolv'
require 'net/http'
require 'logger'
require 'benchmark'
require 'thread'

#
# Simple Browser simulator focusing on DNS resolving behavior
#
#   It will just repeat http get of a host's path specified in arguments. This tool
#   has its own hostname resolving mechanism so that it can simulate DNS resolving behaviors
#   and the round robin mechanism of a browser. The simulations are not 100% precise, as its 
#   simulation design is based on packet (port 53 & 80) observations as a black box test by 
#   the author.
#
# Simulatable browsers are:
#    Safari 3.1.2
#        Apparently it does not have any internal DNS cache mechanism. Round robin order seems to 
#        be from top to the bottom of obtained DNS A records. Does not remember the previous
#        successful IP address out of IP addresses of DNS A records.
#    Firefox 3.0.3
#        Apparently it has an internal DNS cache mechanism with flush interval of 120 seconds. 
#        Round robin order seems to be from top to the bottom of obtained DNS A records.
#        Does not remember the previous successful IP address out of obtained DNS A records.
#    Chrome 0.3.154.9 - not ready yet
#        Apparently it has an internal DNS cache mechanism. Flush interval is unknown, however,
#        it does flush the internal cache when it fails to access all of servers of a host.
#        Round robin order is unknown, but it remembers the previous successful IP address out 
#        of obtained DNS A records (i.e. it will access the successful IP next time)
#    Internet Explorer 7.0.5730.11IC
#        Apparently it has an internal DNS cache mechanism. Flush interval is 30 minutes.
#        Round robin order is unknown, but it remembers the previous successful IP address out 
#        of obtained DNS A records (i.e. it will access the successful IP next time)
#
#    I do not want to ignore Opera, but I could not figure out how it behaves in some black box tests.
#
# Usage
#   Rowser.safari3(number of get accesses, hostname, path, get access interval, TTL value of DNS A records) {|result of one http get| block }
#   where result of one http get is an array of [true/false, an benchmark object]
#     e.g. Rowser.safari3(2, "hoge.testhost.com", "/", 3, 10) {|r| puts r.inspect }
#     e.g. Rowser.ie7(2, "hoge.testhost.com", "/", 3, 10) {|r| puts r.inspect }
#     e.g. Rowser.firefox3(2, "hoge.testhost.com", "/", 3, 10) {|r| puts r.inspect }
#

module Rowser
  VERSION = '0.0.1'

  def Rowser.safari3(number_of_run, hostname, path, sleep_time = 60, ttl = 60, &block)
    timeout_scenario = [1, 1, 2, 2, 4, 4, 8, 8, 16]
    Rowser.execute(number_of_run, hostname, path, timeout_scenario, sleep_time, 0, ttl, false, &block)
  end

  def Rowser.ie7(number_of_run, hostname, path, sleep_time = 60, ttl = 60, &block)
    timeout_scenario = [3, 6, 12]
    Rowser.execute(number_of_run, hostname, path, timeout_scenario, sleep_time, 60 * 30, ttl, true, &block)
  end

  def Rowser.firefox3(number_of_run, hostname, path, sleep_time = 60, ttl = 60, &block)
    timeout_scenario = [0.5, 1, 1, 1, 1, 1, 1, 2, 4, 8, 16, 32]
    Rowser.execute(number_of_run, hostname, path, timeout_scenario, sleep_time, 120, ttl, false, &block)
  end
  
  def Rowser.chrome(number_of_run, hostname, path, sleep_time = 60, ttl = 60, &block)
    timeout_scenario = [3, 6, 12]
    Rowser.execute(number_of_run, hostname, path, timeout_scenario, sleep_time, 0, ttl, true, true, &block)
  end

  
  def Rowser.execute(number_of_run, hostname, path, timeout_scenario, sleep_time, cache_flush, ttl, use_successful_addr = false, wise_chrome = false, &block)
    mutex = Mutex.new
    addrs = []
    simulated_os_dns_cache = Thread.new do
      if wise_chrome
        puts "get addresses only once"
        mutex.synchronize do
          addrs = get_addresses(hostname)
        end
        puts  "got addresses #{addrs.inspect}"
      else
        loop do
          mutex.synchronize do
            puts "getting addresses"
            addrs = get_addresses(hostname)
            puts "got addresses #{addrs.inspect}"
          end
          sleep ttl < cache_flush ? cache_flush : ttl
        end
      end
    end    

    results = []
    runner = Thread.new do
      i = 1
      while (i <= number_of_run)
          address_cache = []
          mutex.synchronize do
            address_cache = addrs
          end
          current_time = Time.now
          puts "========= #{i}-th try #{Time.now.to_i}=========="
          res = nil
        bench_result = Benchmark.measure {
          res = Rowser.simulate(hostname, path, timeout_scenario, address_cache)
          if wise_chrome && res[0].nil?
            puts "getting addresses again because all the servers not accessible"
            mutex.synchronize do
              addrs = Rowser.get_addresses(hostname)
              address_cache = addrs
            end            
            res = Rowser.simulate(hostname, path, timeout_scenario, address_cache)
          end
        }
        # res[1] successful address, res[2] an array of addresses
        result = [res[0].nil? ? false : true, bench_result, res[1], res[2]] 
        block.call(result)
        puts "========= #{i}-th try #{ res[0].nil? ? 'Fail' : 'Success' } #{Time.now.to_i} =========="
        results << result
        if use_successful_addr
          mutex.synchronize do
            if !res[0].nil? && addrs == address_cache
              addrs.delete_at(addrs.index(res[1]))
              addrs.push(res[1]).reverse!
            end
          end
        end
        sleep sleep_time
        i += 1
      end
      simulated_os_dns_cache.kill
    end
    
    begin
      simulated_os_dns_cache.join
      runner.join
    ensure
      simulated_os_dns_cache.kill
      runner.kill
      display_summary(results)
      results
    end
  end
  
  def Rowser.simulate(hostname, path, timeout_scenario, address_cac=nil)
    res = round_robinie_get(hostname, path, timeout_scenario, address_cac)
  end
  
  # timeout_scenario - an array of positive integers or an integer - [1,2,3] means tcp connection will timeout after 1s,
  #                   then retry connection, and then will timeout after 2 secs, then retry connection 
  #                   which will timeout in 3s
  def Rowser.round_robinie_get(hostname, path, timeout_scenario, address_cache=nil)

    timeout_scenario = timeout_scenario.is_a?(Array) ? timeout_scenario : [timeout_scenario]

    addresses = address_cache.nil? ? get_addresses(hostname) : address_cache
    res = nil
    addr = nil
    addresses.each {|address|
      addr = address
      http = Net::HTTP.new(address)
      timeout_scenario.each {|timeout|
        http.open_timeout = timeout
        http.read_timeout = timeout
        begin
          res = http.get(path)
          # puts res.header['Date']
          break
        rescue Timeout::Error
          # puts  "open timeout #{http.open_timeout} "
        rescue
          # puts "An error occurred: ",$!
        end
      }
      break if res      
    }
    puts "#{Time.now.to_i} successful #{addr} out of #{addresses.inspect}" if res
    puts "#{Time.now.to_i} failure any of #{addresses.inspect}" unless res
    [res, addr, addresses]
  end
  
  def Rowser.get_addresses(hostname)
    addresses = []
    r = Resolv::Hosts.new
    addresses = r.getaddresses(hostname)
    if addresses.empty?
      r = Resolv::DNS.new
      addresses = r.getaddresses(hostname).collect {|a| a.to_s }
    end
    
    addresses
  end
  
  def Rowser.display_summary(results)
    success_count = 0
    success_total_time = 0
    failure_total_time = 0
    results.each {|r| 
      success_count += 1 if r[0]
      failure_total_time += r[1].real unless r[0]
      success_total_time += r[1].real if r[0]        
    }
    puts "Tried: #{results.size} Success: #{success_count} Success Time: #{success_total_time} Failure Time: #{failure_total_time}"  
  end
  
#  module_function :simulate, :round_robinie_get, :get_addresses
  
  
end