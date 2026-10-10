/// Pure deep-link helpers (testable, no Flutter deps).
/// Single source of truth for which share-URL hosts the app handles;
/// mirrors the manifest intent-filters + server `_open_url` host sets.
enum DeepLinkKind { spotify, youtube, other }

DeepLinkKind classifyDeepLink(String rawUrl) {
  final url = Uri.tryParse(rawUrl);
  if (url == null) return DeepLinkKind.other;
  final host = (url.host.isNotEmpty ? url.host : url.path).toLowerCase();
  final isSpotify = host == 'open.spotify.com' ||
      host == 'spotify.link' ||
      host.endsWith('.spotify.com') ||
      host.endsWith('.spotify.link');
  if (isSpotify) return DeepLinkKind.spotify;
  final isYt = host == 'youtu.be' ||
      host == 'www.youtube.com' ||
      host == 'm.youtube.com' ||
      host == 'youtube.com' ||
      host == 'music.youtube.com' ||
      host.endsWith('youtube.com');
  if (isYt) return DeepLinkKind.youtube;
  return DeepLinkKind.other;
}

/// True when [url] repeats [lastUrl] within [window] (cold start +
/// warm `openUrl` delivering the same link twice must play once).
bool isDuplicateDeepLink(String? lastUrl, DateTime? lastAt, String url, DateTime now,
    [Duration window = const Duration(seconds: 3)]) {
  if (lastUrl == null || lastAt == null) return false;
  return lastUrl == url && now.difference(lastAt) < window;
}

/// Strip share-tracking query params WhatsApp/Spotify append (`?si=…`,
/// `utm_*`, `fbclid`, …). Spotify track ids live in the path, so the whole
/// query goes; YouTube keeps only playback params (`v`, `list`, `t`,
/// `index`). Returns the input unchanged when unparseable.
String stripTrackingParams(String rawUrl) {
  final url = Uri.tryParse(rawUrl.trim());
  if (url == null || !url.hasScheme) return rawUrl;
  final kind = classifyDeepLink(rawUrl);
  if (kind == DeepLinkKind.spotify) {
    if (url.query.isEmpty && url.fragment.isEmpty) return rawUrl.trim();
    // NOTE: Uri.replace(query: null) KEEPS the query — rebuild instead.
    final port = url.hasPort ? ':${url.port}' : '';
    return '${url.scheme}://${url.host}$port${url.path}';
  }
  if (kind == DeepLinkKind.youtube) {
    if (url.query.isEmpty) return rawUrl.trim();
    const keep = {'v', 'list', 't', 'index'};
    final kept = Map<String, String>.fromEntries(
      url.queryParameters.entries.where((e) => keep.contains(e.key)),
    );
    final port = url.hasPort ? ':${url.port}' : '';
    final base = '${url.scheme}://${url.host}$port${url.path}';
    if (kept.isEmpty) return base;
    final clean = '$base?${Uri(queryParameters: kept).query}';
    if (clean == rawUrl.trim()) return rawUrl.trim();
    return clean;
  }
  return rawUrl;
}

final _urlRe = RegExp(r'https?://[^\s]+');

/// First http(s) URL inside shared text (WhatsApp "share to app" sends
/// ACTION_SEND text/plain, not a VIEW intent). Strips trailing punctuation
/// messengers leave behind. Returns '' when none found.
String extractFirstUrl(String text) {
  final m = _urlRe.firstMatch(text);
  if (m == null) return '';
  return m.group(0)!.replaceAll(RegExp(r'[)\].,;!]+$'), '');
}
