

require 'spec_helper'

describe MaestroDev::JenkinsWorker do
  
  describe 'get_build_data' do

    before(:each) do
      @job_data = IO.read(File.dirname(__FILE__) + '/job_data.json')
      @build_results = IO.read(File.dirname(__FILE__) + '/build_results.json')
      @test_report = IO.read(File.dirname(__FILE__) + '/test_report.json')
    end

    it "should retrieve the build data" do
      # Request for jenkins root, used to get list of projects
      stub_request(:get,  'http://localhost:8080/api/json').to_return(:body => JENKINS_ROOT_WITH_JOB)
      # Request for details about Buildroo project
      stub_request(:get,  'http://localhost:8080/job/Buildaroo/api/json').to_return(:body => @job_data)
      # Request for status of a build
      stub_request(:get,  'http://localhost:8080/job/Buildaroo/22//api/json').
        to_return(:body => @build_results)
      # Request for test report
      stub_request(:get,  'http://localhost:8080/job/Buildaroo/22/testReport/api/json').
        to_return(:body => @test_report)

      subject.perform(:get_build_data, @workitem)

      @workitem['fields']['__error__'].should be_nil
      @workitem['fields']['output'].should be_nil
      @workitem['fields']['__context_outputs__'].should eql({
        'build_number' => 22,
        'tests' => [{
          :tests => 107,
          :failures => 0,
          :skipped => 1,
          :passed => 106,
          :duration => nil}],
        'links' => {
          'build' => 'https://maestro.maestrodev.com/jenkins/job/lucee-lib-ci/22/',
          'log' => 'https://maestro.maestrodev.com/jenkins/job/lucee-lib-ci/22/console',
          'test' => 'https://maestro.maestrodev.com/jenkins/job/lucee-lib-ci/22/testReport'}})
    end

    it "should send a not_needed message if the last build number has not changed since last run" do
      @workitem['fields']['__previous_context_outputs__'] = {'build_number' => 22}

      # Request for jenkins root, used to get list of projects
      stub_request(:get,  'http://localhost:8080/api/json').to_return(:body => JENKINS_ROOT_WITH_JOB)
      # Request for details about Buildroo project
      stub_request(:get,  'http://localhost:8080/job/Buildaroo/api/json').to_return(:body => @job_data)

      subject.expects(:not_needed)

      subject.perform(:get_build_data, @workitem)
    end

  end

end
