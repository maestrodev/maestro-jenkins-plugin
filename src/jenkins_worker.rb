#require 'rubygems'
require 'maestro_plugin'
require 'andand'
require 'jenkins_api_client'
require 'job_config_builder'

module MaestroDev
  module Plugin

    class JenkinsWorker < Maestro::MaestroWorker
      attr_reader :client

      attr_accessor :query_interval

      SCM_GIT = 'git'
      SCM_SVN = 'svn' # Change this if Jenkins calls it something other than svn in changeSet 'kind' value
      JENKINS_SUCCESS = 'SUCCESS'
      JENKINS_UNSTABLE = 'UNSTABLE'

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
          write_output("\n#{job_exists_already ? "Updating existing" : "Creating new"} job '#{@job}'..." )
          write_output("\n - Parsing Steps From #{@steps}")
          write_output("\n - Parsing User-Defined Axes from #{@user_axes}")
          write_output("\n - Parsing Label Axes from #{@label_axes}")

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

        write_output("\nRetrieving latest build data for job #{@job}")

        setup

        job_exists = @client.job.exists?(@job)

        raise PluginError, "Job '#{@job}' Not Found" unless job_exists

        # check if we have been called by a jenkins notifier POST
        context_inputs = get_field('__context_inputs__') || {}
        if job_data = context_inputs['jenkins']
          build_number = job_data && job_data['build'] && job_data['build']['number']
          write_output("\nGot Jenkins build number from context: #{build_number}") if build_number
        end

        # otherwise fetch data from jenkins
        if build_number.nil?
          job_data = @client.job.list_details(@job)
          raise PluginError, "Data for Job '#{@job}' Not Found" unless job_data
          last_completed_build = job_data['lastCompletedBuild']

          last_output_build_number = read_output_value('build_number')
          build_number = last_completed_build && last_completed_build['number']

          write_output("\nLast completed build number: #{build_number}")

          if build_number.nil? or build_number == last_output_build_number
            write_output("\nNo new completed build found for job #{@job}")
            not_needed
            return
          end
        end

        save_output_value('build_number', build_number) if build_number

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
          write_output("\nJenkins job #{@job} build #{build_number} details not found.")
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

        write_output("\nJenkins Job Completed #{success ? "S" : "Uns"}uccessfully")

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

        write_output "\nLoading #{@job} with #{options.to_json}"

        options[:steps].andand.each do |step|
          steps << [:build_shell_step, step]
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
        end

        options[:label_axes].andand.each do |axis|
          label_axes << axis
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

      def build_job
        build_opts = {'build_start_timeout' => @build_start_timeout,
                      'cancel_on_build_start_timeout' => @cancel_on_build_start_timeout,
                      'progress_proc' => self.method(:on_build_start_progress),
                      'completion_proc' => self.method(:on_build_start_complete)
        }

        @client.job.build(@job, @parameters || {}, build_opts)
      rescue JenkinsApi::Exceptions::ApiException => e
        raise PluginError, ("Got error invoking build of '#{@job}'. #{e}")
      rescue Timeout::Error
        raise PluginError, 'Jenkins build failed to start in a timely manner'
      end

      def on_build_start_progress(max_wait, curr_wait, poll_count)
        if poll_count == 0
          write_output("\nJob '#{@job}' queued, will wait up to #{max_wait} seconds for build to start...")
        else
          write_output("\nStill waiting...") if poll_count % 5 == 0
        end
      end

      def on_build_start_complete(build_number, cancelled)
        if build_number
          write_output("\nJob '#{@job}' build ##{build_number} started")
        elsif cancelled
          write_output("\nJob '#{@job}' build did not start in timeout period, build #{cancelled ? "" : "NOT "}cancelled")
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

        uri = URI.parse("http#{'s' if @use_ssl}://#{@host}:#{@port}#{@web_path}")

        proxy_uri = nil
        if uri.respond_to?(:find_proxy)
          proxy_uri = uri.find_proxy
        elsif ENV['http_proxy']
          proxy_uri = URI.parse(ENV['http_proxy'])
        end

        if proxy_uri
          write_output("\nConnecting to Jenkins server at #{uri} (proxy #{proxy_uri.host}:#{proxy_uri.port})")
          options[:proxy_ip] = proxy_uri.host
          options[:proxy_port] = proxy_uri.port
        else
          write_output("\nConnecting to Jenkins server at #{uri} (no proxy)")
        end

        if @username
          options[:username] = @username
          options[:password] = @password
          write_output("\nUsing username '#{@username}' and password")
        end

        @client = JenkinsApi::Client.new(options)
        write_output("\nJenkins version #{@client.get_jenkins_version}")
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
          write_output "\nTest results: test count=#{test_count}, failures=#{fail_count}, skipped=#{skip_count}, passed=#{pass_count}, duration=#{test_results['duration']}"
          test_meta = [{:tests => test_count, :failures => fail_count, :skipped => skip_count, :passed => pass_count, :duration => test_results['duration']}]
          save_output_value('tests', test_meta)
        else
          write_output "\nNo test results available"
        end
      end

      def empty?(field)
        get_field(field).nil? or get_field(field).empty?
      end
    end
  end
end
