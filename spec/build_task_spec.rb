

require 'spec_helper'

describe MaestroDev::JenkinsWorker do
  
  JOB_CONSOLE = "Started by user anonymous\n[workspace] $ /bin/sh -xe /tmp/hudson5379787065231741934.sh\n+ rake\nrake/rdoctask is deprecated.  Use rdoc/task instead (in RDoc 2.4.2+)\n/opt/ruby/bin/ruby -S rspec --colour spec/client_spec.rb spec/connection_spec.rb spec/message_spec.rb\nJeweler not available. Install it with: gem install jeweler\n...........................................................................................connect to localhost failed: exception will retry(#0) in 0.01\n................\n\nFinished in 0.16676 seconds\n107 examples, 0 failures\nFinished: SUCCESS\n"
  
  let(:stub_jenkins) { true }
  let(:local_path) { "/tmp/stomp" }

  before(:each) do
    subject.stubs(:write_output)
    workitem = {'fields' => {
      'host' => 'test',
      'web_path' => 'jenkins' }}
    subject.stubs(:workitem => workitem)
    subject.setup
    
    local_path = "/tmp/stomp"
    if !stub_jenkins
      git = Grit::Git.new(local_path)
      git.clone({:quiet => false, :timeout => 60, :verbose => true, :progress => true, :branch => 'm1.1.8'}, "https://github.com/kellyp/stomp.git", local_path)
      raise "git clone failed to dir - #{local_path}" if not File.exists?("#{local_path}/Rakefile") 
    end
  end
  
  describe 'setup' do
    let(:fields) { {
        'host' => 'jenkins.acme.com',
        'port' => 9999,
        'web_path' => 'jk',
        'username' => 'john',
        'password' => 'pass'
      } }

    it 'should return the jenkins server uri' do
      subject.stubs(:workitem => {'fields' => fields})
      subject.setup.to_s.should eq('http://jenkins.acme.com:9999/jk')
    end

    it 'should return the jenkins server uri with https' do
      subject.stubs(:workitem => {'fields' => fields.merge({'use_ssl' => true, 'web_path' => nil})})
      subject.setup.to_s.should eq('https://jenkins.acme.com:9999/')
    end
  end

  describe 'job_exists?' do
    before :each do
      #create job
      if !stub_jenkins
        subject.delete_job('test job')
        subject.create_job('test job', {:steps => ["bundle", "rspec spec"]})
      else
        #do stubs here
      end
    end
    
    it "should return true if job exists" do
      if stub_jenkins
        plain = mock()
        plain.stubs(:code => 200, :body => {"jobs" => [{"name" => "test job"}]}.to_json)
        subject.stubs(:get_plain_url).returns(plain)
      end
      subject.job_exists?('test job').should be_true
      subject.error.should be_nil
    end

    it "should delete job" do
      if stub_jenkins
        plain = mock()
        plain.stubs(:body => {"jobs" => []}.to_json)
        subject.stubs(:post_plain_url).returns(plain)
        subject.stubs(:get_plain_url).returns(plain)
      end
      subject.delete_job('test job')
      subject.job_exists?('test job').should be_false
      subject.error.should be_nil
    end
    
    it "should return false if job does not exist" do
      response = mock()
      response.stubs(:body => {:jobs => []}.to_json)
      subject.expects(:get_plain_url).with("http://test/jenkins/api/json").returns(response)
      subject.job_exists?('not a real job').should be_false      
      subject.error.should be_nil
    end

    it "should return false if unable to parse json" do
      if stub_jenkins
        plain = mock()
        plain.stubs(:body => "{}}")
        subject.stubs(:get_plain_url => plain)
      end
      subject.job_exists?('job').should be_false
      subject.error.should include("Unable To Parse JSON")
      subject.error.should include("unexpected token at '}'")
    end
  end
  
  describe 'build()' do
    
    it "should validate fields" do
      workitem = {'fields' => {
         'host' => ''
         # 'job' => nil,
         # 'port' => nil
      }}
      subject.expects(:workitem).at_least_once.returns(workitem)
      subject.build

      subject.fields['port'].should == 80
      subject.error.should include("Missing Fields: host,job")
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

      if stub_jenkins
        subject.stubs(:job_exists? => false)
        subject.stubs(:get_test_results => nil)

        Jenkins::Api.expects(:create_job => [])
        response = mock
        response.stubs(:code => "200")
        subject.expects(:post_plain_url).with("https://localhost/jenkins/job/CEE%20Buildaroo/build", '', {}).returns(response)
        # Jenkins::Api.stubs(:build_job => true)
        Jenkins::Api.stubs(:job => {"nextBuildNumber" => 1})
        # on first invocation job is not ready yet
        e = Net::HTTPServerException.new("not found", Net::HTTPNotFound.new(nil,nil,nil))
        Jenkins::Api.expects(:build_details).twice.with("CEE%20Buildaroo", 1).raises(e).then.returns({"building" => false, "result" => "SUCCESS"})
      end
      subject.expects(:get_build_console_for_build => JOB_CONSOLE).at_least_once
      subject.expects(:workitem).at_least_once.returns(workitem)
      subject.build

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
      subject.stubs(:workitem => workitem)
      subject.stubs(:get_test_results => nil)
      subject.expects(:post_plain_url).with("https://localhost/jenkins/job/Parameterized%20CEE%20Buildaroo/buildWithParameters?param1=value1&param2=value2", '', {}).returns(response)
      subject.setup
      subject.build_job(job_name, parameters)
    end

    it "should fail if build details fails to respond" do
      workitem = {'fields' => {
         'host' => 'localhost',
         'job' => 'CEE Buildaroo',
         'steps' => ['bundle', 'rake'],
         'override_existing' => true
      }}

      if stub_jenkins
        subject.stubs(:job_exists? => false)
        subject.stubs(:create_job => [])
        subject.stubs(:get_next_build_number => 1)
        subject.stubs(:build_job => true)
        e = Net::HTTPServerException.new("not found", Net::HTTPNotFound.new(nil,nil,nil))
        subject.stubs(:get_build_details_for_build).times(6).with("CEE Buildaroo", 1).raises(e)
      end
      subject.expects(:workitem).at_least_once.returns(workitem)
      subject.build

      subject.error.should eq("Timed out trying to get build details for CEE Buildaroo build number 1")
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

      if stub_jenkins
        subject.stubs(:job_exists? => false)
        subject.stubs(:get_test_results => nil)
        Jenkins::Api.expects(:create_job => [])
        response = mock
        response.stubs(:code => "200")
        subject.stubs(:post_plain_url => response)
        # Jenkins::Api.stubs(:build_job => true)
        Jenkins::Api.stubs(:job => {"nextBuildNumber" => 1})
        Jenkins::Api.stubs(:build_details => {"building" => false, "result" => "SUCCESS"})
      end
      subject.expects(:get_build_console_for_build => JOB_CONSOLE).at_least_once
      subject.expects(:workitem).at_least_once.returns(workitem)
      subject.build

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
      if stub_jenkins
        Jenkins::Api.expects(:create_job => [])
        Jenkins::Api.stubs(:job_names => [])
        Jenkins::Api.stubs(:job => {"nextBuildNumber" => 1})
        Jenkins::Api.stubs(:build_details => {"building" => false, "result" => "SUCCESS"})
      end
      subject.stubs(:job_exists? => false)
      subject.stubs(:build_job => false)
      subject.stubs(:workitem => workitem)
      subject.build

      workitem['fields']['__error__'].should eql("Jenkins job failed to start")
    end

    it "should supply error when job fails to be created" do
      workitem = {'fields' => {
        'host' => 'localhost',
        'web_path' => 'jenkins',
        'use_ssl' => false,
        'job' => 'myjob',
        'override_existing' => true}}

      if stub_jenkins
        request = {:body => '<?xml version=\'1.0\' encoding=\'UTF-8\'?>\n<project>\n  <actions/>\n  <description/>\n  <keepDependencies>false</keepDependencies>\n  <properties/>\n  <canRoam>true</canRoam>\n  <disabled>false</disabled>\n  <blockBuildWhenUpstreamBuilding>false</blockBuildWhenUpstreamBuilding>\n  <triggers class=\'vector\'/>\n  <concurrentBuild>false</concurrentBuild>\n  <builders>\n  </builders>\n  <publishers/>\n  <buildWrappers/>\n</project>\n', :format => :xml, :headers => {'content-type' => 'application/xml'}}
        response = stub('response', :code => 500, :body => 'error')
        Jenkins::Api.expects(:post).with("/createItem/api/xml?name=myjob", Mocha::ParameterMatchers::Anything.new).returns(response)
        # Jenkins::Api.stubs(:job_names => [])
        # Jenkins::Api.stubs(:job => {"nextBuildNumber" => 1})
      end
      subject.stubs(:workitem => workitem)
      subject.stubs(:job_exists? => false)
      subject.build

      subject.error.should eql("Failed to create job myjob: 500 error")
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
      subject.expects(:get_plain_url).with("https://localhost/jenkins/api/json").returns(response)

      Jenkins::Api.stubs(:job => {"nextBuildNumber" => 1})
      Jenkins::Api.stubs(:build_details => {"building" => false, "result" => "Not SUCCESS"})
      subject.stubs(:build_job => true)
      subject.stubs(:get_test_results => nil)
      subject.expects(:get_build_console_for_build => "").at_least_once
      subject.expects(:workitem).at_least_once.returns(workitem)
      subject.build

      workitem['fields']['__error__'].should eql("Jenkins job failed")
    end

  end

  describe 'get_build_data' do

    before(:each) do
      @job_name = 'lucee-lib-ci'
      @build_number = '22'
      workitem = {'fields' => {
          'host' => 'localhost',
          'web_path' => 'jenkins',
          'use_ssl' => true,
          'job' => @job_name,
      }}
      subject.stubs(:workitem => workitem)
      @job_data = IO.read(File.dirname(__FILE__) + '/job_data.json')
      @build_results = IO.read(File.dirname(__FILE__) + '/build_results.json')
      @test_report = IO.read(File.dirname(__FILE__) + '/test_report.json')

    end

    it "should retrieve the job data" do
      job_data_response = mock
      job_data_response.stubs(:body => @job_data)
      subject.expects(:get_plain).with("/job/#{@job_name}/api/json").returns(job_data_response)
      subject.get_job_data(@job_name)['name'].should == @job_name

    end

    it "should retrieve the test report" do
      test_report_response = mock
      test_report_response.stubs(:body => @test_report)
      subject.expects(:get_plain).with("/job/#{@job_name}/#{@build_number}/testReport/api/json").returns(test_report_response)
      subject.get_test_results(@job_name,@build_number)['totalCount'].should == 107
    end

    it "should retrieve the test data from the latest completed build" do

      subject.expects(:job_exists?).with(@job_name).returns(true)
      subject.expects(:get_build_details_for_build).with(@job_name, @build_number.to_i).returns(JSON.parse(@build_results))
      job_data_response = mock
      job_data_response.stubs(:body => @job_data)
      subject.expects(:get_plain).with("/job/#{@job_name}/api/json").returns(job_data_response)
      test_report_response = mock
      test_report_response.stubs(:body => @test_report)
      subject.expects(:get_plain).with("/job/#{@job_name}/#{@build_number}/testReport/api/json").returns(test_report_response)

      test_meta = [{:tests => 107, :failures => 0, :skipped => 1, :passed => 106, :duration => nil}]
      link_meta = {'build' => 'https://maestro.maestrodev.com/jenkins/job/lucee-lib-ci/22/', 'test' => 'https://maestro.maestrodev.com/jenkins/job/lucee-lib-ci/22/testReport'}
      subject.expects(:save_output_value).with('build_number', @build_number.to_i)
      subject.expects(:save_output_value).with('tests', test_meta)
      subject.expects(:save_output_value).with('links', link_meta)

      subject.get_build_data

    end

    it "should send a not_needed message if the last build number has not changed since last run" do
      subject.expects(:job_exists?).with(@job_name).returns(true)
      job_data_response = mock
      job_data_response.stubs(:body => @job_data)
      subject.expects(:read_output_value).with('build_number').returns(@build_number.to_i)
      subject.expects(:get_plain).with("/job/#{@job_name}/api/json").returns(job_data_response)
      subject.expects(:save_output_value).with('build_number', @build_number.to_i)
      subject.expects(:not_needed)
      subject.get_build_data
    end



  end

end
