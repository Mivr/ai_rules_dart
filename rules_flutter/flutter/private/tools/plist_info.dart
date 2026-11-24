/// `Info.plist` merging and standard Apple bundle keys.
///
/// Merges XML `Info.plist` sources with Xcode variable substitution and
/// injects the standard bundle metadata for iOS and macOS. Parses sources
/// with the reader in `plist_parse.dart`.

import 'plist_parse.dart'
    show PlistEntry, escapeXml, parsePlistEntries, substitutePlistVariables;

bool _isEmptyPlistString(String rawValue) {
  final String trimmed = rawValue.trim();
  return trimmed == '<string></string>' || trimmed == '<string/>';
}

/// Merges plist sources with Xcode variable substitution, remembering key
/// order and overwrite rules.
class _PlistMerger {
  final Map<String, String> variables;
  final merged = <String, String>{};
  final order = <String>[];

  new(this.variables);

  void setEntry(String key, String rawValue, {bool overwriteNonEmpty = true}) {
    final String substituted = substitutePlistVariables(
      rawValue.trim(),
      variables,
    );
    if (!merged.containsKey(key)) {
      merged[key] = substituted;
      order.add(key);
      return;
    }
    if (_isEmptyPlistString(merged[key]!)) {
      merged[key] = substituted;
      return;
    }
    if (overwriteNonEmpty && !_isEmptyPlistString(substituted)) {
      merged[key] = substituted;
    }
  }

  void dropIfEmpty(String key) {
    if (merged.containsKey(key) && _isEmptyPlistString(merged[key]!)) {
      merged.remove(key);
      order.remove(key);
    }
  }
}

Map<String, String> _basePlistVariables({
  required String appName,
  required String bundleId,
  required String minimumOsVersion,
  required Map<String, String> extraVariables,
}) {
  return {
    'EXECUTABLE_NAME': appName,
    'PRODUCT_NAME': appName,
    'PRODUCT_BUNDLE_IDENTIFIER': bundleId,
    'BUNDLE_IDENTIFIER': bundleId,
    'DEVELOPMENT_LANGUAGE': 'en',
    'MACOSX_DEPLOYMENT_TARGET': minimumOsVersion,
    'IPHONEOS_DEPLOYMENT_TARGET': minimumOsVersion,
    'FLUTTER_BUILD_NAME': '1.0.0',
    'FLUTTER_BUILD_NUMBER': '1',
    ...extraVariables,
  };
}

void _mergePlistSources(_PlistMerger merger, List<String> plistXmls) {
  for (var i = 0; i < plistXmls.length; i++) {
    final List<PlistEntry> entries = parsePlistEntries(
      plistXmls[i],
      source: 'plist[$i]',
    );
    for (final entry in entries) {
      merger.setEntry(entry.key, entry.rawValue, overwriteNonEmpty: true);
    }
  }
}

void _applyBuildVersionOverrides(
  _PlistMerger merger,
  Map<String, String> extraVariables,
) {
  // If explicit build/short version variables were supplied, ensure they
  // populate CFBundleVersion / CFBundleShortVersionString even if the base
  // Info.plist had literal strings instead of $(FLUTTER_BUILD_*) placeholders.
  final String? buildName = extraVariables['FLUTTER_BUILD_NAME'];
  if (buildName != null && buildName.isNotEmpty) {
    merger.setEntry(
      'CFBundleShortVersionString',
      '<string>${escapeXml(buildName)}</string>',
      overwriteNonEmpty: true,
    );
  }
  final String? buildNumber = extraVariables['FLUTTER_BUILD_NUMBER'];
  if (buildNumber != null && buildNumber.isNotEmpty) {
    merger.setEntry(
      'CFBundleVersion',
      '<string>${escapeXml(buildNumber)}</string>',
      overwriteNonEmpty: true,
    );
  }
}

Map<String, String> _standardPlistDefaults(
  Map<String, String> variables,
  String appName,
  String bundleId,
) {
  return {
    'CFBundleDevelopmentRegion': '<string>en</string>',
    'CFBundleExecutable': '<string>${escapeXml(appName)}</string>',
    'CFBundleIdentifier': '<string>${escapeXml(bundleId)}</string>',
    'CFBundleInfoDictionaryVersion': '<string>6.0</string>',
    'CFBundleName': '<string>${escapeXml(appName)}</string>',
    'CFBundlePackageType': '<string>APPL</string>',
    'CFBundleShortVersionString':
        '<string>${escapeXml(variables['FLUTTER_BUILD_NAME']!)}</string>',
    'CFBundleVersion':
        '<string>${escapeXml(variables['FLUTTER_BUILD_NUMBER']!)}</string>',
  };
}

String _iosDeviceFamilyXml(List<String> families) {
  final familyIds = <int>[];
  if (families.isEmpty) {
    familyIds.addAll([1, 2]);
  } else {
    for (final f in families) {
      switch (f) {
        case 'iphone':
          if (!familyIds.contains(1)) familyIds.add(1);
        case 'ipad':
          if (!familyIds.contains(2)) familyIds.add(2);
        default:
          throw ArgumentError(
            'Unsupported iOS device family "$f" in families. '
            'Expected "iphone" or "ipad".',
          );
      }
    }
  }
  return '<array>\n${familyIds.map((id) => '\t\t<integer>$id</integer>').join('\n')}\n\t</array>';
}

void _addIosPlistDefaults(
  Map<String, String> defaults,
  String platform,
  String minimumOsVersion,
  List<String> families,
  _PlistMerger merger,
) {
  final supportedPlatform = platform == 'ios_sim'
      ? 'iPhoneSimulator'
      : 'iPhoneOS';
  final dtPlatform = platform == 'ios_sim' ? 'iphonesimulator' : 'iphoneos';
  defaults['MinimumOSVersion'] =
      '<string>${escapeXml(minimumOsVersion)}</string>';
  defaults['CFBundleSupportedPlatforms'] =
      '<array>\n\t\t<string>$supportedPlatform</string>\n\t</array>';
  defaults['DTPlatformName'] = '<string>$dtPlatform</string>';

  final String familyXml = _iosDeviceFamilyXml(families);
  if (families.isNotEmpty) {
    merger.setEntry('UIDeviceFamily', familyXml, overwriteNonEmpty: true);
  } else {
    defaults['UIDeviceFamily'] = familyXml;
  }
}

void _addMacosPlistDefaults(
  Map<String, String> defaults,
  String minimumOsVersion,
) {
  defaults['LSMinimumSystemVersion'] =
      '<string>${escapeXml(minimumOsVersion)}</string>';
  defaults['CFBundleSupportedPlatforms'] =
      '<array>\n\t\t<string>MacOSX</string>\n\t</array>';
  defaults['DTPlatformName'] = '<string>macosx</string>';
  defaults['NSPrincipalClass'] = '<string>NSApplication</string>';
}

/// The inputs for merging an `Info.plist`: XML sources, bundle identity,
/// and platform defaults. Grouped so the plist entry point stays small.
class InfoPlistRequest {
  const new({
    required this.plistXmls,
    required this.platform,
    required this.appName,
    required this.bundleId,
    required this.minimumOsVersion,
    this.extraVariables = const {},
    this.families = const [],
  });

  /// The raw `Info.plist` XML sources to merge.
  final List<String> plistXmls;

  /// The target platform (`ios`, `ios_sim`, or `macos`).
  final String platform;

  /// The `CFBundleName` / executable name.
  final String appName;

  /// The `CFBundleIdentifier` value.
  final String bundleId;

  /// The minimum-OS version string.
  final String minimumOsVersion;

  /// Extra Xcode build-variable substitutions.
  final Map<String, String> extraVariables;

  /// The requested iOS device families.
  final List<String> families;
}

/// Merges zero or more XML `Info.plist` sources, substitutes Xcode build
/// variables, and injects standard Apple bundle keys required by iOS/macOS.
String buildInfoPlist(InfoPlistRequest request) {
  final String platform = request.platform;
  final String minimumOsVersion = request.minimumOsVersion;
  final List<String> families = request.families;
  final Map<String, String> extraVariables = request.extraVariables;
  final Map<String, String> variables = _basePlistVariables(
    appName: request.appName,
    bundleId: request.bundleId,
    minimumOsVersion: minimumOsVersion,
    extraVariables: extraVariables,
  );
  final merger = _PlistMerger(variables);
  _mergePlistSources(merger, request.plistXmls);

  // Drop empty CFBundleIconFile left by `flutter create` scaffolds if nothing
  // populated it.
  merger.dropIfEmpty('CFBundleIconFile');
  _applyBuildVersionOverrides(merger, extraVariables);

  // Standard Apple bundle defaults (only injected when missing or empty).
  final Map<String, String> defaults = _standardPlistDefaults(
    variables,
    request.appName,
    request.bundleId,
  );
  if (platform == 'ios' || platform == 'ios_sim') {
    _addIosPlistDefaults(
      defaults,
      platform,
      minimumOsVersion,
      families,
      merger,
    );
  } else if (platform == 'macos') {
    _addMacosPlistDefaults(defaults, minimumOsVersion);
  }
  for (final MapEntry<String, String> entry in defaults.entries) {
    merger.setEntry(entry.key, entry.value, overwriteNonEmpty: false);
  }
  return _renderPlistXml(merger.order, merger.merged);
}

String _renderPlistXml(List<String> order, Map<String, String> merged) {
  final buffer = StringBuffer()
    ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
    ..writeln(
      '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
      '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">',
    )
    ..writeln('<plist version="1.0">')
    ..writeln('<dict>');
  for (final key in order) {
    final String? value = merged[key];
    if (value == null) continue;
    buffer
      ..writeln('\t<key>$key</key>')
      ..writeln('\t$value');
  }
  buffer
    ..writeln('</dict>')
    ..writeln('</plist>');
  return buffer.toString();
}
