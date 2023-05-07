require "digest/sha1"

module Config
  def self.as_args(args : KVMapping(String, String)) : Array(String)
    args.map { |k, v| "--#{k}=#{v}" }
  end

  class File
    include YAML::Serializable
    include YAML::Serializable::Strict
    getter defaults = Defaults.new(nil, nil)
    getter images = Hash(String, Config::Image).new
    getter containers = Hash(String, Config::Container).new

    def initialize(@defaults)
    end
  end

  class Defaults
    include YAML::Serializable
    include YAML::Serializable::Strict
    getter build : String? = nil
    getter run : String? = nil

    def initialize(@build, @run)
    end
  end

  class Image
    include YAML::Serializable
    include YAML::Serializable::Strict
    getter tag : String? = nil
    getter from : String
    getter context : String = "."
    getter args = KVMapping(String, String).new
    @[YAML::Field(key: "build-args")]
    getter build_args = KVMapping(String, String).new

    getter connection : String? = nil

    def initialize(@from, @tag)
    end

    def to_command : Array(String)
      args = Array(String).new
      podman_args = @args.dup
      if con = @connection
        podman_args.replace "remote", "true"
        podman_args.replace "connection", con
      end
      args.concat Config.as_args(podman_args)
      args << "build"
      build_args = @build_args.dup
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

    getter args = KVMapping(String, String).new
    @[YAML::Field(key: "run-args")]
    getter run_args = KVMapping(String, String).new
    @[YAML::Field(key: "cmd-args")]
    getter cmd_args = Array(String).new

    # options that set other options
    getter interactive : Bool = false
    getter autoremove : Bool = true

    @[YAML::Field(key: "bind-mounts")]
    getter bind_mounts = Hash(String, String).new
    getter volumes = Hash(String, String).new
    getter ports = Hash(Int32, String).new

    getter connection : String? = nil

    def initialize(@name, @image)
    end

    def to_command(include_hash = true)
      args = Array(String).new
      podman_args = @args.dup
      if con = @connection
        podman_args.replace "remote", "true"
        podman_args.replace "connection", con
      end
      args.concat Config.as_args(podman_args)
      args << "run"
      run_args = @run_args.dup
      if @interactive
        run_args["tty"] = "true"
        run_args["interactive"] = "true"
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

      run_args["name"] = @name
      if include_hash
        run_args["label"] = "pod_hash=" + pod_hash
      end
      args.concat Config.as_args(run_args)
      args << @image
      args.concat @cmd_args
      args
    end

    def pod_hash
      dig = Digest::SHA1.new
      self.to_command(include_hash: false).each do |arg|
        dig.update(arg)
      end
      dig.hexfinal
    end
  end
end
