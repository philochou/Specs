# encoding: utf-8

require 'active_support/core_ext/string/inflections'

module Pod
  class Command
    class Spec < Command
      self.abstract_command = true
      self.summary = 'Manage pod specs'

      #-----------------------------------------------------------------------#

      class Create < Spec
        self.summary = 'Create spec file stub.'

        self.description = <<-DESC
          Creates a PodSpec, in the current working dir, called `NAME.podspec'.
          If a GitHub url is passed the spec is prepopulated.
        DESC

        self.arguments = '[ NAME | https://github.com/USER/REPO ]'

        def initialize(argv)
          @name_or_url, @url = argv.shift_argument, argv.shift_argument
          super
        end

        def validate!
          super
          help! "A pod name or repo URL is required." unless @name_or_url
        end

        def run
          if repo_id_match = (@url || @name_or_url).match(/github.com\/([^\/\.]*\/[^\/\.]*)\.*/)
            # This is to make sure Faraday doesn't warn the user about the `system_timer` gem missing.
            old_warn, $-w = $-w, nil
            begin
              require 'faraday'
            ensure
              $-w = old_warn
            end
            require 'octokit'

            repo_id = repo_id_match[1]
            data = github_data_for_template(repo_id)
            data[:name] = @name_or_url if @url
            UI.puts semantic_versioning_notice(repo_id, data[:name]) if data[:version] == '0.0.1'
          else
            data = default_data_for_template(@name_or_url)
          end
          spec = spec_template(data)
          (Pathname.pwd + "#{data[:name]}.podspec").open('w') { |f| f << spec }
          UI.puts "\nSpecification created at #{data[:name]}.podspec".green
        end
      end

      #-----------------------------------------------------------------------#

      class Lint < Spec
        self.summary = 'Validates a spec file.'

        self.description = <<-DESC
          Validates `NAME.podspec'. If a directory is provided it validates
          the podspec files found, including subfolders. In case
          the argument is omitted, it defaults to the current working dir.
        DESC

        self.arguments = '[ NAME.podspec | DIRECTORY | http://PATH/NAME.podspec, ... ]'

        def self.options
          [ ["--quick",       "Lint skips checks that would require to download and build the spec"],
            ["--local",       "Lint a podspec against the local files contained in its directory"],
            ["--only-errors", "Lint validates even if warnings are present"],
            ["--no-clean",    "Lint leaves the build directory intact for inspection"] ].concat(super)
        end

        def initialize(argv)
          @quick       =  argv.flag?('quick')
          @local       =  argv.flag?('local')
          @only_errors =  argv.flag?('only-errors')
          @clean    =  argv.flag?('clean', true)
          @podspecs_paths = argv.arguments!
          super
        end

        def run
          UI.puts
          invalid_count = 0
          podspecs_to_lint.each do |podspec|
            validator             = Validator.new(podspec)
            validator.quick       = @quick
            validator.local       = @local
            validator.no_clean    = !@clean
            validator.only_errors = @only_errors
            validator.validate
            invalid_count += 1 unless validator.validated?

            unless @clean
              UI.puts "Pods project available at `#{validator.validation_dir}/Pods/Pods.xcodeproj` for inspection."
              UI.puts
            end
          end

          count = podspecs_to_lint.count
          UI.puts "Analyzed #{count} #{'podspec'.pluralize(count)}.\n\n"
          if invalid_count == 0
            lint_passed_message = count == 1 ? "#{podspecs_to_lint.first.basename} passed validation." : "All the specs passed validation."
            UI.puts lint_passed_message.green << "\n\n"
          else
            raise Informative, count == 1 ? "The spec did not pass validation." : "#{invalid_count} out of #{count} specs failed validation."
          end
          podspecs_tmp_dir.rmtree if podspecs_tmp_dir.exist?
        end
      end

      #-----------------------------------------------------------------------#

      class Cat < Spec
        self.summary = 'Prints a spec file'

        self.description = <<-DESC
          Prints `NAME.podspec` to standard output.
        DESC

        self.arguments = '[ NAME.podspec ]'

        def initialize(argv)
          @name = argv.shift_argument
          super
        end

        def validate!
          super
          help! "A pod name is required." unless @name
        end

        def run
          found_sets = SourcesManager.search_by_name(@name)
          raise Informative, "Unable to find a spec named `#{@name}'." if found_sets.count == 0
          unless found_sets.count == 1
            names = found_sets.map(&:name) * ', '
            raise Informative, "More that one fitting spec found:\n #{names}"
          end

          set = found_sets.first
          spec = best_spec_from_set(set)
          file_name = spec.defined_in_file
          UI.puts File.open(file_name).read
        end

        #--------------------------------------#

        # @return [Specification] the highest know specification of the given
        #         set.
        #
        def best_spec_from_set(set)
          sources = set.sources

          best_source = sources.first
          best_version = best_source.versions(set.name).first
          sources.each do |source|
            if source.versions(set.name).first > best_version
                best_source = source
                best_version = version
            end
          end

          best_spec = best_source.specification(set.name, best_version)
        end
      end

      #-----------------------------------------------------------------------#

      # TODO some of the following methods can probably move to one of the subclasses.

      private

      def podspecs_to_lint
        @podspecs_to_lint ||= begin
          files = []
          @podspecs_paths << '.' if @podspecs_paths.empty?
          @podspecs_paths.each do |path|
            if path =~ /https?:\/\//
              require 'open-uri'
              output_path = podspecs_tmp_dir + File.basename(path)
              output_path.dirname.mkpath
              open(path) do |io|
                output_path.open('w') { |f| f << io.read }
              end
              files << output_path
            else if (pathname = Pathname.new(path)).directory?
              files += Pathname.glob(pathname + '**/*.podspec')
              raise Informative, "No specs found in the current directory." if files.empty?
            else
              files << (pathname = Pathname.new(path))
              raise Informative, "Unable to find a spec named `#{path}'." unless pathname.exist? && path.include?('.podspec')
            end
          end
        end
          files
        end
      end

      def podspecs_tmp_dir
         Pathname.new('/tmp/CocoaPods/Lint_podspec')
      end

      #--------------------------------------#

      # Templates and github information retrieval for spec create

      # TODO  it would be nice to have a template class that accepts options and
      #       uses the default ones if not provided.

      # TODO  The template is outdated.

      def default_data_for_template(name)
        data = {}
        data[:name]          = name
        data[:version]       = '0.0.1'
        data[:summary]       = "A short description of #{name}."
        data[:homepage]      = "http://EXAMPLE/#{name}"
        data[:author_name]   = `git config --get user.name`.strip
        data[:author_email]  = `git config --get user.email`.strip
        data[:source_url]    = "http://EXAMPLE/#{name}.git"
        data[:ref_type]      = ':tag'
        data[:ref]           = '0.0.1'
        data
      end

      def github_data_for_template(repo_id)
        repo = Octokit.repo(repo_id)
        user = Octokit.user(repo['owner']['login'])
        data = {}

        data[:name]          = repo['name']
        data[:summary]       = (repo['description'] || '').gsub(/["]/, '\"')
        data[:homepage]      = (repo['homepage'] && !repo['homepage'].empty? ) ? repo['homepage'] : repo['html_url']
        data[:author_name]   = user['name']  || user['login']
        data[:author_email]  = user['email'] || 'email@address.com'
        data[:source_url]    = repo['clone_url']

        data.merge suggested_ref_and_version(repo)
      end

      def suggested_ref_and_version(repo)
        tags = Octokit.tags(:username => repo['owner']['login'], :repo => repo['name']).map {|tag| tag["name"]}
        versions_tags = {}
        tags.each do |tag|
          clean_tag = tag.gsub(/^v(er)? ?/,'')
          versions_tags[Gem::Version.new(clean_tag)] = tag if Gem::Version.correct?(clean_tag)
        end
        version = versions_tags.keys.sort.last || '0.0.1'
        data = {:version => version}
        if version == '0.0.1'
          branches        = Octokit.branches(:username => repo['owner']['login'], :repo => repo['name'])
          master_name     = repo['master_branch'] || 'master'
          master          = branches.select {|branch| branch['name'] == master_name }.first
          data[:ref_type] = ':commit'
          data[:ref]      = master['commit']['sha']
        else
          data[:ref_type] = ':tag'
          data[:ref]      = versions_tags[version]
        end
        data
      end

      def spec_template(data)
        return <<-SPEC
#
# Be sure to run `pod spec lint #{data[:name]}.podspec' to ensure this is a
# valid spec.
#
# Remove all comments before submitting the spec. Optional attributes are commented.
#
# For details see: https://github.com/CocoaPods/CocoaPods/wiki/The-podspec-format
#
Pod::Spec.new do |s|
  s.name         = "#{data[:name]}"
  s.version      = "#{data[:version]}"
  s.summary      = "#{data[:summary]}"
  # s.description  = <<-DESC
  #                   An optional longer description of #{data[:name]}
  #
  #                   * Markdown format.
  #                   * Don't worry about the indent, we strip it!
  #                  DESC
  s.homepage     = "#{data[:homepage]}"

  # Specify the license type. CocoaPods detects automatically the license file if it is named
  # `LICEN{C,S}E*.*', however if the name is different, specify it.
  s.license      = 'MIT (example)'
  # s.license      = { :type => 'MIT (example)', :file => 'FILE_LICENSE' }
  #
  # Only if no dedicated file is available include the full text of the license.
  #
  # s.license      = {
  #   :type => 'MIT (example)',
  #   :text => <<-LICENSE
  #             Copyright (C) <year> <copyright holders>

  #             All rights reserved.

  #             Redistribution and use in source and binary forms, with or without
  #             ...
  #   LICENSE
  # }

  # Specify the authors of the library, with email addresses. You can often find
  # the email addresses of the authors by using the SCM log. E.g. $ git log
  #
  s.author       = { "#{data[:author_name]}" => "#{data[:author_email]}" }
  # s.authors      = { "#{data[:author_name]}" => "#{data[:author_email]}", "other author" => "and email address" }
  #
  # If absolutely no email addresses are available, then you can use this form instead.
  #
  # s.author       = '#{data[:author_name]}', 'other author'

  # Specify the location from where the source should be retrieved.
  #
  s.source       = { :git => "#{data[:source_url]}", #{data[:ref_type]} => "#{data[:ref]}" }
  # s.source       = { :svn => 'http://EXAMPLE/#{data[:name]}/tags/1.0.0' }
  # s.source       = { :hg  => 'http://EXAMPLE/#{data[:name]}', :revision => '1.0.0' }

  # If this Pod runs only on iOS or OS X, then specify the platform and
  # the deployment target.
  #
  # s.platform     = :ios, '5.0'
  # s.platform     = :ios

  # ――― MULTI-PLATFORM VALUES ――――――――――――――――――――――――――――――――――――――――――――――――― #

  # If this Pod runs on both platforms, then specify the deployment
  # targets.
  #
  # s.ios.deployment_target = '5.0'
  # s.osx.deployment_target = '10.7'

  # A list of file patterns which select the source files that should be
  # added to the Pods project. If the pattern is a directory then the
  # path will automatically have '*.{h,m,mm,c,cpp}' appended.
  #
  # Alternatively, you can use the FileList class for even more control
  # over the selected files.
  # (See http://rake.rubyforge.org/classes/Rake/FileList.html.)
  #
  s.source_files = 'Classes', 'Classes/**/*.{h,m}'

  # A list of file patterns which select the header files that should be
  # made available to the application. If the pattern is a directory then the
  # path will automatically have '*.h' appended.
  #
  # Also allows the use of the FileList class like `source_files' does.
  #
  # If you do not explicitly set the list of public header files,
  # all headers of source_files will be made public.
  #
  # s.public_header_files = 'Classes/**/*.h'

  # A list of resources included with the Pod. These are copied into the
  # target bundle with a build phase script.
  #
  # Also allows the use of the FileList class like `source_files' does.
  #
  # s.resource  = "icon.png"
  # s.resources = "Resources/*.png"

  # A list of paths to preserve after installing the Pod.
  # CocoaPods cleans by default any file that is not used.
  # Please don't include documentation, example, and test files.
  # Also allows the use of the FileList class like `source_files' does.
  #
  # s.preserve_paths = "FilesToSave", "MoreFilesToSave"

  # Specify a list of frameworks that the application needs to link
  # against for this Pod to work.
  #
  # s.framework  = 'SomeFramework'
  # s.frameworks = 'SomeFramework', 'AnotherFramework'

  # Specify a list of libraries that the application needs to link
  # against for this Pod to work.
  #
  # s.library   = 'iconv'
  # s.libraries = 'iconv', 'xml2'

  # If this Pod uses ARC, specify it like so.
  #
  # s.requires_arc = true

  # If you need to specify any other build settings, add them to the
  # xcconfig hash.
  #
  # s.xcconfig = { 'HEADER_SEARCH_PATHS' => '$(SDKROOT)/usr/include/libxml2' }

  # Finally, specify any Pods that this Pod depends on.
  #
  # s.dependency 'JSONKit', '~> 1.4'
end
      SPEC
    end

      def semantic_versioning_notice(repo_id, repo)
        return <<-EOS

#{'――― MARKDOWN TEMPLATE ―――――――――――――――――――――――――――――――――――――――――――――――――――――――――――'.reversed}

I’ve recently added [#{repo}](https://github.com/CocoaPods/Specs/tree/master/#{repo}) to the [CocoaPods](https://github.com/CocoaPods/CocoaPods) package manager repo.

CocoaPods is a tool for managing dependencies for OSX and iOS Xcode projects and provides a central repository for iOS/OSX libraries. This makes adding libraries to a project and updating them extremely easy and it will help users to resolve dependencies of the libraries they use.

However, #{repo} doesn't have any version tags. I’ve added the current HEAD as version 0.0.1, but a version tag will make dependency resolution much easier.

[Semantic version](http://semver.org) tags (instead of plain commit hashes/revisions) allow for [resolution of cross-dependencies](https://github.com/CocoaPods/Specs/wiki/Cross-dependencies-resolution-example).

In case you didn’t know this yet; you can tag the current HEAD as, for instance, version 1.0.0, like so:

```
$ git tag -a 1.0.0 -m "Tag release 1.0.0"
$ git push --tags
```

#{'――― TEMPLATE END ――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――'.reversed}

#{'[!] This repo does not appear to have semantic version tags.'.yellow}

After commiting the specification, consider opening a ticket with the template displayed above:
  - link:  https://github.com/#{repo_id}/issues/new
  - title: Please add semantic version tags
        EOS
      end
    end
  end
end
