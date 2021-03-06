require "digest"
require "aws/s3"

module TravisBundleCache
  class Cache
    def initialize
      @architecture        = `uname -m`.strip
      @bundle_archive      = ENV['BUNDLE_ARCHIVE'] || ENV['TRAVIS_REPO_SLUG'].gsub(/\//, '-')
      @file_name           = "#{@bundle_archive}-#{@architecture}-#{RUBY_VERSION}p#{RUBY_PATCHLEVEL}.tgz"
      @file_path           = File.expand_path("~/#{@file_name}")
      @lock_file           = File.join(File.expand_path(ENV["TRAVIS_BUILD_DIR"]), "Gemfile.lock")
      @digest_filename     = "#{@file_name}.sha2"
      @old_digest_filename = File.expand_path("~/remote_#{@digest_filename}")
    end

    def install
      run_command %(cd ~ && wget -O "remote_#{@file_name}" "#{storage[@file_name].url_for(:read)}" && tar -xf "remote_#{@file_name}")
      run_command %(cd ~ && wget -O "remote_#{@file_name}.sha2" "#{storage[@digest_filename].url_for(:read)}")
      run_command %(bundle install --without #{ENV['BUNDLE_WITHOUT'] || "development production"} --path=~/.bundle), retry: true
    end

    def cache_bundle
      @bundle_digest = Digest::SHA2.file(@lock_file).hexdigest
      @old_digest    = File.exists?(@old_digest_filename) ? File.read(@old_digest_filename) : ""

      archive_and_upload_bundle
    end

    def archive_and_upload_bundle
      if @old_digest == ""
        puts "=> There was no existing digest, uploading a new version of the archive"
      else
        puts "=> There were changes, uploading a new version of the archive"
        puts "  => Old checksum: #{@old_digest}"
        puts "  => New checksum: #{@bundle_digest}"

        puts "=> Cleaning old gem versions from the bundle"
        run_command "bundle clean"
      end

      puts "=> Preparing bundle archive"
      run_command %(cd ~ && tar -cjf "#{@file_name}" .bundle), exit_on_error: true

      puts "=> Uploading the bundle"
      storage[@file_name].write(Pathname.new(@file_path), :reduced_redundancy => true)

      puts "=> Uploading the digest file"
      storage[@digest_filename].write(@bundle_digest, :content_type => "text/plain", :reduced_redundancy => true)

      puts "All done now."
    end

    protected

    def run_command(cmd, opts = {})
      tries = 1
      puts "Running: #{cmd}"
      while true
        IO.popen(cmd) do |f|
          begin
            print f.readchar while true
          rescue EOFError
          end
        end

        if $?.exitstatus == 0
          break
        elsif opts[:retry] && tries < 3
          tries += 1
          puts "Retrying attempt #{tries} of 3"
        elsif opts[:exit_on_error] || opts[:retry]
          exit($?.exitstatus)
        else
          break
        end
      end
    end

    def storage
      @storage ||= AWS::S3.new({
        :access_key_id     => ENV["AWS_S3_KEY"],
        :secret_access_key => ENV["AWS_S3_SECRET"],
        :region            => ENV["AWS_S3_REGION"] || "us-east-1"
      }).buckets[ENV["AWS_S3_BUCKET"]].objects
    end
  end
end
