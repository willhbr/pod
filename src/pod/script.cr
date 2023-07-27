require "yaml"

class Pod::Scripter
  def initialize(@config : Config)
  end

  def exec(args : Array(String))
    unless file = args[0]?
      raise Pod::Exception.new "missing input file, requires at least one argument"
    end
    extension = Path[file].extension.lchop('.')
    unless container = @config.types[extension]?
      raise Pod::Exception.new("no script config for #{file} (#{extension})")
    end
    if container.pull_latest
      status = Process.run(command: "podman", args: {"pull", container.image},
        input: Process::Redirect::Close, output: Process::Redirect::Inherit,
        error: Process::Redirect::Inherit)
      unless status.success?
        raise Pod::Exception.new("failed to pull latest #{container.image}")
      end
    end
    container.apply_overrides!(
      detached: false, name: sanitise(container.name, file))
    cmd = container.to_command(args)
    Log.info { "Running podman #{cmd.join(' ')}" }
    Process.exec(command: "podman", args: cmd)
  end

  def sanitise(type : String, name : String) : String
    n = name.gsub(/\W+/, '_')
    "#{type}.#{n}"
  end
end

class Pod::Scripter::Config
  include YAML::Serializable

  getter types : Hash(String, Pod::Config::Container)
end
