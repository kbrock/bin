#!/usr/bin/env ruby


class UpdateSanitized
  #dev2.plm = 192.168.10.3
  attr_accessor :target_dir
  attr_accessor :user
  def initialize()
    @user = `whoami`.chomp
    @target_dir="#{ENV['HOME']}/db-dumps"
  end

  def run(cmd,verbose=true)
    puts
    puts("# #{cmd}")
    puts
    ret=[]
    dtstart=Time.now
    IO.popen(cmd) do |output| 
        while line = output.gets do
          puts line
          #ret << line
        end
    end
    dtend=Time.now
    puts "took: #{dtend-dtstart}"
    #ret #join("\n")
  end

  # def run(cmd)
  #   puts "#{cmd}"
  #   puts `time #{cmd}`
  # end

  #the date the file was created (not 'now')
  def datestr
    @datestr ||= File.exist?(file_name) ? File.stat(file_name).ctime.strftime("%Y-%m-%d") : nil
  end

  def remote
    "#{user}@192.168.10.3:/usr/local/pgsql/developer_db.pgdump"
  end

  def dated_file_name
    @dated_file_name ||= "#{target_dir}/developer_db.#{datestr}.pgdump"
  end

  def file_name
    "#{target_dir}/developer_db.pgdump"
  end

  def backup
    true
  end

  # fetch new file
  # symbolic link to new file
  # keeps old files
  def fetch_file(force=false)
    if backup
      return if File.exists?(dated_file_name) && ! force
      run "cp -P #{file_name} #{dated_file_name}" if ! File.exists?(dated_file_name)
      run "touch #{file_name}"
    end
    run "rsync -avz -P -C #{remote} #{file_name}"
  end

  #note, users (user, 'postgres', 'multum' need to exist)
  def load_sanitized
    run "dropdb plm_sanitized"
    run "createdb plm_sanitized -U postgres"
    #run "pg_restore --clean -d plm_sanitized #{dated_file_name} --verbose -j5"
    run "pg_restore -d plm_sanitized #{file_name} --verbose -j5"
    puts "may want to run: rake plm:create_branch_db"
  end

  def create_admin(new_user, as_user='postgres')
    run "createuser --superuser #{new_user} -U ${as_user}" if ! user_exists(new_user)
  end

  def user_exists(user_name)
    false
  end
end

if $0 == __FILE__
  $stdout.sync = true

  force=ARGV.include?('-f')
  download=ARGV.include?('-d')||force
  upload=ARGV.include?('-l')

  us=UpdateSanitized.new
  us.fetch_file(force) if download
  us.load_sanitized if upload

  if (download || force || upload) == false
    puts "usage: -d to download, -l to load, and -f to force the download"
  end
end
