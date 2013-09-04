#require 'rubygems'
require 'maestro_plugin'
require 'andand'
require 'jenkins_api_client'
require 'job_config_builder'

module MaestroDev
  module Plugin

    class JenkinsWorker < Maestro::MaestroWorker
      attr_reader :client

      # every how many seconds to ping jenkins for console updates
      attr_accessor :query_interval

      SCM_GIT = 'git'
      SCM_SVN = 'svn' # Change this if Jenkins calls it something other than svn in changeSet 'kind' value
      JENKINS_SUCCESS = 'SUCCESS'
      JENKINS_UNSTABLE = 'UNSTABLE'

      # How long between polls of the queued job?
      JOB_START_POLL_INTERVAL = 2

      # Version that jenkins started to include queued build info in build response
      JENKINS_QUEUE_ID_SUPPORT_VERSION = 1.519

      def initialize
        @query_interval = 3
      end

      def build
        validate_build_parameters

        setup

        job_exists_already = @client.job.exists?(@job)

        if !job_exists_already and !@override_existing
          raise PluginError, "Job '#{@job}' Not Found And No Override Allowed"
        end
        write_output "\nJob '#{@job}' #{job_exists_already ? "" : "not "}found"

        if(@override_existing)
          log_output("#{job_exists_already ? "Updating existing" : "Creating new"} job '#{@job}'..." )
          log_output(" - Parsing Steps From #{@steps}")
          log_output(" - Parsing User-Defined Axes from #{@user_axes}")
          log_output(" - Parsing Label Axes from #{@label_axes}")

          if job_exists_already
            update_job({:steps => @steps, :user_defined_axes => @user_axes, :label_axes => @label_axes, :scm => @scm_url})
          else
            create_job({:steps => @steps, :user_defined_axes => @user_axes, :label_axes => @label_axes, :scm => @scm_url})
          end
        end

        build_number = build_job

        write_output("\nJenkins Job '#{@job}' initiated with build ##{build_number}")
        save_output_value('build_number', build_number)

        # Last pos is used for incremental console output
        # It is updated upon return of the get_console_output method
        last_pos = 0
        failures = 0

        # Since output lines are prefixed with \n, need to make sure the last line we wrote is closed-off
        write_output("\n", :buffer => true)

        begin
          begin
            latest_output = @client.job.get_console_output(@job, build_number, last_pos)
            write_output(latest_output['output'])
            last_pos = latest_output['size']
            # If this is true the build has not finished
            more_data = as_boolean(latest_output['more'])
            sleep(query_interval)
          end while more_data

          process_job_complete(build_number)
        rescue Timeout::Error
          raise PluginError, "Timed out trying to get build log for #{@job} build number #{build_number}"
        rescue JenkinsApi::Exceptions::ApiException => e
          raise PluginError, "Error while communicating with Jenkins for #{@job} build number #{build_number}. #{e}"
        end
      end

      # Gets the build data used to update the Maestro dashboard. This is meant to be scheduled at regular intervals to
      # Get up to date data without requiring a build composition/task to be run.
      def get_build_data
        validate_fetch_parameters

        log_output("Retrieving latest build data for job #{@job}")

        setup

        job_exists = @client.job.exists?(@job)

        raise PluginError, "Job '#{@job}' Not Found" unless job_exists
        job_data = @client.job.list_details(@job)

        raise PluginError, "Data for Job '#{@job}' Not Found" unless job_data

        last_completed_build = job_data['lastCompletedBuild']
        last_output_build_number = read_output_value('build_number')
        build_number = (last_completed_build ?  last_completed_build['number'] : nil)

        save_output_value('build_number', build_number) if build_number

        if build_number.nil? or build_number == last_output_build_number
          Maestro.log.info("No completed Jenkins build found for job #{@job}")
          write_output("\nNo new completed build found")
          not_needed
          return
        end
        
        log_output("Last completed build number: #{build_number}")

        process_job_complete(build_number)
      end

      ###########
      # PRIVATE #
      ###########
      private

      def process_job_complete(build_number)
        begin
          details = @client.job.get_build_details(@job, build_number)
        rescue JenkinsApi::Exceptions::NotFoundException => e
          log_output("Jenkins job #{@job} build #{build_number} details not found.", :info)
          return false
        end

        jenkins_result = details['result']
        save_output_value('build_result', jenkins_result)

        # If JENKINS reports SUCCESS, then we succeed
        # Jenkins can also report 'UNSTABLE', which is Jenkins-ese means 'SUCCESS' with issues (like acceptable test failures)
        success = jenkins_result == JENKINS_SUCCESS || (!@fail_on_unstable && jenkins_result == JENKINS_UNSTABLE)

        url_meta = {}
        # url_meta['job'] =  # Maybe add root for job at some point
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

            # Both GIT and SVN use commitId
            commit_id = selected_item['commitId']

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

      def update_job(options)
        send_job(options, true)
      end

      def create_job(options)
        send_job(options, false)
      end

      def send_job(options, update)
        rubies = []
        steps = []
        user_axes = []
        label_axes = []

        log_output "Loading #{@job} with #{options.to_json}"

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

        write_output("\nconfig.xml = \n#{xml_config}") if @debug_mode

        begin
          if update
            resp_code = @client.job.post_config(@job, xml_config)
          else
            resp_code = @client.job.create(@job, xml_config)
          end
        rescue JenkinsApi::Exceptions::ApiException => e
          raise PluginError, "Failed to #{update ? 'update' : 'create'} job #{@job}: #{e.class.name}, #{e}"
        end
      end

      def next_build_id
        # API says it will return nil... but looking at the code I suspect it may return a -1
        current_build_id = @client.job.get_current_build_number(@job)
        current_build_id > 0 ? current_build_id + 1 : 1
      end

      def build_job
        # Best-guess build-id
        # This is only used if we go the old-way below... but we can use this number to detect if multiple
        # builds were queued
        expected_build_id = next_build_id

        # We need to call method direct because api client gobbles up response
        if (@parameters.nil? or @parameters.empty?)
          response = @client.api_post_request("/job/#{@job}/build",
            {},
            true)
        else
          response = @client.api_post_request("/job/#{@job}/buildWithParameters",
            @parameters,
            true)
        end

        if @queue_id_support
          return get_build_id_from_queue(response)
        else
          return get_build_id_the_old_way(expected_build_id)
        end
      rescue JenkinsApi::Exceptions::ApiException => e
        raise PluginError, ("Got error invoking build of '#{@job}'. #{e}")
      end

      def get_build_id_from_queue(response)
        # If we get this far the API hasn't detected an error response (it would raise Exception)
        # So no need to check response code
        # If return_build_number is enabled, obtain the queue ID from the location
        # header and wait till the build is moved to one of the executors and a
        # build number is assigned
        if response["location"]
          task_id_match = response["location"].match(/\/item\/(\d*)\//)
          task_id = task_id_match.nil? ? nil : task_id_match[1]
          unless task_id.nil?
            write_output("\nJob '#{@job}' queued, will wait up to #{@build_start_timeout} seconds for build to start...")

            # Wait for the build to start
            begin
              Timeout::timeout(@build_start_timeout) do
                started = false
                attempts = 0

                while !started
                  # Don't really care about the response... if we get thru here, then it must have worked.
                  # Jenkins will return 404's until the job starts
                  queue_item = @client.queue.get_item_by_id(task_id)

                  if queue_item['executable'].nil?
                    # Job not started yet
                    attempts += 1

                    # Every 5 attempts (~10 seconds)
                    write_output("\nStill waiting...") if attempts % 5 == 0

                    sleep JOB_START_POLL_INTERVAL
                  else
                    return queue_item['executable']['number']
                  end
                end
              end
            rescue Timeout::Error
              # Well, we waited - and the job never started building
              # Attempt to kill off queued job (if flag set)
              if @cancel_on_build_start_timeout
                write_output("\nJob did not start in a timely manner, attempting to cancel pending build...")

                begin
                  @client.api_post_request("/queue/cancelItem?id=#{task_id}")
                  write_output(" done")
                rescue JenkinsApi::Exceptions::ApiException => e
                  raise PluginError, "Error while attempting to cancel pending job build for #{@job}. #{e}"
                end
              end

              # Now we need to raise an exception so that the build can be officially failed
              raise PluginError, "Jenkins build failed to start in a timely manner"
            rescue JenkinsApi::Exceptions::ApiException => e
              # Jenkins Api threw an error at us
              raise PluginError, "Problem while waiting for '#{@job}' build ##{build_number} to start.  #{e.class} #{e}"
            end
          else
            raise PluginError, "Jenkins did not return a queue_id for build of '#{@job}' (location: #{response['location']})"
          end
        else
          raise PluginError, "Jenkins did not return a location header for build of '#{@job}'"
        end
      end

      def get_build_id_the_old_way(expected_build_id)
        # Try to wait until the build starts so we can mimic queue
        # Wait for the build to start
        write_output("\nBuild requested, will wait up to #{@build_start_timeout} seconds for build to start...")

        begin
          Timeout::timeout(@build_start_timeout) do
            attempts = 0

            while true
              attempts += 1

              # Don't really care about the response... if we get thru here, then it must have worked.
              # Jenkins will return 404's until the job starts
              begin
                @client.job.get_build_details(@job, expected_build_id)

                return expected_build_id
              rescue JenkinsApi::Exceptions::NotFound => e
                # Every 5 attempts (~10 seconds)
                write_output("\nStill waiting...") if attempts % 5 == 0

                sleep JOB_START_POLL_INTERVAL
              end
            end
          end
        rescue Timeout::Error
          # Well, we waited - and the job never started building
          # Now we need to raise an exception so that the build can be officially failed
          raise PluginError, "Jenkins build failed to start in a timely manner"
        rescue JenkinsApi::Exceptions::ApiException => e
          # Jenkins Api threw an error at us
          raise PluginError, "Problem while waiting for '#{@job}' build ##{build_number} to start.  #{e.class} #{e}"
        end
      end

      def validate_common_parameters
        errors = []

        @debug_mode = get_boolean_field('debug_mode')
        @use_ssl = get_boolean_field('use_ssl')
        @host = get_field('host', '')
        @port = get_int_field('port', @use_ssl ? 443 :80)
        @job = get_field('job', '')
        @fail_on_unstable = get_boolean_field('fail_on_unstable')
        @username = get_field('username')
        @password = get_field('password')
        @web_path = get_field('web_path', '/')
        @web_path = '/' + @web_path.gsub(/^\//, '').gsub(/\/$/, '')

        errors << 'missing field host' if @host.empty?
        errors << 'missing field job' if @job.empty?

        return errors
      end

      def validate_build_parameters
        errors = validate_common_parameters

        # Additional params for build
        @build_start_timeout = get_int_field('build_start_timeout', 60)
        @cancel_on_build_start_timeout = get_boolean_field('cancel_on_build_start_timeout')
        @override_existing = get_boolean_field('override_existing')
        @steps = get_field('steps')
        @steps = JSON.parse steps.gsub(/\'/, '"') if @steps.is_a? String
        @user_axes = get_field('user_defined_axes')
        @user_axes = JSON.parse user_axes.gsub(/\'/, '"') if @user_axes.is_a? String
        @label_axes = get_field('label_axes')
        @label_axes = JSON.parse label_axes.gsub(/\'/, '"') if @label_axes.is_a? String
        @scm_url = get_field('scm_url')
        @parameters = get_field('parameters')

        # Convert list of k=v into hash
        @parameters = Hash[@parameters.map {|v| v.split(%r{\s*=\s*})}] if @parameters

        raise ConfigError, "Configuration Error: #{errors.join(", ")}" unless errors.empty?
      end

      def validate_fetch_parameters
        errors = validate_common_parameters

        raise ConfigError, "Configuration Error: #{errors.join(", ")}" unless errors.empty?
      end

      # Returns the jenkins API endpoint uri or false if host is not set
      # (shouldn't happen as it is validated before)
      def setup
        options = { :server_ip => @host,
                    :server_port => @port,
                    :jenkins_path => @web_path,
                    :ssl => @use_ssl}

        # This URI purely for logging
        uri = "http#{'s' if @use_ssl}://#{@host}:#{@port}#{@web_path}"

        if ENV['http_proxy']
          proxy_uri = URI.parse(ENV['http_proxy'])

          log_output("Connecting to Jenkins server at #{uri} (proxy #{proxy_uri.host}:#{proxy_uri.port})", :info)
          options[:proxy_ip] = proxy_uri.host
          options[:proxy_port] = proxy_uri.port
        else
          log_output("Connecting to Jenkins server at #{uri} (no proxy)", :info)
        end

        if @username
          options[:username] = @username
          options[:password] = @password
          log_output("Using username '#{@username}' and password")
        end

        @client = JenkinsApi::Client.new(options)
        # Bug in client that doesn't support non root-level paths for some operations
        # Pull req #
        @client.api_get_request('/', nil, '', true)['X-Jenkins']
        @jenkins_version = version.to_f || 0.0
        write_output("\nJenkins version #{@jenkins_version} (raw: #{version})")

        @queue_id_support = @jenkins_version >= JENKINS_QUEUE_ID_SUPPORT_VERSION
      end

      def save_test_results(build_number, details, url_meta)
        test_results = @client.job.get_test_results(@job, build_number)

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
