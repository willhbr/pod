require "yaml"
require "./pod-compost/*"
require "clim"

DEFAULT_CONFIG_FILE   = "pods.yaml"
EXAMPLE_CONTAINERFILE = "\
FROM alpine:latest
ENTRYPOINT sh
"

def fail(msg) : NoReturn
  puts msg
  exit 1
end

def load_config(path) : Config::File
  if path && File.exists?(path)
    return Config::File.from_yaml(File.read(path))
  elsif File.exists? DEFAULT_CONFIG_FILE
    return Config::File.from_yaml(File.read(path))
  else
    fail "Config file #{path || DEFAULT_CONFIG_FILE} does not exist"
  end
end

class CLI < Clim
  main do
    desc "Pod CLI"
    usage "pod [sub_command] [arguments]"
    run do |opts, args|
      puts opts.help_string
    end
    sub "build" do
      desc "build an image"
      usage "pod build [options]"
      option "-c CONFIG", "--config=CONFIG", type: String, desc: "Config file", default: DEFAULT_CONFIG_FILE
      option "-s", "--show", type: Bool, desc: "Show command only", default: false
      argument "target", type: String, desc: "target to build", required: false

      run do |opts, args|
        config = load_config(opts.config)
        target = args.target || config.defaults.build || fail "no target or default specified"
        unless image = config.images[target]?
          puts "image #{args.target} not defined in #{opts.config}"
          exit 1
        end
        if opts.show
          puts "podman #{Process.quote(image.to_command)}"
        else
          Process.exec(command: "podman", args: image.to_command)
        end
      end
    end
    sub "run" do
      desc "run a container"
      usage "pod run [options]"
      option "-c CONFIG", "--config=CONFIG", type: String, desc: "Config file", default: DEFAULT_CONFIG_FILE
      option "-s", "--show", type: Bool, desc: "Show command only", default: false
      argument "target", type: String, desc: "target to run", required: false

      run do |opts, args|
        config = load_config(opts.config)
        target = args.target || config.defaults.run || fail "no target or default specified"
        unless container = config.containers[target]?
          puts "container #{args.target} not defined in #{opts.config}"
          exit 1
        end
        if opts.show
          puts "podman #{Process.quote(container.to_command)}"
        else
          Process.exec(command: "podman", args: container.to_command)
        end
      end
    end
    sub "shell" do
      desc "run a shell in a container"
      usage "pod shell <container>"
      argument "target", type: String, desc: "target to run in", required: true

      run do |opts, args|
        Process.exec(command: "podman", args: {"exec", "-it", args.target, "sh", "-c", "if which bash 2> /dev/null; then bash; else sh; fi"})
      end
    end
    sub "attach" do
      desc "attach to a container"
      usage "pod attach <container>"
      argument "target", type: String, desc: "target to run in", required: true
      run do |opts, args|
        Process.exec(command: "podman", args: {"attach", args.target})
      end
    end
    sub "logs" do
      desc "show logs from a container"
      usage "pod logs <container>"
      argument "target", type: String, desc: "target to run in", required: true
      option "-f FOLLOW", "--follow=FOLLOW", type: Bool, desc: "follow logs", default: true

      run do |opts, args|
        Process.exec(command: "podman", args: {"logs", "--follow=#{opts.follow}", args.target})
      end
    end
    sub "init" do
      desc "initialise a config file"
      usage "pod init"

      run do |opts, args|
        config = Config::File.new(Config::Defaults.new("example", "example"))
        config.images["example"] = Config::Image.new("Containerfile", "pod-example:latest")
        container = Config::Container.new("pod-example", "pod-example:latest")
        container.cmd_args << "sh"
        config.containers["example"] = container
        File.open(DEFAULT_CONFIG_FILE, "w") { |f| config.to_yaml(f) }
        unless File.exists? "Containerfile"
          File.write "Containerfile", EXAMPLE_CONTAINERFILE
        end
        puts "Initialised pod config files in #{File.basename(Dir.current)}"
      end
    end
  end
end

CLI.start(ARGV)
