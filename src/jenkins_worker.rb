#require 'rubygems'
require 'maestro_plugin'
require 'andand'
require 'jenkins_api_client'
require 'job_config_builder'

module MaestroDev
  module Plugin

    class JenkinsWorker < Maestro::MaestroWorker
      attr_reader :client

      SCM_GIT = 'git'
      SCM_SVN = 'svn' # Change this if Jenkins calls it something other than svn in changeSet 'kind' value
      JENKINS_SUCCESS = 'SUCCESS'
      JENKINS_UNSTABLE = 'UNSTABLE'

      def build
        validate_inputs

        Maestro.log.info "Inputs: host = #{workitem['fields']['host']}, port = #{workitem['fields']['port']}, job = #{workitem['fields']['job']}, scm_url = #{workitem['fields']['scm_url']}, steps = #{workitem['fields']['steps']},user_defined_axes = #{workitem['fields']['user_defined_axes']}"
        log_output("Beginning Process For Jenkins Job #{job_name}")

        setup

        job_exists_already = @client.job.exists?(job_name)

        if !job_exists_already and !workitem['fields']['override_existing']
          raise PluginError, "Job '#{job_name}' Not Found And No Override Allowed"
        end
        write_output "\nJob '#{job_name}' found"

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
        end

        parameters = workitem['fields']['parameters']

        build_number = (@client.job.get_current_build_number(job_name) || 0) + 1

        success = false

        success = build_job(job_name, parameters)

        log_output("Jenkins Job #{success ? "Started Successfully" : "Failed To Start"}")

        if !success
          raise PluginError, "Jenkins job failed to start"
        end

        log_output("Build Number Is #{build_number}")
        save_output_value('build_number', build_number)

        # Last pos is used for incremental console output
        # It is updated upon return of the get_console_output method
        last_pos = 0
        failures = 0

        # Since output lines are prefixed with \n, need to make sure the last line we wrote is closed-off
        write_output("\n", :buffer => true)

        begin
          details = @client.job.get_build_details(job_name, build_number)
          latest_output = @client.job.get_console_output(job_name, build_number, last_pos)
          write_output(latest_output['output'])
          last_pos = latest_output['size']
          sleep(@query_interval)
        rescue JenkinsApi::Exceptions::NotFoundException
        rescue Timeout::Error
          Maestro.log.debug "Jenkins job #{job_name} has not started build #{build_number} yet. Sleeping"
          failures += 1
          if failures > 5
            raise PluginError, "Timed out trying to get build details for #{job_name} build number #{build_number}"
          end
          sleep(@query_interval)
        end while details.nil? or details.is_a?(FalseClass) or (details.is_a?(Hash) and details["building"])

        latest_output = @client.job.get_console_output(job_name, build_number, last_pos)
        write_output(latest_output['output'])

        process_job_complete(job_name, build_number)
      end

      # Gets the build data used to update the Maestro dashboard. This is meant to be scheduled at regular intervals to
      # Get up to date data without requiring a build composition/task to be run.
      def get_build_data

        Maestro.log.info 'Retrieving build data from Jenkins'
        validate_inputs

        Maestro.log.info "Inputs: host = #{workitem['fields']['host']}, port = #{workitem['fields']['port']}, job = #{workitem['fields']['job']}"
        log_output("Retrieving latest build data for job #{job_name}")

        setup

        job_exists = @client.job.exists?(job_name)

        raise PluginError, "Job '#{job_name}' Not Found" unless job_exists
        job_data = @client.job.list_details(job_name)

        raise PluginError, "Data for Job '#{job_name}' Not Found" unless job_data

        last_completed_build = job_data['lastCompletedBuild']
        last_output_build_number = read_output_value('build_number')
        build_number = (last_completed_build ?  last_completed_build['number'] : nil)

        save_output_value('build_number', build_number) if build_number

        if build_number.nil? or build_number == last_output_build_number
          Maestro.log.info("No completed Jenkins build found for job #{job_name}")
          write_output("\nNo new completed build found")
          not_needed
          return
        end
        
        log_output("Last completed build number: #{build_number}")

        process_job_complete(job_name, build_number)
      end

      ###########
      # PRIVATE #
      ###########
      private

      def process_job_complete(job_name, build_number)
        begin
          details = @client.job.get_build_details(job_name, build_number)
        rescue JenkinsApi::Exceptions::NotFoundException => e
          log_output("Jenkins job #{job_name} build #{build_number} details not found.", :info)
          return false
        end

        jenkins_result = details['result']
        save_output_value('build_result', jenkins_result)

        # If JENKINS reports SUCCESS, then we succeed
        # Jenkins can also report 'UNSTABLE', which is Jenkins-ese means 'SUCCESS' with issues (like acceptable test failures)
        success = jenkins_result == JENKINS_SUCCESS || (!@fail_on_unstable && jenkins_result == JENKINS_UNSTABLE)

        url_meta = {}
#        url_meta['job'] =  # Maybe add root for job at some point
        url_meta['build'] = details['url']
        url_meta['log'] = "#{details['url']}console"

        save_test_results(build_number, details, url_meta)

        # Persist any links to meta data
        save_output_value('links', url_meta)

        if respond_to? :add_link
          add_link("Build Page", details["url"])
          add_link("Test Result", "#{details["url"]}testReport")
        end

        # If there is a changeset with stuff in it, see if we can extract committer info
        if details['changeSet'] && details['changeSet']['items'] && details['changeSet']['items'].size > 0
          # We can only really store a single committer per build, so search for the most recent
          # (jenkins appears to store a timestamp field in each 'item'
          scm = details['changeSet']['kind']
          save_output_value('scm_kind', scm)
          selected_item = nil

          details['changeSet']['items'].each do |item|
            selected_item = item if selected_item.nil? || item['timestamp'] > selected_item['timestamp']
          end

          if selected_item
            author_name = nil
            author_email = nil

            # If it turns out that svn doesn't use 'id' we can pull based on 'scm' var
            commit_id = selected_item['id']

            save_output_value('reference', commit_id) if scm == SCM_GIT
            save_output_value('revision', commit_id) if scm == SCM_SVN
            save_output_value('commit_id', commit_id)

            if selected_item['author']
              author_name = selected_item['author']['fullName']
              author_user = @client.user.get(author_name)

              if author_user && author_user['property']
                address_property = author_user['property'].select { |prop| prop.has_key?('address') }.first

                author_email = address_property['address'] if address_property
              end

              save_output_value('author_email', author_email)
              save_output_value('author_name', author_name)
            end

            write_output("\n#{scm} commit id #{commit_id} authored by #{author_name} (#{author_email})", :buffer => true)
          end
        end

        log_output("Jenkins Job Completed #{success ? "S" : "Uns"}uccessfully")

        raise PluginError, "Jenkins job failed" if !success
        success
      end

      def update_job(job_name, options)
        send_job(job_name, options, true)
      end

      def create_job(job_name, options)
        send_job(job_name, options, false)
      end

      def send_job(job_name, options, update)
        rubies = []
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
          c.rubies        = rubies
          c.steps         = steps
          c.user_axes     = user_axes
          c.node_labels   = label_axes
          c.scm           = options[:scm] || ''
        end

        xml_config = job_config.to_xml

        begin
          if update
            resp_code = @client.job.post_config(job_name, xml_config)
          else
            resp_code = @client.job.create(job_name, xml_config)
          end
        rescue JenkinsApi::Exceptions::ApiException => e
          raise PluginError, "Failed to #{update ? 'update' : 'create'} job #{job_name}: #{e.class.name}, #{e}"
        end
      end

      def job_name
        workitem['fields']['job']
      end

      def build_job(job_name, parameters)
        unless (parameters.nil? or parameters.empty?)
          # Convert list of k=v into hash
          params = Hash[parameters.map {|v| v.split(%r{\s*=\s*})}]
          @client.job.build(job_name, params)
        else
          @client.job.build(job_name)
#          begin
#            response = post_plain "/job/#{job_name}/build"
#          rescue Net::HTTPServerException => e
#            Maestro.log.debug "Error building job, trying with parameterized API call: #{e}"
#            # it may be a build with parameters, launch it with the default parameters
#            if e.response.code == "405"
#              response = post_plain "/job/#{job_name}/buildWithParameters"
#            else
#              raise e
#            end
#          end
        end

        # If we get this far the API hasn't detected an error response (it would raise Exception)
        # So no need to check response code
        true
      rescue JenkinsApi::Exceptions::ApiException => e
        write_output("\nGot error invoking build of '#{job_name}'. Error: #{e.class.name}, #{e}\n", :info)
        false
      end

      def validate_inputs
        if workitem['fields']['port'].nil? or workitem['fields']['port'] == 0
          workitem['fields']['port'] = workitem['fields']['use_ssl'] ? 443 : 80
        end

        missing = ['host', 'job'].select{|f| empty?(f)}
        raise ConfigError, "Missing Fields: #{missing.join(",")}" unless missing.empty?
      end

      def booleanify(value)
        res = false

        if value
          if value.is_a?(TrueClass) || value.is_a?(FalseClass)
            res = value
          elsif value.is_a?(Fixnum)
            res = value != 0
          elsif value.respond_to?(:to_s)
            value = value.to_s.downcase

            res = (value == 't' || value == 'true')
          end
        end

        res
      end

      # Returns the jenkins API endpoint uri or false if host is not set
      # (shouldn't happen as it is validated before)
      def setup
        host = get_field('host')
        port = get_field('port', 80)
        username = get_field('username')
        password = get_field('password')
        @fail_on_unstable = booleanify(get_field('fail_on_unstable', false))
        @query_interval = 3 # every how many seconds to ping jenkins for console updates

        use_ssl = get_field('use_ssl', false)
        @web_path = get_field('web_path', '/')
        @web_path = '/' + @web_path.gsub(/^\//, '').gsub(/\/$/, '')

        options = { :server_ip => host,
                    :server_port => port,
                    :jenkins_path => @web_path,
                    :follow_redirects => true,
                    :ssl => use_ssl}

        uri = "http#{'s' if use_ssl}://#{host}:#{port}#{@web_path}"

        if ENV['http_proxy']
          proxy_uri = URI.parse(ENV['http_proxy'])

          log_output("Connecting to Jenkins server at #{uri} (proxy #{proxy_uri.host}:#{proxy_uri.port})", :info)
          options[:proxy_ip] = proxy_uri.host
          options[:proxy_port] = proxy_uri.port
        else
          log_output("Connecting to Jenkins server at #{uri} (no proxy)", :info)
        end

        if username
          options[:username] = username
          options[:password] = password
          log_output("Using username '#{username}' and password")
        end

        @client = JenkinsApi::Client.new(options)
      end

      def save_test_results(build_number, details, url_meta)
        test_results = @client.job.get_test_results(job_name, build_number)

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
          log_output "Test results: test count=#{test_count}, failures=#{fail_count}, skipped=#{skip_count}, passed=#{pass_count}, duration=#{test_results['duration']}"
          test_meta = [{:tests => test_count, :failures => fail_count, :skipped => skip_count, :passed => pass_count, :duration => test_results['duration']}]
          save_output_value('tests', test_meta)
        else
          log_output "No test results available"
        end
      end

      def empty?(field)
        get_field(field).nil? or get_field(field).empty?
      end

      def log_output(msg, level=:debug)
        Maestro.log.send(level, msg)
        write_output "\n#{msg}"
      end
    end
  end
end
