#!/usr/bin/env ruby
require 'xcodeproj'
require 'pathname'
root = File.expand_path('..', __dir__)
project = Xcodeproj::Project.open(File.join(root, 'strius.xcodeproj'))
app = project.targets.find { |t| t.name == 'strius' }
# Two extensions from the same worker code: StruisRuntime runs Codex, StruisExec runs Python and shell
# for Codex's tool calls. Each extension process has its own memory limit on a device.
# Bundle ID は本体の STRUIS_BUNDLE_ID_BASE から導く(dbd38e3: プロトタイプ配信は preview.sNN の ID に切り替える)。
# 固定の文字列を書くと、再同期のたびに切り替えが外れて Ad Hoc の profile と合わなくなる(2026-10-18 の Prototype #4 b)。
WORKERS = { 'StruisRuntime' => ['$(STRUIS_BUNDLE_ID_BASE).runtime', 'Struis Runtime'], 'StruisExec' => ['$(STRUIS_BUNDLE_ID_BASE).exec', 'Struis Exec'] }
workers = WORKERS.keys.map do |name|
  project.targets.find { |t| t.name == name } || project.new_target(:app_extension, name, :ios, '26.4').tap do |t|
    t.product_type = 'com.apple.product-type.extensionkit-extension'
  end
end
native = project.main_group.find_subpath('NativeRuntime', true)
native.path = 'NativeRuntime'

def reference(group, path)
  group.files.find { |f| f.path == path } || group.new_file(path)
end
# The host runs Codex in its own process from a dynamic framework that also
# exports the trusted workspace operations. Commands (Python, shell) remain in
# the Exec worker.
app_native = 'Vendor/NativeCodexHost.xcframework'
app.frameworks_build_phase.files.to_a.each do |file|
  path = file.file_ref&.path.to_s
  next unless path.start_with?('Vendor/')
  file.remove_from_project unless path == app_native
end
operations = reference(native, app_native)
matching = app.frameworks_build_phase.files.select { |file| file.file_ref == operations }
matching.drop(1).each(&:remove_from_project)
app.frameworks_build_phase.add_file_reference(operations, true) unless app.frameworks_build_phase.files.any? { |file| file.file_ref == operations }
host_embed = app.copy_files_build_phases.find { |p| p.name == 'Embed Native Frameworks' } || app.new_copy_files_build_phase('Embed Native Frameworks')
host_embed.dst_subfolder_spec = '10'
host_build = host_embed.files.find { |file| file.file_ref == operations } || host_embed.add_file_reference(operations, true)
host_build.settings = { 'ATTRIBUTES' => ['CodeSignOnCopy', 'RemoveHeadersOnCopy'] }
host_ca = reference(native, 'Resources/cacert.pem')
app.resources_build_phase.add_file_reference(host_ca, true) unless app.resources_build_phase.files.any? { |file| file.file_ref == host_ca }
notices = reference(native, 'Licenses')
notices.last_known_file_type = 'folder'
matching = app.resources_build_phase.files.select { |file| file.file_ref == notices }
matching.drop(1).each(&:remove_from_project)
app.resources_build_phase.add_file_reference(notices, true) unless app.resources_build_phase.files.any? { |file| file.file_ref == notices }
# striusTests is a filesystem-synchronized group, so its broker test is discovered automatically.
# OS-only telemetry is shared by host and workers without moving either runtime.
host_memory = reference(native, 'Worker/NativeMemory.m')
matching = app.source_build_phase.files.select { |file| file.file_ref == host_memory }
matching.drop(1).each(&:remove_from_project)
app.source_build_phase.add_file_reference(host_memory, true) if matching.empty?
shared = reference(native, 'Shared/RuntimeProtocol.swift')
app.source_build_phase.add_file_reference(shared, true)
# Remove previous shared build entries before applying explicit role ownership.
# Re-running this script must not retain dependencies from the former combined worker.
WORKER_SOURCES = {
  'StruisRuntime' => %w[RuntimeWorker.swift WorkerSupport.m NativeMemory.m AudioDuration.m],
  'StruisExec' => %w[RuntimeWorker.swift WorkerSupport.m NativeMemory.m RuntimeCommand.m PythonCommand.m GraphicsModule.m SearchCommand.m VirtualPythonCommandBridge.c VirtualPythonCommandBridgeAppleProbe.c VirtualPythonProviderAdapter.m]
}
WORKER_FRAMEWORKS = {
  'StruisRuntime' => %w[NativeCodex],
  'StruisExec' => %w[NativeSearch ios_system-native files-native text-native shell-native awk-native dash-native Python]
}
workers.each do |worker|
  source_paths = WORKER_SOURCES.fetch(worker.name).map { |name| "Worker/#{name}" } + ['Shared/RuntimeProtocol.swift']
  if worker.name == 'StruisExec'
    source_paths += ['Worker/CompoundDashPreparation.m', 'DashPipelinePreparation/TrustedPipeline.c']
  end
  seen_sources = []
  worker.source_build_phase.files.to_a.each do |file|
    path = file.file_ref&.path.to_s
    next unless path.start_with?('Worker/') || path.start_with?('DashPipelinePreparation/') || path == 'Shared/RuntimeProtocol.swift'
    if !source_paths.include?(path) || seen_sources.include?(path)
      file.remove_from_project
    else
      seen_sources << path
    end
  end
  framework_paths = WORKER_FRAMEWORKS.fetch(worker.name).map { |name| "Vendor/#{name}.xcframework" }
  seen_frameworks = []
  worker.frameworks_build_phase.files.to_a.each do |file|
    path = file.file_ref&.path.to_s
    next unless path.start_with?('Vendor/')
    if !framework_paths.include?(path) || seen_frameworks.include?(path)
      file.remove_from_project
    else
      seen_frameworks << path
    end
  end
  worker.source_build_phase.add_file_reference(shared, true) unless worker.source_build_phase.files.any? { |file| file.file_ref == shared }
  WORKER_SOURCES.fetch(worker.name).each do |name|
    ref = reference(native, "Worker/#{name}")
    worker.source_build_phase.add_file_reference(ref, true) unless worker.source_build_phase.files.any? { |file| file.file_ref == ref }
  end
  if worker.name == 'StruisExec'
    ['Worker/CompoundDashPreparation.m', 'DashPipelinePreparation/TrustedPipeline.c'].each do |path|
      ref = reference(native, path)
      worker.source_build_phase.add_file_reference(ref, true) unless worker.source_build_phase.files.any? { |file| file.file_ref == ref }
    end
  end
  %w[Resources/cacert.pem Resources/commandDictionary.plist Licenses].each do |path|
    ref = reference(native, path)
    if path == 'Resources/commandDictionary.plist' && worker.name == 'StruisRuntime'
      worker.resources_build_phase.files.to_a.each { |file| file.remove_from_project if file.file_ref == ref }
      next
    end
    matching = worker.resources_build_phase.files.select { |file| file.file_ref == ref }
    matching.drop(1).each(&:remove_from_project)
    ref.last_known_file_type = 'folder' if File.directory?(File.join(root, 'NativeRuntime', path))
    worker.resources_build_phase.add_file_reference(ref, true) unless worker.resources_build_phase.files.any? { |file| file.file_ref == ref }
  end
  python_modules = reference(native, 'PythonModules')
  python_modules.last_known_file_type = 'folder'
  worker.resources_build_phase.files.to_a.each { |f| f.remove_from_project if f.file_ref == python_modules }
  app.resources_build_phase.add_file_reference(python_modules, true)
  WORKER_FRAMEWORKS.fetch(worker.name).each do |name|
    ref = reference(native, "Vendor/#{name}.xcframework")
    worker.frameworks_build_phase.add_file_reference(ref, true) unless worker.frameworks_build_phase.files.any? { |file| file.file_ref == ref }
    unless %w[NativeCodex NativeSearch].include?(name)
      phase = app.copy_files_build_phases.find { |p| p.name == 'Embed Native Frameworks' } || app.new_copy_files_build_phase('Embed Native Frameworks')
      phase.dst_subfolder_spec = '10'
      build = phase.files.find { |file| file.file_ref == ref } || phase.add_file_reference(ref, true)
      build.settings = { 'ATTRIBUTES' => ['CodeSignOnCopy', 'RemoveHeadersOnCopy'] }
    end
  end
app.add_dependency(worker) unless app.dependencies.any? { |d| d.target == worker }
embed = app.copy_files_build_phases.find { |p| p.name == 'Embed Runtime Extension' } || app.new_copy_files_build_phase('Embed Runtime Extension')
embed.dst_subfolder_spec = '1'; embed.dst_path = 'Extensions'
embed.add_file_reference(worker.product_reference, true).settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] } unless embed.files.any? { |f| f.file_ref == worker.product_reference }
bundle_id, display_name = WORKERS[worker.name]
worker.build_configurations.each do |config|
  # CI's dedicated preparation script enables this only after verifying its
  # generated Simulator inputs. A normal regeneration removes stale opt-ins.
  config.build_settings.delete('GCC_PREPROCESSOR_DEFINITIONS[sdk=iphonesimulator*]')
  host_settings = app.build_configurations.find { |c| c.name == config.name }.build_settings
  %w[DEVELOPMENT_TEAM CODE_SIGN_STYLE].each { |key| config.build_settings[key] = host_settings[key] if host_settings[key] }
  config.build_settings['DEBUG_INFORMATION_FORMAT'] = config.name == 'Debug' ? 'dwarf' : 'dwarf-with-dsym'
  config.build_settings.merge!({
    'PRODUCT_NAME'=>'$(TARGET_NAME)', 'MACH_O_TYPE'=>'mh_execute', 'PRODUCT_BUNDLE_IDENTIFIER'=>bundle_id, 'SWIFT_VERSION'=>'5.0',
    'SWIFT_DEFAULT_ACTOR_ISOLATION'=>'nonisolated', 'IPHONEOS_DEPLOYMENT_TARGET'=>'26.4',
    'INFOPLIST_KEY_CFBundleDisplayName'=>display_name, 'GENERATE_INFOPLIST_FILE'=>'YES', 'INFOPLIST_FILE'=>'NativeRuntime/Worker/Info.plist',
    'EX_ENABLE_EXTENSION_POINT_GENERATION'=>'YES', 'ENABLE_DEBUG_DYLIB'=>'NO',
    'SKIP_INSTALL'=>'YES', 'ENABLE_USER_SCRIPT_SANDBOXING'=>'NO',
    'CODE_SIGN_ENTITLEMENTS'=>'NativeRuntime/Worker/RuntimeWorker.entitlements',
    'ENABLE_ENHANCED_SECURITY'=>'YES',
    # Prebuilt CPython/Rust dependencies provide arm64, not an arm64e slice.
    # The extension point does not request EnhancedSecurity: that sandbox denies the app group.
    'ENABLE_POINTER_AUTHENTICATION'=>'NO', 'LD_GENERATE_MAP_FILE'=>'YES',
    'SWIFT_OBJC_BRIDGING_HEADER'=>"NativeRuntime/Worker/#{worker.name == 'StruisRuntime' ? 'Codex' : 'Exec'}-Bridging-Header.h",
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS'=>['$(inherited)', (config.name == 'Debug' ? 'DEBUG' : nil), (worker.name == 'StruisRuntime' ? 'STRUIS_CODEX_WORKER' : 'STRUIS_EXEC_WORKER')].compact,
    'GCC_PREPROCESSOR_DEFINITIONS'=>['$(inherited)', (config.name == 'Debug' ? 'DEBUG=1' : nil), (worker.name == 'StruisRuntime' ? 'STRUIS_CODEX_WORKER=1' : 'STRUIS_EXEC_WORKER=1')].compact,
    'OTHER_LDFLAGS'=>['$(inherited)', '-Wl,-export_dynamic','-lc++','-liconv','-lz','-lresolv','-framework','UIKit','-framework','AVFoundation','-framework','Security','-framework','SystemConfiguration'],
    'LD_RUNPATH_SEARCH_PATHS'=>['$(inherited)','@executable_path/Frameworks','@executable_path/../../Frameworks'],
    'TARGETED_DEVICE_FAMILY'=>'1,2', 'CURRENT_PROJECT_VERSION'=>app.build_configurations.first.build_settings['CURRENT_PROJECT_VERSION'], 'MARKETING_VERSION'=>app.build_configurations.first.build_settings['MARKETING_VERSION']
  })
end
worker.shell_script_build_phases.select { |p| p.name == 'Package Python' }.each(&:remove_from_project)
end
package = app.shell_script_build_phases.find { |p| p.name == 'Package Python' } || app.new_shell_script_build_phase('Package Python')
package.shell_path = '/bin/bash'
package.shell_script = <<~SH
set -eu
cd "$SRCROOT/NativeRuntime"
export EXPANDED_CODE_SIGN_IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
export EXPANDED_CODE_SIGN_IDENTITY_NAME="${EXPANDED_CODE_SIGN_IDENTITY_NAME:-Ad Hoc}"
source "$PWD/Vendor/Python.xcframework/build/utils.sh"
test -d "$PWD/PythonPackages/$PLATFORM_NAME" || { echo "Run NativeRuntime/Scripts/prepare-python.py --platform $PLATFORM_NAME first"; exit 1; }
mkdir -p "$CODESIGNING_FOLDER_PATH/PythonPackages"
rsync -a --delete "$PWD/PythonPackages/$PLATFORM_NAME/" "$CODESIGNING_FOLDER_PATH/PythonPackages/"
install_python NativeRuntime/Vendor/Python.xcframework PythonModules PythonPackages
# Wheels include static development libraries that are not runtime payload.
find "$CODESIGNING_FOLDER_PATH/PythonPackages" -type f -name '*.a' -delete
/usr/bin/python3 "$PWD/Scripts/fix-framework-minimum-os.py" "$CODESIGNING_FOLDER_PATH/Frameworks"
/usr/bin/python3 "$SRCROOT/scripts/package_compound_dash_preparation.py"
# Avoid source-parser allocations when importing large packages on a device.
python_compiler="$(command -v python3.14 || true)"
if [ -z "$python_compiler" ]; then python_compiler="$(brew --prefix python@3.14)/bin/python3.14"; fi
"$python_compiler" "$PWD/Scripts/compile-python.py" "$CODESIGNING_FOLDER_PATH"
SH
package.always_out_of_date = '1'
app.build_configurations.each do |config|
  config.build_settings['LD_GENERATE_MAP_FILE'] = 'YES'
  config.build_settings['ENABLE_USER_SCRIPT_SANDBOXING'] = 'NO'
  config.build_settings['EX_ENABLE_EXTENSION_POINT_GENERATION'] = 'YES'
  config.build_settings['CODE_SIGN_ENTITLEMENTS'] = 'NativeRuntime/Runtime.entitlements'
  config.build_settings['OTHER_LDFLAGS'] = ['$(inherited)', '-lsqlite3', '-lz']
  config.build_settings['HEADER_SEARCH_PATHS'] = '$(inherited)'
  config.build_settings.delete('LIBRARY_SEARCH_PATHS[sdk=iphoneos*]')
  config.build_settings.delete('LIBRARY_SEARCH_PATHS[sdk=iphonesimulator*]')
end
app.resources_build_phase.files.to_a.each do |f|
  f.remove_from_project if f.file_ref && f.file_ref.path.to_s.match?(/rootfs-(manifest|v\d+)/)
end
project.save
