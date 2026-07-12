/// Encrypted-at-rest video playback with on-the-fly native decryption.
///
/// Android: Media3 1.10.1 custom DataSource. iOS: AVPlayer +
/// AVAssetResourceLoaderDelegate.
library;

export 'src/controller.dart'
    show
        SecureVideoController,
        SecureVideoState,
        SecureVideoValue,
        VideoTrack,
        getMediaInfo,
        getScreenBrightness,
        setScreenBrightness,
        setScreenCaptureProtection;
export 'src/messages.g.dart' show MediaInfo, MediaStreamInfo;
export 'src/crypto_scheme.dart';
export 'src/encryptor.dart';
export 'src/errors.dart';
export 'src/player_options.dart';
export 'src/progress_triggers.dart' show ProgressTrigger, TriggerHandle;
export 'src/protocol.dart' show SvpTrackTypes;
export 'src/subtitles/srt_parser.dart'
    show SubtitleCue, SubtitleCueLookup, SrtSubtitles, parseSrt;
export 'src/subtitles/subtitle_overlay.dart' show SrtSubtitleOverlay;
export 'src/widgets/controls.dart';
export 'src/widgets/player_view.dart';
