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
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      themeMode: ThemeMode.system,
      home: const GalleryScreen(),
    );
  }
}

class _Demo {
  const _Demo(this.title, this.subtitle, this.icon, this.builder);

  final String title;
  final String subtitle;
  final IconData icon;
  final Widget Function() builder;
}

class _Section {
  const _Section(this.title, this.color, this.demos);

  final String title;
  final Color color;
  final List<_Demo> demos;
}

class GalleryScreen extends StatefulWidget {
  const GalleryScreen({super.key});

  @override
  State<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends State<GalleryScreen> {
  late final Future<void> _prepare = SampleMedia.prepare();

  static final _sections = <_Section>[
    _Section('Feature demos', Colors.teal, [
      _Demo(
        'Progress triggers + sleep timer',
        'Fire a callback at any position; auto-pause after a countdown',
        Icons.alarm,
        ProgressTriggersAndSleepTimerScreen.new,
      ),
      _Demo(
        'SRT subtitles + delay',
        'Pure-Dart SRT parser + overlay with a live delay slider',
        Icons.subtitles,
        SrtSubtitlesScreen.new,
      ),
      _Demo(
        'Media controls',
        'System notification (Android) / Now Playing (iOS) with live metadata',
        Icons.notifications_active,
        MediaControlsScreen.new,
      ),
      _Demo(
        'Custom Dart cipher',
        'Decrypt in pure Dart via CryptoScheme.dartProxy — no native code',
        Icons.vpn_key,
        DartCipherScreen.new,
      ),
      _Demo(
        'Screen awake',
        'Keep the screen on while playing, with force on/off/auto override',
        Icons.light_mode,
        ScreenAwakeScreen.new,
      ),
      _Demo(
        'PiP / background / secure',
        'Fullscreen-aware picture-in-picture, background audio, FLAG_SECURE',
        Icons.picture_in_picture_alt,
        LifecycleScreen.new,
      ),
    ]),
    _Section('Playback & crypto', Colors.indigo, [
      _Demo(
        'Scheme matrix',
        'none / xorLegacy / aesCtr / custom adapter — each must reach READY',
        Icons.grid_view,
        SchemeMatrixScreen.new,
      ),
      _Demo(
        'Encrypt → play',
        'Encrypt the plain file with progress, then play the ciphertext',
        Icons.lock,
        EncryptPlayScreen.new,
      ),
      _Demo(
        'Tracks & subtitles',
        'Audio/subtitle selection, external VTT sideload',
        Icons.translate,
        TracksScreen.new,
      ),
      _Demo(
        'Texture vs PlatformView',
        'Same encrypted video through both render paths',
        Icons.layers,
        RenderToggleScreen.new,
      ),
    ]),
    _Section('Stress & edge cases', Colors.deepOrange, [
      _Demo(
        'Error cases',
        'Wrong key, truncated file, missing file, unregistered adapter',
        Icons.error_outline,
        ErrorCasesScreen.new,
      ),
      _Demo(
        '4-player grid',
        'Four simultaneous decrypting players',
        Icons.grid_on,
        MultiPlayerScreen.new,
      ),
      _Demo(
        'List recycling stress',
        'Players created/disposed while scrolling a list',
        Icons.view_list,
        ListStressScreen.new,
      ),
      _Demo(
        'Seek hammer + speed + loop',
        'Rapid random seeks, 0.25–3x speed, looping',
        Icons.speed,
        SeekStressScreen.new,
      ),
      _Demo(
        'Buffer tuning (low RAM)',
        'lowRam vs default BufferConfig side by side',
        Icons.memory,
        BufferScreen.new,
      ),
    ]),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('secure_video_player'),
        centerTitle: false,
      ),
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
          return ListView(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
            children: [
              for (final section in _sections) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 16, 8, 8),
                  child: Text(
                    section.title.toUpperCase(),
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: section.color,
                          letterSpacing: 1.2,
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                ),
                for (final demo in section.demos)
                  Card(
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    clipBehavior: Clip.antiAlias,
                    child: ListTile(
                      leading: CircleAvatar(
                        backgroundColor: section.color.withValues(alpha: 0.15),
                        child: Icon(demo.icon, color: section.color, size: 20),
                      ),
                      title: Text(demo.title,
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      subtitle: Text(demo.subtitle,
                          style: const TextStyle(fontSize: 12)),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => demo.builder())),
                    ),
                  ),
              ],
            ],
          );
        },
      ),
    );
  }
}
