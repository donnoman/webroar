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
#

require "fileutils"

class Installer
  include Webroar
  include Webroar::UserInteraction                  
  ADMIN_USER_FILE = File.join(ADMIN_PANEL_DIR,'config','user.yml')
  WEBROAR_CONFIG_FILE = File.join(WEBROAR_ROOT, 'conf', 'config.yml')
  DB_CONFIG_FILE = File.join(ADMIN_PANEL_DIR, 'config', 'database.yml')
  if RUBY_PLATFORM =~ /linux/
    REQUIRED_DEPENDENCIES = [
      Dependencies::Ruby,
      Dependencies::LibRuby,
      Dependencies::Ruby_OpenSSL,
      Dependencies::Zlib,
      Dependencies::Ruby_DevHeaders,
      Dependencies::RubyGems,
      Dependencies::GCC,
      Dependencies::Make,
      Dependencies::LibSqlite,
      Dependencies::Sqlite_DevHeaders,
      Dependencies::Starling,
      Dependencies::Gnutls
    ]
  end
  
  if RUBY_PLATFORM =~ /darwin/
    REQUIRED_DEPENDENCIES = [
      Dependencies::Ruby,
      Dependencies::LibRuby,
      Dependencies::Ruby_OpenSSL,
      Dependencies::Zlib,
      Dependencies::Ruby_DevHeaders,
      Dependencies::RubyGems,
      Dependencies::GCC,
      Dependencies::Make,
      Dependencies::Starling,
      Dependencies::Xcode
    ]
  end
  
  def check_exe_file(file)
    paths = ENV['PATH'].split(":")
    flag = false
    paths.length.times do |i|
      if File.executable?(File.join(paths[i], file))
        flag = true
        break
      end
    end
    return flag
  end
  
  def import_files(gem_name)
    print "Importing configuration, logs and admin panel data from the previous #{gem_name} install ... "
    require File.join(WEBROAR_ROOT, 'src', 'ruby_lib', 'ruby_interface','version.rb')
    if Webroar::SERVER.downcase == gem_name.downcase
      puts "done."
      return YAML.load(File.open(WEBROAR_CONFIG_FILE))["Server Specification"]["port"]
    end
    import_dir = File.expand_path(File.join(WEBROAR_ROOT, "..", gem_name.downcase))
    FileUtils.copy(File.join(import_dir,"conf","config.yml"), WEBROAR_CONFIG_FILE)    
    FileUtils.copy(File.join(import_dir,"src","admin_panel","config","user.yml"), ADMIN_USER_FILE)
    FileUtils.copy(File.join(import_dir,"src","admin_panel","config","database.yml"), DB_CONFIG_FILE)
    configuration = YAML.load(File.open(DB_CONFIG_FILE))["production"]
    if configuration['adapter'] == 'sqlite3' and !configuration['database'].start_with?('/')
      db = File.join(import_dir, "src", "admin_panel", configuration['database'])
      FileUtils.copy(db, File.join(ADMIN_PANEL_DIR, configuration['database'])) if File.exist?(db)
    end
    puts "done."
    return YAML.load(File.open(WEBROAR_CONFIG_FILE))["Server Specification"]["port"]
  end
  
  def create_service_link(level, link_name, script_file)
    system("find /etc/ -name rc#{level}.d > /tmp/search_result 2>>#{WEBROAR_ROOT}/install.log")
    file = File.open("/tmp/search_result")
    line = file.readline.chomp
    file.close()
    link_file = File.join(line,link_name)
    
    if line != nil and script_file != nil and !File.symlink?(link_file)
      system("ln -s #{script_file} #{link_file} >>#{WEBROAR_ROOT}/install.log 2>>#{WEBROAR_ROOT}/install.log")
    end
  end

  def create_service
    script = nil
    script_file = nil
    if(check_exe_file("chkconfig"))
      script = get_service_script("# chkconfig: 2345 85 15")
    else 
      script = get_service_script()
    end
    
    system("find /etc/ -name init.d > /tmp/search_result 2>>#{WEBROAR_ROOT}/install.log")
    file = File.open("/tmp/search_result")
    line = file.readline.chomp
    file.close()
    if line != nil
      script_file = File.join("#{line}",'webroar')
      file = File.open(script_file,"w")
      file.puts(script)
      file.close
      system("chmod +x #{script_file} 2>>#{WEBROAR_ROOT}/install.log")
    end
    
    create_service_link("0", 'K15webroar', script_file)
    create_service_link("1", 'K15webroar', script_file)
    create_service_link("6", 'K15webroar', script_file)
    create_service_link("2", 'S85webroar', script_file)
    create_service_link("3", 'S85webroar', script_file)
    create_service_link("4", 'S85webroar', script_file)
    create_service_link("5", 'S85webroar', script_file)
    
  end

  def destroy_service
    system("find /etc/ -name *webroar > /tmp/search_result")
    File.open("/tmp/search_result").each{|line|
      system("rm #{line}")
    }
  end

  def install(options, args)
    ssl = false
    str = ""
    
    if options[:ssl]
      ssl = true
      str = "ssl=yes "
    end
    
    if CheckUser.new.check == 0
      
#      if File.exist?(File.join(WEBROAR_BIN_DIR,"webroar-head")) && File.exist?(File.join(WEBROAR_BIN_DIR,"webroar-worker"))
#        system("webroar stop")
#        puts "WebROaR is already installed on this machine. Please uninstall it with *sudo webroar uninstall* and run install command again."
#        return
#      end
      
      puts "Checking for the dependencies ..."
      check_dependencies(ssl) || exit(1)
      
      port, import, gem_name = user_input
      port = import_files(gem_name) if import
      write_server_port(port, ssl) if !import
      
      print 'Creating directory structure ...'
      Dir.chdir(WEBROAR_ROOT)
      
      system("ln -s  #{ADMIN_PANEL_DIR} #{File.join(WEBROAR_ROOT)}>install.log 2>>install.log")
      system("chmod ugo+x #{File.join(WEBROAR_BIN_DIR,'webroar-analyzer')}")
      puts " done."
      print "Compiling C source files ..."
      if options[:debug_build]
        system("rake debug_build #{str} >>install.log 2>>install.log")
      else
        system("rake #{str} >>install.log 2>>install.log")
      end
      if($?==0)
        puts " done."
        puts "Installing server ..."        
        system("rake create_install_dirs  >>install.log 2>>install.log") 
        if($?==0)
          print "Setting up server admin panel application database ..."
          Dir.chdir(ADMIN_PANEL_DIR)
          if !import
            # delete existing database if any
            system("rake db:drop >>#{WEBROAR_ROOT}/install.log 2>>#{WEBROAR_ROOT}/install.log")
            system("rake db:create >>#{WEBROAR_ROOT}/install.log 2>>#{WEBROAR_ROOT}/install.log")
          end 
          if($? == 0)
            system("rake db:migrate >>#{WEBROAR_ROOT}/install.log 2>>#{WEBROAR_ROOT}/install.log")
            if($? == 0)
              puts " done."
              # Creating soft link for WebROaR and starling process. In most debian system, secure 
              # sudo path fails to locate it.
              create_softlink()
              if RUBY_PLATFORM =~ /linux/ and !import
                file=File.open(File.join('','etc','logrotate.d','webroar'),"w")
                logrotate_string = get_logrotate()
                file.puts(logrotate_string)
                file.close
              end
              if RUBY_PLATFORM =~ /darwin/ and !import
                # read file into an array
                f = File.open("/etc/newsyslog.conf")
                saved = File.open("tmp.conf", "a")
                results = f.readlines
                # Is there a way to remove everything that's been read here?
                f.close
                
                results.each do |sending|
                  if !sending.include?"webroar"
                    saved.puts("#{sending}")
                  end
                end
                
                saved.puts("/var/log/webroar/*.log   644  5     10   *     GJ") 
                
                # Close the archive file
                saved.close
                
                FileUtils.mv("tmp.conf", "/etc/newsyslog.conf")
              end
              
              if RUBY_PLATFORM =~ /linux/ and !import
                print "Generating service script ..."
                # Add service script in '/etc/init.d/' folder
                create_service()
                puts " done."
              end
              
              puts"WebROaR installed successfully."
              
              # Stop WebROaR if already running.
              system("webroar stop") if File.exist?(PIDFILE)
              
              # Start WebROaR
              puts"Starting WebROaR ... "
              system("webroar start")
              
              install_msg(port, false)
            else
              puts " failed."
              puts "Error while migrating sqlite database. Please refer 'install.log' for details"
              puts "Unfortunately you would need to migrate database manually for the admin panel rails application. Please run *rake db:migrate*  from #{ADMIN_PANEL_DIR}"
              install_msg(port, true)
              return -1
            end
          else
            puts " failed."
            puts "Error while creating sqlite database. Please refer 'install.log' for details."
            puts "Unfortunately you would have to setup database manually for the admin panel rails application. Please run *rake db:create* and *rake db:migrate*  from #{ADMIN_PANEL_DIR}"
            install_msg(port, true)
            return -1
          end
        else
          puts "Installation error. Please refer 'install.log' for details."
          return -1
        end
      else
        puts " failed."
        puts "Compilation error. Please refer 'install.log' for details."
        return -1
      end
    else
      return -1
    end
  end
  
  def test(options, args)  # run test-suite comprises of unit test, functional test, admin-panel test, load test
    # stopping the server.. its get started on installation.
    puts "Please make sure you have made relevant changes in conf/test_suite_config.yml"
    cmd = "webroar stop"
    system(cmd)
    str = ""
    
    str += "load_test=yes " if options[:load_test]
    str += "debug_build=yes " if options[:debug_build]
    str += "no_report=yes " if options[:no_report]
    if options[:report_dir]
      str += "report_dir=#{options[:report_dir]} "
    else
      str += "report_dir=#{File.join(WEBROAR_ROOT,'report')} "
    end
    
    
    if CheckUser.new.check == 0
      Dir.chdir(WEBROAR_ROOT)
      system("rake all_test #{str}")
    end
  end
  
  def uninstall(options, args)
    if CheckUser.new.check == 0
      
      if !File.exist?(File.join(WEBROAR_BIN_DIR,"webroar-head")) or !File.exist?(File.join(WEBROAR_BIN_DIR,"webroar-worker"))
        puts "WebROaR is already uninstalled."
        return
      end
      
      # Stop the server
      filename = File.join(WEBROAR_ROOT, 'conf', 'server_internal_config.yml')
      pid_file = YAML.load(File.open(filename))["webroar_analyzer_script"]["pid_file"]
      if File.exists?(PIDFILE) or File.exists?(pid_file)
        WebroarCommand.new.stop(nil,nil)
      end
      
      Dir.chdir(WEBROAR_ROOT)
      print "Removing executables ..."
      # removing softlink also
      remove_softlink()
      system("rake clobber >uninstall.log 2>>uninstall.log")
      if($?==0)
        puts " done."
        print "Removing admin panel application database ..."
        begin
          Dir.chdir(ADMIN_PANEL_DIR)
          system("rake db:drop >>#{WEBROAR_ROOT}/uninstall.log 2>>#{WEBROAR_ROOT}/uninstall.log")
          if($?==0)
            puts " done."
            puts "WebROaR uninstalled successfully."
          else
            puts "An error occurred while removing the database. Please refer 'uninstall.log' for details."
            return -1
          end
        rescue Exception => e
          puts e
          puts e.backtrace
          puts "An error occurred while removing the database. Please refer 'uninstall.log' for details."
          return -1
        end
        print "Removing files ...\n"
        WebroarCommand.new.remove_logrotate
        dirs = [File.join('','var','log','webroar')]
        for dir in dirs
          file_pattern = File.join(dir, '*')
          files = Dir.glob(file_pattern)
          for file in files
            if File.exists?(file)
              File.delete(file)
            end
          end
          if File.exists?(dir)
            Dir.rmdir(dir)
          end
        end
        
        if RUBY_PLATFORM =~ /linux/ 
          printf "Removing service script ... "
          destroy_service()
          puts "done."
        end
        
      else
        puts "An error occurred while removing the files. Please refer 'uninstall.log' for details."
        return -1
      end
    else
      return -1
    end
  end
  
  def version    
    require File.join(WEBROAR_ROOT, 'src', 'ruby_lib', 'ruby_interface','version.rb')
    puts "#{Webroar::SERVER}"
  end
  
  def install_msg(port, flag)
    puts
    if flag
      puts "Please start the server using the command 'sudo webroar start'"
    end
    
    puts "Deploy a ruby web application using server admin panel, accessible through the link - http://localhost:#{port}/admin-panel"
    puts
  end
  
  def write_user(username, pswd)
    info = Array.new
    u = {}
    u['user_name'] = username
    u['password'] = Digest::MD5.hexdigest(pswd)
    info <<= u
    yaml_obj=YAML::dump(info)
    file=File.open(File.join(ADMIN_PANEL_DIR,'config','user.yml'),"w")
    file.puts(yaml_obj)
    file.close
  end
  
  def write_server_port(port, ssl)
    info = Array.new
    if ssl
      s = {'port' => port, 'min_worker' => 4, 'max_worker' => 8, 'log_level' => "SEVERE",'access_log'=>'enabled','SSL Specification' => {'ssl_port' => 443, 'ssl_support' => "disabled", 'certificate_file' => nil, 'key_file' => nil}}
    else
      s = {'port' => port, 'min_worker' => 4, 'max_worker' => 8, 'log_level' => "SEVERE",'access_log'=>'enabled'}
    end
    info = {'Server Specification' => s}
    yaml_obj=YAML::dump(info)
    file=File.open(File.join(WEBROAR_ROOT,'conf','config.yml'),"w")
    header_string=get_header()
    file.puts(header_string)
    file.puts(yaml_obj)
    file.close
  end
  
  def check_dependencies(ssl)
    failed_dependencies =[]    
    REQUIRED_DEPENDENCIES.each do |dep|
      if (dep.name=="gnutls/gnutls.h" and ssl) or dep.name != "gnutls/gnutls.h"
        print "Checking for #{dep.name}........"
        status = dep.find
        if status == nil
          status = "\e[31mnot found\e[0m."
        end
        puts status
        if status =~ /.*not found.*/
          failed_dependencies[failed_dependencies.size] = dep.name
          #puts "Server could not be installed. Please see the 'user guide' for the list of prerequisites."
          #TODO: Check for all the dependencies and list them with their appropriate solutions.
          #return false
        end
      end
    end
    
    if( failed_dependencies.size > 0)      
      puts "The following dependencies required for installation could not be found:"
      print "\e[31m"
      failed_dependencies.each do |dependency|
        puts dependency
      end
      puts "\e[0mPlease refer the user guide for the list of prerequisites."
      puts "Sorry, WebROaR could not be installed on this machine."
      return false      
    end
    
    return true
  end
  
  def get_logrotate
    return "/var/log/webroar/*.log {\n"\
      "\tdaily\n"\
      "\tmissingok\n"\
      "\trotate 52\n"\
      "\tcompress\n"\
      "\tdelaycompress\n"\
      "\tnotifempty\n"\
      "\tcopytruncate\n"\
      "\}"
  end
  
  def get_service_script(start_stop_level="# Required-Start:    $all
# Required-Stop:     $all
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6")
    return "#!/bin/bash
#
### BEGIN INIT INFO
# Provides:          WebROaR
    "+start_stop_level+"
# Short-Description: Start and stop the WebROaR application server.
# Description:       Controls the WebROaR server using \"webroar\" command.
### END INIT INFO
#

NAME=webroar

case \"$1\" in
  start)
  webroar start
  ;;
  stop)
  webroar stop
  ;;
  restart)
  webroar restart
  ;;
  force-reload)
  webroar restart
  ;;
  *)
  N=/etc/init.d/$NAME
  echo \"Usage: $N {start|stop|restart|force-reload}\" >&2
  exit 1
  ;;
esac

exit 0"
  end
  
  def create_softlink  
    starling_exe = File.join(USR_BIN_DIR,'starling')  
    if File.exists?(File.join(GEM_BIN_DIR,'starling')) and !File.exists?(starling_exe)
      system("ln -s #{File.join(GEM_BIN_DIR,'starling')}  #{USR_BIN_DIR} >>#{File.join(WEBROAR_ROOT,'install.log')} 2>>#{File.join(WEBROAR_ROOT,'install.log')}")
    end
    webroar_exe = File.join(USR_BIN_DIR,'webroar')
    if File.exists?(File.join(GEM_BIN_DIR,'webroar')) and !File.exists?(webroar_exe)
      system("ln -s #{File.join(GEM_BIN_DIR,'webroar')}  #{USR_BIN_DIR} >>#{File.join(WEBROAR_ROOT,'install.log')} 2>>#{File.join(WEBROAR_ROOT,'install.log')}")
    end
    analyzer_exe = File.join(USR_BIN_DIR,'webroar-analyzer')
    if File.exists?(File.join(GEM_BIN_DIR,'webroar-analyzer')) and !File.exists?(analyzer_exe)
      system("ln -s #{File.join(GEM_BIN_DIR,'webroar-analyzer')}  #{USR_BIN_DIR} >>#{File.join(WEBROAR_ROOT,'install.log')} 2>>#{File.join(WEBROAR_ROOT,'install.log')}")
    end
  end
  
  def remove_softlink    
    starling_exe = File.join(USR_BIN_DIR,'starling')
    system("rm #{starling_exe} >>#{File.join(WEBROAR_ROOT,'uninstall.log')} 2>>#{File.join(WEBROAR_ROOT,'uninstall.log')}") if File.symlink?(starling_exe)
    webroar_exe = File.join(USR_BIN_DIR,'webroar')
    system("rm #{webroar_exe} >>#{File.join(WEBROAR_ROOT,'uninstall.log')} 2>>#{File.join(WEBROAR_ROOT,'uninstall.log')}") if File.symlink?(webroar_exe)
    analyzer_exe = File.join(USR_BIN_DIR,'webroar-analyzer')
    system("rm #{analyzer_exe} >>#{File.join(WEBROAR_ROOT,'uninstall.log')} 2>>#{File.join(WEBROAR_ROOT,'uninstall.log')}") if File.symlink?(analyzer_exe)
  end
  
  def get_header
    return "######################################################################################
#                             WebROaR Configuration file                               
######################################################################################

######################################################################################
# Configuration file has three YAML formatted components
# Order of components does not matter.
#   a) Server Specification
#        Elements:
#          1) Server Port(optional)(default port = 3000)
#          2) Minimum number of workers(optional)(default min_worker = 4)
#          3) Maximum number of workers(optional)(default max_worker = 8)
#          4) Logging level(optional)(default log_level = SEVERE)
#          5) SSL Specification(optional)
#             It defines SSL specification.
#             Parameters:
#               I) SSL Support(optional)(values must be 'enabled' or 'disabled'(default))
#              II) SSL Certificate File(optional)(Path to SSL certificate file. Default is empty)
#             III) SSL Key File(optional)(Path to SSL key file. Default is empty)
#              IV) SSL Port(optional)(Default port number 443) 
#          6) Access log(optional)(values must be 'enabled'(default) or 'disabled')
#        Order of the above elements does not matter.
#        Example:
#          Server Specification:
#            port: 3000
#            min_worker: 4
#            max_worker: 8
#            log_level: SEVERE
#            access_log: enabled
#            SSL Specification:
#              ssl_support: enabled
#              certificate_file: /home/smartuser/ca-cert.pem
#              key_file: /home/smartuser/ca-key.pem
#              ssl_port: 443
#                                     
#   b) Application Specification (optional)
#        Elements:
#          1) Application name(mandatory)
#          2) Application baseuri(optional)
#          3) Application path(mandatory)
#          4) Application type(mandatory)(example rails or rack)
#          5) Application environment(optional)(default environment = production)
#          6) Application analytics(mandatory)(values must be 'enabled' or 'disabled')
#          7) Minimum number of workers(optional)(default is 'Server Specification/min_worker')
#          8) Maximum number of workers(optional)(default is 'Server Specification/max_worker')
#          9) Logging level(optional)(default is 'Server Specification/log_level')
#         10) Run as user (mandatory)
#         11) Hostnames(optional)
#        Order of the above elements does not matter.
#        Base-uri 'admin-panel' is reserved for 'Admin Panel'.
#        Either host_names or baseuri(not both) must present to resolve HTTP request.
#        Hostnames can have multiple values, each separated by spaces.(e.g. host_names: server.com server.co.in)
#        Hostnames can be defined using wildcard(*), but wildcard can only be at start of name or at end of name (valid hostnames are (i) *.server.com (ii) www.server.* (iii) *.server.*).
#        Prefix Hostname with tilde(~), if wildcard is used in defining Hostname. e.g. (i) ~*.server.com  (ii) ~www.server.*  (iii) ~*.server.* 
#        Example with baseuri:
#          Application Specification:
#            - name: Mephisto
#              baseuri: /blog
#              path: /home/smartuser/work/rails_workspace/mephisto
#              type: rails
#              run_as_user: smartuser
#              analytics: enabled
#              environment: production
#              min_worker: 2
#              max_worker: 5
#              log_level: SEVERE
#        Example with host_names:
#          Application Specification:
#            - name: Mephisto
#              host_names: myblog.com ~*.myblog.com
#              path: /home/smartuser/work/rails_workspace/mephisto
#              type: rails
#              run_as_user: smartuser
#              analytics: enabled
#              environment: production
#              min_worker: 2
#              max_worker: 5
#              log_level: SEVERE
#  (c)  Headers (optional)
#         It allows adding or changing the Expires and Cache-Control in the response headers for static assets (e.g. *.js, *.gif etc). 
#         Elements:
#           1) Expires header for all static assets (optional) (default is 'off')
#           2) Specific expires header for specific file types (optional)
#              Elements:
#                 I) File Extensions(mandatory)
#                II) Expires value(mandatory) (No of seconds)
#         Possible value for expires is off or no. of seconds. 
#         Example:
#           Header:
#             expires: 3600
#             expires_by_type:
#             - ext: png, jpg, gif
#               expires: 31536000
#
######################################################################################"
    
    
  end
  
end #class Installer
