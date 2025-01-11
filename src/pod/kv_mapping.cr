require "yaml"

module Pod::Config
  class KVMapping(K, V)
    @tuples : Array(Tuple(K, V))

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

    def replace(k : K, v : V)
      @tuples.each_with_index do |tup, idx|
        if tup[0] == k
          @tuples[idx] = {k, v}
          return
        end
      end
      self[k] = v
    end

    def put_no_replace(k : K, v : V)
      return if @tuples.any? { |t| t[0] == k }
      self[k] = v
    end

    def to_yaml(yaml : YAML::Nodes::Builder) : Nil
      yaml.mapping(reference: self) do
        @tuples.each do |key, value|
          key.to_yaml(yaml)
          value.to_yaml(yaml)
        end
      end
    end

    def self.new
      new(Array(Tuple(K, V)).new)
    end

    def initialize(@tuples : Array(Tuple(K, V)))
    end

    def dup
      KVMapping(K, V).new(@tuples.dup)
    end

    def self.new(parser : JSON::PullParser)
      new Array(Tuple(K, V)).new(parser)
    end

    delegate map, each, to_s, inspect, to_json, to: @tuples
  end
end

class YAML::Nodes::Scalar
  @expanded : String? = nil

  def value : String
    @expanded ||= @value.gsub(/\$\w+/) do |key|
      ENV[key[1...]]? || key
    end
  end
end

struct YAML::Any
  def self.new(pull : JSON::PullParser)
    case pull.kind
    when .null?
      new pull.read_null
    when .bool?
      new pull.read_bool
    when .int?
      new pull.read_int
    when .float?
      new pull.read_float
    when .string?
      new pull.read_string
    when .begin_array?
      ary = [] of YAML::Any
      pull.read_array do
        ary << new(pull)
      end
      new ary
    when .begin_object?
      hash = {} of YAML::Any => YAML::Any
      pull.read_object do |key|
        hash[new(key)] = new(pull)
      end
      new hash
    else
      raise "Unknown pull kind: #{pull.kind}"
    end
  end
end
