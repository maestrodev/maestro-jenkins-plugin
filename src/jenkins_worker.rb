require 'rubygems'
require 'jenkins'
require 'maestro_agent'

require File.join(File.dirname(__FILE__),'..','monkey','job_config_builder') 

module MaestroDev
  class JenkinsWorker < Maestro::MaestroWorker

    def setup
      host = workitem['fields']['host']
      port = workitem['fields']['port']
      
      Jenkins::Api.setup_base_url(:host => host, :port => port)
    end
    
    def job_exists?(job_name)
      !Jenkins::Api.job_names.find{|job| job == job_name}.nil?
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
      
      Maestro.log.debug "Loading #{job_name} with #{options.to_json}"
      write_output "Loading #{job_name} with #{options.to_json}\n"

      options[:steps].andand.each do |step|
        steps << [:build_shell_step, step]
        Maestro.log.debug "setting step #{step}"
      end
      
      job_config = Jenkins::JobConfigBuilder.new('none') do |c|
        c.steps         = steps
        c.scm           = options[:scm] || ''
      end
      
      if update
        Jenkins::Api.update_job(job_name, job_config)
      else
        Jenkins::Api.create_job(job_name, job_config)
      end
    end

    def job_name
      workitem['fields']['job']
    end

    def get_next_build_number(job_name)
      job = Jenkins::Api.job(URI.escape(job_name))
      (job['nextBuildNumber'].to_i || 1)
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
      new_console = get_build_console_for_build(job_name, build_number)
      return '' if new_console.include?('Error 404')

      size = (new_console.include?(console))? console.size : 0
      new_size = new_console.size

      Iconv.new('US-ASCII//IGNORE', 'UTF-8').iconv(new_console.slice(size, new_size))
    end

    def build

      Maestro.log.info "Starting JENKINS participant..."
      Maestro.log.info "Inputs: host = #{workitem['fields']['host']}, port = #{workitem['fields']['port']}, job = #{workitem['fields']['job']}, scm_url = #{workitem['fields']['scm_url']}, steps = #{workitem['fields']['steps']}"
      Maestro.log.debug "Beginning Process For Jenkins Job #{job_name}"
      write_output "Beginning Process For Jenkins Job #{job_name}\n"
      begin
        setup
        
        
        Maestro.log.debug "Parsing Steps From #{workitem['fields']['steps']}"
        write_output "Parsing Steps From #{workitem['fields']['steps']}\n"

        steps = workitem['fields']['steps'] 
        steps = JSON.parse steps.gsub(/\'/, '"') if steps.is_a? String

        
        job_exists_already = job_exists?(job_name)
        Maestro.log.debug "Creating Job #{job_name}, None Found" unless job_exists_already
        write_output "Creating Job #{job_name}, None Found\n" unless job_exists_already
        create_job(job_name, {:steps => steps, :scm => workitem['fields']['scm_url']}) unless job_exists_already
        update_job(job_name, {:steps => steps, :scm => workitem['fields']['scm_url']}) if job_exists_already
        
        build_number = get_next_build_number(job_name)
        Maestro.log.debug "Previous Build Number Is #{build_number}"
        write_output "Previous Build Number Is #{build_number}\n"
        
        success = Jenkins::Api.build_job(URI.encode(job_name))
        Maestro.log.debug "Jenkins Job Started #{success ? "" : "Not"} Successfully"
        write_output "Jenkins Job Started #{success ? "" : "Not "}Successfully\n"
        
        if !success
          workitem['fields']['__error__'] = "Jenkins job failed to start" 
          return
        end

        console = ""

        begin
          begin
            details = get_build_details_for_build(job_name, build_number)
            write_output find_new_console(job_name,build_number, console)

            console = get_build_console_for_build(job_name,build_number)
          rescue Timeout::Error => te
            if defined? failures
              failures += 1
            else
              failures = 0
            end
            raise if failures > 5
          end
          sleep(2)

        end while details.is_a? FalseClass  or (details.is_a?Hash and details["building"])

        write_output find_new_console(job_name,build_number, console)

        console = get_build_console_for_build(job_name,build_number)

        success = details['result'] == 'SUCCESS'


        Maestro.log.debug "Jenkins Job Completed #{success ? "" : "Not"} Successfully"
        write_output "Jenkins Job Completed #{success ? "" : "Not "}Successfully\n"
        
        workitem['fields']['__error__'] = "Jenkins job failed" if !success
        workitem['fields']['output'] = Iconv.new('US-ASCII//IGNORE', 'UTF-8').iconv(console)

      rescue Exception => e
        puts e, e.backtrace
        message = "Jenkins job failed "
        if e.message.match("Invalid JSON string")
          message += "make sure Jenkins settings are correct Host = #{workitem['fields']['host'] || config['jenkins']['host']} Port = #{ workitem['fields']['port'] || config['jenkins']['port']}"
        else
          message += e.message
        end

        workitem['fields']['__error__'] = "Jenkins job failed #{message}"
        return
      end
      Maestro.log.debug "Finished Processing Jenkins Job"

      Maestro.log.info "***********************Completed JENKINS***************************"
    end

    private 
    
    # Helper for GET that don't barf at Jenkins's crappy API responses
    def get_plain(path, options = {})
      
      options = options.with_clean_keys
      uri = URI.parse Jenkins::Api.base_uri
      res = Net::HTTP.start(uri.host, uri.port) { |http| http.get(URI.escape(path), options) }
    end


    def post_plain(path, data = "", options = {})
      options = options.with_clean_keys
      uri = URI.parse Jenkins::Api.base_uri
      res = Net::HTTP.start(uri.host, uri.port) do |http|
        
        if RUBY_VERSION =~ /1.8/
          http.post(URI.escape(path), options)
        else
          http.post(URI.escape(path), data, options)
        end
      end
    end
    
  end
end
