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
