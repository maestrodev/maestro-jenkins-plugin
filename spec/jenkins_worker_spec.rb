

require 'spec_helper'

describe MaestroDev::JenkinsWorker do
  
  JOB_CONSOLE = "Started by user anonymous\n[workspace] $ /bin/sh -xe /tmp/hudson5379787065231741934.sh\n+ rake\nrake/rdoctask is deprecated.  Use rdoc/task instead (in RDoc 2.4.2+)\n/opt/ruby/bin/ruby -S rspec --colour spec/client_spec.rb spec/connection_spec.rb spec/message_spec.rb\nJeweler not available. Install it with: gem install jeweler\n...........................................................................................connect to localhost failed: exception will retry(#0) in 0.01\n................\n\nFinished in 0.16676 seconds\n107 examples, 0 failures\nFinished: SUCCESS\n"
  
  before(:all) do

    @participant = MaestroDev::JenkinsWorker.new
    @participant.stubs(:write_output)
    workitem = {'fields' => {}}
    @participant.stubs(:workitem => workitem)
    @participant.setup
    
    @stub_jenkins = true
    
    @local_path = "/tmp/stomp"
    if !@stub_jenkins
      git = Grit::Git.new(@local_path)

      git.clone({:quiet => false, :timeout => 60, :verbose => true, :progress => true, :branch => 'm1.1.8'}, "https://github.com/kellyp/stomp.git", @local_path)
  
      raise "git clone failed to dir - #{@local_path}" if not File.exists?("#{@local_path}/Rakefile") 
    end
  end
  
  describe 'job_exits?' do
    before :all do
      #create job
      if !@stub_jenkins
        @participant.delete_job('test job')
        @participant.create_job('test job', {:steps => ["bundle", "rspec spec"]})
      else
        #do stubs here
      end
    end
    
    it "should return true if job exists" do
      if @stub_jenkins
        Jenkins::Api.stubs(:job_names => ['test job'])
      end
      @participant.job_exists?('test job').should be_true
    end

    it "should delete job" do
      if @stub_jenkins
        @participant.expects(:post_plain)
        Jenkins::Api.stubs(:job_names => [])
      end
      @participant.delete_job('test job')
      @participant.job_exists?('test job').should be_false
    end
    
    it "should return false if job does not exists" do
      if @stub_jenkins
        Jenkins::Api.expects(:job_names => [])
      end
      @participant.job_exists?('not a real job').should be_false      
    end
  end
  
  describe 'build()' do
    
    it "should build job with jenkins" do
      
      workitem = {'fields' => {
         'host' => 'localhost',
         'web_path' => 'jenkins',
         'use_ssl' => true,
         'job' => 'CEE Buildaroo',
         'scm_url' => 'http://kellyp:door4rim@github.com/maestrodev/CEE.git',
         'steps' => ['bundle', 'rake'],
         'override_existing' => true
      }}

      
      if @stub_jenkins
        Jenkins::Api.stubs(:job_names => [])
        Jenkins::Api.expects(:create_job => [])
        response = mock
        response.stub(:code => "200")
        @participant.stubs(:get_plain => response)
        # Jenkins::Api.stubs(:build_job => true)
        Jenkins::Api.stubs(:job => {"nextBuildNumber" => 1})
        Jenkins::Api.stubs(:build_details => {"building" => false, "result" => "SUCCESS"})        
      end
      @participant.expects(:get_build_console_for_build => JOB_CONSOLE).at_least_once
      @participant.expects(:workitem).at_least_once.returns(workitem)
      @participant.build
      
      workitem['fields']['__error__'].should be_nil
      workitem['fields']['output'].should eql(JOB_CONSOLE)
    end
    
    it "should supply error when job fails to start" do
       workitem = {'fields' => {
           'host' => 'localhost',
           'web_path' => 'jenkins',
           'use_ssl' => true,
           'job' => 'stomp',
         'override_existing' => true}}
  
       Jenkins::Api.stubs(:build_job => false)
       if @stub_jenkins
         Jenkins::Api.expects(:create_job => [])
         Jenkins::Api.stubs(:job_names => [])
         Jenkins::Api.stubs(:job => {"nextBuildNumber" => 1})
         Jenkins::Api.stubs(:build_details => {"building" => false, "result" => "SUCCESS"})        
       end
       @participant.stubs(:build_job => false)
       @participant.stubs(:workitem => workitem)
       @participant.build
       
       workitem['fields']['__error__'].should eql("Jenkins job failed to start")
     end
  
     it "should supply error when job fails" do
       workitem = {'fields' => {
           'host' => 'localhost',
           'web_path' => 'jenkins',
           'use_ssl' => true,
           'job' => 'CEE Buildaroo',
           'job' => 'stomp',
                  'override_existing' => true
         }}
       
       #all stubs
       Jenkins::Api.stubs(:job_names => [])
       Jenkins::Api.expects(:create_job => [])
       response = mock
       response.stub(:code => "200")
       @participant.stubs(:get_plain => response)

       Jenkins::Api.stubs(:job => {"nextBuildNumber" => 1})
       Jenkins::Api.stubs(:build_details => {"building" => false, "result" => "Not SUCCESS"})
       @participant.stubs(:build_job => true)
       @participant.expects(:get_build_console_for_build => "").at_least_once
       @participant.expects(:workitem).at_least_once.returns(workitem)
       @participant.build
       
       workitem['fields']['__error__'].should eql("Jenkins job failed")
     end
     
  end
  

  
end
