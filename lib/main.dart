import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:gallery_saver_plus/gallery_saver.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

List<CameraDescription> cameras = [];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  cameras = await availableCameras();
  runApp(const MyApp());
}

/// -------------------- FILTERS --------------------

enum PhotoFilter {
  none,
  warm,
  cool,
  grayscale,
  vintage,
  dramatic,
}

class FilterPreset {
  final String label;

  // matrix 4x5 length 20 (ใช้ทำไฟล์เซฟให้ติดฟิลเตอร์จริง)
  final List<double> matrix;

  // ใช้ทำ Preview ให้ “เห็นผลชัวร์” ด้วย Overlay
  final Color? overlayColor;
  final double overlayOpacity;

  const FilterPreset({
    required this.label,
    required this.matrix,
    this.overlayColor,
    this.overlayOpacity = 0,
  });
}

const Map<PhotoFilter, FilterPreset> kFilters = {
  PhotoFilter.none: FilterPreset(
    label: 'ปกติ',
    matrix: [
      1, 0, 0, 0, 0,
      0, 1, 0, 0, 0,
      0, 0, 1, 0, 0,
      0, 0, 0, 1, 0,
    ],
  ),
  PhotoFilter.warm: FilterPreset(
    label: 'โทนอุ่น',
    matrix: [
      1.10, 0.00, 0.00, 0, 0,
      0.00, 1.02, 0.00, 0, 0,
      0.00, 0.00, 0.90, 0, 0,
      0.00, 0.00, 0.00, 1, 0,
    ],
    overlayColor: Color(0xFFFFA726),
    overlayOpacity: 0.10,
  ),
  PhotoFilter.cool: FilterPreset(
    label: 'โทนเย็น',
    matrix: [
      0.95, 0.00, 0.00, 0, 0,
      0.00, 1.02, 0.00, 0, 0,
      0.00, 0.00, 1.12, 0, 0,
      0.00, 0.00, 0.00, 1, 0,
    ],
    overlayColor: Color(0xFF42A5F5),
    overlayOpacity: 0.10,
  ),
  PhotoFilter.grayscale: FilterPreset(
    label: 'ขาวดำ',
    matrix: [
      0.2126, 0.7152, 0.0722, 0, 0,
      0.2126, 0.7152, 0.0722, 0, 0,
      0.2126, 0.7152, 0.0722, 0, 0,
      0.0000, 0.0000, 0.0000, 1, 0,
    ],
    // overlay ทำให้ดูเป็น BW “พอประมาณ” แต่ไฟล์ที่เซฟจะเป็น BW จริงจาก matrix
    overlayColor: Color(0xFF000000),
    overlayOpacity: 0.18,
  ),
  PhotoFilter.vintage: FilterPreset(
    label: 'วินเทจ',
    matrix: [
      0.90, 0.05, 0.00, 0, 10,
      0.00, 0.85, 0.00, 0, 10,
      0.00, 0.10, 0.80, 0, 10,
      0.00, 0.00, 0.00, 1, 0,
    ],
    overlayColor: Color(0xFFFFD54F),
    overlayOpacity: 0.10,
  ),
  PhotoFilter.dramatic: FilterPreset(
    label: 'ดราม่า',
    matrix: [
      1.30, -0.10, -0.10, 0, -10,
      -0.10, 1.30, -0.10, 0, -10,
      -0.10, -0.10, 1.30, 0, -10,
      0.00, 0.00, 0.00, 1, 0,
    ],
    overlayColor: Color(0xFF000000),
    overlayOpacity: 0.16,
  ),
};

Uint8List applyColorMatrixToJpegBytes(Uint8List jpegBytes, List<double> m) {
  final decoded = img.decodeImage(jpegBytes);
  if (decoded == null) return jpegBytes;

  int clamp255(num v) => v < 0 ? 0 : (v > 255 ? 255 : v.toInt());

  for (int y = 0; y < decoded.height; y++) {
    for (int x = 0; x < decoded.width; x++) {
      final px = decoded.getPixel(x, y); // Pixel object (image 4.x)

      final r = px.r.toDouble();
      final g = px.g.toDouble();
      final b = px.b.toDouble();
      final a = px.a.toDouble();

      final nr = clamp255(m[0] * r + m[1] * g + m[2] * b + m[3] * a + m[4]);
      final ng = clamp255(m[5] * r + m[6] * g + m[7] * b + m[8] * a + m[9]);
      final nb = clamp255(m[10] * r + m[11] * g + m[12] * b + m[13] * a + m[14]);
      final na = clamp255(m[15] * r + m[16] * g + m[17] * b + m[18] * a + m[19]);

      decoded.setPixelRgba(x, y, nr, ng, nb, na);
    }
  }

  return Uint8List.fromList(img.encodeJpg(decoded, quality: 95));
}

/// -------------------- APP --------------------

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Camera + Filters',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const CameraScreen(),
    );
  }
}

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  CameraController? controller;
  bool _ready = false;

  int selectedCameraIndex = 0;
  PhotoFilter selectedFilter = PhotoFilter.none;

  @override
  void initState() {
    super.initState();
    if (cameras.isNotEmpty) {
      _selectCamera(0);
    }
  }

  Future<void> _refreshCameras({bool keepSelection = true}) async {
    final previous = (selectedCameraIndex >= 0 && selectedCameraIndex < cameras.length)
        ? cameras[selectedCameraIndex]
        : null;

    final fresh = await availableCameras();
    cameras = fresh;
    if (!mounted) return;

    if (fresh.isEmpty) {
      await controller?.dispose();
      controller = null;
      setState(() {
        _ready = false;
        selectedCameraIndex = 0;
      });
      return;
    }

    int nextIndex = 0;
    if (keepSelection && previous != null) {
      final idx = fresh.indexWhere(
        (c) => c.name == previous.name && c.lensDirection == previous.lensDirection,
      );
      if (idx >= 0) nextIndex = idx;
    }

    await _selectCamera(nextIndex);
  }

  Future<void> _selectCamera(int index) async {
    if (index < 0 || index >= cameras.length) return;

    setState(() {
      _ready = false;
      selectedCameraIndex = index;
    });

    await controller?.dispose();

    controller = CameraController(
      cameras[selectedCameraIndex],
      ResolutionPreset.high,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );

    try {
      await controller!.initialize();
      if (!mounted) return;
      setState(() => _ready = true);
    } on CameraException catch (e) {
      debugPrint('Camera init error: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('เปิดกล้องไม่สำเร็จ')),
      );
    }
  }

  String _cameraLabel(CameraDescription cam) {
    final dir = cam.lensDirection.name; // front/back/external
    return '$dir • ${cam.name}';
  }

  Future<void> _takePictureAndSaveFiltered() async {
    final c = controller;
    if (c == null || !c.value.isInitialized) return;
    if (c.value.isTakingPicture) return;

    try {
      final XFile xfile = await c.takePicture();
      final originalBytes = await File(xfile.path).readAsBytes();

      final preset = kFilters[selectedFilter]!;
      final outputBytes = (selectedFilter == PhotoFilter.none)
          ? originalBytes
          : applyColorMatrixToJpegBytes(originalBytes, preset.matrix);

      final dir = await getTemporaryDirectory();
      final outPath = p.join(dir.path, 'filtered_${DateTime.now().millisecondsSinceEpoch}.jpg');
      await File(outPath).writeAsBytes(outputBytes, flush: true);

      final ok = await GallerySaver.saveImage(outPath);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ok == true ? 'บันทึกรูปติดฟิลเตอร์แล้ว ✅' : 'บันทึกไม่สำเร็จ ❌')),
      );
    } catch (e) {
      debugPrint('take/save error: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e')),
      );
    }
  }

  @override
  void dispose() {
    controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final camCount = cameras.length;
    final preset = kFilters[selectedFilter]!;

    return Scaffold(
      appBar: AppBar(
        title: const Text('กล้อง + ฟิลเตอร์'),
        actions: [
          IconButton(
            tooltip: 'รีเฟรชกล้อง',
            onPressed: _refreshCameras,
            icon: const Icon(Icons.refresh),
          ),
          if (camCount > 0)
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<int>(
                  value: selectedCameraIndex,
                  onChanged: (v) {
                    if (v == null) return;
                    _selectCamera(v);
                  },
                  items: List.generate(camCount, (i) {
                    return DropdownMenuItem(
                      value: i,
                      child: Text(_cameraLabel(cameras[i])),
                    );
                  }),
                ),
              ),
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Container(
              color: Colors.black,
              width: double.infinity,
              child: !_ready || controller == null
                  ? const Center(child: CircularProgressIndicator())
                  : Stack(
                      fit: StackFit.expand,
                      children: [
                        CameraPreview(controller!),

                        // ✅ Preview filter (เห็นผลชัวร์)
                        if (preset.overlayColor != null && preset.overlayOpacity > 0)
                          Container(
                            color: preset.overlayColor!.withOpacity(preset.overlayOpacity),
                          ),

                        // เพิ่ม vignette เบา ๆ ให้ดูมีฟีล
                        if (selectedFilter == PhotoFilter.vintage ||
                            selectedFilter == PhotoFilter.dramatic)
                          Container(
                            decoration: BoxDecoration(
                              gradient: RadialGradient(
                                center: Alignment.center,
                                radius: 1.0,
                                colors: [
                                  Colors.transparent,
                                  Colors.black.withOpacity(0.20),
                                ],
                                stops: const [0.65, 1.0],
                              ),
                            ),
                          ),

                        // Label มุมซ้ายบน
                        Positioned(
                          top: 12,
                          left: 12,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                            decoration: BoxDecoration(
                              color: Colors.black54,
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              'Filter: ${preset.label}',
                              style: const TextStyle(color: Colors.white),
                            ),
                          ),
                        ),
                      ],
                    ),
            ),
          ),

          Container(
            color: Colors.black87,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            child: Column(
              children: [
                // Filter chips
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: PhotoFilter.values.map((f) {
                      final isActive = f == selectedFilter;
                      return Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text(kFilters[f]!.label),
                          selected: isActive,
                          onSelected: (_) => setState(() => selectedFilter = f),
                          labelStyle: TextStyle(color: isActive ? Colors.black : Colors.white),
                          selectedColor: Colors.white,
                          backgroundColor: Colors.white24,
                        ),
                      );
                    }).toList(),
                  ),
                ),
                const SizedBox(height: 12),

                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    IconButton(
                      onPressed: camCount < 2
                          ? null
                          : () {
                              final next = (selectedCameraIndex + 1) % camCount;
                              _selectCamera(next);
                            },
                      icon: const Icon(Icons.cameraswitch, color: Colors.white, size: 30),
                    ),
                    FloatingActionButton(
                      backgroundColor: Colors.white,
                      onPressed: _takePictureAndSaveFiltered,
                      child: const Icon(Icons.camera_alt, color: Colors.black, size: 34),
                    ),
                    const SizedBox(width: 30),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
