// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HTD",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "HTD", targets: ["HttpsDown"])
    ],
    targets: [
        .executableTarget(
            name: "HttpsDown",
            path: "Sources/HttpsDown",
            resources: [
                .copy("AIResources")
            ]
        )
    ]
)
