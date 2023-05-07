require "yaml"
require "./pod-compost/*"
require "clim"

DEFAULT_CONFIG_FILE = "pods.yaml"

class CLI < Clim
  main do
    desc "Pod CLI"
    usage "pod [sub_command] [arguments]"
    run do |opts, args|
      puts opts.help_string
    end
    sub "build" do
      desc "build stuff"
      usage "pod build [tool] [arguments]"
      option "-c CONFIG", "--config=CONFIG", type: String, desc: "Config file", default: DEFAULT_CONFIG_FILE
      argument "target", type: String, desc: "target to build", required: false

      run do |opts, args|
        config = Config::File.from_yaml(File.read(opts.config))
        image : Config::Image
        if args.target.nil?
          if config.images.size == 1
            image = config.images[0]
          else
            puts "multiple images defined in #{opts.config}, specify what to build"
            exit 1
          end
        else
          unless img = config.images.find { |img| img.name == args.target }
            puts "image #{args.target} not defined in #{opts.config}"
            exit 1
          end
          image = img
        end
        Process.exec(command: "podman", args: image.to_command)
      end
    end
    sub "run" do
      desc "build and run specs"
      usage "pod run [options] [files]"
      option "-c CONFIG", "--config=CONFIG", type: String, desc: "Config file", default: DEFAULT_CONFIG_FILE
      argument "target", type: String, desc: "target to run", required: false

      run do |opts, args|
        config = Config::File.from_yaml(File.read(opts.config))
        container : Config::Container
        if args.target.nil?
          if config.containers.size == 1
            container = config.containers[0]
          else
            puts "multiple containers defined in #{opts.config}, specify what to build"
            exit 1
          end
        else
          unless cont = config.containers.find { |cont| cont.name == args.target }
            puts "container #{args.target} not defined in #{opts.config}"
            exit 1
          end
          container = cont
        end
        Process.exec(command: "podman", args: container.to_command)
      end
    end
    sub "shell" do
      desc "run a shell in a container"
      usage "pod shell"
      argument "target", type: String, desc: "target to run in", required: true

      run do |opts, args|
        Process.exec(command: "podman", args: {"exec", "-it", args.target, "sh", "-c", "if which bash 2> /dev/null; then bash; else sh; fi"})
      end
    end
    sub "attach" do
      desc "attach to a container"
      usage "pod attach"
      argument "target", type: String, desc: "target to run in", required: true
      run do |opts, args|
        Process.exec(command: "podman", args: {"attach", args.target})
      end
    end
    sub "logs" do
      desc "show logs from a container"
      usage "pod logs"
      argument "target", type: String, desc: "target to run in", required: true
      option "-f FOLLOW", "--follow=FOLLOW", type: Bool, desc: "follow logs", default: true

      run do |opts, args|
        Process.exec(command: "podman", args: {"logs", "--follow=#{opts.follow}", args.target})
      end
    end
  end
end

CLI.start(ARGV)
