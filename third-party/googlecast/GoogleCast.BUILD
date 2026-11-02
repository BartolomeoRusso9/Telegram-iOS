# BUILD file of the @google_cast_sdk repository (see MODULE.bazel).
load(
    "@build_bazel_rules_apple//apple:apple.bzl",
    "apple_static_xcframework_import",
)
load(
    "@build_bazel_rules_apple//apple:resources.bzl",
    "apple_bundle_import",
)

apple_static_xcframework_import(
    name = "GoogleCast",
    xcframework_imports = glob(
        ["GoogleCast.xcframework/**"],
        exclude = ["GoogleCast.xcframework/*/GoogleCast.framework/*.bundle/**"],
    ),
    # The SDK registers Objective-C categories that nothing references by name.
    alwayslink = True,
    sdk_dylibs = ["c++", "z"],
    # The SDK's module map names these; nothing links them without it for a static import.
    sdk_frameworks = [
        "Accelerate",
        "CFNetwork",
        "CoreGraphics",
        "CoreText",
        "Foundation",
        "MediaAccessibility",
        "MediaPlayer",
        "QuartzCore",
        "Security",
        "SystemConfiguration",
        "UIKit",
    ],
    visibility = ["//visibility:public"],
)

# A static framework cannot carry resources: the app must embed these itself. The device and
# simulator slices ship the same bundles.
[
    apple_bundle_import(
        name = name,
        bundle_imports = glob(["GoogleCast.xcframework/ios-arm64/GoogleCast.framework/{}.bundle/**".format(name)]),
        visibility = ["//visibility:public"],
    )
    for name in [
        "GoogleCastCoreResources",
        "GoogleCastOptionalUIResources",
        "GoogleCastUIResources",
        "GoogleSansBold",
        "GoogleSansMedium",
        "GoogleSansRegular",
        "MaterialDialogs",
    ]
]
