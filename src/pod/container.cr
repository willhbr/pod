require "json"

module Pod::Podman
  class Container
    include JSON::Serializable
    include YAML::Serializable

    enum State
      Unknown
      Created
      Running
      Paused
      Exited
      Stopped
      Configured

      def self.from_json(parser : JSON::PullParser) : State
        parse?(parser.read_string) || State::Unknown
      end
    end

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

    @[JSON::Field(key: "StartedAt", converter: Time::EpochConverter)]
    getter started_at : Time
    @[JSON::Field(key: "AutoRemove")]
    getter auto_remove : Bool

    def uptime : Time::Span
      Time.utc - @started_at
    end

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

    struct Config
      include JSON::Serializable
      @[JSON::Field(key: "CreateCommand")]
      getter create_command : Array(String)
    end

    @[JSON::Field(key: "Config")]
    getter config : Config
  end
end
