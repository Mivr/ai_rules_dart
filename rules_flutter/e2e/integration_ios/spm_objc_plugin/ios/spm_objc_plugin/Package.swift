// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "spm_objc_plugin",
    platforms: [
        .iOS("15.0")
    ],
    products: [
        .library(name: "spm_objc_plugin", targets: ["spm_objc_plugin"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "spm_objc_plugin",
            dependencies: ["spm_objc_plugin_objc"]
        ),
        .target(
            name: "spm_objc_plugin_objc",
            path: "Sources/spm_objc_plugin_objc",
            publicHeadersPath: "include",
            cSettings: [.define("SPM_LOCAL_C_DEFINE", to: "7")]
        ),
    ]
)
