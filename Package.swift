// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GentleMerge",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "gentlemerge", targets: ["GentleMerge"]),
        .library(name: "GentleMergeCore", targets: ["GentleMergeCore"]),
        .library(name: "GentleMergePorts", targets: ["GentleMergePorts"]),
    ],
    targets: [
        .target(name: "GentleMergeCore"),
        .target(
            name: "GentleMergePorts",
            dependencies: ["GentleMergeCore"]
        ),
        .executableTarget(
            name: "GentleMerge",
            dependencies: ["GentleMergeCore", "GentleMergePorts"]
        ),
        .testTarget(
            name: "GentleMergeCoreTests",
            dependencies: ["GentleMergeCore", "GentleMergePorts"]
        ),
    ]
)
