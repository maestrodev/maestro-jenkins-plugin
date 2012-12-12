

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
        plain = mock()
        plain.stubs(:body => {"jobs" => [{"name" => "test job"}]}.to_json)
        @participant.stubs(:get_plain => plain)
        Jenkins::Api.stubs(:job_names => ['test job'])
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
    
    it "should return false if job does not exists" do
      if @stub_jenkins
        Jenkins::Api.expects(:job_names => [])
      end
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
