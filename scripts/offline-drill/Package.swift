// swift-tools-version: 6.2
// オフライン反復の「問題の型」の解釈器・生成器・点検器を、Linux の Swift だけで回すための入れ物。
// 中身は strius/Engine/Drill と striusTests/Drill へのシンボリックリンクで、アプリのビルドには関係しない。
//   cd scripts/offline-drill && swift test
import PackageDescription

let package = Package(
    name: "OfflineDrill",
    targets: [
        .target(
            name: "strius",
            path: "Sources/strius",
            swiftSettings: [.swiftLanguageMode(.v5), .defaultIsolation(MainActor.self)]
        ),
        .executableTarget(
            name: "drillcheck",
            dependencies: ["strius"],
            path: "Sources/drillcheck",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "striusTests",
            dependencies: ["strius"],
            path: "Tests/striusTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
