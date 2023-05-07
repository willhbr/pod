require "yaml"
require "./pod/*"
require "clim"
require "geode"

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
        config.get_images(args.target).each do |name, image|
          args = image.to_command
          if opts.show
            puts "podman #{Process.quote(args)}"
          else
            status = Process.run(command: "podman", args: args,
              input: Process::Redirect::Close,
              output: Process::Redirect::Inherit,
              error: Process::Redirect::Inherit)
            unless status.success?
              fail "failed to build #{name}"
            end
          end
        end
      end
    end
    sub "run" do
      desc "run a container"
      usage "pod run [options]"
      option "-c CONFIG", "--config=CONFIG", type: String, desc: "Config file", default: DEFAULT_CONFIG_FILE
      option "-s", "--show", type: Bool, desc: "Show command only", default: false
      option "-d", "--detach", type: Bool, desc: "Run container detached", default: false
      option "-i", "--interactive", type: Bool, desc: "Run container interactive", default: false
      argument "target", type: String, desc: "target to run", required: false

      run do |opts, args|
        config = load_config(opts.config)
        containers = config.get_containers(args.target)
        multiple = containers.size > 1
        detached = nil
        if multiple
          detached = true
        elsif opts.detach
          detached = true
        elsif opts.interactive
          detached = false
        end
        containers.each do |name, container|
          args = container.to_command(detached: detached)
          if opts.show
            puts "podman #{Process.quote(args)}"
          elsif multiple
            status = Process.run(command: "podman", args: args,
              input: Process::Redirect::Close,
              output: Process::Redirect::Inherit,
              error: Process::Redirect::Inherit)
            unless status.success?
              fail "failed to run #{name}"
            end
          else
            Process.exec(command: "podman", args: args)
          end
        end
      end
    end
    sub "update" do
      desc "update a running container"
      usage "pod update [options]"
      option "-c CONFIG", "--config=CONFIG", type: String, desc: "Config file", default: DEFAULT_CONFIG_FILE
      argument "target", type: String, desc: "target to run", required: false

      run do |opts, args|
        config = load_config(opts.config)
        containers = config.get_containers(args.target)
        manager = Podman::Manager.new("podman")
        manager.update_containers(containers.map { |c| c[1] })
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

Log.setup do |l|
  l.stderr
end

CLI.start(ARGV)
