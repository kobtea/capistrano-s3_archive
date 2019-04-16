require "capistrano/scm/plugin"
require "aws-sdk-s3"
require "capistrano/scm/s3_archive/s3_param"
require "capistrano/scm/s3_archive/local_cache"

module Capistrano
  class SCM
    class S3Archive < Capistrano::SCM::Plugin

      def define_tasks
        eval_rakefile File.expand_path("tasks/s3_archive.rake", __dir__)
      end

      def register_hooks
        after "deploy:new_release_path", "s3_archive:create_release"
        before "deploy:check", "s3_archive:check"
        before "deploy:set_current_revision", "s3_archive:set_current_revision"
      end

      def set_defaults
        set_if_empty :s3_archive_client_options, {}
        set_if_empty(:s3_archive_sort_proc, ->(new, old) { old.key <=> new.key })
        set_if_empty :s3_archive_strategy, :rsync
        set_if_empty :s3_archive_object_version_id, nil

        # strategy direct
        set_if_empty :s3_archive_remote_cache_dir, -> { File.join(shared_path, "archives") }

        # strategy rsync
        set_if_empty :s3_archive_skip_download, nil
        set_if_empty :s3_archive_local_download_dir, "tmp/archives"
        set_if_empty :s3_archive_local_cache_dir, "tmp/deploy"
        set_if_empty :s3_archive_remote_rsync_options, ['-az', '--delete']
        set_if_empty :s3_archive_remote_rsync_ssh_options, []
        set_if_empty :s3_archive_remote_rsync_runner_options, {}
        set_if_empty :s3_archive_rsync_cache_dir, "shared/deploy"
        set_if_empty :s3_archive_hardlink_release, false
        set_if_empty :s3_archive_remote_rsync_copy_option, "--archive --acls --xattrs"
      end

      ######
      def local_check
        s3_client.list_objects(bucket: s3params.bucket, prefix: s3params.object_prefix)
      end

      def remote_check
        case strategy
        when :direct
          backend.execute :aws, "s3", "ls", ["s3:/", s3params.bucket, archive_object_key].join("/")
        when :rsync
          backend.execute :echo, "ssh connected"
        end
      end

      def strategy
        @strategy ||= fetch(:s3_archive_strategy)
      end

      def current_revision
        if fetch(:s3_archive_object_version_id)
          "#{archive_object_key}?versionid=#{fetch(:s3_archive_object_version_id)}"
        else
          archive_object_key
        end
      end

      def deploy_to_release_path
        case strategy
        when :direct
          archive_dir = File.join(fetch(:s3_archive_remote_cache_dir), fetch(:stage).to_s)
          archive_file = File.join(archive_dir, File.basename(archive_object_key))
          case archive_file
          when /\.zip\Z/
            backend.execute :unzip, "-q -d", release_path, archive_file
          when /\.tar\.gz\Z|\.tar\.bz2\Z|\.tgz\Z/
            backend.execute :tar, "xf", archive_file, "-C", release_path
          end
        when :rsync
          link_option = if fetch(:s3_archive_hardlink_release) && backend.test("[ `readlink #{current_path}` != #{release_path} ]")
                          "--link-dest `readlink #{current_path}`"
                        end
          create_release = %[rsync #{fetch(:s3_archive_remote_rsync_copy_option)} #{link_option} "#{rsync_cache_dir}/" "#{release_path}/"]
          backend.execute create_release
        end
      end

      # for rsync
      def download_to_local_cache
        etag = get_object_metadata.tap { |it| raise "No such object: #{current_revision}" if it.nil? }.etag
        local_cache.download_and_extract(s3params.bucket,
                                         archive_object_key,
                                         fetch(:s3_archive_object_version_id),
                                         etag)
      end

      def cleanup_local_cache
        local_cache.cleanup(keep: fetch(:keep_releases))
      end

      def transfer_sources(dest)
        rsync_options = []
        rsync_options.concat fetch(:s3_archive_remote_rsync_options, [])
        rsync_options << local_cache.cache_dir + "/"

        if dest.local?
          rsync_options << ('--no-compress')
          rsync_options << rsync_cache_dir
        else
          rsync_ssh_options = []
          rsync_ssh_options << dest.ssh_key_option unless dest.ssh_key_option.empty?
          rsync_ssh_options.concat fetch(:s3_archive_remote_rsync_ssh_options)
          rsync_options << "-e 'ssh #{rsync_ssh_options}'" unless rsync_ssh_options.empty?
          rsync_options << "#{dest.login_user_at}#{dest.hostname}:#{rsync_cache_dir}"
        end

        backend.execute :rsync, *rsync_options
      end

      def rsync_cache_dir
        File.join(deploy_to, fetch(:s3_archive_rsync_cache_dir))
      end


      # for direct
      def download_to_shared_path
        # etag = get_object_metadata.tap { |it| fail "No such object: #{current_revision}" if it.nil? }.etag

        # # remote_cache



        archive_dir = File.join(fetch(:s3_archive_remote_cache_dir), fetch(:stage).to_s)
        archive_file = File.join(archive_dir, File.basename(archive_object_key))
        tmp_file = "#{archive_file}.part"
        etag_file = File.join(archive_dir, ".#{File.basename(archive_object_key)}.etag")
        etag = get_object_metadata.tap { |it| fail "No such object: #{current_revision}" if it.nil? }.etag
        if backend.test("[ -f #{archive_file} -a -f #{etag_file} ]") &&
           backend.capture(:cat, etag_file) == etag
          backend.info "#{archive_file} (etag:#{etag}) is found. download skipped."
        else
          backend.info "Download #{current_revision} to #{archive_file}"
          backend.execute(:mkdir, "-p", archive_dir)
          version_id = fetch(:s3_archive_object_version_id)
          backend.execute(:aws, *['s3api', 'get-object', "--bucket #{s3params.bucket}", "--key #{archive_object_key}", version_id ? "--version-id #{version_id}" : nil, tmp_file].compact)
          backend.execute(:mv, tmp_file, archive_file)
          backend.execute(:echo, "-n", "'#{etag}'", "|tee", etag_file)
        end
      end

      def cleanup_shared_path
        archives_dir = File.join(fetch(:s3_archive_remote_cache_dir), fetch(:stage).to_s)
        archives = backend.capture(:ls, "-xtr", archives_dir).split
        if archives.count >= fetch(:keep_releases)
          to_be_removes = (archives - archives.last(fetch(:keep_releases)))
          if to_be_removes.any?
            backend.execute(:rm, *to_be_removes.map { |file| File.join(archives_dir, file) })
            backend.execute(:rm, '-f', *to_be_removes.map { |file| File.join(archives_dir, ".#{file}.etag" ) })
          end
        end
      end

      def s3params
        @s3params ||= S3Params.new(fetch(:repo_url))
      end

      def archive_object
        @archive_object ||= ArchiveObject.new(fetch(:repo_url))
      end

      def list_all_objects
        response = s3_client.list_objects(bucket: s3params.bucket, prefix: s3params.object_prefix)
        response.inject([]) do |objects, page|
          objects + page.contents
        end
      end

      def latest_object_key
        list_all_objects.sort(&fetch(:s3_archive_sort_proc)).first.key
      end

      def archive_object_key
        @archive_object_key ||=
          case fetch(:branch, :latest).to_sym
          when :master, :latest
            latest_object_key
          else
            s3params.object_prefix + fetch(:branch).to_s
          end
      end

      def current_revision
        if fetch(:s3_archive_object_version_id)
          "#{archive_object_key}?versionid=#{fetch(:s3_archive_object_version_id)}"
        else
          archive_object_key
        end
      end

      def get_object_metadata
        s3_client.list_object_versions(bucket: s3params.bucket, prefix: archive_object_key).versions.find do |v|
          if fetch(:s3_archive_object_version_id) then v.version_id == fetch(:s3_archive_object_version_id)
          else v.is_latest
          end
        end
      end

      private

      def s3_client
        @s3_client ||= Aws::S3::Client.new(fetch(:s3_archive_client_options))
      end

      def local_cache
        @local_cache ||= LocalCache.new(
          backend,
          File.join(fetch(:s3_archive_local_download_dir), fetch(:stage).to_s),
          File.join(fetch(:s3_archive_local_cache_dir), fetch(:stage).to_s),
          s3_client
        )
      end
    end
  end

  class Configuration
    class Server
      def login_user_at
        user = [user, ssh_options[:user]].compact.first
        user ? "#{user}@" : ''
      end

      def ssh_key_option
        key = [keys, ssh_options[:keys]].flatten.compact.first
        key ? "-i #{key}" : ''
      end

      def ssh_port_option
        port ? "-p #{port}" : ''
      end
    end
  end
end
