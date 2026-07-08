import Flutter
import UIKit
import secure_video_player

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Custom cipher demo: register once, reference from Dart with
    // CryptoScheme.custom(adapterName: 'repeatingXor').
    CipherRegistry.shared.register("repeatingXor") { RepeatingXorAdapter() }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}

/// Example custom cipher: XOR every byte with a repeating multi-byte key.
/// Position-addressable, involution — see the plugin README guide.
final class RepeatingXorAdapter: CipherAdapter {
  private var key: [UInt8] = [0x5A]

  func initialize(params: [String: Any?]) throws {
    guard let list = params["key"] as? [Any] else {
      throw NSError(domain: "repeatingXor", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "requires 'key' list"])
    }
    key = list.map { UInt8(truncating: $0 as! NSNumber) }
  }

  func transform(_ buffer: inout Data, filePosition: Int64) {
    let k = key
    let n = Int64(k.count)
    buffer.withUnsafeMutableBytes { raw in
      let bytes = raw.bindMemory(to: UInt8.self)
      for i in 0..<bytes.count {
        bytes[i] ^= k[Int((filePosition + Int64(i)) % n)]
      }
    }
  }
}
