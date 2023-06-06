require "digest/sha1"
require "yaml"
require "./kv_mapping"

class YAML::Nodes::Scalar
  @expanded : String? = nil

  def value : String
    @expanded ||= @value.gsub(/\$\w+/) do |key|
      ENV[key[1...]]? || key
    end
  end
end

class String
end

module Pod::Config
  def self.load_config(file) : Config::File?
    paths = Path[Dir.current].parents
    paths << Path[Dir.current]
    paths.reverse.each do |path|
      Dir.cd path
      target = path / (file || DEFAULT_CONFIG_FILE)
      if ::File.exists? target
        Log.info { "Loading config from #{target}" }
        return Config::File.from_yaml(::File.read(target))
      end
    end
  end

  def self.load_config!(file) : Config::File
    begin
      if conf = load_config(file)
        return conf
      end
    rescue ex : YAML::ParseException
      raise Pod::Exception.new("Failed to parse config file #{file}", cause: ex)
    end

    raise Pod::Exception.new("Config file #{file || DEFAULT_CONFIG_FILE} does not exist")
  end

  def self.as_args(args : KVMapping(String, String)) : Array(String)
    args.map { |k, v| "--#{k}=#{v}" }
  end

  def self.json_flags(args : KVMapping(String, YAML::Any)) : Array(String)
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

    def get_images(target : String?) : Array({String, Config::Image})
      if target.nil?
        target = @defaults.run || ":all"
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
  end

  class Defaults
    include YAML::Serializable
    include YAML::Serializable::Strict
    getter build : String? = nil
    getter run : String? = nil
    getter update : String? = nil

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
    getter podman_flags = KVMapping(String, String).new
    getter build_flags = KVMapping(String, String).new

    getter remote : String? = nil

    def initialize(@from, @tag)
    end

    def to_command(remote = nil) : Array(String)
      args = Array(String).new
      podman_args = @podman_flags.dup
      if rem = remote
        podman_args.replace "remote", "true"
        podman_args.replace "connection", rem
      elsif con = @remote
        podman_args.replace "remote", "true"
        podman_args.replace "connection", con
      end
      args.concat Config.as_args(podman_args)
      args << "build"
      build_args = @build_flags.dup
      if t = @tag
        build_args.replace "tag", t
      end
      build_args.replace "file", @from
      args.concat Config.as_args(build_args)
      args << @context
    end
  end

  class Container
    include YAML::Serializable
    include YAML::Serializable::Strict
    getter name : String
    getter image : String
    getter connection : String? = nil

    # for podman
    getter podman_flags = KVMapping(String, String).new
    getter run_flags = KVMapping(String, String).new
    # for the container
    getter flags = KVMapping(String, YAML::Any).new
    getter args = Array(String).new

    getter environment = Hash(String, String).new

    # options that set other options
    getter interactive : Bool = false
    getter autoremove : Bool = false

    # convenience opts
    getter pull_latest : Bool = false

    getter bind_mounts = Hash(String, String).new
    getter volumes = Hash(String, String).new
    getter ports = Hash(Int32, String).new

    getter remote : String? = nil

    def initialize(@name, @image)
    end

    def to_command(
      cmd_args : Enumerable(String)?,
      detached : Bool? = nil,
      include_hash = true, remote = nil
    )
      args = Array(String).new
      podman_args = @podman_flags.dup
      if rem = remote
        podman_args.replace "remote", "true"
        podman_args.replace "connection", rem
      elsif con = @remote
        podman_args.replace "remote", "true"
        podman_args.replace "connection", con
      end
      args.concat Config.as_args(podman_args)
      args << "run"
      run_args = @run_flags.dup
      do_interactive = @interactive
      if detached != nil
        do_interactive = !detached
      end
      if do_interactive
        run_args["tty"] = "true"
        run_args["interactive"] = "true"
      else
        run_args["detach"] = "true"
      end
      if @autoremove
        run_args["rm"] = "true"
      end

      @bind_mounts.each do |source, dest|
        run_args["mount"] = "type=bind,src=#{source},dst=#{dest}"
      end
      @volumes.each do |name, dest|
        run_args["mount"] = "type=volume,src=#{name},dst=#{dest}"
      end
      @ports.each do |host, cont|
        run_args["publish"] = "#{host}:#{cont}"
      end

      @environment.each do |name, value|
        run_args["env"] = "#{name}=#{value}"
      end

      run_args["name"] = @name
      run_args["hostname"] = @name
      if include_hash
        run_args["label"] = "pod_hash=" + pod_hash(cmd_args)
      end
      args.concat Config.as_args(run_args)
      args << @image

      if ca = cmd_args
        args.concat ca
      else
        args.concat Config.json_flags(@flags)
        args.concat @args
      end
      args
    end

    def pod_hash(args)
      dig = Digest::SHA1.new
      self.to_command(
        cmd_args: args,
        # Always use an empty string here to keep hashes consistent even if
        # it's running somewhere else
        remote: "", include_hash: false).each do |arg|
        dig.update(arg)
      end
      dig.hexfinal
    end
  end
end
