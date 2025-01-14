require "file_utils"
require "ecr"

class Pod::Initializer
  SOURCE_DIRECTORY_NAMES = Set{
    "src",
    "Sources",
    "lib",
  }
  TITLE = "                _
  _ __  ___  __| |
 | '_ \\/ _ \\/ _` |
 | .__/\\___/\\__,_|
 |_|
"

  def self.run
    new.run
  end

  def run
    print TITLE
    workdir = Path[Dir.current]
    name = prompt("Project name", [] of String, workdir.basename)
    image = get_image
    if name != workdir.basename
      workdir /= name
      FileUtils.mkdir_p name
      FileUtils.cd workdir
    end
    Log.info { "Making project #{name} in #{workdir}" }
    if image && confirm("Enter container to setup project now?")
      do_container_setup(name, image)
    end
    image ||= "<<YOUR IMAGE>>"
    write_config_files(name, image)
    puts "Initialised project in #{workdir}"
  end

  def write_config_files(project, image)
    File.write "pods.yaml", ECR.render "src/template/pods.yaml"
    File.write "Containerfile.prod", ECR.render "src/template/Containerfile.prod"
  end

  def do_container_setup(name, image)
    container_name = "#{name}-setup"
    first = true
    loop do
      start = Time.utc
      if first
        status = PodmanCLI.run_inherit_all_io({
          "run", "-it", "--name", container_name,
          "--workdir", "/#{name}",
          "--entrypoint", {"sh", "-c", Runner::MAGIC_SHELL}.to_json,
          "--mount", "type=bind,src=.,dst=/#{name}",
          "--env", "PS1=#{name} $ ",
          image,
        })
      else
        Log.info { "Restarting prev setup container..." }
        status = PodmanCLI.run_inherit_io({"restart", container_name})
      end
      first = false
      if !status.success? && (Time.utc - start) < 3.seconds
        puts "Container failed fast, make sure the image is available and supports a shell"
      end
      if confirm("Setup complete?")
        break
      end
    end
    print "Removing container used for setup: "
    unless PodmanCLI.run_inherit_io({"rm", container_name}).success?
      puts "unable to remove setup container (#{container_name}) you can delete it later"
    end
    puts
  end

  COPY_ALL = "COPY . ."

  def project_specific_setup(is_dev, name)
    if File.exists? "./shard.yml"
      return String.build do |io|
        if is_dev
          io.puts "COPY shard.yml ."
          io.puts "RUN shards install"
          io.puts %(ENTRYPOINT ["shards", "run", "--error-trace", "--"])
        else
          io.puts COPY_ALL
          io.puts "RUN shards build --error-trace --release"
          io.puts %(ENTRYPOINT ["/src/bin/project"])
        end
      end
    end
    if File.exists? "./Gemfile"
      return String.build do |io|
        if is_dev
          io.puts "COPY Gemfile ."
          io.puts "RUN bundle install"
          io.puts %(ENTRYPOINT ["ruby", "..."])
        else
          io.puts "COPY Gemfile ."
          io.puts "RUN bundle install"
          io.puts COPY_ALL
          io.puts %(ENTRYPOINT ["ruby", "..."])
        end
      end
    end
    if File.exists? "./Cargo.toml"
      return String.build do |io|
        if is_dev
          io.puts "COPY Cargo.toml ."
          io.puts %(ENTRYPOINT ["cargo", "run", "--"])
        else
          io.puts COPY_ALL
          io.puts %(RUN cargo build --release)
          io.puts %(ENTRYPOINT ["/src/target/release/#{name}"])
        end
      end
    end
    if File.exists? "./Package.swift"
      return String.build do |io|
        if is_dev
          io.puts "COPY Package.swift ."
          io.puts %(ENTRYPOINT ["swift", "run", "--"])
        else
          io.puts COPY_ALL
          io.puts %(RUN swift build -c release)
          io.puts %(ENTRYPOINT ["/src/.build/release/#{name}"])
        end
      end
    end
  end

  def get_image
    loop do
      images = Podman.get_images(
        remote: nil,
        filter: "dangling=false"
      ).sort_by { |i| {i.name.starts_with?("localhost") ? 1 : 0, i.name} }
      if fzf = Process.find_executable("fzf")
        io = IO::Memory.new
        Process.run(
          fzf,
          input: IO::Memory.new(images.map(&.name).join("\n")),
          output: io, error: Process::Redirect::Inherit)
        io.rewind
        image = io.to_s.strip
        puts "Using #{image}"
        return image.empty? ? nil : image
      else
        unless images.empty?
          puts "Local images:"
          puts images[0...20].map_with_index { |im, idx|
            " [#{idx + 1}] #{im.name}"
          }.join("\n")
          puts "Select existing image or enter name."
        end
        unless image = prompt("Base image for development")
          puts "not adding image, you can do that later"
          return nil
        end
      end

      if (idx = image.to_i?) && (im = images[idx - 1]?)
        return im.name
      end

      if PodmanCLI.run_inherit_io({"pull", image}).success?
        return image
      end
      puts
      puts "Unable to pull #{image}"
      puts "Make sure the image and tag is correct"
    end
  end

  def confirm(message, default = "y")
    prompt(message, {"y", "n"}, default: default).downcase == "y"
  end

  def prompt(text : String, options : Enumerable(String) = [] of String, default : String? = nil)
    p = String.build do |io|
      io << text
      unless options.empty?
        io << " ["
        options.each_with_index do |opt, idx|
          io << '/' unless idx == 0
          if opt == default
            io << opt.upcase
          else
            io << opt
          end
        end
        io << "] "
      else
        if default
          io << " [" << default << "] "
        else
          io << ": "
        end
      end
    end
    print p
    unless input = gets
      raise Podman::Exception.new "expected input"
    end
    if input.blank?
      default
    else
      input
    end
  end
end
