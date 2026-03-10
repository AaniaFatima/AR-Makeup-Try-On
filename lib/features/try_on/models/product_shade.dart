import 'package:flutter/material.dart';

class ProductShade {
  final String productKey;
  final String shadeName;
  final String shadeHex;
  final int shadeOrder;

  ProductShade({
    required this.productKey,
    required this.shadeName,
    required this.shadeHex,
    required this.shadeOrder,
  });

  factory ProductShade.fromMap(Map<String, dynamic> map) {
    return ProductShade(
      productKey: map['product_key'] as String? ?? '',
      shadeName: map['shade_name'] as String? ?? '',
      shadeHex: map['shade_hex'] as String? ?? '#D81B60',
      shadeOrder: (map['shade_order'] as num?)?.toInt() ?? 0,
    );
  }

  Color get color {
    final hex = shadeHex.replaceAll('#', '').trim();
    return Color(int.parse('FF$hex', radix: 16));
  }
}
