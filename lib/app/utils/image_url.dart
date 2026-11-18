/// Rewrites a cleartext image URL to HTTPS before it is decoded.
///
/// The app does not allow cleartext, so an `http://` catalog or look image
/// would fail to load. Only the scheme changes; the host and path stay put.
/// Anything that is not `http://` is returned unchanged.
String upgradeImageUrl(String url) {
  final trimmed = url.trim();
  const prefix = 'http://';
  if (trimmed.length >= prefix.length &&
      trimmed.substring(0, prefix.length).toLowerCase() == prefix) {
    return 'https://${trimmed.substring(prefix.length)}';
  }
  return trimmed;
}
