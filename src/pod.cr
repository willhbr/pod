require "yaml"
require "./pod/*"
require "clim"
require "geode"
require "ecr"

module Pod
  DEFAULT_CONFIG_FILE = "pods.yaml"
  VERSION             = "0.1.0"
end

def exec_podman(args, remote = nil)
  wrap_exceptions do
    if remote
      a = ["--remote=true", "--connection=#{remote}"]
      a.concat(args)
    else
      a = args
    end
    Process.exec(command: "podman", args: a)
  end
end

def wrap_exceptions
  yield
  return
  begin
    yield
  rescue ex : Pod::Exception
    STDERR.puts ex.message
    Log.notice(exception: ex) { "Pod failed" }
    exit 1
  rescue ex : ::Exception
    STDERR.puts ex.message
    Log.error(exception: ex) { "Unexpected exception" }
    exit 1
  end
end

class Pod::CLI < Clim
  STORE_PATH    = ENV["POD_HISTORY_STORE"]? || "~/.config/pod/"
  SCRIPT_CONFIG = ENV["POD_SCRIPT_CONFIG"]? || "~/.config/pod/script.yaml"

  main do
    desc "Pod CLI"
    usage "pod [sub_command] [arguments]"

    version "pod version: #{Pod::VERSION}", short: "-v"
    help short: "-h"

    run do |opts, args|
      wrap_exceptions do
        puts opts.help_string
        if conf = Config.load_config(nil)
          puts "pod build => pod build #{conf.defaults.build}" if conf.defaults.build
          puts "pod run => pod run #{conf.defaults.build}" if conf.defaults.run
          puts "pod update => pod run #{conf.defaults.update}" if conf.defaults.update
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
      option "-c CONFIG", "--config=CONFIG", type: String, desc: "Config file", default: DEFAULT_CONFIG_FILE
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
      option "-c CONFIG", "--config=CONFIG", type: String, desc: "Config file", default: DEFAULT_CONFIG_FILE
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
      option "-c CONFIG", "--config=CONFIG", type: String, desc: "Config file", default: DEFAULT_CONFIG_FILE
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
      option "-c CONFIG", "--config=CONFIG", type: String, desc: "Config file", default: DEFAULT_CONFIG_FILE
      option "-r REMOTE", "--remote=REMOTE", type: String, desc: "Remote host to use", required: false
      option "-d", "--diff", type: Bool, desc: "Show a diff", default: false
      argument "target", type: String, desc: "target to run", required: false

      run do |opts, args|
        wrap_exceptions do
          config = Config.load_config!(opts.config)
          containers = config.get_containers(args.target || config.defaults.update)
          store = StateStore.new(Path[STORE_PATH].expand(home: true))
          manager = Updater.new(STDOUT, opts.remote, store)
          configs = containers.map { |c| c[1] }
          configs.each do |conf|
            conf.apply_overrides! remote: opts.remote
          end
          updates = manager.calculate_updates(configs)
          if opts.diff
            manager.print_changes(updates)
            if updates.any? &.actionable?
              print "update? [y/N] "
              if (inp = gets) && inp.chomp.downcase == "y"
                manager.update_containers(updates)
                store.save
              end
            end
          else
            manager.update_containers(updates)
            store.save
          end
        end
      end
    end

    sub "diff" do
      alias_name "d"
      desc "preview updates to running containers"
      usage "pod diff [options]"
      option "-c CONFIG", "--config=CONFIG", type: String, desc: "Config file", default: DEFAULT_CONFIG_FILE
      option "-r REMOTE", "--remote=REMOTE", type: String, desc: "Remote host to use", required: false
      argument "target", type: String, desc: "target to run", required: false

      run do |opts, args|
        wrap_exceptions do
          config = Config.load_config!(opts.config)
          containers = config.get_containers(args.target || config.defaults.update)
          manager = Updater.new(STDOUT, opts.remote,
            StateStore.new(Path[STORE_PATH].expand(home: true)))
          configs = containers.map { |c| c[1] }
          updates = manager.calculate_updates(configs)
          manager.print_changes(updates)
        end
      end
    end

    sub "revert" do
      alias_name "undo", "rollback"
      desc "revert an update"
      usage "pod revert [options]"
      option "-c CONFIG", "--config=CONFIG", type: String, desc: "Config file", default: DEFAULT_CONFIG_FILE
      option "-r REMOTE", "--remote=REMOTE", type: String, desc: "Remote host to use", required: false
      option "-d", "--diff", type: Bool, desc: "Show a diff", default: false
      argument "target", type: String, desc: "target to run", required: false

      run do |opts, args|
        wrap_exceptions do
          config = Config.load_config!(opts.config)
          containers = config.get_containers(args.target || config.defaults.update)
          store = StateStore.new(Path[STORE_PATH].expand(home: true))
          manager = Updater.new(STDOUT, opts.remote, store)
          states = Array(StateStore::ContainerState).new
          containers.each do |name, container|
            versions = store[opts.remote || container.remote, container.name]
            if versions.empty?
              STDERR.puts "No update history for #{name}"
              next
            end
            versions.each_with_index do |version, index|
              puts "[#{index + 1}] #{version.update_time}: #{version.config.image.truncated}"
            end
            print "select version [1-#{versions.size}]: "
            unless (choice = gets.try(&.chomp)) && (idx = choice.to_i?)
              raise Pod::Exception.new("enter an index, 1-#{versions.size}")
            end
            version = versions[idx - 1]
            states << version
          end
          updates = manager.calculate_reversions(states)
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

    sub "shell" do
      alias_name "sh"
      desc "run a shell in a container"
      usage "pod shell <container>"
      argument "target", type: String, desc: "target to run in", required: true
      option "-r REMOTE", "--remote=REMOTE", type: String, desc: "Remote host to use", required: false

      run do |opts, args|
        exec_podman({"exec", "-it", args.target, "sh", "-c",
                     "if which bash > /dev/null 2>&1; then bash; else sh; fi"}, remote: opts.remote)
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
      alias_name "i"
      desc "initialise a config file"
      usage "pod init"

      run do |opts, args|
        wrap_exceptions do
          project = Path[Dir.current].basename
          unless File.exists? DEFAULT_CONFIG_FILE
            File.open(DEFAULT_CONFIG_FILE, "w") do |f|
              ECR.embed("src/template/pods.yaml", f)
            end
          end
          unless File.exists? "Containerfile.dev"
            File.write "Containerfile.dev", ECR.render("src/template/Containerfile.dev")
          end
          unless File.exists? "Containerfile.prod"
            File.write "Containerfile.prod", ECR.render("src/template/Containerfile.prod")
          end
          puts "Initialised pod config files in #{project}."
          puts "Please edit to taste."
        end
      end
    end

    sub "targets" do
      desc "targets as defined in config file, for shell completion"
      usage "pod init"
      option "-c CONFIG", "--config=CONFIG", type: String, desc: "Config file", default: DEFAULT_CONFIG_FILE

      run do |opts, args|
        wrap_exceptions do
          config = Config.load_config!(opts.config)
          puts Set(String).new(config.images.keys + config.containers.keys + config.groups.keys).join('\n')
        end
      end
    end

    sub "script" do
      alias_name "sc"
      desc "run a script"
      usage "pod script <name> -- script args"

      run do |opts, args|
        wrap_exceptions do
          config = Scripter::Config.from_yaml(File.read(Path[SCRIPT_CONFIG].expand(home: true)))
          scripter = Pod::Scripter.new(config)
          scripter.exec(args.argv)
        end
      end
    end
  end
end

severity = Log::Severity.parse?(ENV["POD_LOG_LEVEL"]? || "error") || Log::Severity::Error
{% unless flag? :release %}
  severity = Log::Severity::Debug
{% end %}
Log.setup do |l|
  l.stderr(severity: severity)
end
Log.info { "Logging at: #{severity}" }

Colorize.on_tty_only!
Pod::CLI.start(ARGV)
