

require 'spec_helper'

describe MaestroDev::JenkinsWorker do
  
  JOB_CONSOLE = "Started by user anonymous\n[workspace] $ /bin/sh -xe /tmp/hudson5379787065231741934.sh\n+ rake\nrake/rdoctask is deprecated.  Use rdoc/task instead (in RDoc 2.4.2+)\n/opt/ruby/bin/ruby -S rspec --colour spec/client_spec.rb spec/connection_spec.rb spec/message_spec.rb\nJeweler not available. Install it with: gem install jeweler\n...........................................................................................connect to localhost failed: exception will retry(#0) in 0.01\n................\n\nFinished in 0.16676 seconds\n107 examples, 0 failures\nFinished: SUCCESS\n"
  
  before(:each) do
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
  
  describe 'setup' do
    before :each do
      @fields = {
         'host' => 'jenkins.acme.com',
         'port' => 9999,
         'web_path' => 'jk',
         'username' => 'john',
         'password' => 'pass'
      }
    end

    it 'should return the jenkins server uri' do
      @participant.stubs(:workitem => {'fields' => @fields})
      @participant.setup.to_s.should eq('http://jenkins.acme.com:9999/jk')
    end
    it 'should return the jenkins server uri with https' do
      @participant.stubs(:workitem => {'fields' => @fields.merge({'use_ssl' => true, 'web_path' => nil})})
      @participant.setup.to_s.should eq('https://jenkins.acme.com:9999/')
    end
  end

  describe 'job_exists?' do
    before :each do
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
        plain = mock()
        plain.stubs(:code => 200, :body => {"jobs" => [{"name" => "test job"}]}.to_json)
        @participant.stubs(:get_plain).returns(plain)
      end
      @participant.job_exists?('test job').should be_true
      @participant.error.should be_nil
    end

    it "should delete job" do
      if @stub_jenkins
        @participant.expects(:post_plain)
        plain = mock()
        plain.stubs(:body => {"jobs" => []}.to_json)
        @participant.stubs(:get_plain => plain)
      end
      @participant.delete_job('test job')
      @participant.job_exists?('test job').should be_false
      @participant.error.should be_nil
    end
    
    it "should return false if job does not exist" do
      response = mock()
      response.stubs(:body => {:jobs => []}.to_json)
      @participant.expects(:get_plain).with("//api/json").returns(response)
      @participant.job_exists?('not a real job').should be_false      
      @participant.error.should be_nil
    end

    it "should return false if unable to parse json" do
      if @stub_jenkins
        plain = mock()
        plain.stubs(:body => "{}}")
        @participant.stubs(:get_plain => plain)
      end
      @participant.job_exists?('job').should be_false
      @participant.error.should include("Unable To Parse JSON")
      @participant.error.should include("unexpected token at '}'")
    end
  end
  
  describe 'build()' do
    
    it "should validate fields" do
      workitem = {'fields' => {
         'host' => ''
         # 'job' => nil,
         # 'port' => nil
      }}
      @participant.expects(:workitem).at_least_once.returns(workitem)
      @participant.build

      @participant.fields['port'].should == 80
      @participant.error.should include("Missing Fields: host,job")
    end

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
        @participant.stubs(:job_exists? => false)

        Jenkins::Api.expects(:create_job => [])
        response = mock
        response.stubs(:code => "200")
        @participant.stubs(:get_plain => response)
        # Jenkins::Api.stubs(:build_job => true)
        Jenkins::Api.stubs(:job => {"nextBuildNumber" => 1})
        # on first invocation job is not ready yet
        e = Net::HTTPServerException.new("not found", Net::HTTPNotFound.new(nil,nil,nil))
        Jenkins::Api.expects(:build_details).twice.with("CEE%20Buildaroo", 1).raises(e).then.returns({"building" => false, "result" => "SUCCESS"})
      end
      @participant.expects(:get_build_console_for_build => JOB_CONSOLE).at_least_once
      @participant.expects(:workitem).at_least_once.returns(workitem)
      @participant.build

      workitem['fields']['__error__'].should be_nil
      workitem['fields']['output'].should eql(JOB_CONSOLE)
    end

    it "should build a parameterized job with jenkins" do

      job_name = 'Parameterized CEE Buildaroo'
      parameters = [ 'param1=value1', 'param2=value2' ]
      workitem = {'fields' => {
          'host' => 'localhost',
          'web_path' => 'jenkins',
          'use_ssl' => true,
          'job' => job_name,
          'override_existing' => false,
          'parameters' => parameters
      }}
      response = stub(:code => "200")
      @participant.stubs(:workitem => workitem)
      @participant.expects(:get_plain).with("/jenkins/job/Parameterized CEE Buildaroo/buildWithParameters?param1=value1&param2=value2").returns(response)
      @participant.setup
      @participant.build_job(job_name, parameters)

    end

    it "should fail if build details fails to respond" do
      workitem = {'fields' => {
         'host' => 'localhost',
         'job' => 'CEE Buildaroo',
         'steps' => ['bundle', 'rake'],
         'override_existing' => true
      }}

      if @stub_jenkins
        @participant.stubs(:job_exists? => false)
        @participant.stubs(:create_job => [])
        @participant.stubs(:get_next_build_number => 1)
        @participant.stubs(:build_job => true)
        e = Net::HTTPServerException.new("not found", Net::HTTPNotFound.new(nil,nil,nil))
        @participant.stubs(:get_build_details_for_build).times(6).with("CEE Buildaroo", 1).raises(e)
      end
      @participant.expects(:workitem).at_least_once.returns(workitem)
      @participant.build

      @participant.error.should eq("Timed out trying to get build details for CEE Buildaroo build number 1")
    end

    it "should build jobs with user defined axes with jenkins" do
      workitem = {'fields' => {
          'host' => 'localhost',
          'web_path' => 'jenkins',
          'use_ssl' => true,
          'job' => 'Centerpoint',
          'scm_url' => 'https://github.com/etiennep/centrepoint/',
          'override_existing' => true,
          'user_defined_axes' => ['goal install package'],
          'label_axes' => ['linux', 'macos'],
          'steps' => ['ls -la /']

      }}


      if @stub_jenkins
        @participant.stubs(:job_exists? => false)
        Jenkins::Api.expects(:create_job => [])
        response = mock
        response.stubs(:code => "200")
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
       @participant.stubs(:job_exists? => false)
       @participant.stubs(:build_job => false)
       @participant.stubs(:workitem => workitem)
       @participant.build

       workitem['fields']['__error__'].should eql("Jenkins job failed to start")
    end

    it "should supply error when job fails to be created" do
      workitem = {'fields' => {
        'host' => 'localhost',
        'web_path' => 'jenkins',
        'use_ssl' => false,
        'job' => 'myjob',
        'override_existing' => true}}

      if @stub_jenkins
        request = {:body => '<?xml version=\'1.0\' encoding=\'UTF-8\'?>\n<project>\n  <actions/>\n  <description/>\n  <keepDependencies>false</keepDependencies>\n  <properties/>\n  <canRoam>true</canRoam>\n  <disabled>false</disabled>\n  <blockBuildWhenUpstreamBuilding>false</blockBuildWhenUpstreamBuilding>\n  <triggers class=\'vector\'/>\n  <concurrentBuild>false</concurrentBuild>\n  <builders>\n  </builders>\n  <publishers/>\n  <buildWrappers/>\n</project>\n', :format => :xml, :headers => {'content-type' => 'application/xml'}}
        response = mock('response')
        response.stubs(:code => 500, :body => 'error')
        Jenkins::Api.expects(:post).with("/createItem/api/xml?name=myjob", Mocha::ParameterMatchers::Anything.new).returns(response)
        # Jenkins::Api.stubs(:job_names => [])
        # Jenkins::Api.stubs(:job => {"nextBuildNumber" => 1})
      end
      @participant.stubs(:workitem => workitem)
      @participant.stubs(:job_exists? => false)
      @participant.build

      @participant.error.should eql("Failed to create job myjob: 500 error")
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
      response = mock()
      response.stubs(:code => 200, :body => {:jobs => []}.to_json)
      @participant.expects(:get_plain).with("/jenkins/api/json").returns(response)

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
