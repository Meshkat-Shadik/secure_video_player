/// Encrypted-at-rest video playback with on-the-fly native decryption.
///
/// Android: Media3 1.10.1 custom DataSource. iOS: AVPlayer +
/// AVAssetResourceLoaderDelegate. See README for the custom-cipher guide.
library;

export 'src/controller.dart'
    show
        SecureVideoController,
        SecureVideoState,
        SecureVideoValue,
        VideoTrack,
        setScreenCaptureProtection;
export 'src/crypto_scheme.dart';
export 'src/encryptor.dart';
export 'src/errors.dart';
export 'src/player_options.dart';
export 'src/protocol.dart' show SvpTrackTypes;
export 'src/widgets/controls.dart';
export 'src/widgets/player_view.dart';
