#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'pathname'
require 'xcodeproj'

ROOT = File.expand_path(__dir__)
PROJECT_PATH = File.join(ROOT, 'ObsidianVocabImporter.xcodeproj')
SOURCE_DIR = File.join(ROOT, 'ObsidianVocabImporter')

FileUtils.rm_rf(PROJECT_PATH)

project = Xcodeproj::Project.new(PROJECT_PATH)

# Create target (macOS app).
# Platform symbol in xcodeproj is :osx.
target = project.new_target(:application, 'ObsidianVocabImporter', :osx, '13.0')

# Groups
main_group = project.main_group
app_group = main_group.new_group('ObsidianVocabImporter', 'ObsidianVocabImporter')

# Files
swift_files = Dir.glob(File.join(SOURCE_DIR, '**', '*.swift')).sort
asset_catalogs = Dir.glob(File.join(SOURCE_DIR, '**', '*.xcassets')).sort

swift_refs = swift_files.map do |p|
  rel = Pathname(p).relative_path_from(Pathname(SOURCE_DIR)).to_s
  app_group.new_file(rel)
end
asset_refs = asset_catalogs.map do |p|
  rel = Pathname(p).relative_path_from(Pathname(SOURCE_DIR)).to_s
  app_group.new_file(rel)
end

# Add build phases
# - Swift sources
# - Asset catalog as resources
swift_refs.each { |ref| target.add_file_references([ref]) }
asset_refs.each { |ref| target.resources_build_phase.add_file_reference(ref) }

# Build settings
info_plist_rel = 'ObsidianVocabImporter/Info.plist'

project.build_configurations.each do |config|
  config.build_settings['MACOSX_DEPLOYMENT_TARGET'] = '13.0'
  config.build_settings['SWIFT_VERSION'] = '5.9'
end

target.build_configurations.each do |config|
  config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.wenjiegu.obsidian-vocab-importer'
  config.build_settings['PRODUCT_NAME'] = 'Obsidian Vocab Importer'
  config.build_settings['MARKETING_VERSION'] = '1.0'
  config.build_settings['CURRENT_PROJECT_VERSION'] = '1'

  config.build_settings['INFOPLIST_FILE'] = info_plist_rel
  config.build_settings['ASSETCATALOG_COMPILER_APPICON_NAME'] = 'AppIcon'

  config.build_settings['CODE_SIGN_STYLE'] = 'Automatic'
  config.build_settings['DEVELOPMENT_TEAM'] = ''

  # Keep builds deterministic across machines.
  config.build_settings['SWIFT_VERSION'] = '5.9'
  config.build_settings['MACOSX_DEPLOYMENT_TARGET'] = '13.0'
end

# Scheme (shared)
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(target)
scheme.set_launch_target(target)
scheme.save_as(PROJECT_PATH, target.name, true)

project.save
