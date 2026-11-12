#!/usr/bin/env ruby
# Ad Hoc prototypes (scripts/agent/prototype.py) do not carry the App Clip (#133): a prototype slot has no App Clip App ID,
# and an App Clip ID can only be registered on the Developer portal. In the disposable prototype checkout this drops the
# app's dependency on StruisClip, the "Embed App Clips" phase and the associated App Clip entitlement. The target stays.
require 'xcodeproj'

root = ARGV.fetch(0) { File.expand_path('../..', __dir__) }
project = Xcodeproj::Project.open(File.join(root, 'strius.xcodeproj'))
app = project.targets.find { |t| t.name == 'strius' } or abort('app target not found')
clip = project.targets.find { |t| t.name == 'StruisClip' }
if clip
  app.dependencies.to_a.each do |dependency|
    next unless dependency.target == clip
    dependency.target_proxy&.remove_from_project
    dependency.remove_from_project
  end
  app.copy_files_build_phases.select { |phase| phase.name == 'Embed App Clips' }.each do |phase|
    phase.files.to_a.each(&:remove_from_project)
    phase.remove_from_project
  end
  project.save
end

entitlements = File.join(root, 'NativeRuntime/Runtime.entitlements')
text = File.read(entitlements)
stripped = text.sub(%r{\t<key>com\.apple\.developer\.associated-appclip-app-identifiers</key>\n\t<array>\n.*?\t</array>\n}m, '')
File.write(entitlements, stripped) unless stripped == text
