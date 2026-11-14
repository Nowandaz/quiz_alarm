/// The picture of a spotter question. Tap it to open a zoomable view.
/// Works with bundled assets and, later, pictures served by the admin site.
library;

import 'package:material_ui/material_ui.dart';

class QuestionImage extends StatelessWidget {
  final String path;
  final double maxHeight;
  const QuestionImage(this.path, {super.key, this.maxHeight = 220});

  bool get _remote => path.startsWith('http://') || path.startsWith('https://');

  Widget _image({BoxFit fit = BoxFit.contain}) {
    Widget broken(BuildContext context, Object error, StackTrace? stack) =>
        Container(
          height: 120,
          alignment: Alignment.center,
          color: Colors.black12,
          child: const Text('Picture unavailable'),
        );
    return _remote
        ? Image.network(path, fit: fit, errorBuilder: broken)
        : Image.asset(path, fit: fit, errorBuilder: broken);
  }

  @override
  Widget build(BuildContext context) {
    if (path.isEmpty) return const SizedBox.shrink();
    return Semantics(
      label: 'Question picture. Tap to enlarge',
      button: true,
      child: GestureDetector(
        onTap: () => showDialog<void>(
          context: context,
          builder: (ctx) => Dialog.fullscreen(
            backgroundColor: Colors.black,
            child: Stack(
              children: [
                Positioned.fill(
                  child: InteractiveViewer(
                    maxScale: 6,
                    child: Center(child: _image()),
                  ),
                ),
                SafeArea(
                  child: Align(
                    alignment: Alignment.topRight,
                    child: IconButton(
                      icon: const Icon(Icons.close, color: Colors.white),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight),
            child: _image(fit: BoxFit.cover),
          ),
        ),
      ),
    );
  }
}
