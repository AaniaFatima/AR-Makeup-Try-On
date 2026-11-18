import 'package:flutter_test/flutter_test.dart';
import 'package:makeup_tryon/app/utils/demo_looks.dart';

void main() {
  test('wear order is foundation, eyes, cheeks, then lips', () {
    final lines = wearOrderForItems(
      [
        {
          'product_key': 'lip_mac_matte',
          'intensity': 70,
          'layer_order': 1,
        },
        {
          'product_key': 'esh_elf_bite_size',
          'intensity': 40,
          'layer_order': 2,
        },
        {
          'product_key': 'fnd_covergirl_clean',
          'intensity': 35,
          'layer_order': 3,
        },
        {
          'product_key': 'blu_nyx_sweet_cheeks',
          'intensity': 50,
          'layer_order': 4,
        },
        {
          'product_key': 'gone_product',
          'intensity': 10,
          'layer_order': 5,
        },
      ],
      titleFor: (item) {
        final key = item['product_key']?.toString() ?? '';
        if (key == 'gone_product') return null;
        return key;
      },
    );

    expect(lines.map((line) => line.zone).toList(), [
      'foundation',
      'eyes',
      'cheeks',
      'lips',
      'other',
    ]);
    expect(lines.first.title, 'fnd_covergirl_clean');
    expect(lines.first.intensity, 35);
    expect(lines.last.missing, isTrue);
    expect(lines.last.title, missingCatalogProductLabel);
  });

  test('the divider keeps the shade that fills more of the frame', () {
    const a = CatalogShade(
      productKey: 'lip_a',
      shadeKey: 'a',
      shadeName: 'A',
      shadeHex: '#111111',
    );
    const b = CatalogShade(
      productKey: 'lip_b',
      shadeKey: 'b',
      shadeName: 'B',
      shadeHex: '#222222',
    );

    expect(compareWinner(a, b, 0.8).shadeKey, 'a');
    expect(compareWinner(a, b, 0.2).shadeKey, 'b');
    expect(compareWinner(a, b, 0.5).shadeKey, 'a');
  });

  test('harmony picks the nearest catalog shade and still returns a thin list', () {
    final shades = [
      {
        'product_key': 'blu_far',
        'shade_key': 'blue',
        'shade_name': 'Blue',
        'shade_hex': '#2244AA',
      },
      {
        'product_key': 'blu_near',
        'shade_key': 'peach',
        'shade_name': 'Peach',
        'shade_hex': '#E8A07A',
      },
    ];

    final pick = nearestHarmonyShade(
      shades: shades,
      skinHex: '#C68642',
      undertone: 'warm',
      lip: false,
    );
    expect(pick?.shadeKey, 'peach');

    final only = nearestHarmonyShade(
      shades: [shades.first],
      skinHex: '#C68642',
      undertone: 'warm',
      lip: false,
    );
    expect(only?.shadeKey, 'blue');
    expect(
      nearestHarmonyShade(
        shades: const [],
        skinHex: '#C68642',
        undertone: 'warm',
        lip: true,
      ),
      isNull,
    );
  });
}
