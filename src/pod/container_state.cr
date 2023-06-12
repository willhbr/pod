require "file_utils"
require "json"

class Pod::StateStore
  class ContainerState
    include JSON::Serializable
    getter update_time : Time
    getter config : Pod::Config::Container
    getter image_id : String

    def initialize(@update_time, @config, @image_id)
    end
  end

  def initialize(@dir : Path)
    @states = Hash({String, String}, Array(ContainerState)).new
  end

  def record(remote : String?, config : Pod::Config::Container, image : String) : Nil
    Log.info { "Recording #{remote}->#{image}\n#{config.to_yaml}" }
    states = self[remote, config.name]
    states << ContainerState.new(
      update_time: Time.utc,
      config: config,
      image_id: image
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
