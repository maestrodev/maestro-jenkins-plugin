# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
# 
#  http://www.apache.org/licenses/LICENSE-2.0
# 
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.

require 'simplecov'
SimpleCov.start

require 'rspec'
require 'mocha/api'
require 'webmock/rspec'
require 'maestro_plugin/logging_stdout'

$LOAD_PATH.unshift(File.dirname(__FILE__) + '/../src') unless $LOAD_PATH.include?(File.dirname(__FILE__) + '/../src')


require 'jenkins_worker'

RSpec.configure do |config|
  config.mock_framework = :mocha
  
  config.before(:each) do
    Maestro::MaestroWorker.mock!
    subject.query_interval = 1
  end
  
end

JENKINS_ROOT_WITHOUT_JOB = '{"assignedLabels":[{}],"mode":"NORMAL","nodeDescription":"the master Jenkins node","nodeName":"","numExecutors":2,"description":null,"jobs":[],"overallLoad":{},"primaryView":{"name":"All","url":"http://localhost:8080/"},"quietingDown":false,"slaveAgentPort":0,"unlabeledLoad":{},"useCrumbs":false,"useSecurity":false,"views":[{"name":"All","url":"http://localhost:8080/"}]}'

JENKINS_ROOT_WITH_JOB = '{"assignedLabels":[{}],"mode":"NORMAL","nodeDescription":"the master Jenkins node","nodeName":"","numExecutors":2,"description":null,"jobs":[{"name":"AntWithIvy","url":"http://localhost:8080/job/AntWithIvy/","color":"red"},{"name":"Buildaroo","url":"http://localhost:8080/job/Buildaroo/","color":"blue"}],"overallLoad":{},"primaryView":{"name":"All","url":"http://localhost:8080/"},"quietingDown":false,"slaveAgentPort":0,"unlabeledLoad":{},"useCrumbs":false,"useSecurity":false,"views":[{"name":"All","url":"http://localhost:8080/"}]}'

BUILDAROO_DETAILS = '{"actions":[],"description":"","displayName":"Buildaroo","displayNameOrNull":null,"name":"Buildaroo","url":"http://localhost:8080/job/Buildaroo/","buildable":true,"builds":[],"color":"grey","firstBuild":null,"healthReport":[],"inQueue":false,"keepDependencies":false,"lastBuild":null,"lastCompletedBuild":null,"lastFailedBuild":null,"lastStableBuild":null,"lastSuccessfulBuild":null,"lastUnstableBuild":null,"lastUnsuccessfulBuild":null,"nextBuildNumber":1,"property":[],"queueItem":null,"concurrentBuild":false,"downstreamProjects":[],"scm":{},"upstreamProjects":[]}'

BUILDAROO_STATUS_BUILDING = '{"actions":[{"causes":[{"shortDescription":"Started by user anonymous","userId":null,"userName":"anonymous"}]}],"artifacts":[],"building":true,"description":null,"duration":117,"estimatedDuration":117,"executor":null,"fullDisplayName":"Buildaroo #1","id":"2013-06-14_14-33-03","keepLog":false,"number":1,"result":null,"timestamp":1371245583809,"url":"http://localhost:8080/job/Buildaroo/1/","builtOn":"","changeSet":{"items":[],"kind":null},"culprits":[]}'

BUILDAROO_STATUS_SUCCESS = '{"actions":[{"causes":[{"shortDescription":"Started by user anonymous","userId":null,"userName":"anonymous"}]}],"artifacts":[],"building":false,"description":null,"duration":117,"estimatedDuration":117,"executor":null,"fullDisplayName":"Buildaroo #1","id":"2013-06-14_14-33-03","keepLog":false,"number":1,"result":"SUCCESS","timestamp":1371245583809,"url":"http://localhost:8080/job/Buildaroo/1/","builtOn":"","changeSet":{"items":[],"kind":null},"culprits":[]}'

BUILDAROO_STATUS_FAILED = '{"actions":[{"causes":[{"shortDescription":"Started by user anonymous","userId":null,"userName":"anonymous"}]}],"artifacts":[],"building":false,"description":null,"duration":117,"estimatedDuration":117,"executor":null,"fullDisplayName":"Buildaroo #1","id":"2013-06-14_14-33-03","keepLog":false,"number":1,"result":"Not SUCCESS","timestamp":1371245583809,"url":"http://localhost:8080/job/Buildaroo/1/","builtOn":"","changeSet":{"items":[],"kind":null},"culprits":[]}'

BUILDAROO_CONSOLE_1 = "Started by user anonymous\n"

BUILDAROO_CONSOLE_2 = "[workspace] $ /bin/sh -xe /tmp/hudson5379787065231741934.sh\n+ rake\nrake/rdoctask is deprecated.  Use rdoc/task instead (in RDoc 2.4.2+)\n/opt/ruby/bin/ruby -S rspec --colour spec/client_spec.rb spec/connection_spec.rb spec/message_spec.rb\nJeweler not available. Install it with: gem install jeweler\n...........................................................................................connect to localhost failed: exception will retry(#0) in 0.01\n................\n\nFinished in 0.16676 seconds\n107 examples, 0 failures\nFinished: SUCCESS\n"

BUILDAROO_CONSOLE_3 = ""
