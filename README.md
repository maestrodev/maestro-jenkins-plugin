# maestro-jenkins-plugin
Maestro plugin providing a "task" to control jenkins. This
plugin is a Ruby-based deployable that gets delivered as a Zip file.

<http://jenkins.com/>

Manifest:

* src/jenkins_worker.rb
* manifest.json
* README.md (this file)

## The Task
This Jenkins plugin requires a few inputs:

* **nickanme** (for the Message From)
* **api_token** (Jenkins API Token)
* **tags** (list of tags used in the message)
* **message** (message to be posted)


## License
Apache 2.0 License: <http://www.apache.org/licenses/LICENSE-2.0.html>

