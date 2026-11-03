// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Murmur",
    platforms: [.macOS(.v15)],
    dependencies: [
        // Murmur only transcribes: no speech synthesis, no speaker
        // diarization, and no inverse-text-normalization. Opting out of all
        // three optional traits drops ~215 compiled-in files and the
        // prebuilt NemoTextProcessing xcframework (~8 MB on its own).
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.18.2", traits: [])
    ],
    targets: [
        .executableTarget(
            name: "Murmur",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            path: "Sources/Murmur",
            swiftSettings: [
                .swiftLanguageMode(.v5),
                // Nothing in Murmur is latency-sensitive Swift code — the
                // actual ASR compute runs on the Neural Engine via CoreML —
                // so trading code generation speed for size costs nothing
                // noticeable while shrinking the shipped binary.
                .unsafeFlags(["-Osize"], .when(configuration: .release)),
            ],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-dead_strip"], .when(configuration: .release))
            ]
        ),
        .testTarget(
            name: "MurmurTests",
            dependencies: ["Murmur"],
            path: "Tests/MurmurTests",
            swiftSettings: [
                // Swift Testing ships as a framework under Command Line
                // Tools rather than on the default search path (that's only
                // true without a full Xcode.app install).
                .unsafeFlags([
                    "-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                ])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                ])
            ]
        ),
    ]
)
