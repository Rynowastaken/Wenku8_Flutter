import 'dart:math' as math;
import 'dart:ui' show DisplayFeature, DisplayFeatureState, DisplayFeatureType;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

/// One pagination width for both leaves, including off-centre hardware hinges.
/// Rectangles are viewport-local; reading order is applied by ReaderBookSpread.
class ReaderBookLayout {
  const ReaderBookLayout._(
    this.viewport,
    this.pages,
    this.spine, {
    this.isBunkobon = false,
  });

  /// Japanese Bunkobon (A6: 105 mm × 148 mm) text-block proportions on tablets.
  static const double bunkobonAspectRatio = 105 / 148;
  static const double maxBunkobonWidth = 510;
  static const double maxBunkobonHeight =
      maxBunkobonWidth / bunkobonAspectRatio;

  static bool isTabletViewport(Size size) => size.shortestSide >= 560;

  /// Compact Bunkobon font size and line height on tablet and portrait mobile
  /// viewports (~15 columns on tablets and compact phones at default settings).
  static ({double fontSize, double lineHeight}) bunkobonTypography(
    Size screenSize, {
    required double fontSize,
    required double lineHeight,
  }) {
    if (isTabletViewport(screenSize)) {
      return (
        fontSize: (fontSize * .88).clamp(10.0, 27.0),
        lineHeight: (lineHeight * .93).clamp(1.25, 2.2),
      );
    }
    if (screenSize.height > screenSize.width && screenSize.height >= 500) {
      return (
        fontSize: (fontSize * .70).clamp(10.5, 22.0),
        lineHeight: (lineHeight * .84).clamp(1.25, 2.0),
      );
    }
    return (fontSize: fontSize, lineHeight: lineHeight);
  }

  /// Horizontal margins that center scroll prose within Bunkobon width on tablets
  /// while preserving responsiveness to user left/right margin adjustments.
  static ({double left, double right}) scrollMargins({
    required Size screenSize,
    required EdgeInsets safe,
    required double leftMargin,
    required double rightMargin,
  }) {
    if (!isTabletViewport(screenSize)) {
      return (left: leftMargin, right: rightMargin);
    }
    final available = screenSize.width - safe.horizontal;
    final column = math.min(available, maxBunkobonWidth + 52);
    final extra = math.max(0.0, available - column);
    final maxTotalMargin = math.max(0.0, column - 180);
    final total = leftMargin + rightMargin;
    final scale = total > maxTotalMargin && total > 0
        ? maxTotalMargin / total
        : 1.0;
    return (
      left: leftMargin * scale + extra / 2,
      right: rightMargin * scale + extra / 2,
    );
  }

  final Size viewport;
  final List<Rect> pages;
  final Rect? spine;
  final bool isBunkobon;
  int get count => pages.length;
  Size get pageSize => pages.first.size;
  Object get key =>
      (viewport, pages.first, pages.last, count, spine, isBunkobon);

  /// Paper reaches the screen edges while pagination keeps its text rectangle.
  Rect frameFor(int index, EdgeInsets insets) {
    final body = pages[index].shift(Offset(insets.left, insets.top));
    return Rect.fromLTRB(
      index == 0 ? 0 : body.left,
      0,
      index == count - 1 ? viewport.width + insets.horizontal : body.right,
      viewport.height + insets.vertical,
    );
  }

  factory ReaderBookLayout.resolve({
    required Size viewport,
    required double margin,
    EdgeInsets? marginInsets,
    List<DisplayFeature> features = const [],
    Offset origin = Offset.zero,
  }) {
    var area = Offset.zero & viewport;
    final resolvedMargins =
        marginInsets ?? EdgeInsets.symmetric(horizontal: margin, vertical: 8);
    Rect? hinge;
    for (final feature in features) {
      if (feature.type != DisplayFeatureType.hinge &&
          feature.type != DisplayFeatureType.fold) {
        continue;
      }
      final bounds = feature.bounds.shift(-origin);
      final vertical = bounds.height > bounds.width;
      // A fully opened flexible display has a crease, not two separate panes.
      // Treating its zero-width fold as a hinge made compact inner screens fall
      // below the two-page threshold and render only the left half of the book.
      final occludes = vertical ? bounds.width > 0 : bounds.height > 0;
      if (feature.type == DisplayFeatureType.fold &&
          !occludes &&
          feature.state != DisplayFeatureState.postureHalfOpened) {
        continue;
      }
      if (vertical &&
          bounds.left > area.left &&
          bounds.right < area.right &&
          bounds.bottom > area.top &&
          bounds.top < area.bottom) {
        hinge = bounds;
      } else if (!vertical &&
          bounds.width > area.width / 2 &&
          bounds.top > area.top &&
          bounds.bottom < area.bottom &&
          (bounds.height > 0 ||
              feature.state == DisplayFeatureState.postureHalfOpened)) {
        // A tabletop fold uses the larger unobstructed pane, never text across
        // the physical hinge. Flat, zero-width crease metadata costs no space.
        area = bounds.top - area.top >= area.bottom - bounds.bottom
            ? Rect.fromLTRB(area.left, area.top, area.right, bounds.top - 12)
            : Rect.fromLTRB(
                area.left,
                bounds.bottom + 12,
                area.right,
                area.bottom,
              );
      }
    }
    final isTablet =
        hinge == null &&
        math.min(area.width + margin * 2, area.height + 100) >= 580 &&
        area.height >= 500;
    Size bunkobonSize(double maxWidth, double maxHeight) {
      var pageWidth = math.min(maxWidth, maxBunkobonWidth);
      var pageHeight = math.min(maxHeight, pageWidth / bunkobonAspectRatio);
      pageWidth = math.min(pageWidth, pageHeight * bunkobonAspectRatio);
      return Size(pageWidth, pageHeight);
    }

    double insetSpan(double available, double slack) => math.max(
      math.min(available, 200.0),
      math.min(available, available - slack),
    );

    final dH = resolvedMargins.horizontal - 52;
    final dV = resolvedMargins.vertical - 16;
    final baseW = math.max(1.0, area.width + dH);
    final baseH = math.max(1.0, area.height + dV);

    final gutter = math.max(40.0, margin * 2);
    final leftEnd = hinge == null
        ? area.center.dx - gutter / 2
        : hinge.left - margin;
    final rightStart = hinge == null
        ? area.center.dx + gutter / 2
        : hinge.right + margin;
    final width = math.min(leftEnd - area.left, area.right - rightStart);
    if ((hinge != null || area.width > area.height) &&
        area.width + margin * 2 >= 720 &&
        area.height >= 220 &&
        width >= 300) {
      late final Size leaf;
      late final double leafTop;
      if (isTablet) {
        final baseLeafWidth = math.max(1.0, (baseW - 52.0) / 2);
        final baseLeaf = bunkobonSize(
          baseLeafWidth,
          math.max(220, baseH - 24),
        );
        final slackX = math.max(0.0, baseLeafWidth - baseLeaf.width);
        final slackY = math.max(0.0, baseH - baseLeaf.height);
        leaf = Size(
          insetSpan(width, slackX),
          insetSpan(area.height, slackY),
        );
        leafTop =
            area.top + (area.height - leaf.height).clamp(0.0, slackY) / 2;
      } else {
        leaf = Size(width, area.height);
        leafTop = area.top + (area.height - leaf.height) / 2;
      }
      return ReaderBookLayout._(
        viewport,
        [
          Rect.fromLTWH(leftEnd - leaf.width, leafTop, leaf.width, leaf.height),
          Rect.fromLTWH(rightStart, leafTop, leaf.width, leaf.height),
        ],
        hinge == null
            ? Rect.fromLTWH(area.center.dx - 12, leafTop, 24, leaf.height)
            : null,
        isBunkobon: isTablet,
      );
    }
    if (hinge != null) {
      area = leftEnd - area.left >= area.right - rightStart
          ? Rect.fromLTRB(area.left, area.top, leftEnd, area.bottom)
          : Rect.fromLTRB(rightStart, area.top, area.right, area.bottom);
    } else if (isTablet ||
        (area.height > area.width && area.height >= 420 && area.width >= 260)) {
      final baseMaxWidth = isTablet
          ? baseW
          : math.max(240.0, baseW - 12);
      final basePage = bunkobonSize(
        baseMaxWidth,
        math.max(220, baseH - 24),
      );
      final slackX = math.max(0.0, baseW - basePage.width);
      final slackY = math.max(0.0, baseH - basePage.height);
      final targetWidth = insetSpan(area.width, slackX);
      final targetHeight = insetSpan(area.height, slackY);
      area = Rect.fromLTWH(
        area.left + (area.width - targetWidth).clamp(0.0, slackX) / 2,
        area.top + (area.height - targetHeight).clamp(0.0, slackY) / 2,
        targetWidth,
        targetHeight,
      );
      return ReaderBookLayout._(viewport, [area], null, isBunkobon: true);
    }
    return ReaderBookLayout._(viewport, [area], null);
  }
}

class ReaderBookSpread extends StatelessWidget {
  const ReaderBookSpread({
    super.key,
    required this.layout,
    required this.pages,
    this.rightToLeft = false,
    this.edgeOverflow = 0,
    this.verticalOverflow = 0,
    this.clipLeaves = true,
    this.frameInsets,
  });
  final ReaderBookLayout layout;
  final List<Widget> pages;
  final bool rightToLeft;
  final double edgeOverflow;
  final double verticalOverflow;
  final bool clipLeaves;
  final EdgeInsets? frameInsets;

  @override
  Widget build(BuildContext context) => Stack(
    clipBehavior: Clip.none,
    children: [
      if (layout.spine case final spine?)
        Positioned.fromRect(
          rect: frameInsets == null
              ? spine
              : layout.isBunkobon
              ? spine.shift(Offset(frameInsets!.left, frameInsets!.top))
              : Rect.fromLTWH(
                  spine.left + frameInsets!.left,
                  0,
                  spine.width,
                  layout.viewport.height + frameInsets!.vertical,
                ),
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    Colors.transparent,
                    Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: .045),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),
        ),
      for (var index = 0; index < pages.length; index++)
        Positioned.fromRect(
          rect: frameInsets == null
              ? layout.pages[rightToLeft ? layout.count - 1 - index : index]
              : layout.frameFor(
                  rightToLeft ? layout.count - 1 - index : index,
                  frameInsets!,
                ),
          child: Semantics(
            sortKey: OrdinalSortKey(index.toDouble()),
            child: ClipRect(
              clipBehavior: clipLeaves ? Clip.hardEdge : Clip.none,
              clipper: edgeOverflow == 0 && verticalOverflow == 0
                  ? null
                  : _BookTurnClip(
                      vertical: verticalOverflow,
                      left:
                          (rightToLeft ? layout.count - 1 - index : index) == 0
                          ? edgeOverflow
                          : 0,
                      right:
                          (rightToLeft ? layout.count - 1 - index : index) ==
                              layout.count - 1
                          ? edgeOverflow
                          : 0,
                    ),
              child: pages[index],
            ),
          ),
        ),
    ],
  );
}

class _BookTurnClip extends CustomClipper<Rect> {
  const _BookTurnClip({
    required this.left,
    required this.right,
    this.vertical = 0,
  });
  final double left, right, vertical;
  @override
  Rect getClip(Size size) => Rect.fromLTRB(
    -left,
    -vertical,
    size.width + right,
    size.height + vertical,
  );
  @override
  bool shouldReclip(_BookTurnClip oldClipper) =>
      left != oldClipper.left ||
      right != oldClipper.right ||
      vertical != oldClipper.vertical;
}
