#--
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
#++

require 'jcode' if RUBY_VERSION.gsub(/\D/,'').to_i < 187
#This is the model class App which relates itself with the apps table in database.
class App < ActiveRecord::Base
  class<< self
    #This method is used to get the application data.
    #It needs name of the application as an input.
    def get_application_data(name)
      app = find(:first, :conditions => ['name = ?', name])
      return app
    end
  end
  
    # Start the application
  def self.start(app_name)
    ctl = Control.new(app_name)
    reply = nil
    err_obj = nil
    begin
      reply = ctl.add    
    rescue Exception => e
      err_obj = e      
      reply = "An error occurred while sending 'start' request for application '#{app_name}'. Please refer the '/var/log/webroar/Admin_panel.production.log' file for details."
    end
    return reply, e
  end
  
  # Stop the application
  def self.stop(app_name)
    ctl = Control.new(app_name)
    reply = nil
    begin
      reply = ctl.delete      
    rescue Exception => e
      reply = "An error occurred while sending 'stop' request for application '#{app_name}'. Please refer the '/var/log/webroar/Admin_panel.production.log' file for details."
    end
    return reply
  end
  
  # Restart the application
  def self.restart(app_name)
    ctl = Control.new(app_name)
    reply = nil
    begin
      reply = ctl.restart
    rescue Exception => e
      reply = "An error occurred while sending 'stop' request for application '#{app_name}'. Please refer the '/var/log/webroar/Admin_panel.production.log' file for details."
    end
    return reply
  end    
end
