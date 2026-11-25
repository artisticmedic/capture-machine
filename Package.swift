// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GIFMachine",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "GIFMachine", dependencies: ["GIFMachineCore"], path: "Sources/GIFMachine"),
        .target(name: "GIFMachineCore", path: "Sources/GIFMachineCore"),
        .testTarget(name: "GIFMachineCoreTests", dependencies: ["GIFMachineCore"], path: "Tests/GIFMachineCoreTests"),
        .executableTarget(name: "EncoderBench", path: "Sources/EncoderBench"),
    ]
)
