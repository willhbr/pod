require "file_utils"
require "json"

class Pod::StateStore
  class ContainerState
    include JSON::Serializable
    getter update_time : Time
    getter config : Pod::Config::Container

    def initialize(@update_time, @config)
    end
  end

  def initialize(@dir : Path)
    @states = Hash({String, String}, Array(ContainerState)).new
  end

  def record(config : Pod::Config::Container) : Nil
    remote = config.remote || "localhost"
    states = self[remote, config.name]
    states << ContainerState.new(
      update_time: Time.utc,
      config: config,
    )
    nil
  end

  def [](remote : String?, name : String)
    remote ||= "localhost"
    @states[{remote, name}]? || self.load(remote, name)
  end

  private def load(remote, container_name)
    dir = @dir / remote
    FileUtils.mkdir_p dir
    path = dir / container_name
    if File.exists? path
      val = Array(ContainerState).from_json(File.read(path))
    else
      val = Array(ContainerState).new
    end
    @states[{remote, container_name}] = val
    val
  end

  def save
    @states.each do |tup, val|
      remote, container_name = tup

      dir = @dir / remote
      FileUtils.mkdir_p dir
      path = dir / container_name
      File.write(path, val.to_json)
    end
  end
end
