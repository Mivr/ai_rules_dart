class IconData {
  const new(
    this.codePoint, {
    this.fontFamily,
    this.fontPackage,
    this.matchTextDirection = false,
  });

  @pragma('vm:entry-point')
  final int codePoint;
  @pragma('vm:entry-point')
  final String? fontFamily;
  @pragma('vm:entry-point')
  final String? fontPackage;
  @pragma('vm:entry-point')
  final bool matchTextDirection;
}

class _StaticIconProvider {
  const new();
}

const Object staticIconProvider = _StaticIconProvider();
