require "digest/sha1"
require "json"
require "yaml"
require "./kv_mapping"

module Pod::Config
  CONFIG_FILES = {
    "pods.yaml",
    "pods.yml",
    "pods.json",
  }

  def self.find_config_path(file) : Path?
    paths = Path[Dir.current].parents
    paths << Path[Dir.current]
    files = file.nil? ? CONFIG_FILES : {file}
    paths.reverse.each do |path|
      files.each do |file|
        target = path / file
        Dir.cd target.parent
        if ::File.exists? target
          return target
        end
      end
    end
  end

  def self.parse_config(target) : Config::File?
    Log.info { "Loading config from #{target}" }
    case target.extension.downcase
    when ".yaml", ".yml"
      config = Config::File.from_yaml(::File.read(target))
    when ".json"
      config = Config::File.from_json(::File.read(target))
    else
      Log.warn { "Unsure of file type for #{target}, defaulting to YAML" }
      config = Config::File.from_yaml(::File.read(target))
    end
    Log.info { config.to_yaml }
    return config
  end

  def self.try_show_context(line_number, msg, path, io)
    line = line_number - 1
    content = ::File.read(path).lines
    context = 5
    start = {line - context, 0}.max
    finish = {line + context, content.size}.min
    (start..finish).each do |idx|
      if idx == line
        io.puts "#{(idx + 1).to_s.rjust(3)}: #{content[idx]} <-- #{msg}".colorize(:red)
      else
        io.puts "#{(idx + 1).to_s.rjust(3)}: #{content[idx]}"
      end
    end
  end

  def self.load_config!(file) : Config::File
    path : Path? = nil
    begin
      if path = find_config_path(file)
        if conf = parse_config(path)
          return conf
        end
      end
    rescue ex : YAML::ParseException | JSON::ParseException
      STDERR.puts ex.message
      if path
        begin
          if ex.is_a? YAML::ParseException
            ln = ex.line_number
            try_show_context(ln, ex.message, path, STDERR)
          elsif ex.is_a? JSON::ParseException
            ln = ex.line_number
            try_show_context(ln, ex.message, path, STDERR)
          end
        rescue err
          Log.warn(exception: err) { "Unable to show config file context" }
        end
      end
      raise Podman::Exception.new("Failed to parse config file #{file}", cause: ex)
    end

    raise Podman::Exception.new("Config file #{file || CONFIG_FILES.join(", ")} does not exist")
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

  module MultiSerializable
    macro included
      include YAML::Serializable
      include JSON::Serializable
    end
  end

  class File
    include MultiSerializable

    getter defaults = Defaults.new
    getter images = Hash(String, Config::Image).new
    getter containers = Hash(String, Config::Container).new
    getter development = Hash(String, Config::DevContainer).new
    getter groups = Hash(String, Set(String)).new

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
      raise Podman::Exception.new("no image or group matches #{target}")
    end

    def get_containers(target : String?) : Array({String, Config::Container})
      if target.nil?
        if @development.size == 1
          k, v = @development.first
          return [{k, v.as(Container)}]
        end
        target = @defaults.run || ":all"
      end
      if c = find_container(target)
        return [{target, c}]
      end
      if target == ":all"
        return @containers.to_a + @development.to_a
      end
      if group = @groups[target]?
        return group.map { |c| {c, find_container!(c)} }
      end
      raise Podman::Exception.new("no container or group matches #{target}")
    end

    private def find_container(target : String) : Config::Container?
      if c = @containers[target]?
        return c
      end
      if c = @development[target]?
        return c.as(Container)
      end
      nil
    end

    private def find_container!(target : String) : Config::Container
      find_container(target) || raise Podman::Exception.new("no container matches #{target}")
    end

    def initialize(@defaults)
    end

    protected def on_unknown_yaml_attribute(ctx, key, key_node, value_node)
      Log.debug { "Got unknown yaml key in top-level: #{key}" }
    end

    def inspect(io)
      to_yaml(io)
    end
  end

  class Defaults
    include MultiSerializable
    include YAML::Serializable::Strict
    getter build : String? = nil
    getter run : String? = nil
    getter update : String? = nil
    getter entrypoint : String? = nil

    def initialize(*, @build = nil, @run = nil, @update = nil)
    end
  end

  class Image
    include MultiSerializable
    include YAML::Serializable::Strict
    getter tag : String? = nil # | Array(String) = Array(String).new
    getter from : String
    getter push : String? = nil
    getter scp : String? = nil
    getter auto_push : Bool = false
    getter context : String = "."
    getter podman_flags = KVMapping(String, YAML::Any).new
    getter build_flags = KVMapping(String, YAML::Any).new
    # for --build-arg
    getter build_args = KVMapping(String, YAML::Any).new

    getter remote : String? = nil

    def tags
      t = @tag
      t.is_a?(String) ? [t] : t
    end

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
    include MultiSerializable
    include YAML::Serializable::Strict
    getter name : String
    getter image : String

    # for podman
    getter podman_flags = KVMapping(String, YAML::Any).new
    getter run_flags = KVMapping(String, YAML::Any).new
    # for the container
    getter flags = KVMapping(String, YAML::Any).new
    getter args = Array(YAML::Any).new

    getter environment = Hash(String, String).new
    getter labels = Hash(String, YAML::Any).new
    getter network : String | Array(String) = Array(String).new

    # options that set other options
    getter interactive : Bool = false
    getter autoremove : Bool = false
    getter secrets = Hash(String, SecretConfig).new

    # convenience opts
    getter pull_latest : Bool = false

    getter bind_mounts = Hash(String, String).new
    getter volumes = Hash(String, String).new
    getter ports = Hash(Int32, String).new
    getter entrypoint : YAML::Any? = nil

    # helth
    class HealthConfig
      include MultiSerializable
      include YAML::Serializable::Strict
      getter command : YAML::Any
      getter interval : String? = nil
      getter on_failure : String? = nil
      getter retries : Int32? = nil
      getter start_period : String? = nil
      getter timeout : String? = nil
    end

    class SecretConfig
      include MultiSerializable
      include YAML::Serializable::Strict

      getter local : String? = nil
      getter remote : String? = nil
    end

    getter health : HealthConfig? = nil

    getter remote : String? = nil

    def initialize(@name, @image)
    end

    def resolve_refs(config : Config::File)
      unless @image.starts_with? ':'
        return
      end
      img = @image[1..]
      unless image = config.images[img]?
        raise "unable to find #{img} in config, images are: #{config.images.keys.join(", ")}"
      end
      if tag = image.tag
        @image = tag
      else
        raise "can't use ref to untagged image #{img}"
      end
    end

    def apply_overrides!(
      detached : Bool? = nil, remote : String? = nil,
      image : String? = nil, name : String? = nil,
      autoremove : Bool? = nil,
      entrypoint : YAML::Any? = nil
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
      unless autoremove.nil?
        @autoremove = autoremove
      end
      if entrypoint
        @entrypoint = entrypoint
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
        source = Path[source].expand(home: true).to_s
        run_args["mount"] = YAML::Any.new("type=bind,src=#{source},dst=#{dest}")
      end
      @volumes.each do |name, dest|
        run_args["mount"] = YAML::Any.new("type=volume,src=#{name},dst=#{dest}")
      end
      @ports.each do |host, cont|
        # use port zero to assign random free port
        run_args["publish"] = YAML::Any.new("#{host.zero? ? "" : host}:#{cont}")
      end

      if entrypoint = @entrypoint
        run_args["entrypoint"] = entrypoint
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

      @secrets.each do |name, _|
        run_args["secret"] = YAML::Any.new(name)
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
        args.concat @args.map { |a|
          if a.raw.is_a?(Hash) || a.raw.is_a?(Set) || a.raw.is_a?(Array)
            a.to_json
          else
            a.to_s
          end
        }
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

  class DevContainer < Container
    @name = DevContainer.auto_name
    @interactive = true
    @autoremove = true

    def self.new(ctx : ::YAML::ParseContext, node : ::YAML::Nodes::Node)
      dev = previous_def(ctx, node)
      dev.add_defaults
      dev
    end

    def self.auto_name
      ::File.basename(Dir.current) + "-dev"
    end

    def add_defaults
      @bind_mounts["."] = "/src" unless @bind_mounts.includes? "."
      @run_flags.put_no_replace "workdir", YAML::Any.new("/src")
    end
  end
end
