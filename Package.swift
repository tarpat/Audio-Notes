// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "LectureRecorder",
  platforms: [.macOS(.v14)],
  products: [.executable(name: "LectureRecorder", targets: ["LectureRecorder"])],
  targets: [.executableTarget(name: "LectureRecorder")],
  swiftLanguageModes: [.v5]
)
