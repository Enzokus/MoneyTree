import 'dart:math' as math;

import 'package:flutter/material.dart';

const treeAsset = 'assets/images/tree.png';
const leafAsset = 'assets/images/leaf.png';
const leafImageSize = 85.0;
// Leaf base in the supplied square PNG, including transparent margins.
const leafBase = Offset(.423, .868);

Rect treeImageRect(Size area) {
  final side = math.min(area.width * 1.12, (area.height * .98 - 70) / .825);
  return Rect.fromLTWH(
    (area.width - side) / 2,
    area.height * .98 - side * .91,
    side,
    side,
  );
}

// Branch tips in the supplied tree image's square canvas.
const treeLeafAnchors = <Offset>[
  Offset(.500, .085),
  Offset(.423, .147),
  Offset(.577, .147),
  Offset(.323, .189),
  Offset(.677, .189),
  Offset(.217, .298),
  Offset(.783, .298),
  Offset(.390, .350),
  Offset(.610, .350),
  Offset(.220, .438),
  Offset(.780, .438),
  Offset(.322, .572),
  Offset(.678, .572),
  Offset(.215, .500),
];

// The ground at the root of the tree follows the image layout.
double treeGroundY(Size area) {
  final rect = treeImageRect(area);
  return rect.top + rect.height * .91;
}
