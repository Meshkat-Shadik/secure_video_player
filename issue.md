1. I see some memory issue (may be) after even closing the video and land to list screen back

log: (occurs infinitely)

D/BufferPoolAccessor2.0( 4211): bufferpool2 0xb4000077531bb478 : 5(10485760 size) total buffers - 1(2097152 size) used buffers - 36284/36312 (recycle/alloc) - 28/36311 (fetch/transfer)
D/BufferPoolAccessor2.0( 4211): bufferpool2 0xb400007753161868 : 5(10485760 size) total buffers - 1(2097152 size) used buffers - 36291/36324 (recycle/alloc) - 33/36323 (fetch/transfer)
D/EGL_emulation( 4211): app_time_stats: avg=4.49ms min=2.11ms max=27.08ms count=61
D/BufferPoolAccessor2.0( 4211): bufferpool2 0xb400007753108c88 : 5(10485760 size) total buffers - 1(2097152 size) used buffers - 36313/36353 (recycle/alloc) - 40/36352 (fetch/transfer)
D/PipelineWatcher( 4211): onInputBufferReleased: frameIndex not found (66041); ignored
D/BufferPoolAccessor2.0( 4211): bufferpool2 0xb4000077530e53a8 : 5(10485760 size) total buffers - 1(2097152 size) used buffers - 36004/36015 (recycle/alloc) - 11/36014 (fetch/transfer)
D/EGL_emulation( 4211): app_time_stats: avg=3.54ms min=1.99ms max=13.08ms count=60
D/BufferPoolAccessor2.0( 4211): bufferpool2 0xb40000775317c688 : 5(40960 size) total buffers - 1(8192 size) used buffers - 66298/66322 (recycle/alloc) - 47/65702 (fetch/transfer)
D/BufferPoolAccessor2.0( 4211): bufferpool2 0xb40000775311f798 : 5(40960 size) total buffers - 1(8192 size) used buffers - 65755/65761 (recycle/alloc) - 8/65123 (fetch/transfer)
D/BufferPoolAccessor2.0( 4211): bufferpool2 0xb400007753136058 : 5(10485760 size) total buffers - 1(2097152 size) used buffers - 36320/36345 (recycle/alloc) - 25/36344 (fetch/transfer)
D/BufferPoolAccessor2.0( 4211): bufferpool2 0xb4000077531ce5b8 : 5(40960 size) total buffers - 1(8192 size) used buffers - 65741/65747 (recycle/alloc) - 14/65131 (fetch/transfer)
D/BufferPoolAccessor2.0( 4211): bufferpool2 0xb400007753121a48 : 5(10485760 size) total buffers - 1(2097152 size) used buffers - 36330/36361 (recycle/alloc) - 31/36360 (fetch/transfer)
D/EGL_emulation( 4211): app_time_stats: avg=3.59ms min=1.98ms max=10.28ms count=60
D/BufferPoolAccessor2.0( 4211): bufferpool2 0xb40000775319b7b8 : 5(40960 size) total buffers - 1(8192 size) used buffers - 66331/66354 (recycle/alloc) - 48/65737 (fetch/transfer)
D/BufferPoolAccessor2.0( 4211): bufferpool2 0xb4000077531cb9c8 : 5(40960 size) total buffers - 1(8192 size) used buffers - 66340/66359 (recycle/alloc) - 46/65740 (fetch/transfer)
D/BufferPoolAccessor2.0( 4211): bufferpool2 0xb400007753193f78 : 5(10485760 size) total buffers - 2(4194304 size) used buffers - 36054/36067 (recycle/alloc) - 13/36065 (fetch/transfer)
D/BufferPoolAccessor2.0( 4211): bufferpool2 0xb400007753132d78 : 5(40960 size) total buffers - 1(8192 size) used buffers - 66355/66377 (recycle/alloc) - 46/65750 (fetch/transfer)
D/MediaCodec( 4211): keep callback message for reclaim
I/CCodecConfig( 4211): query failed after returning 19 values (BAD_INDEX)
W/Codec2Client( 4211): query -- param skipped: index = 1342179345.
W/Codec2Client( 4211): query -- param skipped: index = 2415921170.
W/Codec2Client( 4211): query -- param skipped: index = 1610614798.
D/EGL_emulation( 4211): app_time_stats: avg=3.70ms min=2.01ms max=18.47ms count=60
D/MediaCodec( 4211): keep callback message for reclaim
I/CCodecConfig( 4211): query failed after returning 19 values (BAD_INDEX)
W/Codec2Client( 4211): query -- param skipped: index = 1342179345.
W/Codec2Client( 4211): query -- param skipped: index = 2415921170.
W/Codec2Client( 4211): query -- param skipped: index = 1610614798.




2. Hardcoded string should replaced by possible enums or static variables (class level)
3. follow the coding pattern clean and concise like the repo hulkenstein itself (except from video other features are clean enough)

4. clone this repo - https://github.com/Meshkat-Shadik/Hulkenstein , and then use this plugin to this repo's main branch -> new_native_player and implement the full feature of enc/dec and the video_player integration of secure_video_player