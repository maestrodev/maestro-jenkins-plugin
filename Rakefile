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

require 'rake/clean'
require 'rspec/core/rake_task'
require 'zippy'
require 'git'
require 'nokogiri'
require 'json'

$:.push File.expand_path("../src", __FILE__)

CLEAN.include("manifest.json", "*-plugin.zip", "vendor", "package", "tmp", ".bundle")

task :default => :all
task :all => [:clean, :bundle, :spec, :package]

desc "Run specs"
RSpec::Core::RakeTask.new do |t|
  t.pattern = "./spec/**/*_spec.rb" # don't need this, it's default.
  t.rspec_opts = "--fail-fast --format p --color"
  # Put spec opts in a file named .rspec in root
end

desc "Get dependencies with Bundler"
task :bundle do
  sh %{bundle package} do |ok, res|
    raise "Error bundling" if ! ok
  end
end

def add_file( zippyfile, dst_dir, f )
  puts "Writing #{f} at #{dst_dir}"
  zippyfile["#{dst_dir}/#{f}"] = File.open(f)
end

def add_dir( zippyfile, dst_dir, d )
  glob = "#{d}/**/*"
  FileList.new( glob ).each { |f|
    if (File.file?(f))
      add_file zippyfile, dst_dir, f
    end
  }
end

desc "Package plugin zip"
task :package do
  f = File.open("pom.xml")
  doc = Nokogiri::XML(f.read)
  f.close
  artifactId = doc.css('artifactId').first.text
  version = doc.css('version').first.text
  zip_file = "#{artifactId}-#{version}.zip"

  if File.exists?(".git")
    git = Git.open(".")
    # check if there are modified files
    if git.status.select {|s| s.type == "M"}.empty?
      commit = git.log.first.sha[0..5]
      version = "#{version}-#{commit}"
    else
      puts "WARNINIG: There are modified files, not using commit hash in version"
    end
  end

  # update manifest
  manifest = JSON.parse(IO.read("manifest.template.json"))
  manifest.each { |m| m['version'] = version }
  File.open("manifest.json",'w'){ |f| f.write(JSON.pretty_generate(manifest)) }

  Zippy.create zip_file do |z|
    add_dir z, '.', 'src'
    add_dir z, '.', 'vendor'
    add_dir z, '.', 'images'
    add_file z, '.', 'manifest.json'
    add_file z, '.', 'README.md'
    add_file z, '.', 'LICENSE'
  end
end
