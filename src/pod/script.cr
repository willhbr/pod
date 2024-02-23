require "yaml"

class Pod::Scripter
  def initialize(@config : Config)
  end

  def exec(type : String?, args : Array(String))
    unless file = args[0]?
      raise Pod::Exception.new "missing input file, requires at least one argument"
    end
    extension = Path[file].extension.lchop('.')
    if type
      extension = type
    end
    unless container = @config.scripts[extension]?
      raise Pod::Exception.new("no script config for #{file} (#{extension})")
    end
    if container.pull_latest
      status = Podman.run_inherit_io(args: {"pull", container.image})
      unless status.success?
        raise Pod::Exception.new("failed to pull latest #{container.image}")
      end
    end
    container.apply_overrides!(
      detached: false, name: sanitise(container.name, file))
    cmd = container.to_command(args)
    Podman.exec(args: cmd)
  end

  def repl(type : String, args : Array(String))
    unless container = @config.repls[type]?
      raise Pod::Exception.new("no repl config for #{type}")
    end
    if container.pull_latest
      status = Podman.run_inherit_io({"pull", container.image})
      unless status.success?
        raise Pod::Exception.new("failed to pull latest #{container.image}")
      end
    end
    container.apply_overrides!(
      detached: false, name: sanitise(container.name, type))
    cmd = container.to_command(args)
    Podman.exec(args: cmd)
  end

  def sanitise(type : String, name : String) : String
    n = name.gsub(/\W+/, '_')
    "#{type}.#{n}"
  end
end

class Pod::Scripter::Config
  include YAML::Serializable

  getter scripts : Hash(String, Pod::Config::Container)
  getter repls : Hash(String, Pod::Config::Container)
end
