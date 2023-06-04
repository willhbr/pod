require "yaml"

class Config::YAMLFlag
  @value : String | Hash(String, YAMLFlag) | Array(YAMLFlag)

  def self.new(ctx : YAML::ParseContext, node : YAML::Nodes::Node)
    ctx.read_alias(node, self) do |obj|
      return obj
    end

    if node.is_a? YAML::Nodes::Mapping
      hash = Hash(String, YAMLFlag).new
      flag = new(hash)
      ctx.record_anchor(node, flag)
      YAML::Schema::Core.each(node) do |key, value|
        hash[String.new(ctx, key)] = YAMLFlag.new(ctx, value)
      end
      return flag
    end

    if node.is_a? YAML::Nodes::Sequence
      array = Array(YAMLFlag).new
      flag = new(array)
      ctx.record_anchor(node, flag)
      node.each do |value|
        array << YAMLFlag.new(ctx, value)
      end
      return flag
    end

    unless node.is_a?(YAML::Nodes::Scalar)
      node.raise "Expected mapping, sequence, or scalar, not #{node.kind}"
    end

    YAMLFlag.new(String.new(ctx, node))
  end

  def to_yaml(yaml : YAML::Nodes::Builder) : Nil
    yaml.mapping(reference: self) do
      @tuples.each do |key, value|
        key.to_yaml(yaml)
        value.to_yaml(yaml)
      end
    end
  end

  def initialize(@value)
  end

  def as_s?
    if v = @value.as? String
      return v
    end
  end

  delegate to_yaml, to_json, to: @value
end
