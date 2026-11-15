// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CtxGraph",
    platforms: [.macOS(.v14)],
    targets: [
        // SwiftTerm v1.18.0 소스 (Vendor/SwiftTerm/VENDORED.txt). Xcode 없이 빌드하려고 Metal 셰이더는 뺐다.
        .target(
            name: "SwiftTerm",
            path: "Vendor/SwiftTerm",
            exclude: ["LICENSE", "VENDORED.txt"]
        ),
        .executableTarget(
            name: "CtxGraph",
            dependencies: ["SwiftTerm"],
            path: "Sources/CtxGraph",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
    ]
)
