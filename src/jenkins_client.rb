module MaestroDev

  # This module contains some low-level methods used by the worker

  module JenkinsClient
    # Generate the url to visit
    def get_jenkins_url(method, path)
      uri = URI.parse Jenkins::Api.base_uri
      escaped_path = URI.escape(path)
      url = "#{Jenkins::Api.base_uri}#{escaped_path}"
      Maestro.log.debug "URL for #{method}: #{url}"
      url
    end

    def get_http(uri)
      if ENV['http_proxy']
        Maestro.log.debug "Connecting through proxy #{ENV['http_proxy']}"
        proxy_uri = URI.parse(ENV['http_proxy'])
        http = Net::HTTP::Proxy(proxy_uri.host, proxy_uri.port).new(uri.host, uri.port)
        http.use_ssl = (uri.scheme == "https")
      else
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = (uri.scheme == "https")
      end
      http
    end

    # Helper for GET that don't barf at Jenkins's crappy API responses
    # get_plain
    #  path = portion of path to use AFTER jenkins root url, prefixed with a forward-slash
    #         ex: if jenkins params to setup are:
    #             host => 'localhost'
    #             port => '8080'
    #             use_ssl => false
    #             path/web-path => 'jenkins'
    #         Then the jenkins root url will be:
    #             http://localhost:8080/jenkins
    #         'path' is appended to this, so if 'path' is '/api/json' we end up with:
    #             http://localhost:8080/jenkins/api/json
    #  options = not used
    def get_plain(path, options = {})
      options = options.with_clean_keys
      get_plain_url(get_jenkins_url('GET', path))
    end

    # called by 'get_plain' above
    # will follow redirects and return end result.
    # not smart enough to know that it is following its own tail
    def get_plain_url(url)
      uri = URI.parse(url)
      http = get_http(uri)

      username_s = get_field('username') ? " with username #{get_field('username')}" : ""
      Maestro.log.debug("Requesting GET #{url}#{username_s}")

      http.start do |http|
        req = Net::HTTP::Get.new(uri.path)
        if get_field('username').to_s == ''
          req.basic_auth(get_field('username'),get_field('password'))
        end
        response = http.request(req)
        case response
          when Net::HTTPSuccess     then
            return response
          when Net::HTTPRedirection then
            Maestro.log.debug("Redirected to #{response['location']}")
            get_plain_url(response['location'])
          else
            Maestro.log.debug "Error requesting Jenkins url #{url}#{username_s}: #{response.code} #{response.message}"
            response.error!
        end
      end
    end

    # Helper for POST to jenkins
    #  path = portion of path to use AFTER jenkins root url, prefixed with a forward-slash
    #         @see get_plain
    def post_plain(path, data = "", options = {})
      options = options.with_clean_keys
      post_plain_url(get_jenkins_url('POST', path), data, options)
    end

    # called by 'post_plain' above
    # will follow redirects (but issue GET requests for them - actually hands off to 'get_plain_url')
    def post_plain_url(url, data, options)
      uri = URI.parse(url)
      http = get_http(uri)

      username_s = get_field('username') ? " with username #{get_field('username')}" : ""
      Maestro.log.debug("Performing POST #{url}#{username_s}")

      http.start do |http|
        path = uri.path
        path += "?#{uri.query}" unless uri.query.nil?
        req = Net::HTTP::Post.new(path)
        req.basic_auth(get_field('username'),get_field('password'))
        response = http.request(req)

        case response
          when Net::HTTPSuccess     then
            return response
          when Net::HTTPRedirection then
            Maestro.log.debug("Redirected to #{response['location']}")
            get_plain_url(response['location'])
          else
            Maestro.log.debug "Error posting to Jenkins url #{url}#{username_s}: #{response.code} #{response.message}"
            response.error!
        end
      end
    end
  end

end
