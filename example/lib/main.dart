import 'package:flutter/material.dart';

import 'sample_media.dart';
import 'screens/buffer_screen.dart';
import 'screens/dart_cipher_screen.dart';
import 'screens/encrypt_play_screen.dart';
import 'screens/error_cases_screen.dart';
import 'screens/lifecycle_screen.dart';
import 'screens/list_stress_screen.dart';
import 'screens/media_controls_screen.dart';
import 'screens/multi_player_screen.dart';
import 'screens/progress_triggers_sleep_timer_screen.dart';
import 'screens/render_toggle_screen.dart';
import 'screens/scheme_matrix_screen.dart';
import 'screens/screen_awake_screen.dart';
import 'screens/seek_stress_screen.dart';
import 'screens/srt_subtitles_screen.dart';
import 'screens/tracks_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ExampleApp());
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'secure_video_player',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: const GalleryScreen(),
    );
  }
}

class GalleryScreen extends StatefulWidget {
  const GalleryScreen({super.key});

  @override
  State<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends State<GalleryScreen> {
  late final Future<void> _prepare = SampleMedia.prepare();

  static final _entries = <(String, String, Widget Function())>[
    (
      'Scheme matrix',
      'none / xorLegacy / aesCtr / custom adapter — each must reach READY',
      SchemeMatrixScreen.new,
    ),
    (
      'Encrypt → play',
      'Encrypt the plain file with progress, then play the ciphertext',
      EncryptPlayScreen.new,
    ),
    (
      'Error cases',
      'Wrong key, truncated file, missing file, unregistered adapter',
      ErrorCasesScreen.new,
    ),
    (
      '4-player grid',
      'Four simultaneous decrypting players',
      MultiPlayerScreen.new,
    ),
    (
      'List recycling stress',
      'Players created/disposed while scrolling a list',
      ListStressScreen.new,
    ),
    (
      'Seek hammer + speed + loop',
      'Rapid random seeks, 0.25–3x speed, looping',
      SeekStressScreen.new,
    ),
    (
      'Tracks & subtitles',
      'Audio/subtitle selection, external VTT sideload',
      TracksScreen.new,
    ),
    (
      'PiP / background / secure',
      'Picture-in-picture, background audio, FLAG_SECURE',
      LifecycleScreen.new,
    ),
    (
      'Texture vs PlatformView',
      'Same encrypted video through both render paths',
      RenderToggleScreen.new,
    ),
    (
      'Buffer tuning (low RAM)',
      'lowRam vs default BufferConfig side by side',
      BufferScreen.new,
    ),
    // NEW FEATURE DEMOS
    (
      'Progress triggers + sleep timer',
      'Fire callback at position, set sleep timer, adjust in real time',
      ProgressTriggersAndSleepTimerScreen.new,
    ),
    (
      'SRT subtitles + delay',
      'Load SRT cues, render overlay, adjust delay slider (≤50ms sync)',
      SrtSubtitlesScreen.new,
    ),
    (
      'Media controls',
      'System notification (Android) + now-playing (iOS) integration',
      MediaControlsScreen.new,
    ),
    (
      'Custom Dart cipher',
      'Register DartCipherDelegate, decrypt in Dart via IPC',
      DartCipherScreen.new,
    ),
    (
      'Screen awake',
      'keepScreenAwakeWhilePlaying option + manual override (true/false/auto)',
      ScreenAwakeScreen.new,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('secure_video_player gallery')),
      body: FutureBuilder<void>(
        future: _prepare,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
                child: Text('Sample prep failed:\n${snapshot.error}',
                    textAlign: TextAlign.center));
          }
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 12),
                  Text('Preparing sample media\n(copy + encrypt variants)…',
                      textAlign: TextAlign.center),
                ],
              ),
            );
          }
          return ListView.separated(
            itemCount: _entries.length,
            separatorBuilder: (context, index) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final (title, subtitle, builder) = _entries[i];
              return ListTile(
                leading: CircleAvatar(child: Text('${i + 1}')),
                title: Text(title),
                subtitle: Text(subtitle),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(
                    context, MaterialPageRoute(builder: (_) => builder())),
              );
            },
          );
        },
      ),
    );
  }
}
