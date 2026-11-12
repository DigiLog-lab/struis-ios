#!/usr/bin/env ruby
# The App Clip (#133): StruisClip opens a time attack link, solves the same five problems and sends a record back.
# It compiles its own sources (StruisClip/) plus a few of the app's files that it shares, and the app embeds it.
# Idempotent: run by scripts/sync_project.py after the native runtime sync.
require 'xcodeproj'

root = File.expand_path('..', __dir__)
project = Xcodeproj::Project.open(File.join(root, 'strius.xcodeproj'))
app = project.targets.find { |t| t.name == 'strius' } or abort('app target not found')

NAME = 'StruisClip'
PRODUCT_TYPE = 'com.apple.product-type.application.on-demand-install-capable'
# The app's files that the App Clip compiles too (the time attack, the terms version and age bands, the design system,
# the expression checker, App Attest).
SHARED = Dir.glob('strius/Features/TimeAttack/Shared/*.swift', base: root).sort + %w[
  strius/Features/Onboarding/LegalTerms.swift
  strius/Design/Theme.swift
  strius/Design/Typography.swift
  strius/Engine/TimelineExpression.swift
  strius/Runtime/Claude/AppAttestClient.swift
]
FONTS = %w[ZenKakuGothicNew-Regular.ttf ZenKakuGothicNew-Medium.ttf ZenKakuGothicNew-Bold.ttf].map { |f| "strius/Resources/Fonts/#{f}" }

clip = project.targets.find { |t| t.name == NAME } || project.new_target(:application, NAME, :ios, '26.4')
clip.product_type = PRODUCT_TYPE

def file_ref(project, root, relative)
  absolute = File.join(root, relative)
  project.files.find { |f| f.real_path.to_s == absolute } or abort("not in the project: #{relative} (run scripts/sync_project.py)")
end

def ensure_in(phase, ref)
  phase.files.find { |build| build.file_ref == ref } || phase.add_file_reference(ref, true)
end

# StruisClip/ group and its own files.
group = project.main_group.children.find { |g| g.respond_to?(:path) && g.path == NAME } || project.main_group.new_group(NAME, NAME)
own = Dir.glob('*', base: File.join(root, NAME)).sort
own.each do |name|
  ref = group.children.find { |c| c.path == name } || group.new_reference(name)
  case File.extname(name)
  when '.swift' then ensure_in(clip.source_build_phase, ref)
  when '.xcassets' then ensure_in(clip.resources_build_phase, ref)
  end
end
# Files removed from StruisClip/ leave the project.
group.children.to_a.each do |child|
  next if own.include?(child.path.to_s)
  child.build_files.to_a.each(&:remove_from_project)
  child.remove_from_project
end

SHARED.each { |relative| ensure_in(clip.source_build_phase, file_ref(project, root, relative)) }
FONTS.each { |relative| ensure_in(clip.resources_build_phase, file_ref(project, root, relative)) }
# Shared files dropped from SHARED leave the App Clip (only those under the app's tree; StruisClip/ is handled above).
shared_paths = SHARED.map { |relative| File.join(root, relative) }
clip.source_build_phase.files.to_a.each do |build|
  path = build.file_ref&.real_path.to_s
  next unless path.start_with?(File.join(root, 'strius') + '/')
  next if shared_paths.include?(path)
  build.file_ref.referrers.delete_if { |referrer| referrer.equal?(build) }
  project.objects_by_uuid.delete(build.uuid)
  Array.instance_method(:delete).bind(clip.source_build_phase.files).call(build)
end

# SwiftMath, from the package the app already uses.
math = project.root_object.package_references.find { |p| p.respond_to?(:repositoryURL) && p.repositoryURL.to_s.include?('SwiftMath') } or abort('SwiftMath package not found')
dependency = clip.package_product_dependencies.find { |d| d.product_name == 'SwiftMath' } || begin
  d = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  d.package = math
  d.product_name = 'SwiftMath'
  clip.package_product_dependencies << d
  d
end
unless clip.frameworks_build_phase.files.any? { |f| f.product_ref == dependency }
  build = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  build.product_ref = dependency
  clip.frameworks_build_phase.files << build
end

# Build settings: the app's signing, Swift mode and versions; the App Clip's own ID, Info.plist and entitlements.
app.build_configurations.each do |host|
  config = clip.build_configurations.find { |c| c.name == host.name } or next
  config.base_configuration_reference = host.base_configuration_reference
  settings = host.build_settings
  config.build_settings.merge!({
    'PRODUCT_NAME' => '$(TARGET_NAME)',
    'PRODUCT_BUNDLE_IDENTIFIER' => '$(STRUIS_BUNDLE_ID_BASE).Clip',
    'INFOPLIST_FILE' => "#{NAME}/Info.plist",
    'GENERATE_INFOPLIST_FILE' => 'NO',
    'CODE_SIGN_ENTITLEMENTS' => "#{NAME}/#{NAME}.entitlements",
    'CODE_SIGN_STYLE' => settings['CODE_SIGN_STYLE'],
    'DEVELOPMENT_TEAM' => settings['DEVELOPMENT_TEAM'],
    'CURRENT_PROJECT_VERSION' => settings['CURRENT_PROJECT_VERSION'],
    'MARKETING_VERSION' => settings['MARKETING_VERSION'],
    'IPHONEOS_DEPLOYMENT_TARGET' => settings['IPHONEOS_DEPLOYMENT_TARGET'],
    'SWIFT_VERSION' => settings['SWIFT_VERSION'],
    'SWIFT_DEFAULT_ACTOR_ISOLATION' => settings['SWIFT_DEFAULT_ACTOR_ISOLATION'],
    'SWIFT_APPROACHABLE_CONCURRENCY' => settings['SWIFT_APPROACHABLE_CONCURRENCY'],
    'SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY' => settings['SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY'],
    'ASSETCATALOG_COMPILER_APPICON_NAME' => 'AppIcon',
    'ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME' => 'AccentColor',
    'TARGETED_DEVICE_FAMILY' => '1,2',
    'SDKROOT' => 'iphoneos',
    'SUPPORTED_PLATFORMS' => 'iphoneos iphonesimulator',
    'SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD' => 'NO',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'x86_64',
    'LD_RUNPATH_SEARCH_PATHS' => ['$(inherited)', '@executable_path/Frameworks'],
    'ENABLE_PREVIEWS' => 'NO',
    'DEAD_CODE_STRIPPING' => 'YES',
  }.compact)
end

# The app builds and embeds the App Clip.
app.add_dependency(clip) unless app.dependencies.any? { |d| d.target == clip }
embed = app.copy_files_build_phases.find { |p| p.name == 'Embed App Clips' } || app.new_copy_files_build_phase('Embed App Clips')
embed.dst_subfolder_spec = '16'
embed.dst_path = '$(CONTENTS_FOLDER_PATH)/AppClips'
unless embed.files.any? { |f| f.file_ref == clip.product_reference }
  embed.add_file_reference(clip.product_reference, true).settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }
end

project.save
