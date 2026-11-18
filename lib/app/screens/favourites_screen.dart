import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart'; // 🆕 added
import 'package:supabase_flutter/supabase_flutter.dart';
import '../cache/favourites_cache.dart';
import '../cache/products_cache.dart';
import '../config/app_config.dart';
import '../services/web_bridge.dart';
import '../utils/app_colors.dart';
import '../widgets/app_loader.dart';
import '../utils/app_image_cache.dart';
import '../utils/image_url.dart';

class FavouritesScreen extends StatefulWidget {
  const FavouritesScreen({super.key});

  @override
  State<FavouritesScreen> createState() => _FavouritesScreenState();
}

class _FavouritesScreenState extends State<FavouritesScreen> {
  @override
  void initState() {
    super.initState();
    // Disk copy shows immediately. A stale catalog refreshes in the background.
    ProductsCache.instance.prefetch();

    // Favourites ko fresh karo aur realtime listener guarantee karo
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId != null) {
      FavouritesCache.instance.prefetch(userId);
      FavouritesCache.instance.listenRealtime(userId);
    }
  }

  void _openWebFavourites() {
    WebBridge.openAuthenticated(context, '/account/favourites');
  }

  void _buyProduct(String productKey, String? shadeKey) {
    final path = shadeKey != null && shadeKey.isNotEmpty
        ? '${AppConfig.productsPath}/$productKey?shade=$shadeKey'
        : '${AppConfig.productsPath}/$productKey';
    WebBridge.openAuthenticated(context, path);
  }

  void _removeFavourite(String productKey, String? shadeKey) {
    FavouritesCache.instance.toggleFavourite(productKey, shadeKey);
  }

  @override
  Widget build(BuildContext context) {
    AppColors.watch(context);
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        centerTitle: true,
        leading: IconButton(
          icon: Icon(Icons.chevron_left, color: AppColors.textMain),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          'Favourites',
          style: TextStyle(
            color: AppColors.textMain,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      body: ListenableBuilder(
        listenable: Listenable.merge([
          FavouritesCache.instance,
          ProductsCache.instance,
        ]),
        builder: (context, _) {
          final favs = FavouritesCache.instance.favourites;

          if (FavouritesCache.instance.isLoading && favs.isEmpty) {
            return const AppLoader.centered();
          }

          if (favs.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.favorite_border_rounded,
                    size: 64,
                    color: AppColors.border,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'No favourites yet',
                    style: TextStyle(
                      color: AppColors.textMain,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Tap the heart on the try-on screen to save a shade.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppColors.textMuted, fontSize: 14),
                  ),
                ],
              ),
            );
          }

          final catalog = ProductsCache.instance;
          final namesLoading = catalog.isLoading && !catalog.isLoaded;
          final namesFailed = catalog.isLoaded && catalog.isEmpty;

          return Column(
            children: [
              if (namesLoading)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Loading product names...',
                      style: TextStyle(color: AppColors.textMuted, fontSize: 14),
                    ),
                  ),
                ),
              if (namesFailed)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Could not load product names.',
                      style: TextStyle(color: AppColors.textMuted, fontSize: 14),
                    ),
                  ),
                ),
              Expanded(
                child: ListView.separated(
                  padding: const EdgeInsets.all(20),
                  physics: const BouncingScrollPhysics(),
                  itemCount: favs.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 16),
                  itemBuilder: (context, index) {
                    final item = favs[index];
                    final rawKey = item['product_key'];
                    final productKey =
                        rawKey is String && rawKey.isNotEmpty ? rawKey : '';
                    final rawShade = item['shade_key'];
                    final shadeKey = rawShade is String && rawShade.isNotEmpty
                        ? rawShade
                        : null;
                    final product = productKey.isEmpty
                        ? null
                        : catalog.byKey(productKey);

                    return _FavouriteCard(
                      productKey: productKey,
                      shadeKey: shadeKey,
                      product: product,
                      namesLoading: namesLoading && product == null,
                      onBuy: productKey.isEmpty
                          ? null
                          : () => _buyProduct(productKey, shadeKey),
                      onRemove: () => _removeFavourite(
                        productKey,
                        shadeKey,
                      ),
                    );
                  },
                ),
              ),
              Container(
                padding: EdgeInsets.fromLTRB(
                  24,
                  16,
                  24,
                  MediaQuery.of(context).padding.bottom + 16,
                ),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  border: Border(top: BorderSide(color: AppColors.border)),
                ),
                child: SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _openWebFavourites,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    child: const Text(
                      'Shop All Favourites',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _FavouriteCard extends StatelessWidget {
  final String productKey;
  final String? shadeKey;
  final DbProduct? product;
  final bool namesLoading;
  final VoidCallback? onBuy;
  final VoidCallback onRemove;

  const _FavouriteCard({
    required this.productKey,
    this.shadeKey,
    this.product,
    this.namesLoading = false,
    required this.onBuy,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          // 🆕 REPLACED: pehle Container + BoxDecoration(DecorationImage(NetworkImage(...)))
          // tha — NetworkImage har rebuild pe re-download/re-decode karta tha kyunki
          // uska in-memory cache screen dispose hote hi evict ho jata hai.
          // Ab CachedNetworkImage disk + memory dono pe persist karta hai, so
          // dobara screen kholne par image *instant* dikhti hai.
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: product?.imageUrl != null
                ? CachedNetworkImage(
                    imageUrl: upgradeImageUrl(product!.imageUrl!),
                    cacheManager: AppImageCache.manager,
                    width: 70,
                    height: 70,
                    fit: BoxFit.cover,
                    memCacheWidth: 140, // 2x the 70px thumbnail
                    fadeInDuration: const Duration(milliseconds: 150),
                    placeholder: (context, url) => Container(
                      width: 70,
                      height: 70,
                      color: AppColors.background,
                      child: Center(
                        child: const AppLoader.inline(size: 16),
                      ),
                    ),
                    errorWidget: (context, url, error) => Container(
                      width: 70,
                      height: 70,
                      color: AppColors.background,
                      child: Icon(Icons.image_outlined, color: AppColors.textMuted),
                    ),
                  )
                : Container(
                    width: 70,
                    height: 70,
                    color: AppColors.background,
                    child: Icon(Icons.image_outlined, color: AppColors.textMuted),
                  ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  namesLoading
                      ? 'Loading...'
                      : (product?.displayBrand ?? '—'),
                  style: TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  product?.displayName ??
                      (productKey.isNotEmpty ? productKey : 'Saved favourite'),
                  style: TextStyle(
                    color: AppColors.textMain,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                if ((shadeKey?.isNotEmpty ?? false))
                  Text(
                    'Shade: $shadeKey',
                    style: TextStyle(
                      color: AppColors.primary,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.favorite, color: Colors.redAccent),
            tooltip: 'Remove from favourites',
            onPressed: onRemove,
          ),
          if (onBuy != null) ...[
            const SizedBox(width: 4),
            OutlinedButton(
              onPressed: onBuy,
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.primary,
                side: BorderSide(color: AppColors.primary.withOpacity(0.3)),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(30),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              ),
              child: const Text(
                'Buy on Web',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ],
      ),
    );
  }
}