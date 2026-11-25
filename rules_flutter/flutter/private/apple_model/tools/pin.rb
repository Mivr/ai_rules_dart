# frozen_string_literal: true

# Spike T17a (S9): the Apple pin step. Not for merge.
#
#   ruby pin.rb <app>/ios <out.json>
#
# Runs CocoaPods' own installer on the app's Podfile (resolve, download, generate
# the Pods project, run the Podfile's post_install hooks) and writes what CocoaPods
# computed as one JSON file: per pod target its source, the files CocoaPods'
# file accessors matched, headers with their mapped include paths, resources,
# binary frameworks with their slices, build settings and dependencies; per
# aggregate target what the app links and embeds. Nothing here reads a podspec or
# a Podfile.lock as text: every value comes from a CocoaPods object.
#
# Environment: PUB_CACHE (named root `pub:`), FLUTTER_ROOT (`flutter:`),
# RDF_PIN_CACHE (archives hashed once per URL), RDF_PIN_PATTERNS=1 (also write the
# podspec's glob patterns, to compare sizes).

require 'cocoapods'
require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'yaml'

SCHEMA = 1

ios_dir = Pathname(ARGV.fetch(0)).realpath
out_path = File.expand_path(ARGV.fetch(1))
app_dir = ios_dir.parent
pin_cache = Pathname(ENV['RDF_PIN_CACHE'] || File.join(Dir.home, '.rdf-pin-cache'))
FileUtils.mkdir_p(pin_cache)

ROOTS = [
  ['pods', (ios_dir + 'Pods').to_s],
  ['app', app_dir.to_s],
  ['pub', ENV['PUB_CACHE'] && File.realpath(ENV['PUB_CACHE'])],
  ['flutter', ENV['FLUTTER_ROOT'] && File.realpath(ENV['FLUTTER_ROOT'])],
].select { |_, dir| dir }.freeze

# A path as `<root name>:<relative path>`; `abs:` marks a machine-dependent path.
def rooted(path)
  real = File.exist?(path.to_s) ? File.realpath(path.to_s) : path.to_s
  ROOTS.each do |name, dir|
    return "#{name}:" if real == dir
    return "#{name}:#{real[(dir.length + 1)..]}" if real.start_with?(dir + '/')
  end
  "abs:#{real}"
end

def sorted(value)
  case value
  when Hash then value.keys.map(&:to_s).sort.to_h { |k| [k, sorted(value[k] || value[k.to_sym])] }
  when Array then value.map { |v| sorted(v) }
  when Pathname, Symbol then sorted(value.to_s)
  when String then ROOTS.reduce(value) { |text, (name, dir)| text.gsub(dir + '/', "${RDF_ROOT:#{name}}/") }
  else value
  end
end

def run!(*cmd)
  out, status = Open3.capture2(*cmd)
  raise "#{cmd.join(' ')} failed" unless status.success?
  out
end

# sha256 and size of what a URL serves, downloaded once per URL into the pin cache.
def hashed_url(cache, url)
  memo = cache + "#{Digest::SHA1.hexdigest(url)}.json"
  return JSON.parse(memo.read) if memo.exist?
  tmp = cache + "#{Digest::SHA1.hexdigest(url)}.part"
  run!('curl', '-fsSL', '--retry', '3', '-o', tmp.to_s, url)
  result = { 'sha256' => Digest::SHA256.file(tmp).hexdigest, 'size' => tmp.size }
  tmp.delete
  memo.write(JSON.generate(result))
  result
end

TARBALLS = %i[tgz tar tbz txz].freeze

def http_type(source)
  return source[:type].to_sym if source[:type]
  case source[:http]
  when /\.zip$/ then :zip
  when /\.(tgz|tar\.gz)$/ then :tgz
  when /\.tar$/ then :tar
  when /\.(tbz|tar\.bz2)$/ then :tbz
  when /\.(txz|tar\.xz)$/ then :txz
  when /\.dmg$/ then :dmg
  end
end

# What Bazel has to fetch to get the tree CocoaPods' downloader produced.
def remote_source(cache, source)
  if source[:http]
    type = http_type(source)
    # cocoapods-downloader: a tarball is flattened unless the spec says no, a zip only when it says yes.
    flatten = source.key?(:flatten) ? source[:flatten] : TARBALLS.include?(type)
    { 'http' => source[:http], 'type' => type.to_s, 'flatten' => flatten ? true : false,
      'spec_sha256' => source[:sha256], 'spec_sha1' => source[:sha1] }.compact.merge(hashed_url(cache, source[:http]))
  elsif source[:git]
    commit = source[:commit]
    ref = source[:tag] || source[:branch]
    if commit.nil? && ref
      # A tag is resolved once and remembered, as CocoaPods' own download cache does per version.
      memo = cache + "#{Digest::SHA1.hexdigest("#{source[:git]} #{ref}")}.commit"
      unless memo.exist?
        listed = run!('git', 'ls-remote', source[:git], "refs/tags/#{ref}", "refs/tags/#{ref}^{}", "refs/heads/#{ref}")
        lines = listed.lines.map(&:split)
        peeled = lines.find { |_, name| name.end_with?('^{}') }
        memo.write((peeled || lines.first)&.first.to_s)
      end
      commit = memo.read.strip
      commit = nil if commit.empty?
    end
    raise "no commit for #{source}" unless commit
    result = { 'git' => source[:git], 'tag' => source[:tag]&.to_s, 'branch' => source[:branch]&.to_s,
               'commit' => commit, 'submodules' => source[:submodules] ? true : nil }.compact
    if (m = source[:git].match(%r{\Ahttps://github\.com/([^/]+)/([^/]+?)(\.git)?/?\z})) && !source[:submodules]
      url = "https://github.com/#{m[1]}/#{m[2]}/archive/#{commit}.tar.gz"
      result.merge!('archive' => url, 'strip_prefix' => "#{m[2]}-#{commit}").merge!(hashed_url(cache, url))
    end
    result
  else
    { 'unsupported' => source.keys.map(&:to_s).sort }
  end
end

# Settings per configuration name: what all share under "*", then what differs per name.
def settings_by_name(by_name)
  values = by_name.values
  return { '*' => values.first } if values.uniq.size <= 1
  return by_name unless values.all? { |v| v.is_a?(Hash) }
  common = values.first.select { |k, v| values.all? { |other| other.key?(k) && other[k] == v } }
  { '*' => common }.merge(by_name.transform_values { |v| v.reject { |k, _| common.key?(k) } })
end

# ---------------------------------------------------------------------------
# 1. CocoaPods installs, exactly as `pod install` does.

Dir.chdir(ios_dir)
config = Pod::Config.instance
Pod::UI.title_level = 0
config.silent = ENV['RDF_PIN_VERBOSE'].nil?
started = Time.now
installer = Pod::Installer.new(config.sandbox, config.podfile, config.lockfile)
installer.repo_update = false
installer.update = false
installer.install!
install_seconds = Time.now - started

sandbox = config.sandbox
lockfile = Pod::Lockfile.from_file(ios_dir + 'Podfile.lock')
project = installer.pods_project
project_targets = project ? project.targets.to_h { |t| [t.name, t] } : {}

# ---------------------------------------------------------------------------
# 2. Pub packages behind local pods (`:path` into the pub cache).

pub_lock = YAML.safe_load((app_dir + 'pubspec.lock').read)['packages']
plugins_file = app_dir + '.flutter-plugins-dependencies'
plugins = plugins_file.exist? ? JSON.parse(plugins_file.read).dig('plugins', 'ios') || [] : []
pub_packages = plugins.to_h do |plugin|
  locked = pub_lock.fetch(plugin['name'])
  description = locked['description']
  entry = { 'version' => locked['version'], 'source' => locked['source'], 'dir' => rooted(plugin['path']) }
  if locked['source'] == 'hosted'
    entry['sha256'] = description['sha256']
    entry['archive'] = "#{description['url']}/api/archives/#{description['name']}-#{locked['version']}.tar.gz"
  end
  [plugin['name'], entry]
end

# ---------------------------------------------------------------------------
# 3. One entry per pod target.

def target_settings(native_target)
  return nil unless native_target
  settings_by_name(native_target.build_configurations.to_h { |c| [c.name, sorted(c.build_settings)] })
end

pods = installer.pod_targets.sort_by(&:name).to_h do |pt|
  root = sandbox.pod_dir(pt.pod_name)
  local = sandbox.local?(pt.pod_name)
  rel = ->(path) { Pathname(path).relative_path_from(root).to_s }
  accessors = pt.file_accessors.select { |fa| fa.spec.library_specification? }
  consumers = accessors.map(&:spec_consumer)
  union = ->(&block) { accessors.flat_map(&block).uniq.map(&rel).sort }
  native = project_targets[pt.label]

  headers = union.call(&:headers)
  sources = union.call(&:source_files) - headers
  mapped = lambda do |by_accessor|
    by_accessor.select { |fa, _| accessors.include?(fa) }.values.flat_map do |mappings|
      mappings.flat_map { |dir, files| files.map { |file| [(dir + file.basename).to_s, rel.call(file)] } }
    end.sort.to_h
  end

  # Per-file compiler flags, as CocoaPods wrote them into the Pods project.
  flags = {}
  if native.respond_to?(:source_build_phase)
    native.source_build_phase.files.each do |build_file|
      value = build_file.settings && build_file.settings['COMPILER_FLAGS']
      next if value.nil? || value.empty? || build_file.file_ref.nil?
      path = build_file.file_ref.real_path
      (flags[value] ||= []) << rel.call(path) if path.to_s.start_with?(root.to_s + '/')
    end
  end

  xcframeworks = pt.xcframeworks.values.flatten.uniq(&:path).sort_by { |x| x.path.to_s }.map do |xc|
    { 'path' => rel.call(xc.path),
      'slices' => xc.slices.sort_by(&:identifier).map do |slice|
        { 'identifier' => slice.identifier, 'platform' => slice.platform.name.to_s,
          'variant' => slice.platform_variant&.to_s, 'archs' => slice.supported_archs.sort,
          'path' => rel.call(slice.path), 'binary' => rel.call(slice.binary_path),
          'package' => slice.package_type.to_s, 'linkage' => slice.build_type.linkage.to_s }.compact
      end }
  end

  bundles = accessors.flat_map { |fa| fa.resource_bundles.to_a }.group_by(&:first).sort.to_h do |name, pairs|
    files = pairs.flat_map(&:last).uniq.map(&rel).sort
    [name, { 'files' => files, 'settings' => target_settings(project_targets["#{pt.label}-#{name}"]) }.compact]
  end
  resources = union.call(&:resources)
  privacy = (resources + bundles.values.flat_map { |b| b['files'] }).select { |f| f.end_with?('.xcprivacy') }.uniq

  spec = pt.root_spec
  attribute = ->(name) { consumers.flat_map { |c| Array(c.send(name)) }.uniq }
  merged = ->(name) { consumers.map { |c| c.send(name) }.reduce({}) { |a, b| a.merge(b) { |_, x, y| x == y ? x : "#{x} #{y}" } } }

  source = if local
             { 'path' => rooted(root) }
           else
             remote_source(pin_cache, spec.source)
           end

  entry = {
    'version' => pt.version.to_s,
    'checksum' => lockfile.checksum(pt.pod_name),
    'source' => source,
    'specs' => pt.specs.map(&:name).sort,
    'subspecs' => { 'all' => spec.recursive_subspecs.reject(&:non_library_specification?).map(&:name).sort,
                    'default' => Array(spec.default_subspecs).map(&:to_s).sort },
    'platform' => { 'name' => pt.platform.name.to_s, 'deployment_target' => pt.platform.deployment_target.to_s },
    'build' => { 'should_build' => pt.should_build? ? true : false, 'linkage' => pt.build_as_dynamic? ? 'dynamic' : 'static',
                 'packaging' => pt.build_as_framework? ? 'framework' : 'library', 'static_framework' => spec.static_framework ? true : false,
                 'uses_swift' => pt.uses_swift? ? true : false, 'swift_version' => pt.uses_swift? ? pt.swift_version.to_s : nil,
                 'swift_versions' => spec.swift_versions.map(&:to_s), 'module_name' => pt.product_module_name,
                 'product_name' => pt.product_name, 'defines_module' => pt.defines_module? }.compact,
    'sources' => sources,
    'non_arc_sources' => union.call(&:non_arc_source_files),
    'compiler_flags_by_file' => flags.sort.to_h { |flag, files| [flag, files.sort] },
    'headers' => { 'all' => headers,
                   'public' => mapped.call(pt.public_header_mappings_by_file_accessor),
                   'mapped' => mapped.call(pt.header_mappings_by_file_accessor),
                   'private' => union.call(&:private_headers), 'project' => union.call(&:project_headers) },
    'header_dir' => attribute.call(:header_dir).first,
    'header_mappings_dir' => attribute.call(:header_mappings_dir).first,
    'module_map' => accessors.map(&:module_map).compact.map(&rel).first,
    'generated_module_map' => (pt.module_map_path.exist? && !pt.module_map_path.to_s.start_with?(root.to_s) ? pt.module_map_path.read : nil),
    'generated_umbrella_header' => (pt.umbrella_header_path.exist? ? pt.umbrella_header_path.read : nil),
    'prefix_header_contents' => attribute.call(:prefix_header_contents).join("\n").then { |s| s.empty? ? nil : s },
    'prefix_header_file' => union.call { |fa| Array(fa.prefix_header) }.first,
    'resources' => resources,
    'resource_bundles' => bundles,
    'privacy_manifests' => privacy,
    'vendored' => { 'xcframeworks' => xcframeworks,
                    'static_frameworks' => union.call(&:vendored_static_frameworks).reject { |f| f.end_with?('.xcframework') },
                    'dynamic_frameworks' => union.call(&:vendored_dynamic_frameworks).reject { |f| f.end_with?('.xcframework') },
                    'static_libraries' => union.call(&:vendored_static_libraries),
                    'dynamic_libraries' => union.call(&:vendored_dynamic_libraries) },
    'frameworks' => attribute.call(:frameworks).sort,
    'weak_frameworks' => attribute.call(:weak_frameworks).sort,
    'libraries' => attribute.call(:libraries).sort,
    'compiler_flags' => attribute.call(:compiler_flags),
    'requires_arc' => attribute.call(:requires_arc).map { |v| v.is_a?(Array) ? 'patterns' : v }.uniq,
    'pod_target_xcconfig' => sorted(merged.call(:pod_target_xcconfig)),
    'user_target_xcconfig' => sorted(merged.call(:user_target_xcconfig)),
    'xcconfig' => settings_by_name(pt.build_settings.to_h { |name, settings| [name.to_s, sorted(settings.xcconfig.to_hash)] }),
    'build_settings' => target_settings(native),
    'dependencies' => pt.dependent_targets.map(&:name).sort,
    'features' => {
      'prepare_command' => spec.prepare_command,
      'script_phases' => pt.script_phases.map { |phase| sorted(phase) },
      'on_demand_resources' => accessors.any? { |fa| !fa.on_demand_resources.empty? },
      'subspec_count' => spec.recursive_subspecs.count(&:library_specification?),
      'test_specs' => spec.recursive_subspecs.select(&:test_specification?).map(&:name).sort,
      'app_specs' => spec.recursive_subspecs.select(&:app_specification?).map(&:name).sort,
      'info_plist' => !merged.call(:info_plist).empty?,
      'deprecated' => spec.deprecated? || !spec.deprecated_in_favor_of.nil? ? true : false,
    },
  }
  if ENV['RDF_PIN_PATTERNS']
    entry['patterns'] = consumers.to_h do |c|
      [c.spec.name, sorted(%i[source_files public_header_files private_header_files project_header_files exclude_files
                              resources resource_bundles vendored_frameworks vendored_libraries preserve_paths]
                           .to_h { |name| [name, c.send(name)] }.reject { |_, v| v.empty? })]
    end
  end
  [pt.name, entry.compact]
end

# ---------------------------------------------------------------------------
# 4. What each user target (the app, its tests) links, embeds and copies.

aggregates = installer.aggregate_targets.sort_by(&:name).to_h do |at|
  configs = at.user_build_configurations.keys.sort
  by_config = lambda do |paths_by_config, &block|
    settings_by_name(configs.to_h { |c| [c, (paths_by_config[c] || []).map(&block).sort] })
  end
  [at.name, {
    'user_targets' => at.user_targets.map(&:name).sort,
    'platform' => { 'name' => at.platform.name.to_s, 'deployment_target' => at.platform.deployment_target.to_s },
    'linkage' => at.build_as_dynamic? ? 'dynamic' : 'static',
    'packaging' => at.build_as_framework? ? 'framework' : 'library',
    'pods' => settings_by_name(configs.to_h { |c| [c, at.pod_targets_for_build_configuration(c).map(&:name).sort] }),
    'xcconfig' => settings_by_name(configs.to_h { |c| [c, sorted(at.build_settings(c).xcconfig.to_hash)] }),
    'embed_frameworks' => by_config.call(at.framework_paths_by_config) { |p| p.source_path.to_s },
    'copy_resources' => settings_by_name(configs.to_h { |c| [c, (at.resource_paths_by_config[c] || []).sort] }),
    'build_settings' => target_settings(project_targets[at.label]),
  }]
end

model = {
  'schema' => SCHEMA,
  'tools' => { 'cocoapods' => Pod::VERSION },
  'podfile' => {
    'checksum' => lockfile.internal_data['PODFILE CHECKSUM'],
    'lock_sha256' => Digest::SHA256.file(ios_dir + 'Podfile.lock').hexdigest,
    'installation_options' => sorted(config.podfile.installation_options.to_h),
    'spec_repos' => sorted(lockfile.internal_data['SPEC REPOS'] || {}),
  },
  'pub_packages' => sorted(pub_packages),
  'pods' => pods,
  'aggregate_targets' => aggregates,
}

text = JSON.pretty_generate(sorted(model)) + "\n"
File.write(out_path, text)
warn format('rdf pin: %d pod targets, %d bytes, install %.1f s, total %.1f s',
            pods.size, text.bytesize, install_seconds, Time.now - started)
