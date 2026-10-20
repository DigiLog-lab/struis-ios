#!/usr/bin/env ruby
require 'xcodeproj'
root = File.expand_path('..', __dir__)
project = Xcodeproj::Project.open(File.join(root, 'strius.xcodeproj'))
# Legacy iSH resources are excluded from this standalone source tree.
project.files.to_a.each do |ref|
  next unless ref.real_path.to_s.start_with?(File.join(root, 'Runtime') + '/')
  project.objects.grep(Xcodeproj::Project::Object::PBXBuildFile).to_a.each do |build|
    build.remove_from_project if build.file_ref == ref
  end
  ref.remove_from_project
end
group = project.main_group.find_subpath('TestResources', true)
unit = project.targets.find { |t| t.name == 'striusTests' }
ui = project.targets.find { |t| t.name == 'striusUITests' }
resources = [
  ['striusTests/Fixtures/engine-vectors', 'folder', unit, true],
  ['striusTests/Fixtures/learning-feed', 'folder', unit, true],
  ['striusTests/Fixtures/math', 'folder', unit, true],
  ['striusUITests/Fixtures/handwritten_eigenvalue.jpeg', 'image.jpeg', ui, true],
  ['striusTests/Fixtures/DeliveredScripts/struis_tutor_memory.py', 'text.script.python', unit, false],
  ['striusTests/Fixtures/DeliveredScripts/struis_reply_lint.py', 'text.script.python', unit, false],
  ['NativeRuntime/VirtualPythonTestAssets', 'folder', unit, false],
  ['NativeRuntime/VirtualPythonGitTestAssets', 'folder', unit, false],
  ['NativeRuntime/ThreadedPythonFoundationTestAssets', 'folder', unit, false],
  ['NativeRuntime/threaded-foundation-policy.json', 'text.json', unit, true],
  ['NativeRuntime/ThreadedPythonCommandTestOverlay', 'folder', unit, true],
]
# Replace only the resource group managed by this script, including the former
# monorepo entries. Preserve all other groups and resource membership.
def resource_available?(root, path)
  full = File.join(root, path)
  return false unless File.exist?(full)
  if ['NativeRuntime/VirtualPythonTestAssets', 'NativeRuntime/VirtualPythonGitTestAssets'].include?(path)
    return false if (Dir.children(full) - ['.gitkeep']).empty?
    raise "Incomplete generated bundle: #{path}" unless File.file?(File.join(full, 'manifest.json'))
  end
  true
end
present_paths = resources.select { |path, _type, _target, _required| resource_available?(root, path) }.map(&:first)
group.files.to_a.each do |ref|
  next if present_paths.include?(ref.path)
  project.targets.each do |target|
    target.resources_build_phase.files.to_a.each { |build| build.remove_from_project if build.file_ref == ref }
  end
  ref.remove_from_project
end
resources.each do |path, type, target, required|
  unless resource_available?(root, path)
    raise "Missing required test resource: #{path}" if required
    puts "SKIP optional resource: #{path}"
    next
  end
  ref = group.files.find { |file| file.path == path } || group.new_file(path)
  ref.source_tree = 'SOURCE_ROOT'
  ref.last_known_file_type = type
  matches = target.resources_build_phase.files.select { |build| build.file_ref == ref }
  matches.drop(1).each(&:remove_from_project)
  target.resources_build_phase.add_file_reference(ref, true) if matches.empty?
end
config_group = project.main_group.find_subpath('Config', true)
config_ref = config_group.files.find { |f| f.path == 'Config/Build.xcconfig' } || config_group.new_file('Config/Build.xcconfig')
config_ref.source_tree = 'SOURCE_ROOT'
project.targets.find { |t| t.name == 'strius' }.build_configurations.each { |config| config.base_configuration_reference = config_ref }
# Match the existing GitHub unit-test command, only for Cloud's test build.
# Release archives keep the application's existing authentication setting.
cloud_test = ENV['CI_XCODE_CLOUD'] == 'TRUE' && (
  ['StruisPRGate', 'StruisRelease'].include?(ENV['CI_XCODE_SCHEME']) ||
  ['PR Gate', 'Release'].include?(ENV['CI_WORKFLOW'])
)
if cloud_test
  debug = project.targets.find { |t| t.name == 'strius' }.build_configurations.find { |c| c.name == 'Debug' }
  raise 'Missing strius Debug configuration' unless debug
  debug.build_settings['STRUIS_AUTH_REQUIRED'] = 'YES'
  debug.build_settings['ARCHS'] = 'arm64'
end
project.save
puts 'Standalone test resources registered'
