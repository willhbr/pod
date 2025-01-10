require "yaml"
require "./pod/*"
require "clim"
require "geode"
require "ecr"

module Pod
  VERSION = "0.1.0"

  def self.build_info
    Geode::ProgramInfo::BUILT_AT
  end
end

def exec_podman(args, remote = nil)
  wrap_exceptions do
    Pod::PodmanCLI.exec(args, remote)
  end
end

def wrap_exceptions
  begin
    yield
  rescue ex : Podman::Exception
    ex.print_message STDERR
    Log.notice(exception: ex) { "Pod failed" }
    exit 1
  rescue ex : ::Exception
    STDERR.puts ex.message
    Log.error(exception: ex) { "Unexpected exception" }
    exit 1
  end
end

class Pod::CLI < Clim
  SCRIPT_CONFIG = ENV["POD_SCRIPT_CONFIG"]? || "~/.config/pod/script.yaml"

  main do
    desc "Pod CLI"
    usage "pod [sub_command] [arguments]"

    version "pod version: #{Pod::VERSION} (#{Pod.build_info})", short: "-v"
    help short: "-h"

    run do |opts, args|
      wrap_exceptions do
        puts opts.help_string
        if conf = Config.load_config(nil)
          puts "pod build => pod build #{conf.defaults.build}" if conf.defaults.build
          puts "pod run => pod run #{conf.defaults.build}" if conf.defaults.run
          puts "pod update => pod update #{conf.defaults.update}" if conf.defaults.update
          puts
          puts "pod build #{conf.images.keys.join(", ")}" unless conf.images.size.zero?
          puts "pod run #{conf.containers.keys.join(", ")}" unless conf.containers.size.zero?
          puts
          puts "pod build|run :all,#{conf.groups.keys.join(", ")}" unless conf.groups.size.zero?
        end
      end
    end

    sub "build" do
      alias_name "b"
      desc "build an image"
      usage "pod build [options]"
      option "-c CONFIG", "--config=CONFIG", type: String, desc: "Config file", required: false
      option "-s", "--show", type: Bool, desc: "Show command only", default: false
      option "-r REMOTE", "--remote=REMOTE", type: String, desc: "Remote host to use", required: false
      argument "target", type: String, desc: "target to build", required: false

      run do |opts, args|
        wrap_exceptions do
          config = Config.load_config!(opts.config)
          actuator = Runner.new(config, opts.remote, opts.show, STDOUT)
          actuator.build(args.target)
        end
      end
    end

    sub "run" do
      alias_name "r"
      desc "run a container"
      usage "pod run [options]"
      option "-c CONFIG", "--config=CONFIG", type: String, desc: "Config file", required: false
      option "-s", "--show", type: Bool, desc: "Show command only", default: false
      option "-d", "--detach", type: Bool, desc: "Run container detached", default: false
      option "-i", "--interactive", type: Bool, desc: "Run container interactive", default: false
      option "-r REMOTE", "--remote=REMOTE", type: String, desc: "Remote host to use", required: false
      argument "target", type: String, desc: "target to run", required: false

      run do |opts, args|
        wrap_exceptions do
          extra_args = args.argv.skip_while { |a| a != "--" }.to_a
          if extra_args.empty?
            extra_args = nil
          else
            extra_args = extra_args[1...]
          end
          config = Config.load_config!(opts.config)
          if opts.detach
            detached = true
          elsif opts.interactive
            detached = false
          else
            detached = nil
          end
          Runner.new(config, opts.remote, opts.show, STDOUT).run(
            args.target, detached, extra_args)
        end
      end
    end

    sub "push" do
      alias_name "p"
      desc "push an image to a registry"
      usage "pod push [options]"
      option "-c CONFIG", "--config=CONFIG", type: String, desc: "Config file", required: false
      option "-s", "--show", type: Bool, desc: "Show command only", default: false
      option "-r REMOTE", "--remote=REMOTE", type: String, desc: "Remote host to use", required: false
      argument "target", type: String, desc: "target to push", required: false

      run do |opts, args|
        wrap_exceptions do
          config = Config.load_config!(opts.config)
          Runner.new(config, opts.remote, opts.show, STDOUT).push(args.target)
        end
      end
    end

    sub "update" do
      alias_name "u"
      desc "update a running container"
      usage "pod update [options]"
      option "-c CONFIG", "--config=CONFIG", type: String, desc: "Config file", required: false
      option "-r REMOTE", "--remote=REMOTE", type: String, desc: "Remote host to use", required: false
      option "-d", "--diff", type: Bool, desc: "Show a diff", default: false
      option "-b", "--bounce", type: Bool, desc: "Force restart all containers", default: false
      argument "target", type: String, desc: "target to run", required: false

      run do |opts, args|
        wrap_exceptions do
          config = Config.load_config!(opts.config)
          containers = config.get_containers(args.target || config.defaults.update)
          manager = Updater.new(STDOUT, opts.remote, opts.bounce)
          configs = containers.map { |c| c[1] }
          configs.each do |conf|
            conf.apply_overrides! remote: opts.remote, detached: true
          end
          updates = manager.calculate_updates(configs)
          if opts.diff
            manager.print_changes(updates)
            if updates.any? &.actionable?
              print "update? [y/N] "
              if (inp = gets) && inp.chomp.downcase == "y"
                manager.update_containers(updates)
              end
            end
          else
            manager.update_containers(updates)
          end
        end
      end
    end

    sub "diff" do
      alias_name "d"
      desc "preview updates to running containers"
      usage "pod diff [options]"
      option "-c CONFIG", "--config=CONFIG", type: String, desc: "Config file", required: false
      option "-r REMOTE", "--remote=REMOTE", type: String, desc: "Remote host to use", required: false
      option "-b", "--bounce", type: Bool, desc: "Force restart all containers", default: false
      argument "target", type: String, desc: "target to run", required: false

      run do |opts, args|
        wrap_exceptions do
          config = Config.load_config!(opts.config)
          containers = config.get_containers(args.target || config.defaults.update)
          manager = Updater.new(STDOUT, opts.remote, opts.bounce)
          configs = containers.map { |c| c[1] }
          updates = manager.calculate_updates(configs)
          manager.print_changes(updates)
        end
      end
    end

    sub "secrets" do
      desc "update secrets for containers"
      usage "pod secrets <container>"
      argument "target", type: String, desc: "container(s) to update", required: false
      option "-c CONFIG", "--config=CONFIG", type: String, desc: "Config file", required: false
      option "-r REMOTE", "--remote=REMOTE", type: String, desc: "Remote host to use", required: false

      run do |opts, args|
        wrap_exceptions do
          config = Config.load_config!(opts.config)
          runner = Runner.new(config, opts.remote, false, STDOUT)
          runner.update_secrets(args.target || config.defaults.update)
        end
      end
    end

    sub "shell" do
      alias_name "sh"
      desc "attach a shell to a container"
      usage "pod shell <container>"
      argument "target", type: String, desc: "target to run in", required: true
      option "-r REMOTE", "--remote=REMOTE", type: String, desc: "Remote host to use", required: false

      run do |opts, args|
        exec_podman({"exec", "-it", args.target, "sh", "-c",
                     Runner::MAGIC_SHELL}, remote: opts.remote)
      end
    end

    sub "attach" do
      alias_name "a"
      desc "attach to a container"
      usage "pod attach <container>"
      argument "target", type: String, desc: "target to run in", required: true
      option "-r REMOTE", "--remote=REMOTE", type: String, desc: "Remote host to use", required: false
      run do |opts, args|
        exec_podman({"attach", args.target}, remote: opts.remote)
      end
    end

    sub "enter" do
      alias_name "e"
      desc "run a shell from an entrypoint"
      usage "pod enter <entrypoint>"
      argument "entrypoint", type: String, desc: "entrypoint to run", required: false
      option "-c CONFIG", "--config=CONFIG", type: String, desc: "Config file", required: false
      option "-r REMOTE", "--remote=REMOTE", type: String, desc: "Remote host to use", required: false
      option "-s", "--show", type: Bool, desc: "Show command only", default: false
      run do |opts, args|
        wrap_exceptions do
          extra_args = args.argv.skip_while { |a| a != "--" }.to_a
          if extra_args.empty?
            extra_args = nil
          else
            extra_args = extra_args[1...]
          end
          config = Config.load_config!(opts.config)
          Runner.new(config, opts.remote, opts.show, STDOUT).enter(
            args.entrypoint, extra_args)
        end
      end
    end

    sub "logs" do
      alias_name "l"
      desc "show logs from a container"
      usage "pod logs <container>"
      argument "target", type: String, desc: "target to run in", required: true
      option "-f FOLLOW", "--follow=FOLLOW", type: Bool, desc: "follow logs", default: true
      option "-r REMOTE", "--remote=REMOTE", type: String, desc: "Remote host to use", required: false

      run do |opts, args|
        exec_podman({"logs", "--follow=#{opts.follow}", args.target}, remote: opts.remote)
      end
    end

    sub "init" do
      alias_name "i", "initialise", "initialize"
      desc "setup a pod project"
      usage "pod init"

      run do |opts, args|
        wrap_exceptions do
          Pod::Initializer.run
        end
      end
    end

    sub "targets" do
      desc "targets as defined in config file, for shell completion"
      usage "pod init"
      option "-c CONFIG", "--config=CONFIG", type: String, desc: "Config file", required: false

      run do |opts, args|
        wrap_exceptions do
          config = Config.load_config!(opts.config)
          puts Set(String).new(
            config.images.keys +
            config.containers.keys
          ).join('\n')
        end
      end
    end

    sub "script" do
      alias_name "sc"
      desc "run a script"
      usage "pod script <name> -- [args]"
      option "-t TYPE", "--type=TYPE", type: String, desc: "force a particular file extension", required: false

      run do |opts, args|
        wrap_exceptions do
          path = Path[SCRIPT_CONFIG].expand(home: true)
          unless File.exists? path
            STDERR.puts "Script config doesn't exist in #{SCRIPT_CONFIG}"
            exit 1
          end
          config = Scripter::Config.from_yaml(File.read(path))
          scripter = Pod::Scripter.new(config)
          scripter.exec(opts.type, args.argv)
        end
      end
    end

    sub "repl" do
      desc "run a repl"
      usage "pod repl <type>"
      argument "type", type: String, desc: "repl to run", required: true

      run do |opts, args|
        wrap_exceptions do
          config = Scripter::Config.from_yaml(File.read(Path[SCRIPT_CONFIG].expand(home: true)))
          scripter = Pod::Scripter.new(config)
          scripter.repl(args.type, args.argv.shift(0))
        end
      end
    end
  end
end
