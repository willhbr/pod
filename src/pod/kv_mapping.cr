module Config
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

    delegate map, to: @tuples
  end
end
