import 'package:flutter/foundation.dart';

/// True once [AudioService.init] has completed successfully.
///
/// We deliberately do NOT use `AudioService.running` / `runningStream`: those
/// deprecated compatibility getters are broken in audio_service 0.18.19 with
/// rxdart 0.28 (`ValueStream.map(...) as ValueStream<bool>` casts a
/// `_MapStream` that is not a ValueStream and throws at runtime).
final ValueNotifier<bool> audioSessionReady = ValueNotifier(false);