require 'rubygems'
require 'jenkins'
require 'maestro_plugin'
require 'andand'
require 'jenkins_client'
require 'jenkins_api'

module MaestroDev
  class JenkinsWorker < Maestro::MaestroWorker

    include MaestroDev::JenkinsClient

    def build
      Maestro.log.info "Starting JENKINS build task..."
      validate_inputs
      return if error?

      Maestro.log.info "Inputs: host = #{workitem['fields']['host']}, port = #{workitem['fields']['port']}, job = #{workitem['fields']['job']}, scm_url = #{workitem['fields']['scm_url']}, steps = #{workitem['fields']['steps']},user_defined_axes = #{workitem['fields']['user_defined_axes']}"
      log_output("Beginning Process For Jenkins Job #{job_name}")

      uri = setup
      log_output("Connecting to Jenkins server at #{uri.to_s}", :info)
      log_output("Using username '#{get_field("username")}' and #{"no " if get_field("password").nil?}password", :info) if get_field("username")

      job_exists_already = job_exists?(job_name)
      return if error?

      if !job_exists_already and !workitem['fields']['override_existing']
        set_error("Job '#{job_name}' Not Found And No Override Allowed")
        return
      end
      write_output "Job '#{job_name}' found\n"

      if(workitem['fields']['override_existing'])
        unless job_exists_already
          log_output("Creating Job '#{job_name}', None Found" )
        end
        log_output("Parsing Steps From #{workitem['fields']['steps']}")

        steps = workitem['fields']['steps']
        steps = JSON.parse steps.gsub(/\'/, '"') if steps.is_a? String

        log_output("Parsing User-Defined Axes from #{workitem['fields']['user_defined_axes']}")

        user_axes = workitem['fields']['user_defined_axes']
        user_axes = JSON.parse user_axes.gsub(/\'/, '"') if user_axes.is_a? String

        log_output("Parsing Label Axes from #{workitem['fields']['label_axes']}")

        label_axes = workitem['fields']['label_axes']
        label_axes = JSON.parse label_axes.gsub(/\'/, '"') if label_axes.is_a? String

        if job_exists_already
          update_job(job_name, {:steps => steps, :user_defined_axes => user_axes, :label_axes => label_axes, :scm => workitem['fields']['scm_url']})
        else
          create_job(job_name, {:steps => steps, :user_defined_axes => user_axes, :label_axes => label_axes, :scm => workitem['fields']['scm_url']})
        end
        return if error?
      end

      parameters = workitem['fields']['parameters']

      build_number = get_next_build_number(job_name)

      success = false

      success = build_job(job_name, parameters)

      log_output("Jenkins Job #{success ? "Started Successfully" : "Failed To Start"}")

      if !success
        workitem['fields']['__error__'] = "Jenkins job failed to start"
        return
      end

      log_output("Build Number Is #{build_number}")
      save_output_value('build_number', build_number)

      console = ""

      failures = 0
      begin
        details = get_build_details_for_build(job_name, build_number)
        write_output find_new_console(job_name,build_number, console)
        console = get_build_console_for_build(job_name,build_number)
        sleep(@query_interval)
      rescue Net::HTTPServerException => e
        case e.response
          when Net::HTTPNotFound
            Maestro.log.debug "Jenkins job #{job_name} has not started build #{build_number} yet. Sleeping"
            failures += 1
            if failures > 5
              set_error("Timed out trying to get build details for #{job_name} build number #{build_number}")
              return
            end
            sleep(@query_interval)
          else
            raise e
        end
      end while details.nil? or details.is_a?(FalseClass) or (details.is_a?(Hash) and details["building"])

      write_output find_new_console(job_name,build_number, console)

      console = get_build_console_for_build(job_name,build_number)
      success = details['result'] == 'SUCCESS'

      url_meta = {}
#      url_meta['job'] =  # Maybe add root for job at some point
      url_meta['build'] = details['url']
      url_meta['log'] = "#{details['url']}console"

      save_test_results(build_number, details, url_meta)

      # Persist any links to meta data
      save_output_value('links', url_meta)

      if respond_to? :add_link
        add_link("Build Page", details["url"])
        add_link("Test Result", "#{details["url"]}testReport")
      end

      log_output("Jenkins Job Completed #{success ? "S" : "Uns"}uccessfully")

      workitem['fields']['__error__'] = "Jenkins job failed" if !success
      workitem['fields']['output'] = Iconv.new('US-ASCII//IGNORE', 'UTF-8').iconv(console)


      Maestro.log.debug "Finished Processing Jenkins Job"

      Maestro.log.info "***********************Completed JENKINS***************************"
    end

    # Gets the build data used to update the Maestro dashboard. This is meant to be scheduled at regular intervals to
    # Get up to date data without requiring a build composition/task to be run.
    def get_build_data

      Maestro.log.info 'Retrieving build data from Jenkins'
      validate_inputs
      return if error?

      Maestro.log.info "Inputs: host = #{workitem['fields']['host']}, port = #{workitem['fields']['port']}, job = #{workitem['fields']['job']}"
      log_output("Retrieving latest build data for job #{job_name}")

      uri = setup
      log_output("Connecting to Jenkins server at #{uri.to_s}", :info)
      log_output("Using username '#{get_field("username")}' and #{"no " if get_field("password").nil?}password", :info) if get_field("username")

      job_exists = job_exists?(job_name)
      return if error?

      unless job_exists
        set_error("Job '#{job_name}' Not Found")
        return
      end
      job_data = get_job_data(job_name)

      unless job_data
        set_error("Data for Job '#{job_name}' Not Found")
        return
      end

      last_completed_build = job_data['lastCompletedBuild']
      last_output_build_number = read_output_value('build_number')
      build_number = (last_completed_build ?  last_completed_build['number'] : nil)

      save_output_value('build_number', build_number) if build_number

      if build_number.nil? or build_number == last_output_build_number
        Maestro.log.info("No completed Jenkins build found for job #{job_name}")
        write_output("No new completed build found")
        not_needed
        return
      end

      begin
        details = get_build_details_for_build(job_name, build_number)
      rescue Net::HTTPServerException => e
        case e.response
          when Net::HTTPNotFound
            Maestro.log.debug "Jenkins job #{job_name} build #{build_number} details not found."
          else
            raise e
        end
      end

      url_meta = {}
      url_meta['build'] = last_completed_build['url']

      save_test_results(build_number, details, url_meta)

      # Persist any links to meta data
      save_output_value('links', url_meta)

      if respond_to? :add_link
        add_link("Build Page", details["url"])
        add_link("Test Result", "#{details["url"]}testReport")
      end

      Maestro.log.debug "Finished retrieving Jenkins build data"

      Maestro.log.info "***********************Completed JENKINS get_build_data ***********************"

    end

    # Returns the jenkins API endpoint uri or false if host is not set
    # (shouldn't happen as it is validated before)
    def setup
      host = workitem['fields']['host']
      port = workitem['fields']['port']
      username = workitem['fields']['username']
      password = workitem['fields']['password']
      @query_interval = 3 # every how many seconds to ping jenkins for console updates
      
      use_ssl = workitem['fields']['use_ssl'] || false
      @web_path = workitem['fields']['web_path'] || '/'
      @web_path = '/' + @web_path.gsub(/^\//, '').gsub(/\/$/, '')
      
      Jenkins::Api.setup_base_url(
       :host => host,
       :port => port, 
       :ssl => use_ssl,
       :username => username,
       :password => password,
       :path => @web_path
       )
    end
    
    def job_exists?(job_name)
      api_url = "/api/json"
      response = get_plain(api_url)
      if response.nil?
        msg = "Unable To Get Response From Jenkins Server at: '#{api_url}'"
        set_error msg
        Maestro.log.warn msg
      else
        if !response.respond_to?('body')
          msg = "Unable To Get Response From Jenkins Server at '#{api_url}': #{response}"
          set_error msg
          Maestro.log.warn msg
        else
          begin
            response = JSON.parse(response.body)
            if response.keys.find{|key| key == 'jobs'}
              return !response['jobs'].find{|job| job['name'] == job_name }.nil?
            else
              msg = "Invalid JSON: Missing 'jobs' Entry #{response.to_json}" 
              set_error msg
              Maestro.log.warn msg
            end
          rescue JSON::ParserError => e
            msg = "Unable To Parse JSON from Jenkins Server '#{api_url}' -> #{e.message}: #{response.body}" 
            set_error msg
            Maestro.log.warn msg
          end
        end
      end
      return false
    end

    def get_job_data(job_name)
      # A 404 indicates no test data available
      path  = "/job/#{job_name}/api/json"
      begin
        response = get_plain(path)
      rescue Net::HTTPServerException => e
        case e.response
          when Net::HTTPNotFound
            Maestro.log.debug "Jenkins job #{job_name} has no data"
          else
            raise e
        end
      end

      if response
        begin
          write_output "Retrieved job data\n"
          return JSON.parse(response.body)
        rescue JSON::ParserError => e
          msg = "Unable To Parse JSON from Jenkins Server '#{path}' -> #{e.message}: #{response.body}"
          Maestro.log.warn msg
        end
      else
        write_output "No job data available\n"
      end
      return false

    end
    
    def get_test_results(job_name, build_number)
      # A 404 indicates no test data available
      path  = "/job/#{job_name}/#{build_number}/testReport/api/json"
      begin
        response = get_plain(path)
      rescue Net::HTTPServerException => e
        case e.response
        when Net::HTTPNotFound
          Maestro.log.debug "Jenkins job #{job_name} has no test output"
        else
          raise e
        end
      end
      
      if response
        begin
          write_output "Retrieved test results\n"
          return JSON.parse(response.body)
        rescue JSON::ParserError => e
          msg = "Unable To Parse JSON from Jenkins Server '#{path}' -> #{e.message}: #{response.body}" 
          Maestro.log.warn msg
        end
      else
        write_output "No test results available\n"
      end
      return false
    end
   
    def delete_job(job_name)
      post_plain("/job/#{job_name}/doDelete")
    end

    def update_job(job_name, options)
      send_job(job_name, options, true)
    end
    
    def create_job(job_name, options)
      send_job(job_name, options, false)
    end

    def send_job(job_name, options, update)
      steps = []
      user_axes = []
      label_axes = []
      
      log_output "Loading #{job_name} with #{options.to_json}"

      options[:steps].andand.each do |step|
        steps << [:build_shell_step, step]
        Maestro.log.debug "setting step #{step}"
      end


      options[:user_defined_axes].andand.each do |axis_string|
        values = []
        name = nil
        axis_string.split(' ').each do |part|
          if name.nil?
            name = part
          else
            values << part
          end
        end
        axis = { :name => name, :values => values }
        user_axes << axis
        Maestro.log.debug "setting user-defined axis #{axis.inspect}"
      end

      options[:label_axes].andand.each do |axis|
        label_axes << axis
        Maestro.log.debug "setting label axis #{axis}"
      end

      job_config = Jenkins::JobConfigBuilder.new('none') do |c|
        c.steps         = steps
        c.user_axes     = user_axes
        c.node_labels   = label_axes
        c.scm           = options[:scm] || ''
      end
      
      if update
        success = Jenkins::Api.update_job(job_name, job_config)
        set_error("Failed to update job #{job_name}: #{Jenkins::Api.error}") unless success
      else
        success = Jenkins::Api.create_job(job_name, job_config)
        set_error("Failed to create job #{job_name}: #{Jenkins::Api.error}") unless success
      end
    end

    def job_name
      workitem['fields']['job']
    end

    def get_next_build_number(job_name)
      job = Jenkins::Api.job(URI.escape(job_name))
      job['nextBuildNumber'] ? job['nextBuildNumber'].to_i : 1
    end
    
    def get_build_details_for_build(job_name, build_number)
      Jenkins::Api.build_details(URI.encode(job_name), build_number)
    end
    
    def get_build_console_for_build(job_name, build_number)
      path  = "/job/#{job_name}/#{build_number}/"
      path << "consoleText"
      get_plain(path).body
    end

    def find_new_console(job_name, build_number, console)
      # If we were to use the jenkins /job/#{job_name}/#{build_number}/logText/progressiveText?start=${last_known_pos}
      # then jenkins would do all this work for us, and we wouldn't consume increasing amounts of memory (x2) in order
      # for us to calculate the increment
      # Note the additional headers that Jenkins makes available so we know where we're up to, and whether the log is
      # "done" (i.e. build complete, log isn't gonna be getting any bigger)
      # Improvement logged in MAESTRO-2743
      new_console = get_build_console_for_build(job_name, build_number)
      return '' if new_console.include?('Error 404')

      size = (new_console.include?(console))? console.size : 0
      new_size = new_console.size

      Iconv.new('US-ASCII//IGNORE', 'UTF-8').iconv(new_console.slice(size, new_size))
    end

    def build_job(job_name, parameters)

      unless (parameters.nil? or parameters.empty?)
        url_params = ''
        parameters.each do |param|
          url_params << '&' unless url_params.empty?
          url_params << param
        end
        url = "/job/#{job_name}/buildWithParameters?#{url_params}"
        response = post_plain(url)
      else
        begin
          response = post_plain "/job/#{job_name}/build"
        rescue Net::HTTPServerException => e
          Maestro.log.debug "Error building job, trying with parameterized API call: #{e}"
          # it may be a build with parameters, launch it with the default parameters
          if e.response.code == "405"
            response = post_plain "/job/#{job_name}/buildWithParameters"
          else
            raise e
          end
        end
      end

      response.code == "200"
    end

    def validate_inputs
      write_output "Validating Inputs\n"
      if workitem['fields']['port'].nil? or workitem['fields']['port'] == 0
        workitem['fields']['port'] = workitem['fields']['use_ssl'] ? 443 : 80
      end

      missing = ['host', 'job'].select{|f| empty?(f)}
      set_error("Missing Fields: #{missing.join(",")}") unless missing.empty?
    end


    private

    def save_test_results(build_number, details, url_meta)
      test_results = get_test_results(job_name, build_number)

      if test_results
        # Add test url to links
        url_meta['test'] = "#{details['url']}testReport"

        fail_count = test_results['failCount'] || 0
        skip_count = test_results['skipCount'] || 0
        pass_count = test_results['passCount']
        test_count = test_results['totalCount']

        if pass_count.nil?
          pass_count = !test_count.nil? ? test_count - (skip_count + fail_count) : 0
        end

        if test_count.nil?
          test_count = fail_count + skip_count + pass_count
        end

        test_meta = [{:tests => test_count, :failures => fail_count, :skipped => skip_count, :passed => pass_count, :duration => test_results['duration']}]
        save_output_value('tests', test_meta)
      end
    end
    

    
    def empty?(field)
      get_field(field).nil? or get_field(field).empty?
    end

    def log_output(msg, level=:debug)
      Maestro.log.send(level, msg)
      write_output "#{msg}\n"
    end
  end
end
