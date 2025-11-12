#!/usr/bin/env ruby

require 'optparse'
require 'fileutils'

# Deterine wihch Gemfiles and gemspecs reference the library (rack in this example)
# ag -l --ruby "['\"]rack['\"]" ~/src{,/gems}/manageiq*/{Gemfile,*.gemspec}
# cd to an affected repository
# git checkout master ; git pull
# gem_updater.rb "rack" "2.2.20" --advisory https://github.com/advisories/GHSA-6xw4-3v39-52mm --cve CVE-2025-61919
# if something has changed:
# git checkout -b CVE-2025-61919
# git add -u .
# git commit -m "update rack for CVE-2025-59830" -m "CVE-2025-59830 https://github.com/advisories/GHSA-625h-95r8-8xpm"
#
# feel like this could be optimized to run the the update, checkout, add, and commit
class GemVersionUpdater
  attr_reader :gem_name, :min_version, :cve, :advisory

  def initialize
  end

  def parse(argv)
    parser = OptionParser.new do |opts|
      opts.banner = "Usage: update_gem_version.rb GEM_NAME MIN_VERSION [FILE1 FILE2 ...]"
      opts.version = "1.0.0"
      opts.on("-c CVE", "--cve CVE",      "CVE identifier (e.g., CVE-2025-61772)")  { |c| @cve = c }
      opts.on("-a URL", "--advisory URL", "GitHub advisory URL (e.g., https://github.com/advisories/GHSA-wpv5-97wm-hp9c)") { |a| @advisory = a }
    end

    parser.parse!(argv)

    if argv.size < 2
      puts "Error: Missing required arguments."
      puts parser.help
      exit 1
    end

    @gem_name = argv[0]
    @min_version = argv[1]

    file_paths = argv[2..]
    # If no files specified, use Gemfile and all gemspec files in current directory
    if file_paths.empty?
      file_paths = []
      file_paths << 'Gemfile' if File.exist?('Gemfile')
      file_paths.concat(Dir.glob('*.gemspec'))

      if file_paths.empty?
        puts "No Gemfile or gemspec files found in current directory. Please specify files to update."
        exit 1
      end
    end

    file_paths
  rescue OptionParser::InvalidOption => e
    puts e.message
    puts parser.help
    exit 1
  end

  def run(argv)
    success = true

    file_paths = parse(argv)
    file_paths.each do |file_path|
      success &&= update(file_path)
    end

    success
  end

  def update(file_path)
    unless File.exist?(file_path)
      puts "Error: File '#{file_path}' not found."
      return false
    end

    content = File.read(file_path)
    updated_content = update_file(content)

    if content == updated_content
      puts "#{file_path} unchanged"
      return true
    end

    # Write updated content
    File.write(file_path, updated_content)
    puts "#{file_path}: updated"
    true
  end

  private

  def escaped_gem_name
    Regexp.escape(gem_name)
  end

  # Extract major.minor version from min_version
  def version_parts
    min_version.split('.')
  end

  def major_minor
    version_parts[0..1].compact.join(".")
  end

  def is_three_digit
    version_parts.length >= 3
  end

  # Pattern that matches both Gemfile (gem ...) and gemspec (*.add_dependency ...) formats
  def update_file(content)
    new_content = content.dup
    gem_pattern = '(?:gem\s+|\S+\.add_(?:runtime_|development_)?dependency\s+)'

    # Quick check if the file contains the gem at all
    quick_gem_check = /#{gem_pattern}['"]#{escaped_gem_name}['"]/
    return new_content unless new_content.match?(quick_gem_check)

    # Process the file line by line
    lines = new_content.split("\n")
    modified_lines = lines.map do |line|
      # Skip lines that don't contain our gem
      next line unless line.match?(quick_gem_check)

      line = update_version_constraints_line(gem_pattern, line)
      line = update_cve(line) if cve
      line = update_advisory(line) if advisory
      line
    end

    modified_lines.join("\n") + "\n"
  end

  def update_version_constraints_line(gem_pattern, line)
    # Case 1: Update existing ">= x.y.z" constraint
    greater_than_eq_pattern = /(#{gem_pattern}['"]#{escaped_gem_name}['"].*>=\s*)[0-9.]+/
    if line.match?(greater_than_eq_pattern)
      return line.gsub(greater_than_eq_pattern, "\\1#{min_version}")
    end

    # Case 2: Update existing "> x.y.z" constraint
    greater_than_pattern = /(#{gem_pattern}['"]#{escaped_gem_name}['"].*>\s*)[0-9.]+/
    if line.match?(greater_than_pattern)
      return line.gsub(greater_than_pattern, "\\1#{min_version}")
    end

    # Case 3: Handle "~> x.y" pattern with or without ">= x.y.z"
    tilde_pattern = /(#{gem_pattern}['"]#{escaped_gem_name}['"].*?)(~>\s*[0-9.]+)/
    if line.match?(tilde_pattern)
      if is_three_digit
        # For 3-digit min_version with existing ~> constraint: "~> major.minor", ">= major.minor.patch"
        if line.include?(">= ")
          return line.gsub(/(#{gem_pattern}['"]#{escaped_gem_name}['"].*?~>\s*)[0-9.]+(['"].*?>=\s*)[0-9.]+/,
                            "\\1#{major_minor}\\2#{min_version}")
        else
          return line.gsub(/(#{gem_pattern}['"]#{escaped_gem_name}['"].*?~>\s*)[0-9.]+/,
                            "\\1#{major_minor}\", \">= #{min_version}")
        end
      else
        # For 2-digit min_version with existing ~> constraint: "~> major.minor"
        return line.gsub(/(#{gem_pattern}['"]#{escaped_gem_name}['"].*?~>\s*)[0-9.]+/,
                          "\\1#{min_version}")
      end
    end

    # Case 4: Handle "= x.y.z" constraint
    equal_pattern = /(#{gem_pattern}['"]#{escaped_gem_name}['"].*?=\s*)[0-9.]+/
    if line.match?(equal_pattern)
      return line.gsub(equal_pattern, "~> #{min_version}")
    end

    # Case 5: No version constraint exists, add "> min_version"
    no_version_pattern = /(#{gem_pattern}['"]#{escaped_gem_name}['"])(?!\s*,)/
    if line.match?(no_version_pattern)
      return line.gsub(no_version_pattern, "\\1, \"> #{min_version}\"")
    end

    # Case 6: Has version but no constraints, add ">= min_version"
    plain_version_pattern = /(#{gem_pattern}['"]#{escaped_gem_name}['"],\s*['"])([^~>].*?['"])/
    if line.match?(plain_version_pattern)
      return line.gsub(plain_version_pattern, "\\1 \">= #{min_version}\"\\2")
    end

    # warning. not sure why it got here
    line
  end

  def update_cve(content)
    # Pattern to match GitHub advisory URLs on gem lines
    cve_pattern = /CVE-[0-9\-]*/

    if content.match?(cve_pattern)
      # Replace existing advisory with new one
      content.gsub(cve_pattern, cve)
    elsif content.include?("#") # assuming this is a comment
      "#{content} #{cve}"
    else
      "#{content} # #{cve}"
    end
  end

  def update_advisory(content)
    # Pattern to match GitHub advisory URLs on gem lines
    advisory_pattern = /(https?:\/\/github\.com\/.*advisories\/GHSA-[a-z0-9\-]+)/

    if content.match?(advisory_pattern)
      # Replace existing advisory with new one
      content.gsub(advisory_pattern, advisory)
    elsif content.include?("#") # assuming this is a comment
      "#{content} #{advisory}"
    else
      "#{content} # #{advisory}"
    end
  end
end

# Execute the updater
success = GemVersionUpdater.new.run(ARGV)
exit(success ? 0 : 1)
