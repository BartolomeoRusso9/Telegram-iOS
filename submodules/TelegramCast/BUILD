load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "TelegramCast",
    module_name = "TelegramCast",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    deps = [
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/TelegramCore:TelegramCore",
        "@google_cast_sdk//:GoogleCast",
    ],
    visibility = [
        "//visibility:public",
    ],
)
