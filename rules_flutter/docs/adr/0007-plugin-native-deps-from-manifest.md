---
status: accepted
unenforceable: "Manifest reads and pinned fetches run in repository rules, not in a metric."
---

# 0007. Plugin native deps come from each plugin's manifest; fetches are pinned

## Decision

A plugin's native dependencies are read from the plugin itself:

- the `flutter.plugin` block of its `pubspec.yaml`, which names its
  platforms (`flutter/private/flutter_pubspec.bzl`);
- its Gradle build, read from `android/build.gradle*` when an Android target
  analyses the spoke (`flutter/private/flutter_pub_android_package.bzl:1-14`). A
  Maven coordinate is mapped through the built-in table or through
  `flutter.pub(android_maven_deps)`
  (`flutter/private/flutter_pub_maven.bzl:27-37`). A coordinate in neither table
  fails;
- its CocoaPods `.podspec` (`flutter/private/podspec_read.bzl`);
- its SwiftPM `Package.resolved` (`flutter/private/swiftpm_resolved.bzl`).

Pub packages are fetched by their sha256, recorded in `pubspec.lock`
(`flutter/private/pub_lock_sdks.bzl:122`), and every fetch goes through the
download helpers in ADR 0006.

**Known gap.** The rule set's own `maven.install` in `MODULE.bazel:340-373`
names no `lock_file`, so its Maven artifacts are not checksum-locked by this
repository. `docs/dependencies.md:243-245` explains why the lock belongs in the
consumer's root module. This defect has its own work item. The tree does not yet
meet this decision for its own Maven artifacts.

## Alternatives ruled out

- **A hand-written dependency list per plugin in rules_flutter.** Every plugin
  upgrade would need a rules_flutter change. The manifest is the source.
- **A library-level Maven lock in rules_flutter's `MODULE.bazel`.** A consumer's
  root install replaces it, and rules_jvm_external allows only one module to pin
  an install name (`docs/dependencies.md:245`).
- **Unpinned plugin archives.** A fetch with no digest accepts any bytes.

## Consequence

A plugin that declares a Maven coordinate outside both tables fails when its
Android target is analysed, so the fix is `android_maven_deps` in the consumer.
A Maven lock must be added at the consumer's root module, not in this one.
