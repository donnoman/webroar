# WebROaR - Ruby Application Server - http://webroar.in/
# Copyright (C) 2009  Goonj LLC
#
# This file is part of WebROaR.
#
# WebROaR is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# WebROaR is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with WebROaR.  If not, see <http://www.gnu.org/licenses/>.

require File.expand_path(File.join(WEBROAR_ROOT,'src','ruby_lib','mailer','smtpmail'))

include Email

module Webroar
  module Analyzer
    class MessageAnalyzer
      attr_reader :sampling_rate
      attr_accessor :application_samples, :url_samples
      MAX_TRIAL = 3
      def initialize(reader, analyzer, sampling_rate = 1)
        @message_reader = reader
        @resources_analyzer = analyzer
        # Keeping application name and its id in memory. Useful in creating sample for the application without querying database.
        @apps = Hash.new
        @sampling_rate = sampling_rate * 60 # rate in seconds
        # @applicatoin_sample is a hash having app_id as key and sample for respective application as value.
        # Sample is an Array having two items.
        # First item is wall_time to determine sampling period in conjuction with sampling_rate.
        # Second item is again an array having summarized value for the sampling period. Array contains total_spent_time, db_time, rendering_time and no_of_requests
        @application_samples = Hash.new
        # @url_sample is hash having app_id as key and hash of url sample for that application as value.
        # Hash of url sample has url as key and sample for that url as value.
        # Sample is an Array having two items.
        # First item is wall_time to determine sampling period in conjuction with sampling_rate.
        # Second item is again an array having summarized value for the sampling period. Array contains total_spent_time, db_time, rendering_time, no_of_requests and hash of db breakup time for a particular url.
        @url_samples = Hash.new
        load_apps
      end
      
      def load_apps
        apps = App.find(:all,:select => "id, name")
        apps = App.find(:all,:select => "id, name")
        apps.each do |app|
          @apps[app.name] = app.id
          @application_samples[app.id] = Array.new
          @url_samples[app.id] = Hash.new
        end
      end
      
      # This method keep on executing until message queue become empty.
      def process_messages
        begin
          # return on getting nil from @message_reader.read()
          item = @message_reader.read()
          #p item
          while item
            wall_time = item[:wall_time]
            message_type = item[:message_type]
            case message_type
            when "url_metric"
              # determining different component of measurement and giving it to AppTimeSample and UrlTimeSample.
              app_name = item[:app_name]
              unless app_id = @apps[app_name]
                #TODO: Here chances of race condition in record creation with ResourceAnalyzer#set_pid
                # Creating an Application as its not in our database.
                app = App.find(:first, :conditions=>["name = ?", app_name])
                if app
                  app_id = app.id
                else
                  app = App.create({:name => app_name})
                  app_id = app.id
                end
                @apps[app_name] = app_id
                @application_samples[app_id] = Array.new
                @url_samples[app_id] = Hash.new
              end
              url = item[:controller_action].shift
              url = url << "/" << item[:controller_action].shift
              total_spent_time =  item[:controller_action].shift
              rendering_time =  item[:rendering]
              db_time = 0
              db_time_breakup = Hash.new
              item[:database].each do |key1, value1|
                value1.each do |key2, value2|
                  db_time = db_time + value2
                  mn = "#{key2}.#{key1}"
                  db_time_breakup[mn] = value2
                end
              end
              #puts "app_id=#{app_id},total_spent_time=#{total_spent_time},wall_time=#{wall_time}"
              begin
                AppTimeSample.add_to_sample(self, app_id, total_spent_time, db_time, rendering_time, wall_time)
                UrlTimeSample.add_to_sample(self, app_id, url, total_spent_time, db_time, rendering_time, db_time_breakup, wall_time)
              rescue Exception => e
                Logger.error(e)
                Logger.error(e.backtrace.join("\n"))
              end            
            end  # case message_type
            item = @message_reader.read()
          end # while item
        rescue Exception => e
          Logger.error(e)
          Logger.error(e.backtrace.join("\n"))
          return
        end
      end #process messages
      
      # @application_samples and @url_samples contains at the most one sample and that is for current sampling period.
      # This method selects and writes all the samples for which sampling period has been passed.
      # Usually this method gets called at interval of 60 seconds.
      def process_stale_samples
        begin
          AppTimeSample.write_stale_samples(self)
          UrlTimeSample.write_stale_samples(self)
        rescue Exception => e
          Logger.error(e)
          Logger.error(e.backtrace.join("\n"))
        end
      end # process_stale_samples
      
      def process_pid
        item = @message_reader.read_pid()        
        while item    
          item = item.split(/:/)
          # Registering pid for application. Useful in monitoring the resources used by that application.
          # Usually called when new worker is created.
          @resources_analyzer.set_pid(item[1].to_i, item[0])        
          item = @message_reader.read_pid()
        end # while item
      end
      
      # This method writes all @application_samples and @url_samples into database.
      # Usually called at time of shutdown.
      def write_all_samples
        begin
          AppTimeSample.write_all_samples(self)
          UrlTimeSample.write_all_samples(self)
        rescue Exception => e
          Logger.error(e)
          Logger.error(e.backtrace.join("\n"))
        end
      end
      
      def process_exceptions
        begin 
          exception_hash=@message_reader.read_exception()
          from,recipients,mail_configuration=Email.mail_settings
          while exception_hash
            if exception_hash[:app_name]
              app_name = exception_hash[:app_name]
              trial = 0
              begin
                app = App.find(:first, :conditions=>["name = ?", app_name])
              rescue ActiveRecord::StatementInvalid => e
                if trial < MAX_TRIAL
                  trial += 1
                  Logger.info "Exception entry App.find - Database is busy try no #{trial}"
                  sleep(2)          
                  retry
                end
                Logger.info("Exception entry App.find failed.")
                Logger.error(e)
                Logger.error(e.backtrace.join("\n"))                
              rescue Exception => e
                Logger.error(e) 
                Logger.error(e.backtrace.join("\n"))
                if trial < 1
                  trial += 1
                  sleep(2)
                  Logger.info"Retrying..."
                  retry
                end
                Logger.info("Exception entry App.find failed.")
              end   
              app_id = app.id if app
              if app_name.strip != "Admin Panel"
                status=1
                trial = 0
                begin
                  exception=AppException.find(:first,:conditions=>["exception_message=? and app_id=?",exception_hash[:exception_message],app_id])
                rescue ActiveRecord::StatementInvalid => e
                  if trial < MAX_TRIAL
                    trial += 1
                    Logger.info "Exception entry AppException.find - Database is busy try no #{trial}"
                    sleep(2)          
                    retry
                  end
                  Logger.info("Exception entry AppException.find failed.")
                  Logger.error(e)
                  Logger.error(e.backtrace.join("\n"))                
                rescue Exception => e
                  Logger.error(e) 
                  Logger.error(e.backtrace.join("\n"))
                  if trial < 1
                    trial += 1
                    sleep(2)
                    Logger.info"Retrying..."
                    retry
                  end
                  Logger.info("Exception entry AppException.find failed.")
                end
                if exception 
                  if exception.exception_status.to_i==2
                    status=2
                  elsif exception.exception_status.to_i==1     
                    status=1
                  else
                    trial = 0
                    begin     
                      exceptions=AppException.find(:all,:conditions=>["exception_message=? and app_id=?",exception_hash[:exception_message],app_id])
                    rescue ActiveRecord::StatementInvalid => e
                      if trial < MAX_TRIAL
                        trial += 1
                        Logger.info "Exception entry AppException.find - Database is busy try no #{trial}"
                        sleep(2)          
                        retry
                      end
                      Logger.info("Exception entry AppException.find failed.")
                      Logger.error(e)
                      Logger.error(e.backtrace.join("\n"))                
                    rescue Exception => e
                      Logger.error(e) 
                      Logger.error(e.backtrace.join("\n"))
                      if trial < 1
                        trial += 1
                        sleep(2)
                        Logger.info"Retrying..."
                        retry
                      end
                      Logger.info("Exception entry AppException.find failed.")
                    end
                    exceptions.each do |exception|
                      exception.update_attribute(:exception_status,1)
                    end if exceptions
                    status=1
                  end
                end
                trial = 0
                begin
                  app=AppException.new({:app_id=>app_id,:app_env=>exception_hash[:app_env],:controller=>exception_hash[:controller],:method=>exception_hash[:method],:exception_message=>exception_hash[:exception_message],:exception_class=>exception_hash[:exception_class],:exception_backtrace=>exception_hash[:exception_backtrace],:exception_status=>status,:wall_time=>exception_hash[:wall_time],:chunked=>exception_hash[:chunked],:content_length=>exception_hash[:content_length],:http_accept=>exception_hash[:http_accept],:http_accept_charset=>exception_hash[:http_accept_charset],:http_accept_encoding=>exception_hash[:http_accept_encoding],:http_accept_language=>exception_hash[:http_accept_language],:http_connection=>exception_hash[:http_connection],:http_cookie=>exception_hash[:http_cookie],:http_host=>exception_hash[:http_host],:http_keep_alive=>exception_hash[:http_keep_alive],:http_user_agent=>exception_hash[:http_user_agent],:http_version=>exception_hash[:http_version],:path_info=>exception_hash[:path_info],:query_string=>exception_hash[:query_string],:remote_addr=>exception_hash[:remote_addr],:request_method=>exception_hash[:request_method],:request_path=>exception_hash[:request_path],:request_uri=>exception_hash[:request_uri],:script_name=>exception_hash[:script_name],:server_name=>exception_hash[:server_name],:server_port=>exception_hash[:server_port],:server_protocol=>exception_hash[:server_protocol],:server_software=>exception_hash[:server_software],:rack_errors=>exception_hash[:rack_errors],:rack_input=>exception_hash[:rack_input],:rack_multiprocess=>exception_hash[:rack_multiprocess],:rack_multithread=>exception_hash[:rack_multithread],:rack_run_once=>exception_hash[:rack_run_once],:rack_url_scheme=>exception_hash[:rack_url_scheme],:rack_version=>exception_hash[:rack_version]})
                  app.save
                rescue ActiveRecord::StatementInvalid => e
                  if trial < MAX_TRIAL
                    trial += 1
                    Logger.info "Exception entry AppException.create - Database is busy try no #{trial}"
                    sleep(2)          
                    retry
                  end
                  Logger.info("Exception entry AppException.create failed.")
                  Logger.error(e)
                  Logger.error(e.backtrace.join("\n"))                
                rescue Exception => e
                  Logger.error(e) 
                  Logger.error(e.backtrace.join("\n"))
                  if trial < 1
                    trial += 1
                    sleep(2)
                    Logger.info"Retrying..."
                    retry
                  end
                  Logger.info("Exception entry AppException.create failed.")
                end  
                if mail_configuration
                  subject = "#{exception_hash[:app_name]} : #{exception_hash[:controller]}# #{exception_hash[:method]} (#{exception_hash[:exception_class]}) ' #{exception_hash[:exception_message]}'"
                  body = "Application Name\n.................\n #{exception_hash[:app_name]}\n\nError Message \n------------------\n#{exception_hash[:exception_message]}\n\nError Class\n.............\n#{exception_hash[:exception_class]}\n\nTime\n..................\n#{exception_hash[:wall_time]}\n\nBacktrace \n-------------------\n#{exception_hash[:exception_backtrace]}\n\nEnvironment\n---------------------------\nCHUNKED : #{exception_hash[:chunked]}\nCONTENT_LENGTH : #{exception_hash[:content_length]}\nHTTP_ACCEPT : #{exception_hash[:http_accept]}\nHTTP_ACCEPT_CHARSET : #{exception_hash[:http_accept_charset]}\nHTTP_ACCEPT_ENCOADING : #{exception_hash[:http_accept_encoding]}\nHTTP_ACCEPT_LANGUAGE : #{exception_hash[:http_accept_language]}\nHTTP_CONNECTION : #{exception_hash[:http_connection]}\nHTTP_COOKIE : #{exception_hash[:http_cookie]}\nHTTP_HOST:#{exception_hash[:http_host]}\nHTTP_KEEP_ALIVE : #{exception_hash[:http_keep_alive]}\nHTTP_USER_AGENT : #{exception_hash[:http_user_agent]}\nHTTP_VERSION:#{exception_hash[:http_version]}\nPATH_INFO : #{exception_hash[:path_info]}\nQUERY_STRING : #{exception_hash[:query_string]}\nREMOTE_ADDR : #{exception_hash[:remote_addr]}\nREQUEST_METHOD : #{exception_hash[:request_method]}\nREQUEST_PATH : #{exception_hash[:request_path]}\nREQUEST_URI : #{exception_hash[:request_uri]}\nSCRIPT_NAME : #{exception_hash[:script_name]}\nSERVER_NAME : #{exception_hash[:server_name]}\nSERVER_PORT : #{exception_hash[:server_port]}\nSERVER_PROTOCOL : #{exception_hash[:server_protocol]}\nSERVER_SOFTWARE : #{exception_hash[:server_software]}\nrack.errors : #{exception_hash[:rack_errors]}\nrack.input : #{exception_hash[:rack_input]}\nrack.multiprocess : #{exception_hash[:rack_multiprocess]}\nrack.multithread : #{exception_hash[:rack_multithread]}\nrack.run_once : #{exception_hash[:rack_run_once]}\nrack.url_scheme : #{exception_hash[:rack_url_scheme]}\nrack.version : #{exception_hash[:rack_version]}"
                  EmailHandler.deliver_send_email(subject,body,from,recipients)
                end
              end  
            end
            exception_hash=@message_reader.read_exception()
          end
        rescue Exception => e
          Logger.error(e)
          Logger.error(e.backtrace.join("\n"))
        end
      end      
    end #class MessageAnalyzer
  end #module Analyzer
end #module Webroar
