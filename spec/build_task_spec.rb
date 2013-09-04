require 'spec_helper'

describe MaestroDev::Plugin::JenkinsWorker do

  let(:fields) { {
    'host' => 'localhost',
    'port' => '8080',
    'web_path' => '',
    'job' => 'Buildaroo',
    'scm_url' => 'git://github.com/maestrodev/CEE.git',
    'steps' => ['bundle', 'rake'],
    'override_existing' => true,
    'build_start_timeout' => 3,
    'cancel_on_build_start_timeout' => true} }
  let(:workitem) { {'fields' => fields} }

  def standard_build_start_webmock(params = nil, build_result = {:body => '', :headers => {'location' => "/item/1/"}})
    # Request for jenkins root, used to get version
    stub_request(:get,  'http://localhost:8080/').to_return(:headers => {'X-Jenkins' => '9.001'})
    # Request for jenkins root, used to get list of projects
    stub_request(:get,  'http://localhost:8080/api/json').to_return(:body => JENKINS_ROOT_WITHOUT_JOB)
    # Request to create Buildaroo job
    stub_request(:post, 'http://localhost:8080/createItem?name=Buildaroo')
    # Request for details about Buildroo project
    stub_request(:get,  'http://localhost:8080/job/Buildaroo/api/json').to_return(:body => BUILDAROO_DETAILS)

    # Request to kick off a build
    if params
      stub_request(:post, 'http://localhost:8080/job/Buildaroo/buildWithParameters').
        with(:body => params).
        to_return(build_result)
    else
      stub_request(:post, 'http://localhost:8080/job/Buildaroo/build').
        to_return(build_result)
    end
  end

  def standard_build_run_webmock(result = {:body => BUILDAROO_STATUS_SUCCESS}, test_result = {:status => 404})
    # Request queue id => build id
    stub_request(:get, 'http://localhost:8080/queue/item/1/api/json').to_return(:body => "{\"executable\":{\"number\":1}}")

    # Request for log text of build
    stub_request(:get,  'http://localhost:8080/job/Buildaroo/1/logText/progressiveText?start=0').
      to_return(:body => BUILDAROO_CONSOLE_1, :headers => {'X-Text-Size' => 100, 'X-More-Data' => true})
    stub_request(:get,  'http://localhost:8080/job/Buildaroo/1/logText/progressiveText?start=100').
      to_return(:body => BUILDAROO_CONSOLE_2, :headers => {'X-Text-Size' => 300})
    # Request for status of a build
    stub_request(:get,  'http://localhost:8080/job/Buildaroo/1//api/json').
      to_return(result)
    # Request for test report
    stub_request(:get,  'http://localhost:8080/job/Buildaroo/1/testReport/api/json').to_return(test_result)
  end

  describe 'build()' do
    
    context "when fields are missing" do
      let(:fields) { super().reject{|k,v| ['host','job'].include?(k) } }
      before { subject.perform(:build, workitem) }
      its(:error) { should include('missing field host') }
      its(:error) { should include('missing field job') }
    end

    it "should build job with jenkins (create job)" do
      standard_build_start_webmock
      standard_build_run_webmock

      subject.perform(:build, workitem)
      subject.error.should be_nil
      subject.output.should be_nil
    end

    context "when building a parameterized job" do
      let(:fields) { super().merge({'parameters' => [ 'param1=value1', 'param2=value2' ] }) }

      it "should build a parameterized job with jenkins (create job)" do
        standard_build_start_webmock({:param1 => 'value1', :param2 => 'value2'})
        standard_build_run_webmock

        subject.perform(:build, workitem)

        subject.error.should be_nil
        subject.output.should be_nil
      end
    end

    it "should fail if build details fails to respond" do
      standard_build_start_webmock

      # Request queue id => build id
      stub_request(:get, 'http://localhost:8080/queue/item/1/api/json').to_return(:body => "{\"executable\":{\"number\":1}}")

      # Request for log
      stub_request(:get,  'http://localhost:8080/job/Buildaroo/1/logText/progressiveText?start=0').
        to_timeout

      subject.perform(:build, workitem)

      subject.error.should start_with('Timed out trying to get build log')
    end

    context "when building jobs with user defined axes" do
      let(:fields) { super().merge({
        'user_defined_axes' => ['goal install package'],
        'label_axes' => ['linux', 'macos'],
        'steps' => ['ls -la /']
        }) }

      it "should build jobs with user defined axes with jenkins" do
        standard_build_start_webmock
        standard_build_run_webmock

        subject.perform(:build, workitem)

        subject.error.should be_nil
        subject.output.should be_nil
      end
    end

    context "when job fails to start" do
      it "when fails immediately" do
        standard_build_start_webmock(nil, {:status => 400, :body => 'What *did* you do?'})

        subject.perform(:build, workitem)
        subject.error.should start_with("Got error invoking build of")
      end

      it "when job is not created" do
        standard_build_start_webmock

        # Request queue id => build id
        stub_request(:get, 'http://localhost:8080/queue/item/1/api/json').to_return(:body => "{\"executable\":{\"number\":1}}")

        # The job is not actually created (yes, it happens)
        stub_request(:get,  'http://localhost:8080/job/Buildaroo/1/logText/progressiveText?start=0').to_return(:status => 404)
        Timeout::timeout(10) { subject.perform(:build, workitem) }

        subject.error.should eq("Error while communicating with Jenkins for Buildaroo build number 1. Requested component is not found on the Jenkins CI server.")
      end

      it "should attempt to cancel pending job if timeout before start" do
        standard_build_start_webmock

        # Request queue id => build id
        stub_request(:get, 'http://localhost:8080/queue/item/1/api/json').to_return(:body => "{}")

        # Allow cancel of job
        stub_request(:post, "http://localhost:8080/queue/cancelItem?id=1").to_return(:status => 302)

        Timeout::timeout(10) { subject.perform(:build, workitem) }

        subject.error.should eq("Jenkins build failed to start in a timely manner")
      end
    end

    it "should supply error when job fails to be created" do
      # Request for jenkins root, used to get version
      stub_request(:get,  'http://localhost:8080/').to_return(:headers => {'X-Jenkins' => '9.001'})
      # Request for jenkins root, used to get list of projects
      stub_request(:get,  'http://localhost:8080/api/json').to_return(:body => JENKINS_ROOT_WITHOUT_JOB)
      # Request to create Buildaroo job
      stub_request(:post, 'http://localhost:8080/createItem?name=Buildaroo').to_return(:status => 500, :body => 'Exception: gone broke<br>')

      subject.perform(:build, workitem)

      subject.error.should start_with('Failed to create job Buildaroo: JenkinsApi::Exceptions::InternalServerError')
    end

    it "should supply error when job fails" do
      standard_build_start_webmock
      standard_build_run_webmock({:status => 200, :body => BUILDAROO_STATUS_FAILED})

      subject.perform(:build, workitem)

      subject.error.should start_with('Jenkins job failed')
      subject.output.should be_nil
    end

  end

end
