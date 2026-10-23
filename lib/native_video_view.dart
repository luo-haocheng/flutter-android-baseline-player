import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

class NativeVideoView extends StatelessWidget {
  const NativeVideoView({super.key});

  @override
  Widget build(BuildContext context) {
    const viewType = 'native_video_view';

    return PlatformViewLink(
      viewType: viewType,
      surfaceFactory: (context, controller) {
        return AndroidViewSurface(
          controller: controller as AndroidViewController,
          gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
          hitTestBehavior: PlatformViewHitTestBehavior.opaque,
        );
      },
      onCreatePlatformView: (p) {
        return PlatformViewsService.initSurfaceAndroidView(
          id: p.id,
          viewType: viewType,
          layoutDirection: TextDirection.ltr,
          creationParams: const <String, dynamic>{},
          creationParamsCodec: const StandardMessageCodec(),
          onFocus: () => p.onFocusChanged(true),
        )
          ..addOnPlatformViewCreatedListener(p.onPlatformViewCreated)
          ..create();
      },
    );
  }
}
