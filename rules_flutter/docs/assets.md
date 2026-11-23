# Assets

An app's asset bundle is written by the Flutter tool's own code. One action
per app runs a small program (`flutter/private/assets_tool/`) compiled
against `package:flutter_tools` of the Flutter release in use, with the Dart
SDK bundled in that release. It calls the tool's own classes, as
`flutter build` does, for:

- the assets the pubspec names and their resolution variants, flavor- and
  platform-conditioned entries, and asset transformers;
- fonts, the Material icons (`uses-material-design`) and icon tree shaking in
  release and profile builds;
- shaders, the framework's and the app's and its packages', compiled with the
  release's `impellerc`;
- `AssetManifest.bin`, `FontManifest.json`, `NOTICES.Z`,
  `NativeAssetsManifest.json` and, on Linux, `version.json`;
- on web: the release bundle around the compiled program, the templated
  `index.html` and `flutter_bootstrap.js`, `flutter.js`, the renderer,
  `version.json`, the project's `web/` files and the service worker.

The pubspec is the source of truth for what is bundled, as it is for
`flutter build`.

## What an app declares

```starlark
flutter_application(
    name = "app",
    main = "lib/main.dart",
    package_name = "my_app",
    # pubspec defaults to this package's pubspec.yaml.
    pubspec_srcs = glob(["assets/**", "shaders/**"]),
    pub_packages = "@pub//packages",
    deps = [":lib"],
)
```

- `pubspec`: the app's `pubspec.yaml`; its directory is the project
  directory. `flutter_application` and `flutter_web_app` default it to the
  package's `pubspec.yaml`; `flutter_test` and `flutter_web_bundle` take it
  explicitly.
- `pubspec_srcs`: the files the pubspec names. A file it names that is not
  listed fails the build with the tool's own message and a line naming each
  missing file. `flutter_web_app` adds `web/**`.
- `pub_packages`: `@<hub>//packages`, every package of the lock. With it the
  package config the tool reads lists dev dependencies too, as `pub get`
  writes it, so `NOTICES` holds their licences, and a test bundles its dev
  dependencies' assets as `flutter test` does. Without it, the packages
  `deps` reach. A regular dependency of the app they miss fails the build,
  as a stale `pub get` does; any other package they miss (a dev dependency,
  or a package another package depends on) is left out, as none of its
  files are inputs.
- A package's assets, fonts and shaders are bundled only when the app's
  `pubspec.yaml` names the package (directly or through other pubspecs), as
  stock walks the dependency graph; a hand-written package in the workspace
  is named as a `path:` dependency.
- `asset_transformers`: `{":binary": "package"}`. What `dart run <package>`
  runs for the pubspec's `transformers`, offline.
- `build_name`, `build_number`: `--build-name` and `--build-number`
  (`version.json`).
- `flavor`: bundles the pubspec's flavor-conditioned assets, as
  `flutter build --flavor` does.

A package's own files reach the bundle through its `data`: a pub spoke lists
its `pubspec.yaml`, its licence and the files its pubspec names; a
hand-written `flutter_library` lists them itself.

## What the bundle action reads, per mode

- Every mode: the pubspec and the files it names, each package's pubspec and
  licence, the framework's shaders, the Material icons font, and `impellerc`
  with its include files. A Dart edit does not rerun it.
- Release and profile: also the app's kernel, `const_finder` and
  `font-subset`, to shake icon fonts (`tree_shake_icons`, on by default).
- Web: also the compiled program and the web SDK's `flutter.js` and renderer.

## Differences from `flutter build`

- `flutter_bootstrap.js` carries a random service-worker version, as stock
  does: the tool draws it inside `WebTemplatedFiles.build` and takes no
  argument for it. Two builds of the same inputs differ in that line.
- The tool reads directory listings sorted by path, so the bundle is the same
  on every machine; stock takes them in its file system's order. Where that
  order shows (the `wasmHashes` in `flutter_bootstrap.js`, the order of an
  asset directory's files and variants in `AssetManifest.bin`), stock's bytes
  can differ between machines; the content is equal.
- A pub package's asset spelled `packages/<another package>/<path>` (a file
  in the other package's `lib/`) is not among the files its spoke lists, so
  it fails the build naming the asset; `packages/<its own name>/<path>` is.
- The package graph is derived from the packages' pubspecs inside the action
  until the pub layer writes `package_graph.json`; the tool then takes it
  with `--package-graph`.

## Migrating from the attribute-based rules

What goes from BUILD files, and what to do instead:

| Before | Now |
| --- | --- |
| `assets = glob([...])` on `flutter_application`, `flutter_library`, `flutter_test` | name them in `pubspec.yaml`'s `flutter: assets:`; list the files in the app's `pubspec_srcs` |
| `fonts = [...]`, `flutter_font_family(...)` | `flutter: fonts:` in `pubspec.yaml`; the files in `pubspec_srcs` |
| `shaders`, `shader_includes`, `require_sksl_shaders` | `flutter: shaders:` in `pubspec.yaml`; the shader and its includes in `pubspec_srcs` |
| `@rules_flutter//flutter:material_icons` in `deps` | `flutter: uses-material-design: true` in `pubspec.yaml` |
| `license_files` | the licences of the packages in the package config (`pub_packages`), and `flutter: licenses:` in `pubspec.yaml` |
| `flutter_asset_bundle(...)` | the bundle of the app (`flutter_application`'s `flutter_assets` output) |
| web `index_html`, `bootstrap_js`, `manifest_json`, `web_assets`, `web_dir` | the project's `web/` directory, as `flutter create --platforms=web` writes it |
| web `title`, `app_name` (`flutter_web_app`), `flutter_web_manifest_gen` | `web/index.html` and `web/manifest.json` |
| web `version_json`, `app_version`, `app_build_number` | the pubspec's `version`, or `build_name` / `build_number` |
| web `keep_placeholders` | not needed: an unreplaced placeholder is a warning, as stock |
| `flutter_library`'s `pkg_assets`, `font_files`, `fonts_json`, `pkg_shaders`, `pkg_asset_platforms`, `pkg_asset_flavors` | the package's `data` (spokes generate it) |

The old attributes are removed outright rather than accepted for one release:
the rule set is alpha, and an attribute accepted but ignored would ship a
bundle that silently lacks what the BUILD file names.
