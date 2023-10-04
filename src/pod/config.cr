require "digest/sha1"
require "json"
require "yaml"
require "./kv_mapping"

module Pod::Config
  def self.load_config(file) : Config::File?
    paths = Path[Dir.current].parents
    paths << Path[Dir.current]
    paths.reverse.each do |path|
      target = path / (file || DEFAULT_CONFIG_FILE)
      Dir.cd target.parent
      if ::File.exists? target
        Log.info { "Loading config from #{target}" }
        config = Config::File.from_yaml(::File.read(target))
        Log.info { config.pretty_inspect }
        return config
      end
    end
  end

  def self.load_config!(file) : Config::File
    begin
      if conf = load_config(file)
        return conf
      end
    rescue ex : YAML::ParseException
      STDERR.puts ex.message
      raise Pod::Exception.new("Failed to parse config file #{file}", cause: ex)
    end

    raise Pod::Exception.new("Config file #{file || DEFAULT_CONFIG_FILE} does not exist")
  end

  def self.as_args(args : KVMapping(String, YAML::Any)) : Array(String)
    args.map do |k, v|
      if str = v.as_s?
        "--#{k}=#{str}"
      else
        "--#{k}=#{v.to_json}"
      end
    end
  end

  class File
    include YAML::Serializable

    getter defaults = Defaults.new
    getter images = Hash(String, Config::Image).new
    getter containers = Hash(String, Config::Container).new
    getter groups = Hash(String, Set(String)).new
    getter entrypoints = Hash(String, Entrypoint).new

    def get_images(target : String?) : Array({String, Config::Image})
      if target.nil?
        target = @defaults.build || ":all"
      end
      if i = @images[target]?
        return [{target, i}]
      end
      if target == ":all"
        return @images.to_a
      end
      if group = @groups[target]?
        return group.map { |c| {c, @images[c]} }
      end
      raise Pod::Exception.new("no image or group matches #{target}")
    end

    def get_containers(target : String?) : Array({String, Config::Container})
      if target.nil?
        target = @defaults.run || ":all"
      end
      if c = @containers[target]?
        return [{target, c}]
      end
      if target == ":all"
        return @containers.to_a
      end
      if group = @groups[target]?
        return group.map { |c| {c, @containers[c]} }
      end
      raise Pod::Exception.new("no container or group matches #{target}")
    end

    def initialize(@defaults)
    end

    protected def on_unknown_yaml_attribute(ctx, key, key_node, value_node)
      Log.debug { "Got unknown yaml key in top-level: #{key}" }
    end
  end

  class Defaults
    include YAML::Serializable
    include YAML::Serializable::Strict
    getter build : String? = nil
    getter run : String? = nil
    getter update : String? = nil
    getter entrypoint : String? = nil

    def initialize(*, @build = nil, @run = nil, @update = nil)
    end
  end

  class Image
    include YAML::Serializable
    include YAML::Serializable::Strict
    getter tag : String? = nil
    getter from : String
    getter push : String? = nil
    getter auto_push : Bool = false
    getter context : String = "."
    getter podman_flags = KVMapping(String, YAML::Any).new
    getter build_flags = KVMapping(String, YAML::Any).new
    # for --build-arg
    getter build_args = KVMapping(String, YAML::Any).new

    getter remote : String? = nil

    def initialize(@from, @tag)
    end

    def apply_overrides!(remote : String? = nil)
      if remote
        @remote = remote
      end
    end

    def to_command : Array(String)
      args = Array(String).new
      podman_args = @podman_flags.dup
      if remote = @remote
        podman_args.replace "remote", YAML::Any.new(true)
        podman_args.replace "connection", YAML::Any.new(remote)
      end
      args.concat Config.as_args(podman_args)
      args << "build"
      build_args = @build_flags.dup
      if t = @tag
        build_args.replace "tag", YAML::Any.new(t)
      end
      build_args.replace "file", YAML::Any.new(@from)
      @build_args.each do |name, value|
        build_args["build-arg"] = YAML::Any.new("#{name}=#{value}")
      end
      args.concat Config.as_args(build_args)
      args << @context
    end
  end

  class Container
    include JSON::Serializable
    include YAML::Serializable
    include YAML::Serializable::Strict
    getter name : String
    getter image : String

    # for podman
    getter podman_flags = KVMapping(String, YAML::Any).new
    getter run_flags = KVMapping(String, YAML::Any).new
    # for the container
    getter flags = KVMapping(String, YAML::Any).new
    getter args = Array(String).new

    getter environment = Hash(String, String).new
    getter labels = Hash(String, YAML::Any).new
    getter network : String | Array(String) = Array(String).new

    # options that set other options
    getter interactive : Bool = false
    getter autoremove : Bool = false

    # convenience opts
    getter pull_latest : Bool = false

    getter bind_mounts = Hash(String, String).new
    getter volumes = Hash(String, String).new
    getter ports = Hash(Int32, String).new

    # helth
    class HealthConfig
      include JSON::Serializable
      include YAML::Serializable
      include YAML::Serializable::Strict
      getter command : YAML::Any
      getter interval : String? = nil
      getter on_failure : String? = nil
      getter retries : Int32? = nil
      getter start_period : String? = nil
      getter timeout : String? = nil
    end

    getter health : HealthConfig? = nil

    getter remote : String? = nil

    def initialize(@name, @image)
    end

    def apply_overrides!(
      detached : Bool? = nil, remote : String? = nil,
      image : String? = nil, name : String? = nil
    )
      unless detached.nil?
        @interactive = !detached
      end
      if remote
        @remote = remote
      end
      if image
        @image = image
      end
      if name
        @name = name
      end
    end

    def to_command(
      cmd_args : Enumerable(String)?,
      include_hash = true
    )
      args = Array(String).new
      podman_args = @podman_flags.dup
      if remote = @remote
        podman_args.replace "remote", YAML::Any.new(true)
        podman_args.replace "connection", YAML::Any.new(remote)
      end
      args.concat Config.as_args(podman_args)
      args << "run"
      run_args = @run_flags.dup
      if @interactive
        run_args["tty"] = YAML::Any.new(true)
        run_args["interactive"] = YAML::Any.new(true)
      else
        run_args["detach"] = YAML::Any.new(true)
      end
      if @autoremove
        run_args["rm"] = YAML::Any.new(true)
      end

      if health = @health
        run_args["health-cmd"] = health.command
        if interval = health.interval
          run_args["health-interval"] = YAML::Any.new(interval)
        end
        if on_failure = health.on_failure
          run_args["health-on-failure"] = YAML::Any.new(on_failure)
        end
        if retries = health.retries
          run_args["health-retries"] = YAML::Any.new(retries)
        end
        if start_period = health.start_period
          run_args["health-start-period"] = YAML::Any.new(start_period)
        end
        if timeout = health.timeout
          run_args["health-timeout"] = YAML::Any.new(timeout)
        end
      end

      @bind_mounts.each do |source, dest|
        if source.starts_with? '~'
          source = Path[source].expand(home: true).to_s
        end
        run_args["mount"] = YAML::Any.new("type=bind,src=#{source},dst=#{dest}")
      end
      @volumes.each do |name, dest|
        run_args["mount"] = YAML::Any.new("type=volume,src=#{name},dst=#{dest}")
      end
      @ports.each do |host, cont|
        # use port zero to assign random free port
        run_args["publish"] = YAML::Any.new("#{host.zero? ? "" : host}:#{cont}")
      end

      @environment.each do |name, value|
        run_args["env"] = YAML::Any.new("#{name}=#{value}")
      end

      case network = @network
      when String
        run_args["network"] = YAML::Any.new(network)
      when Array(String)
        network.each do |network|
          run_args["network"] = YAML::Any.new(network)
        end
      end
      run_args["name"] = YAML::Any.new(@name)
      run_args["hostname"] = YAML::Any.new(@name)

      if include_hash
        run_args["label"] = YAML::Any.new("pod_hash=#{pod_hash(cmd_args)}")
      end

      @labels.each do |name, value|
        run_args["label"] =
          if str = value.as_s?
            YAML::Any.new("#{name}=#{str}")
          else
            YAML::Any.new("#{name}=#{value.to_json}")
          end
      end
      args.concat Config.as_args(run_args)

      args << @image

      if ca = cmd_args
        args.concat ca
      else
        args.concat Config.as_args(@flags)
        args.concat @args
      end
      args
    end

    def pod_hash(args)
      dig = Digest::SHA1.new
      self.to_command(
        cmd_args: args,
        include_hash: false
      ).each do |arg|
        dig.update(arg)
      end
      dig.hexfinal
    end
  end

  # For running a throw-away shell in within an image
  class Entrypoint
    include YAML::Serializable

    # for podman
    getter podman_flags = KVMapping(String, YAML::Any).new
    getter run_flags = KVMapping(String, YAML::Any).new

    getter remote : String? = nil
    getter image : String
    getter shell : Array(String) | String = Runner::MAGIC_SHELL

    def initialize(@image)
    end

    def to_command(
      cmd_args : Enumerable(String)?
    )
      args = Array(String).new
      podman_args = @podman_flags.dup
      if remote = @remote
        podman_args.replace "remote", YAML::Any.new(true)
        podman_args.replace "connection", YAML::Any.new(remote)
      end
      args.concat Config.as_args(podman_args)

      args << "run"
      run_args = @run_flags.dup
      run_args["tty"] = YAML::Any.new(true)
      run_args["interactive"] = YAML::Any.new(true)
      run_args["rm"] = YAML::Any.new(true)

      run_args["workdir"] = YAML::Any.new("/src")
      run_args["mount"] = YAML::Any.new("type=bind,src=.,dst=/src")

      shell = @shell
      if shell.is_a? String
        run_args["entrypoint"] = YAML::Any.new({"sh", "-c", shell}.to_json)
      else
        run_args["entrypoint"] = YAML::Any.new(shell.to_json)
      end

      args.concat Config.as_args(run_args)

      args << @image

      if ca = cmd_args
        args.concat ca
      end
      args
    end
  end
end
