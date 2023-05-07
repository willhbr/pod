module Config
  class KVMapping(K, V)
    @tuples = Array(Tuple(K, V)).new

    def self.new(ctx : YAML::ParseContext, node : YAML::Nodes::Node)
      ctx.read_alias(node, self) do |obj|
        return obj
      end

      hash = new

      ctx.record_anchor(node, hash)

      unless node.is_a?(YAML::Nodes::Mapping)
        node.raise "Expected mapping, not #{node.kind}"
      end

      YAML::Schema::Core.each(node) do |key, value|
        hash[K.new(ctx, key)] = V.new(ctx, value)
      end
      hash
    end

    def []=(k : K, v : V)
      @tuples << {k, v}
    end

    def replace(k : V, v : V)
      @tuples.each_with_index do |tup, idx|
        if tup[0] == k
          @tuples[idx] = {k, v}
          return
        end
      end
      self[k] = v
    end

    def to_yaml(yaml : YAML::Nodes::Builder) : Nil
      yaml.mapping(reference: self) do
        each do |key, value|
          key.to_yaml(yaml)
          value.to_yaml(yaml)
        end
      end
    end

    delegate map, to: @tuples
  end

  def self.as_args(args : KVMapping(String, String)) : Array(String)
    args.map { |k, v| "--#{k}=#{v}" }
  end

  class File
    include YAML::Serializable
    include YAML::Serializable::Strict
    getter images : Array(Config::Image)
    getter containers : Array(Config::Container)
  end

  class Image
    include YAML::Serializable
    include YAML::Serializable::Strict
    getter name : String
    getter tag : String? = nil
    getter from : String
    getter context : String = "."
    getter args = KVMapping(String, String).new
    @[YAML::Field(key: "build-args")]
    getter build_args = KVMapping(String, String).new

    def to_command : Array(String)
      args = Array(String).new
      args.concat Config.as_args(@args)
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

    def to_command
      args = Array(String).new
      args.concat Config.as_args(@args)
      args << "run"
      run_args = @run_args.dup
      run_args["name"] = @name
      args.concat Config.as_args(run_args)
      args << @image
      args.concat @cmd_args
      args
    end
  end
end
