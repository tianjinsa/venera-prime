import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Keeps its layout slot fixed while painting and hit-testing above the IME.
class AgentFloatingComposer extends StatelessWidget {
  const AgentFloatingComposer({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(end: MediaQuery.viewInsetsOf(context).bottom),
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 160),
      curve: Curves.easeOutCubic,
      child: RepaintBoundary(child: child),
      builder: (context, inset, child) => _ComposerTranslation(
        inset: inset,
        viewHeight: MediaQuery.sizeOf(context).height,
        child: child!,
      ),
    );
  }
}

class _ComposerTranslation extends SingleChildRenderObjectWidget {
  const _ComposerTranslation({
    required this.inset,
    required this.viewHeight,
    required super.child,
  });

  final double inset;
  final double viewHeight;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderComposerTranslation(inset, viewHeight);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderComposerTranslation renderObject,
  ) {
    renderObject.update(inset, viewHeight);
  }
}

class _RenderComposerTranslation extends RenderProxyBox {
  _RenderComposerTranslation(this._inset, this._viewHeight);

  double _inset;
  double _viewHeight;

  void update(double inset, double viewHeight) {
    if (_inset == inset && _viewHeight == viewHeight) return;
    _inset = inset;
    _viewHeight = viewHeight;
    markNeedsPaint();
    markNeedsSemanticsUpdate();
  }

  Offset get _translation {
    // Account for navigation and safe-area space below the original slot.
    final bottom = localToGlobal(Offset(0, size.height)).dy;
    final covered = math.max(0.0, _inset - (_viewHeight - bottom));
    return Offset(0, -covered);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final translation = _translation;
    layer = context.pushTransform(
      needsCompositing,
      offset,
      Matrix4.translationValues(translation.dx, translation.dy, 0),
      super.paint,
      oldLayer: layer as TransformLayer?,
    );
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    return result.addWithPaintOffset(
      offset: _translation,
      position: position,
      hitTest: (result, position) =>
          child?.hitTest(result, position: position) ?? false,
    );
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    final translation = _translation;
    transform.translateByDouble(translation.dx, translation.dy, 0, 1);
  }
}
