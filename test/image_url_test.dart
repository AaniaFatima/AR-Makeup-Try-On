import 'package:flutter_test/flutter_test.dart';
import 'package:makeup_tryon/app/utils/image_url.dart';

void main() {
  test('upgradeImageUrl rewrites only a cleartext scheme', () {
    expect(
      upgradeImageUrl('http://cdn.example/a.jpg'),
      'https://cdn.example/a.jpg',
    );
    expect(
      upgradeImageUrl('HTTP://cdn.example/a.jpg'),
      'https://cdn.example/a.jpg',
    );
    expect(
      upgradeImageUrl('https://cdn.example/a.jpg'),
      'https://cdn.example/a.jpg',
    );
    expect(upgradeImageUrl('assets/images/hero_model.webp'), 'assets/images/hero_model.webp');
  });
}
