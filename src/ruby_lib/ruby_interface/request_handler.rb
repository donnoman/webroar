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

#RequestHandler class based on ebb server's http://github.com/ry/ebb/tree/v0.1.0

require File.join(File.dirname(__FILE__), 'version')

module Webroar
  class RequestHandler
    def self.need_content_length?(result)
      status, headers, body = result
      return false if headers.has_key?(Content_Length)
      return false if (100..199).include?(status) || status == 204 || status == 304
      return false if headers.has_key?(Transfer_Encoding) && headers[Transfer_Encoding] =~ /\bchunked\b/i
      return false unless body.kind_of?(String) || body.kind_of?(Array)
      true
    end
    
    def self.process(client)
      begin
        app = $app
        status, headers, body = app.call(client.env)
      rescue
        raise if $DEBUG
        status = 500
        headers = {Content_Type => TEXT_PLAIN}
        body = InternalServerError
        Webroar.log_debug("Webroar:ProcessClient:Process() inside 500 error")
      end # begin
      
      status = status.to_i
      
      if status == 304 || status == 204 || (100..199).include?(status)
        headers[Content_Length] = "0"
      else
        # Content-Length header checking and calculation according to Thin 
        headers[Content_Length] = Webroar::Utils.calculate_content_length(body) if need_content_length?([status,headers,body])
      end
      
      if !client.keep_alive?          
        Webroar.log_debug("connection-close")
        headers[CONNECTION] = CLOSE
      else
        headers[CONNECTION] = KEEP_ALIVE
      end       
      headers['Server'] = SERVER
      
      content_length = (headers[Content_Length] || ZERO).to_i
      
      client.write_headers(headers, status, content_length)
      
      if(content_length > 0) 
        client.write_body(body)
      end
    rescue => e
      Webroar.log_error("WebROaR Error! #{e.class}  #{e.message}\n #{e.backtrace.join("\n")}")
      return
    ensure
    end # self.process
  end # RequestHandler
end # Webroar
