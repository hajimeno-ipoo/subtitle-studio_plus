require 'xcodeproj'

project_path = 'SubtitleStudioPlus.xcodeproj'
project = Xcodeproj::Project.open(project_path)

target = project.targets.find { |t| t.name == 'SubtitleStudioPlus' }

# Find or create the package dependency
package_name = 'DSWaveformImage'
repo_url = 'https://github.com/dmrschmidt/DSWaveformImage.git'

# Check if package is already in project
package = project.root_object.package_references.find { |pr| pr.repositoryURL == repo_url }

unless package
  package = project.new(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
  package.repositoryURL = repo_url
  package.requirement = {
    'kind' => 'upToNextMajorVersion',
    'minimumVersion' => '14.0.0'
  }
  project.root_object.package_references << package
end

# Check if the product is already linked
build_phase = target.frameworks_build_phase
existing_product = build_phase.files.find do |f|
  f.product_ref && f.product_ref.is_a?(Xcodeproj::Project::Object::XCSwiftPackageProductDependency) && f.product_ref.product_name == package_name
end

unless existing_product
  product_dependency = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  product_dependency.product_name = package_name
  product_dependency.package = package

  build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  build_file.product_ref = product_dependency

  build_phase.files << build_file
end

project.save
puts "Successfully added #{package_name} to #{target.name}"
