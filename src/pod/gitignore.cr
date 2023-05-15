class Gitignore
  @ignored_dirs = Set(String).new

  def add(path : Path)
    File.open(path) do |f|
      while line = f.gets.try &.chomp
        next if line.blank?
        next if line.starts_with? '#'
        if line.starts_with?('/') && line.ends_with?('/')
          @ignored_dirs << line[1...-1]
        end
      end
    end
  end

  def includes?(path : Path) : Bool
    path.each_part do |part|
      if @ignored_dirs.includes? part
        return true
      end
    end
    false
  end
end
