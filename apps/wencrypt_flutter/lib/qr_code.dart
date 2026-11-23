import 'dart:convert';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';

enum QrErrorCorrection { low, medium }

class _QrVersionSpec {
  const _QrVersionSpec({
    required this.version,
    required this.align,
    required this.ecPerBlockL,
    required this.blocksL,
    required this.ecPerBlockM,
    required this.blocksM,
  });

  final int version;
  final List<int> align;
  final int ecPerBlockL;
  final List<int> blocksL;
  final int ecPerBlockM;
  final List<int> blocksM;

  int totalDataBytes(QrErrorCorrection ecc) {
    final blocks = ecc == QrErrorCorrection.low ? blocksL : blocksM;
    var sum = 0;
    for (final b in blocks) {
      sum += b;
    }
    return sum;
  }

  int maxByteCapacity(QrErrorCorrection ecc) {
    final headerBits = version <= 9 ? 12 : 20;
    return (totalDataBytes(ecc) * 8 - headerBits) ~/ 8;
  }
}

const List<_QrVersionSpec> _qrSpecs = [
  _QrVersionSpec(version: 1, align: [], ecPerBlockL: 7, blocksL: [19], ecPerBlockM: 10, blocksM: [16]),
  _QrVersionSpec(version: 2, align: [6, 18], ecPerBlockL: 10, blocksL: [34], ecPerBlockM: 16, blocksM: [28]),
  _QrVersionSpec(version: 3, align: [6, 22], ecPerBlockL: 15, blocksL: [55], ecPerBlockM: 26, blocksM: [44]),
  _QrVersionSpec(version: 4, align: [6, 26], ecPerBlockL: 20, blocksL: [80], ecPerBlockM: 18, blocksM: [32, 32]),
  _QrVersionSpec(version: 5, align: [6, 30], ecPerBlockL: 26, blocksL: [108], ecPerBlockM: 24, blocksM: [43, 43]),
  _QrVersionSpec(version: 6, align: [6, 34], ecPerBlockL: 18, blocksL: [68, 68], ecPerBlockM: 16, blocksM: [27, 27, 27, 27]),
  _QrVersionSpec(version: 7, align: [6, 22, 38], ecPerBlockL: 20, blocksL: [78, 78], ecPerBlockM: 18, blocksM: [31, 31, 31, 31]),
  _QrVersionSpec(version: 8, align: [6, 24, 42], ecPerBlockL: 24, blocksL: [97, 97], ecPerBlockM: 22, blocksM: [38, 38, 39, 39]),
  _QrVersionSpec(version: 9, align: [6, 26, 46], ecPerBlockL: 30, blocksL: [116, 116], ecPerBlockM: 22, blocksM: [36, 36, 36, 37, 37]),
  _QrVersionSpec(version: 10, align: [6, 28, 50], ecPerBlockL: 18, blocksL: [68, 68, 69, 69], ecPerBlockM: 26, blocksM: [43, 43, 43, 43, 44]),
  _QrVersionSpec(version: 11, align: [6, 30, 54], ecPerBlockL: 20, blocksL: [81, 81, 81, 81], ecPerBlockM: 30, blocksM: [50, 51, 51, 51, 51]),
  _QrVersionSpec(version: 12, align: [6, 32, 58], ecPerBlockL: 24, blocksL: [92, 92, 93, 93], ecPerBlockM: 22, blocksM: [36, 36, 36, 36, 36, 36, 37, 37]),
  _QrVersionSpec(version: 13, align: [6, 34, 62], ecPerBlockL: 26, blocksL: [107, 107, 107, 107], ecPerBlockM: 22, blocksM: [37, 37, 37, 37, 37, 37, 37, 37, 38]),
  _QrVersionSpec(version: 14, align: [6, 26, 46, 66], ecPerBlockL: 30, blocksL: [115, 115, 115, 116], ecPerBlockM: 24, blocksM: [40, 40, 40, 40, 41, 41, 41, 41, 41]),
  _QrVersionSpec(version: 15, align: [6, 26, 48, 70], ecPerBlockL: 22, blocksL: [87, 87, 87, 87, 87, 88], ecPerBlockM: 24, blocksM: [41, 41, 41, 41, 41, 42, 42, 42, 42, 42]),
  _QrVersionSpec(version: 16, align: [6, 26, 50, 74], ecPerBlockL: 24, blocksL: [98, 98, 98, 98, 98, 99], ecPerBlockM: 28, blocksM: [45, 45, 45, 45, 45, 45, 45, 46, 46, 46]),
  _QrVersionSpec(version: 17, align: [6, 30, 54, 78], ecPerBlockL: 28, blocksL: [107, 108, 108, 108, 108, 108], ecPerBlockM: 28, blocksM: [46, 46, 46, 46, 46, 46, 46, 46, 46, 46, 47]),
  _QrVersionSpec(version: 18, align: [6, 30, 56, 82], ecPerBlockL: 30, blocksL: [120, 120, 120, 120, 120, 121], ecPerBlockM: 26, blocksM: [43, 43, 43, 43, 43, 43, 43, 43, 43, 44, 44, 44, 44]),
  _QrVersionSpec(version: 19, align: [6, 30, 58, 86], ecPerBlockL: 28, blocksL: [113, 113, 113, 114, 114, 114, 114], ecPerBlockM: 26, blocksM: [44, 44, 44, 45, 45, 45, 45, 45, 45, 45, 45, 45, 45, 45]),
  _QrVersionSpec(version: 20, align: [6, 34, 62, 90], ecPerBlockL: 28, blocksL: [107, 107, 107, 108, 108, 108, 108, 108], ecPerBlockM: 26, blocksM: [41, 41, 41, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42]),
];

class _Gf256 {
  static final Uint8List exp = _buildExp();
  static final Uint8List log = _buildLog(exp);

  static Uint8List _buildExp() {
    final table = Uint8List(512);
    var x = 1;
    for (var i = 0; i < 255; i++) {
      table[i] = x;
      table[i + 255] = x;
      x <<= 1;
      if ((x & 0x100) != 0) x ^= 0x11d;
    }
    return table;
  }

  static Uint8List _buildLog(Uint8List expTable) {
    final table = Uint8List(256);
    for (var i = 0; i < 255; i++) {
      table[expTable[i]] = i;
    }
    return table;
  }

  static int mul(int a, int b) {
    if (a == 0 || b == 0) return 0;
    return exp[log[a] + log[b]];
  }

  static Uint8List generatorPoly(int degree) {
    var poly = <int>[1];
    for (var i = 0; i < degree; i++) {
      final next = List<int>.filled(poly.length + 1, 0);
      final root = exp[i];
      for (var j = 0; j < poly.length; j++) {
        next[j] ^= poly[j];
        next[j + 1] ^= mul(poly[j], root);
      }
      poly = next;
    }
    return Uint8List.fromList(poly);
  }

  static Uint8List reedSolomon(Uint8List data, int ecCount) {
    final gen = generatorPoly(ecCount);
    final work = Uint8List(data.length + ecCount);
    work.setRange(0, data.length, data);
    for (var i = 0; i < data.length; i++) {
      final factor = work[i];
      if (factor == 0) continue;
      for (var j = 0; j < gen.length; j++) {
        work[i + j] ^= mul(gen[j], factor);
      }
    }
    return Uint8List.sublistView(work, data.length);
  }
}

class QrMatrix {
  const QrMatrix._({
    required this.version,
    required this.size,
    required this.ecc,
    required this.modules,
  });

  final int version;
  final int size;
  final QrErrorCorrection ecc;
  final Uint8List modules;

  bool isDark(int x, int y) => modules[y * size + x] != 0;

  static QrMatrix encode(
    String text, {
    QrErrorCorrection ecc = QrErrorCorrection.medium,
  }) {
    final payload = Uint8List.fromList(utf8.encode(text));
    var chosenEcc = ecc;
    _QrVersionSpec? spec;
    for (final candidate in _qrSpecs) {
      if (payload.length <= candidate.maxByteCapacity(chosenEcc)) {
        spec = candidate;
        break;
      }
    }
    if (spec == null && chosenEcc == QrErrorCorrection.medium) {
      chosenEcc = QrErrorCorrection.low;
      for (final candidate in _qrSpecs) {
        if (payload.length <= candidate.maxByteCapacity(chosenEcc)) {
          spec = candidate;
          break;
        }
      }
    }
    if (spec == null) {
      throw ArgumentError.value(payload.length, 'text', 'QR payload exceeds capacity');
    }

    final codewords = _buildCodewords(payload, spec, chosenEcc);
    final size = spec.version * 4 + 17;
    final fixed = Uint8List(size * size);
    final base = Uint8List(size * size);
    _placeFunctionPatterns(spec, size, base, fixed);

    final bits = _toBitStream(codewords, spec.version);
    _placeDataBits(size, bits, base, fixed);

    var bestScore = 1 << 30;
    Uint8List? best;
    for (var mask = 0; mask < 8; mask++) {
      final candidate = Uint8List.fromList(base);
      _applyMask(size, candidate, fixed, mask);
      _writeFormatInfo(size, candidate, chosenEcc, mask);
      if (spec.version >= 7) {
        _writeVersionInfo(size, spec.version, candidate);
      }
      final score = _penaltyScore(size, candidate);
      if (score < bestScore) {
        bestScore = score;
        best = candidate;
      }
    }
    return QrMatrix._(
      version: spec.version,
      size: size,
      ecc: chosenEcc,
      modules: best!,
    );
  }

  static Uint8List _buildCodewords(
    Uint8List payload,
    _QrVersionSpec spec,
    QrErrorCorrection ecc,
  ) {
    final totalData = spec.totalDataBytes(ecc);
    final totalBits = totalData * 8;
    final bits = <int>[];

    void appendBits(int value, int count) {
      for (var i = count - 1; i >= 0; i--) {
        bits.add((value >> i) & 1);
      }
    }

    // Mode 0100 = Byte
    appendBits(0x4, 4);
    appendBits(payload.length, spec.version <= 9 ? 8 : 16);
    for (final byte in payload) {
      appendBits(byte, 8);
    }

    final terminator = (totalBits - bits.length).clamp(0, 4);
    for (var i = 0; i < terminator; i++) {
      bits.add(0);
    }
    while (bits.length % 8 != 0) {
      bits.add(0);
    }

    final dataBytes = Uint8List(totalData);
    final byteCount = bits.length ~/ 8;
    for (var i = 0; i < byteCount; i++) {
      var b = 0;
      for (var bit = 0; bit < 8; bit++) {
        b = (b << 1) | bits[i * 8 + bit];
      }
      dataBytes[i] = b;
    }
    var padIndex = 0;
    for (var i = byteCount; i < totalData; i++) {
      dataBytes[i] = (padIndex++ & 1) == 0 ? 0xec : 0x11;
    }

    final blockSizes = ecc == QrErrorCorrection.low ? spec.blocksL : spec.blocksM;
    final ecCount = ecc == QrErrorCorrection.low ? spec.ecPerBlockL : spec.ecPerBlockM;
    final dataBlocks = <Uint8List>[];
    final ecBlocks = <Uint8List>[];
    var offset = 0;
    var maxDataLen = 0;
    for (final len in blockSizes) {
      final block = Uint8List.sublistView(dataBytes, offset, offset + len);
      offset += len;
      if (len > maxDataLen) maxDataLen = len;
      dataBlocks.add(block);
      ecBlocks.add(_Gf256.reedSolomon(block, ecCount));
    }

    final result = BytesBuilder(copy: false);
    for (var i = 0; i < maxDataLen; i++) {
      for (final block in dataBlocks) {
        if (i < block.length) result.addByte(block[i]);
      }
    }
    for (var i = 0; i < ecCount; i++) {
      for (final block in ecBlocks) {
        result.addByte(block[i]);
      }
    }
    return result.toBytes();
  }

  static List<int> _toBitStream(Uint8List codewords, int version) {
    final remainder = version >= 2 && version <= 6
        ? 7
        : (version >= 14 ? 3 : 0);
    final bits = List<int>.filled(codewords.length * 8 + remainder, 0);
    for (var i = 0; i < codewords.length; i++) {
      final b = codewords[i];
      for (var bit = 0; bit < 8; bit++) {
        bits[i * 8 + bit] = (b >> (7 - bit)) & 1;
      }
    }
    return bits;
  }

  static void _setFixed(
    Uint8List grid,
    Uint8List fixed,
    int size,
    int x,
    int y,
    bool dark,
  ) {
    final idx = y * size + x;
    grid[idx] = dark ? 1 : 0;
    fixed[idx] = 1;
  }

  static void _placeFinder(
    Uint8List grid,
    Uint8List fixed,
    int size,
    int ox,
    int oy,
  ) {
    for (var dy = -1; dy <= 7; dy++) {
      for (var dx = -1; dx <= 7; dx++) {
        final x = ox + dx;
        final y = oy + dy;
        if (x < 0 || x >= size || y < 0 || y >= size) continue;
        final inBox = dx >= 0 && dx <= 6 && dy >= 0 && dy <= 6;
        final dark =
            inBox &&
            (dx == 0 ||
                dx == 6 ||
                dy == 0 ||
                dy == 6 ||
                (dx >= 2 && dx <= 4 && dy >= 2 && dy <= 4));
        _setFixed(grid, fixed, size, x, y, dark);
      }
    }
  }

  static void _placeAlignment(
    Uint8List grid,
    Uint8List fixed,
    int size,
    int cx,
    int cy,
  ) {
    for (var dy = -2; dy <= 2; dy++) {
      for (var dx = -2; dx <= 2; dx++) {
        final dark =
            dx.abs() == 2 || dy.abs() == 2 || (dx == 0 && dy == 0);
        _setFixed(grid, fixed, size, cx + dx, cy + dy, dark);
      }
    }
  }

  static void _placeFunctionPatterns(
    _QrVersionSpec spec,
    int size,
    Uint8List grid,
    Uint8List fixed,
  ) {
    _placeFinder(grid, fixed, size, 0, 0);
    _placeFinder(grid, fixed, size, size - 7, 0);
    _placeFinder(grid, fixed, size, 0, size - 7);

    // Alignment patterns (skip corners overlapping finders).
    final coords = spec.align;
    for (var i = 0; i < coords.length; i++) {
      for (var j = 0; j < coords.length; j++) {
        final isCorner =
            (i == 0 && j == 0) ||
            (i == 0 && j == coords.length - 1) ||
            (i == coords.length - 1 && j == 0);
        if (isCorner) continue;
        _placeAlignment(grid, fixed, size, coords[i], coords[j]);
      }
    }

    // Timing patterns.
    for (var i = 8; i < size - 8; i++) {
      final dark = (i & 1) == 0;
      _setFixed(grid, fixed, size, i, 6, dark);
      _setFixed(grid, fixed, size, 6, i, dark);
    }

    // Dark module.
    _setFixed(grid, fixed, size, 8, spec.version * 4 + 9, true);

    // Reserve format information slots.
    for (var i = 0; i < 9; i++) {
      if (i != 6) {
        fixed[8 * size + i] = 1;
        fixed[i * size + 8] = 1;
      }
    }
    for (var i = size - 8; i < size; i++) {
      fixed[8 * size + i] = 1;
    }
    for (var i = size - 7; i < size; i++) {
      fixed[i * size + 8] = 1;
    }

    // Reserve version information slots (v7+).
    if (spec.version >= 7) {
      for (var a = 0; a < 6; a++) {
        for (var b = size - 11; b < size - 8; b++) {
          fixed[a * size + b] = 1;
          fixed[b * size + a] = 1;
        }
      }
    }
  }

  static void _placeDataBits(
    int size,
    List<int> bits,
    Uint8List grid,
    Uint8List fixed,
  ) {
    var bitIndex = 0;
    var upward = true;
    for (var right = size - 1; right >= 1; right -= 2) {
      if (right == 6) right--;
      for (var step = 0; step < size; step++) {
        final y = upward ? size - 1 - step : step;
        for (var dx = 0; dx < 2; dx++) {
          final x = right - dx;
          final idx = y * size + x;
          if (fixed[idx] == 0) {
            grid[idx] = bitIndex < bits.length ? bits[bitIndex++] : 0;
          }
        }
      }
      upward = !upward;
    }
  }

  static bool _maskCondition(int mask, int row, int col) => switch (mask) {
    0 => (row + col) % 2 == 0,
    1 => row % 2 == 0,
    2 => col % 3 == 0,
    3 => (row + col) % 3 == 0,
    4 => ((row ~/ 2) + (col ~/ 3)) % 2 == 0,
    5 => (row * col) % 2 + (row * col) % 3 == 0,
    6 => ((row * col) % 2 + (row * col) % 3) % 2 == 0,
    _ => ((row + col) % 2 + (row * col) % 3) % 2 == 0,
  };

  static void _applyMask(
    int size,
    Uint8List grid,
    Uint8List fixed,
    int mask,
  ) {
    for (var y = 0; y < size; y++) {
      for (var x = 0; x < size; x++) {
        final idx = y * size + x;
        if (fixed[idx] == 0 && _maskCondition(mask, y, x)) {
          grid[idx] ^= 1;
        }
      }
    }
  }

  static void _writeFormatInfo(
    int size,
    Uint8List grid,
    QrErrorCorrection ecc,
    int mask,
  ) {
    final eccBits = ecc == QrErrorCorrection.low ? 1 : 0;
    final data = (eccBits << 3) | mask;
    var rem = data << 10;
    for (var i = 4; i >= 0; i--) {
      if ((rem & (1 << (i + 10))) != 0) {
        rem ^= 0x537 << i;
      }
    }
    final bits = ((data << 10) | rem) ^ 0x5412;

    for (var i = 0; i < 15; i++) {
      final bit = (bits >> i) & 1;
      // Top-left vertical then horizontal (i=0 at top-right of finder).
      if (i < 6) {
        grid[i * size + 8] = bit;
      } else if (i < 8) {
        grid[(i + 1) * size + 8] = bit;
      } else {
        grid[8 * size + (14 - i)] = bit;
      }

      // Bottom-left and top-right copies.
      if (i < 8) {
        grid[8 * size + (size - 1 - i)] = bit;
      } else {
        grid[(size - 15 + i) * size + 8] = bit;
      }
    }
  }

  static void _writeVersionInfo(int size, int version, Uint8List grid) {
    var rem = version << 12;
    for (var i = 5; i >= 0; i--) {
      if ((rem & (1 << (i + 12))) != 0) {
        rem ^= 0x1f25 << i;
      }
    }
    final bits = (version << 12) | rem;
    for (var i = 0; i < 18; i++) {
      final bit = (bits >> i) & 1;
      final a = i ~/ 3;
      final b = (i % 3) + size - 11;
      grid[a * size + b] = bit;
      grid[b * size + a] = bit;
    }
  }

  static int _penaltyScore(int size, Uint8List grid) {
    var penalty = 0;
    var darkCount = 0;

    // N1 + N3 horizontal
    for (var y = 0; y < size; y++) {
      var runColor = -1;
      var runLen = 0;
      var window = 0;
      for (var x = 0; x < size; x++) {
        final v = grid[y * size + x];
        darkCount += v;
        if (v == runColor) {
          runLen++;
        } else {
          if (runLen >= 5) penalty += 3 + (runLen - 5);
          runColor = v;
          runLen = 1;
        }
        window = ((window << 1) | v) & 0x7ff;
        if (x >= 10 && (window == 0x5d0 || window == 0x05d)) {
          penalty += 40;
        }
      }
      if (runLen >= 5) penalty += 3 + (runLen - 5);
    }

    // N1 + N3 vertical
    for (var x = 0; x < size; x++) {
      var runColor = -1;
      var runLen = 0;
      var window = 0;
      for (var y = 0; y < size; y++) {
        final v = grid[y * size + x];
        if (v == runColor) {
          runLen++;
        } else {
          if (runLen >= 5) penalty += 3 + (runLen - 5);
          runColor = v;
          runLen = 1;
        }
        window = ((window << 1) | v) & 0x7ff;
        if (y >= 10 && (window == 0x5d0 || window == 0x05d)) {
          penalty += 40;
        }
      }
      if (runLen >= 5) penalty += 3 + (runLen - 5);
    }

    // N2: 2x2 blocks
    for (var y = 0; y < size - 1; y++) {
      for (var x = 0; x < size - 1; x++) {
        final v = grid[y * size + x];
        if (grid[y * size + x + 1] == v &&
            grid[(y + 1) * size + x] == v &&
            grid[(y + 1) * size + x + 1] == v) {
          penalty += 3;
        }
      }
    }

    // N4: dark ratio deviation from 50%
    final total = size * size;
    final deviation = (darkCount * 200 - total * 100).abs();
    penalty += (deviation ~/ (total * 10)) * 10;
    return penalty;
  }
}

class WQrCode extends StatelessWidget {
  const WQrCode({
    super.key,
    required this.data,
    this.size = 220,
    this.ecc = QrErrorCorrection.medium,
  });

  final String data;
  final double size;
  final QrErrorCorrection ecc;

  @override
  Widget build(BuildContext context) {
    final matrix = QrMatrix.encode(data, ecc: ecc);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE4E8F0)),
      ),
      clipBehavior: Clip.antiAlias,
      child: CustomPaint(
        size: Size.square(size),
        painter: _QrPainter(matrix),
      ),
    );
  }
}

class _QrPainter extends CustomPainter {
  const _QrPainter(this.matrix);

  final QrMatrix matrix;

  @override
  void paint(Canvas canvas, Size size) {
    const quietZone = 4;
    final totalModules = matrix.size + quietZone * 2;
    final side = size.shortestSide;
    final moduleSize = side / totalModules;
    final offsetX = (size.width - side) / 2;
    final offsetY = (size.height - side) / 2;

    final bgPaint = Paint()..color = Colors.white;
    canvas.drawRect(Offset.zero & size, bgPaint);

    final fgPaint = Paint()
      ..color = const Color(0xFF0F172A)
      ..isAntiAlias = false;

    for (var y = 0; y < matrix.size; y++) {
      for (var x = 0; x < matrix.size; x++) {
        if (matrix.isDark(x, y)) {
          final left = offsetX + (x + quietZone) * moduleSize;
          final top = offsetY + (y + quietZone) * moduleSize;
          final right = offsetX + (x + quietZone + 1) * moduleSize;
          final bottom = offsetY + (y + quietZone + 1) * moduleSize;
          canvas.drawRect(Rect.fromLTRB(left, top, right, bottom), fgPaint);
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant _QrPainter oldDelegate) =>
      oldDelegate.matrix.version != matrix.version ||
      !_listEquals(oldDelegate.matrix.modules, matrix.modules);

  static bool _listEquals(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
