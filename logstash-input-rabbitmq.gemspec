Gem::Specification.new do |s|

  s.name            = 'logstash-input-rabbitmq'
  s.version         = '0.1.0'
  s.licenses        = ['Apache License (2.0)']
  s.summary         = "Pull events from a RabbitMQ exchange."
  s.description     = "Pull events from a RabbitMQ exchange."
  s.authors         = ["Elasticsearch"]
  s.email           = 'richard.pijnenburg@elasticsearch.com'
  s.homepage        = "http://logstash.net/"
  s.require_paths = ["lib"]

  # Files
  s.files = `git ls-files`.split($\)+::Dir.glob('vendor/*')

  # Tests
  s.test_files = s.files.grep(%r{^(test|spec|features)/})

  # Special flag to let us know this is actually a logstash plugin
  s.metadata = { "logstash_plugin" => "true", "group" => "input" }

  # Gem dependencies
  s.add_runtime_dependency 'logstash', '>= 1.4.0', '< 2.0.0'

  s.add_runtime_dependency 'logstash-codec-json'

  if RUBY_PLATFORM == 'java'
    s.add_runtime_dependency 'march_hare', ['~> 2.5.1']
  else
    s.add_runtime_dependency 'bunny', ['1.4.0']
  end

end

