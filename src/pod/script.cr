require "yaml"

class Pod::Scripter
  def initialize(@config : Config)
  end

  def exec(args : Array(String))
    file = args[0]
    extension = Path[file].extension.lchop('.')
    container = @config.types[extension]
    if container.pull_latest
      status = Process.run(command: "podman", args: {"pull", container.image},
        input: Process::Redirect::Close, output: Process::Redirect::Inherit,
        error: Process::Redirect::Inherit)
      unless status.success?
        raise Pod::Exception.new("failed to pull latest #{container.image}")
      end
    end
    Process.exec(command: "podman", args: container.to_command(args))
  end
end

class Pod::Scripter::Config
  include YAML::Serializable

  getter types : Hash(String, Pod::Config::Container)
end
