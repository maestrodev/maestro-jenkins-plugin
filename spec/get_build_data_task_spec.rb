

require 'spec_helper'

describe MaestroDev::JenkinsWorker do
  
  JOB_CONSOLE = "Started by user anonymous\n[workspace] $ /bin/sh -xe /tmp/hudson5379787065231741934.sh\n+ rake\nrake/rdoctask is deprecated.  Use rdoc/task instead (in RDoc 2.4.2+)\n/opt/ruby/bin/ruby -S rspec --colour spec/client_spec.rb spec/connection_spec.rb spec/message_spec.rb\nJeweler not available. Install it with: gem install jeweler\n...........................................................................................connect to localhost failed: exception will retry(#0) in 0.01\n................\n\nFinished in 0.16676 seconds\n107 examples, 0 failures\nFinished: SUCCESS\n"


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

      subject.stubs(:write_output)
      subject.stubs(:workitem => workitem)
      subject.setup

      @job_data = IO.read(File.dirname(__FILE__) + '/job_data.json')
      @build_results = IO.read(File.dirname(__FILE__) + '/build_results.json')
      @test_report = IO.read(File.dirname(__FILE__) + '/test_report.json')

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
