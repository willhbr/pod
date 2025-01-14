require "spec"
require "../src/pod"

def config(str)
  Pod::Config::File.from_yaml(str)
end

def assert_runner(config : Pod::Config::File)
  String.build do |io|
    yield Pod::Runner.new(config, nil, show: true, io: io)
  end.split('\n')
end
