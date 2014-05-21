

require 'spec_helper'

describe MaestroDev::Plugin::JenkinsWorker do
  
  describe 'get_build_data' do

    let(:fields) { {
      'host' => 'localhost',
      'port' => '8080',
      'web_path' => '',
      'job' => 'Buildaroo',
      'scm_url' => 'git://github.com/maestrodev/CEE.git',
      'steps' => ['bundle', 'rake'],
      'override_existing' => true
    } }
    let(:workitem) { {'fields' => fields} }

    let(:job_data) { IO.read(File.dirname(__FILE__) + '/job_data.json') }
    let(:build_results) { IO.read(File.dirname(__FILE__) + '/build_results.json') }
    let(:test_report) { IO.read(File.dirname(__FILE__) + '/test_report.json') }

    it "should retrieve the build data" do
      # Request for jenkins root, used to get version
      stub_request(:get,  'http://localhost:8080/').to_return(:headers => {'X-Jenkins' => '9.001'})
      # Request for jenkins root, used to get list of projects
      stub_request(:get,  'http://localhost:8080/api/json').to_return(:body => JENKINS_ROOT_WITH_JOB)
      # Request for details about Buildroo project
      stub_request(:get,  'http://localhost:8080/job/Buildaroo/api/json').to_return(:body => job_data)
      # Request for status of a build
      stub_request(:get,  'http://localhost:8080/job/Buildaroo/22//api/json').
        to_return(:body => build_results)
      # Request for test report
      stub_request(:get,  'http://localhost:8080/job/Buildaroo/22/testReport/api/json').
        to_return(:body => test_report)

      subject.perform(:get_build_data, workitem)

      subject.error.should be_nil
      subject.get_field(Maestro::MaestroWorker::CONTEXT_OUTPUTS_META).should eql({
        'build_number' => 22,
        'build_result' => 'SUCCESS',
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

    context "when the last build number has not changed since last run" do
      let(:fields) { super().merge({'__previous_context_outputs__' => {'build_number' => 22}}) }

      it "should send a not_needed message" do
        # Request for jenkins root, used to get version
        stub_request(:get,  'http://localhost:8080/').to_return(:headers => {'X-Jenkins' => '9.001'})
        # Request for jenkins root, used to get list of projects
        stub_request(:get,  'http://localhost:8080/api/json').to_return(:body => JENKINS_ROOT_WITH_JOB)
        # Request for details about Buildroo project
        stub_request(:get,  'http://localhost:8080/job/Buildaroo/api/json').to_return(:body => job_data)

        subject.expects(:not_needed)

        subject.perform(:get_build_data, workitem)
      end
    end

  end

end
