#!/usr/bin/env bash
# Builds a one-screen UIKit test app as an arm64 simulator .ipa, for checking
# the embedded LiveContainer runtime (install, launch, per-app data).
#
#   scripts/build-container-test-ipa.sh [output.ipa]
#
# Serve it to the simulator with `python3 -m http.server` from its folder and
# install it from Settings > Developer > Container Apps.
set -euo pipefail

OUTPUT_PATH="${1:-$PWD/.build/container-test/HermexContainerTest.ipa}"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/hermex-container-test.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT
APP_DIR="$BUILD_DIR/Payload/HermexContainerTest.app"
mkdir -p "$APP_DIR"

cat > "$BUILD_DIR/main.m" <<'OBJC'
#import <UIKit/UIKit.h>

// iOS 27's SDK requires the scene life cycle, so the window lives in a scene
// delegate.
@interface TestAppDelegate : UIResponder <UIApplicationDelegate>
@end

@implementation TestAppDelegate
- (UISceneConfiguration *)application:(UIApplication *)application configurationForConnectingSceneSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    UISceneConfiguration *config = [[UISceneConfiguration alloc] initWithName:@"Default" sessionRole:session.role];
    config.delegateClass = NSClassFromString(@"TestSceneDelegate");
    return config;
}
@end

@interface TestSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation TestSceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)connectionOptions {
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    UIViewController *controller = [UIViewController new];
    controller.view.backgroundColor = [UIColor colorWithRed:0.10 green:0.16 blue:0.30 alpha:1.0];

    UILabel *title = [UILabel new];
    title.text = @"Container test app running";
    title.textColor = UIColor.whiteColor;
    title.font = [UIFont boldSystemFontOfSize:24.0];
    title.textAlignment = NSTextAlignmentCenter;
    title.numberOfLines = 0;

    // Persisted in this guest's own data container, so a relaunch shows the
    // previous count.
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    UILabel *count = [UILabel new];
    count.textColor = UIColor.systemYellowColor;
    count.font = [UIFont monospacedDigitSystemFontOfSize:20.0 weight:UIFontWeightSemibold];
    count.textAlignment = NSTextAlignmentCenter;
    count.accessibilityIdentifier = @"TestAppCount";
    void (^render)(void) = ^{
        count.text = [NSString stringWithFormat:@"Taps: %ld", (long)[defaults integerForKey:@"taps"]];
    };
    render();

    UIButton *tap = [UIButton buttonWithType:UIButtonTypeSystem];
    [tap setTitle:@"Tap" forState:UIControlStateNormal];
    [tap setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    tap.backgroundColor = UIColor.systemBlueColor;
    tap.layer.cornerRadius = 14.0;
    tap.titleLabel.font = [UIFont boldSystemFontOfSize:20.0];
    tap.accessibilityIdentifier = @"TestAppTap";
    [tap addAction:[UIAction actionWithHandler:^(__kindof UIAction *action) {
        [defaults setInteger:[defaults integerForKey:@"taps"] + 1 forKey:@"taps"];
        render();
    }] forControlEvents:UIControlEventTouchUpInside];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[title, count, tap]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 24.0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [controller.view addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.centerYAnchor constraintEqualToAnchor:controller.view.centerYAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:controller.view.leadingAnchor constant:32.0],
        [stack.trailingAnchor constraintEqualToAnchor:controller.view.trailingAnchor constant:-32.0],
        [tap.heightAnchor constraintEqualToConstant:52.0],
    ]];

    self.window.rootViewController = controller;
    [self.window makeKeyAndVisible];
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(TestAppDelegate.class));
    }
}
OBJC

xcrun clang "$BUILD_DIR/main.m" \
  -target arm64-apple-ios15.0-simulator \
  -isysroot "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
  -fobjc-arc \
  -framework UIKit \
  -o "$APP_DIR/HermexContainerTest"

cat > "$APP_DIR/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleDisplayName</key><string>Container Test</string>
  <key>CFBundleExecutable</key><string>HermexContainerTest</string>
  <key>CFBundleIdentifier</key><string>dev.hermex.containertest</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>HermexContainerTest</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSRequiresIPhoneOS</key><true/>
  <key>MinimumOSVersion</key><string>15.0</string>
  <key>UIApplicationSceneManifest</key>
  <dict>
    <key>UIApplicationSupportsMultipleScenes</key><false/>
    <key>UISceneConfigurations</key><dict/>
  </dict>
  <key>UISupportedInterfaceOrientations</key>
  <array><string>UIInterfaceOrientationPortrait</string></array>
</dict>
</plist>
PLIST

mkdir -p "$(dirname "$OUTPUT_PATH")"
rm -f "$OUTPUT_PATH"
(cd "$BUILD_DIR" && /usr/bin/zip -qry "$OUTPUT_PATH" Payload)
printf '%s\n' "$OUTPUT_PATH"
