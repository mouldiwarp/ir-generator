// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "IRGenerator",
    platforms: [.macOS(.v14)],
    targets: [
        // Real-time duplex play/record on one Core Audio device (C: no Swift runtime on the audio thread).
        .target(name: "CIRAudio",
                linkerSettings: [.linkedFramework("CoreAudio")]),
        // Measurement DSP: test signals, deconvolution, post-processing, analysis, WAV files. No UI.
        .target(name: "IRCore",
                linkerSettings: [.linkedFramework("Accelerate")]),
        // The SwiftUI app. Bundled into "IR Generator.app" by scripts/build-app.sh.
        .executableTarget(name: "IRGenerator", dependencies: ["CIRAudio", "IRCore"],
                          linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("CoreAudio"),
                                           .linkedFramework("AVFoundation")]),
        // Offline tests for IRCore (no audio hardware needed): swift run ircore-tests
        .executableTarget(name: "ircore-tests", dependencies: ["IRCore"]),
    ]
)
