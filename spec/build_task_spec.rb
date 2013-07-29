require 'spec_helper'

describe MaestroDev::Plugin::JenkinsWorker do

  describe 'build()' do
    
    it "should validate fields" do
      @workitem['fields'].delete('host')
      @workitem['fields'].delete('job')
      subject.perform(:build, @workitem)

      subject.error.should include("Missing Fields: host,job")
    end

    it "should build job with jenkins (create job)" do
      # Request for jenkins root, used to get list of projects
      stub_request(:get,  'http://localhost:8080/api/json').to_return(:body => JENKINS_ROOT_WITHOUT_JOB)
      # Request to create Buildaroo job
      stub_request(:post, 'http://localhost:8080/createItem?name=Buildaroo')
      # Request for details about Buildroo project
      stub_request(:get,  'http://localhost:8080/job/Buildaroo/api/json').to_return(:body => BUILDAROO_DETAILS)
      # Request to kick off a build
      stub_request(:post, 'http://localhost:8080/job/Buildaroo/build').to_return(:body => '')
      # Request for status of a build
      stub_request(:get,  'http://localhost:8080/job/Buildaroo/1//api/json').
        to_return(:status => 404).then.
        to_return(:body => BUILDAROO_STATUS_BUILDING).then.
        to_return(:body => BUILDAROO_STATUS_SUCCESS)
      # Request for log text of build
      stub_request(:get,  'http://localhost:8080/job/Buildaroo/1/logText/progressiveText?start=0').
        to_return(:body => BUILDAROO_CONSOLE_1, :headers => {'X-Text-Size' => 100, 'X-More-Data' => true})
      stub_request(:get,  'http://localhost:8080/job/Buildaroo/1/logText/progressiveText?start=100').
        to_return(:body => BUILDAROO_CONSOLE_2, :headers => {'X-Text-Size' => 300})
      stub_request(:get,  'http://localhost:8080/job/Buildaroo/1/logText/progressiveText?start=300').
        to_return(:body => BUILDAROO_CONSOLE_3, :headers => {'X-Text-Size' => 300})
      # Request for test report
      stub_request(:get,  'http://localhost:8080/job/Buildaroo/1/testReport/api/json').to_return(:status => 404)

      subject.perform(:build, @workitem)

      @workitem['fields']['__error__'].should be_nil
      @workitem['fields']['output'].should be_nil
    end

    it "should build a parameterized job with jenkins (create job)" do
      @workitem['fields']['parameters'] = [ 'param1=value1', 'param2=value2' ]

      # Request for jenkins root, used to get list of projects
      stub_request(:get,  'http://localhost:8080/api/json').to_return(:body => JENKINS_ROOT_WITHOUT_JOB)
      # Request to create Buildaroo job
      stub_request(:post, 'http://localhost:8080/createItem?name=Buildaroo')
      # Request for details about Buildroo project
      stub_request(:get,  'http://localhost:8080/job/Buildaroo/api/json').to_return(:body => BUILDAROO_DETAILS)
      # Request to kick off a build
      stub_request(:post, 'http://localhost:8080/job/Buildaroo/buildWithParameters').
        with(:body => {:param1 => 'value1', :param2 => 'value2'}).
        to_return(:body => '')
      # Request for status of a build
      stub_request(:get,  'http://localhost:8080/job/Buildaroo/1//api/json').
        to_return(:status => 404).then.
        to_return(:body => BUILDAROO_STATUS_BUILDING).then.
        to_return(:body => BUILDAROO_STATUS_SUCCESS)
      # Request for log text of build
      stub_request(:get,  'http://localhost:8080/job/Buildaroo/1/logText/progressiveText?start=0').
        to_return(:body => BUILDAROO_CONSOLE_1, :headers => {'X-Text-Size' => 100, 'X-More-Data' => true})
      stub_request(:get,  'http://localhost:8080/job/Buildaroo/1/logText/progressiveText?start=100').
        to_return(:body => BUILDAROO_CONSOLE_2, :headers => {'X-Text-Size' => 300})
      stub_request(:get,  'http://localhost:8080/job/Buildaroo/1/logText/progressiveText?start=300').
        to_return(:body => BUILDAROO_CONSOLE_3, :headers => {'X-Text-Size' => 300})
      # Request for test report
      stub_request(:get,  'http://localhost:8080/job/Buildaroo/1/testReport/api/json').to_return(:status => 404)

      subject.perform(:build, @workitem)

      @workitem['fields']['__error__'].should be_nil
      @workitem['fields']['output'].should be_nil
    end

    it "should fail if build details fails to respond" do
      # Request for jenkins root, used to get list of projects
      stub_request(:get,  'http://localhost:8080/api/json').to_return(:body => JENKINS_ROOT_WITHOUT_JOB)
      # Request to create Buildaroo job
      stub_request(:post, 'http://localhost:8080/createItem?name=Buildaroo')
      # Request for details about Buildroo project
      stub_request(:get,  'http://localhost:8080/job/Buildaroo/api/json').to_return(:body => BUILDAROO_DETAILS)
      # Request to kick off a build
      stub_request(:post, 'http://localhost:8080/job/Buildaroo/build').to_return(:body => '')
      # Request for status of a build
      stub_request(:get,  'http://localhost:8080/job/Buildaroo/1//api/json').
        to_timeout

      subject.perform(:build, @workitem)

      subject.error.should eq("Timed out trying to get build details for Buildaroo build number 1")
    end

    it "should build jobs with user defined axes with jenkins" do
      @workitem['fields']['user_defined_axes'] = ['goal install package']
      @workitem['fields']['label_axes'] = ['linux', 'macos']
      @workitem['fields']['steps'] = ['ls -la /']

      # Request for jenkins root, used to get list of projects
      stub_request(:get,  'http://localhost:8080/api/json').to_return(:body => JENKINS_ROOT_WITHOUT_JOB)
      # Request to create Buildaroo job
      stub_request(:post, 'http://localhost:8080/createItem?name=Buildaroo')
      # Request for details about Buildroo project
      stub_request(:get,  'http://localhost:8080/job/Buildaroo/api/json').to_return(:body => BUILDAROO_DETAILS)
      # Request to kick off a build
      stub_request(:post, 'http://localhost:8080/job/Buildaroo/build').to_return(:body => '')
      # Request for status of a build
      stub_request(:get,  'http://localhost:8080/job/Buildaroo/1//api/json').
        to_return(:status => 404).then.
        to_return(:body => BUILDAROO_STATUS_BUILDING).then.
        to_return(:body => BUILDAROO_STATUS_SUCCESS)
      # Request for log text of build
      stub_request(:get,  'http://localhost:8080/job/Buildaroo/1/logText/progressiveText?start=0').
        to_return(:body => BUILDAROO_CONSOLE_1, :headers => {'X-Text-Size' => 100, 'X-More-Data' => true})
      stub_request(:get,  'http://localhost:8080/job/Buildaroo/1/logText/progressiveText?start=100').
        to_return(:body => BUILDAROO_CONSOLE_2, :headers => {'X-Text-Size' => 300})
      stub_request(:get,  'http://localhost:8080/job/Buildaroo/1/logText/progressiveText?start=300').
        to_return(:body => BUILDAROO_CONSOLE_3, :headers => {'X-Text-Size' => 300})
      # Request for test report
      stub_request(:get,  'http://localhost:8080/job/Buildaroo/1/testReport/api/json').to_return(:status => 404)

      subject.perform(:build, @workitem)

      @workitem['fields']['__error__'].should be_nil
      @workitem['fields']['output'].should be_nil
    end

    it "should supply error when job fails to start" do
      # Request for jenkins root, used to get list of projects
      stub_request(:get,  'http://localhost:8080/api/json').to_return(:body => JENKINS_ROOT_WITHOUT_JOB)
      # Request to create Buildaroo job
      stub_request(:post, 'http://localhost:8080/createItem?name=Buildaroo')
      # Request for details about Buildroo project
      stub_request(:get,  'http://localhost:8080/job/Buildaroo/api/json').to_return(:body => BUILDAROO_DETAILS)
      # Request to kick off a build
      stub_request(:post, 'http://localhost:8080/job/Buildaroo/build').to_return(:status => 400, :body => 'What *did* you do?')

      subject.perform(:build, @workitem)

      subject.error.should eq("Jenkins job failed to start")
    end

    it "should supply error when job fails to be created" do
      # Request for jenkins root, used to get list of projects
      stub_request(:get,  'http://localhost:8080/api/json').to_return(:body => JENKINS_ROOT_WITHOUT_JOB)
      # Request to create Buildaroo job
      stub_request(:post, 'http://localhost:8080/createItem?name=Buildaroo').to_return(:status => 500, :body => 'error')

      subject.perform(:build, @workitem)

      subject.error.should start_with('Failed to create job Buildaroo: JenkinsApi::Exceptions::InternalServerError')
    end

    it "should supply error when job fails" do
      # Request for jenkins root, used to get list of projects
      stub_request(:get,  'http://localhost:8080/api/json').to_return(:body => JENKINS_ROOT_WITHOUT_JOB)
      # Request to create Buildaroo job
      stub_request(:post, 'http://localhost:8080/createItem?name=Buildaroo')
      # Request for details about Buildroo project
      stub_request(:get,  'http://localhost:8080/job/Buildaroo/api/json').to_return(:body => BUILDAROO_DETAILS)
      # Request to kick off a build
      stub_request(:post, 'http://localhost:8080/job/Buildaroo/build').to_return(:body => '')
      # Request for status of a build
      stub_request(:get,  'http://localhost:8080/job/Buildaroo/1//api/json').
        to_return(:status => 404).then.
        to_return(:body => BUILDAROO_STATUS_BUILDING).then.
        to_return(:body => BUILDAROO_STATUS_FAILED)
      # Request for log text of build
      stub_request(:get,  'http://localhost:8080/job/Buildaroo/1/logText/progressiveText?start=0').
        to_return(:body => BUILDAROO_CONSOLE_1, :headers => {'X-Text-Size' => 100, 'X-More-Data' => true})
      stub_request(:get,  'http://localhost:8080/job/Buildaroo/1/logText/progressiveText?start=100').
        to_return(:body => BUILDAROO_CONSOLE_2, :headers => {'X-Text-Size' => 300})
      stub_request(:get,  'http://localhost:8080/job/Buildaroo/1/logText/progressiveText?start=300').
        to_return(:body => BUILDAROO_CONSOLE_3, :headers => {'X-Text-Size' => 300})
      # Request for test report
      stub_request(:get,  'http://localhost:8080/job/Buildaroo/1/testReport/api/json').to_return(:status => 404)

      subject.perform(:build, @workitem)

      subject.error.should eql('Jenkins job failed')
      @workitem['fields']['output'].should be_nil
    end

  end

end
