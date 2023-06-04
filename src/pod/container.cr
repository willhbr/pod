require "json"

module Podman
  class Container
    include JSON::Serializable
    include YAML::Serializable

    enum State
      Running
      Paused
      Exited
      Configured
    end

    @[JSON::Field(key: "Command")]
    getter command : Array(String)
    @[JSON::Field(key: "Id")]
    getter id : String
    @[JSON::Field(key: "Image")]
    getter image : String
    @[JSON::Field(key: "ImageID")]
    getter image_id : String
    @[JSON::Field(key: "Names")]
    getter names : Array(String)

    def name
      @names.first.not_nil!
    end

    @[JSON::Field(key: "Pid")]
    getter pid : Int32
    @[JSON::Field(key: "StartedAt", converter: Time::EpochConverter)]
    getter started_at : Time
    @[JSON::Field(key: "Created", converter: Time::EpochConverter)]
    getter created : Time

    def uptime : Time::Span
      Time.utc - @started_at
    end

    @[JSON::Field(key: "Exited")]
    getter exited : Bool
    @[JSON::Field(key: "ExitCode")]
    getter exit_code : Int32
    @[JSON::Field(key: "State")]
    getter state : State

    @[JSON::Field(key: "Labels")]
    @[YAML::Field(key: "labels")]
    getter _labels : Hash(String, String)?

    def labels
      @_labels ||= Hash(String, String).new
    end

    def pod_hash : String
      self.labels["pod_hash"]? || ""
    end
  end

  class Container::Inspect
    include JSON::Serializable
    @[JSON::Field(key: "Id")]
    getter id : String
    @[JSON::Field(key: "Created")]
    getter created : Time
    @[JSON::Field(key: "Image")]
    getter image : String
    @[JSON::Field(key: "ImageName")]
    getter image_name : String

    class Config
      include JSON::Serializable
      @[JSON::Field(key: "CreateCommand")]
      getter create_command : Array(String)
    end

    @[JSON::Field(key: "Config")]
    getter config : Config
  end
end
