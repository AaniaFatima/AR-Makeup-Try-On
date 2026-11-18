import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../config/app_config.dart';
import '../services/web_bridge.dart';
import '../utils/app_colors.dart';
import '../widgets/app_loader.dart';
import '../utils/image_url.dart';
import '../cache/makeup_bag_cache.dart';
import '../cache/products_cache.dart';
import '../utils/app_image_cache.dart';

class MakeupBagScreen extends StatefulWidget {
  const MakeupBagScreen({super.key});

  @override
  State<MakeupBagScreen> createState() => _MakeupBagScreenState();
}

class _MakeupBagScreenState extends State<MakeupBagScreen> {
  @override
  void initState() {
    super.initState();
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId != null) {
      MakeupBagCache.instance.prefetch(userId);
    }
    MakeupBagCache.instance.ensureDefaultBagForSignedInUser();
    ProductsCache.instance.prefetch();
  }

  void _openAddProducts() {
    WebBridge.openAuthenticated(context, AppConfig.makeupBagAddPath());
  }

  void _openRefill(String productKey, String shadeKey) {
    WebBridge.openAuthenticated(
      context,
      AppConfig.productPagePath(productKey, shadeKey: shadeKey),
    );
  }

  void _openProductDetails(String productKey) {
    WebBridge.openAuthenticated(
      context,
      AppConfig.productPagePath(productKey),
    );
  }

  void _showItemOptions(Map<String, dynamic> item, String title) {
    final productKey = item['product_key'] as String;
    final shadeKey = item['shade_key'] as String;

    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Text(
                  title,
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                    color: AppColors.textMain,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              ListTile(
                leading: Icon(Icons.shopping_cart_checkout, color: AppColors.primary),
                title: const Text('Refill / buy again'),
                onTap: () {
                  Navigator.pop(ctx);
                  _openRefill(productKey, shadeKey);
                },
              ),
              ListTile(
                leading: Icon(Icons.info_outline, color: AppColors.primary),
                title: const Text('View product details'),
                onTap: () {
                  Navigator.pop(ctx);
                  _openProductDetails(productKey);
                },
              ),
              ListTile(
                leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
                title: const Text(
                  'Remove from bag',
                  style: TextStyle(color: Colors.redAccent),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  MakeupBagCache.instance.toggleInBag(productKey, shadeKey);
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    AppColors.watch(context);
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        title: Text(
          'My Makeup Bag',
          style: TextStyle(
            color: AppColors.textMain,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        leading: IconButton(
          icon: Icon(Icons.chevron_left, color: AppColors.textMain, size: 28),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          IconButton(
            icon: Icon(Icons.add_shopping_cart, color: AppColors.primary),
            tooltip: 'Add products',
            onPressed: _openAddProducts,
          ),
        ],
      ),
      body: AnimatedBuilder(
        animation: Listenable.merge([MakeupBagCache.instance, ProductsCache.instance]),
        builder: (context, _) {
          final items = MakeupBagCache.instance.items;
          final isLoading = MakeupBagCache.instance.isLoading;

          if (isLoading && items.isEmpty) {
            return const AppLoader.centered();
          }

          if (items.isEmpty) {
            return _buildEmptyState();
          }

          return _buildGrid(items);
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.pop(context, 'tryOnWithMyBag'),
        backgroundColor: AppColors.primary,
        icon: const Icon(Icons.auto_fix_high, color: Colors.white),
        label: const Text('Try On', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.shopping_bag_outlined, size: 64, color: AppColors.primary),
          ),
          const SizedBox(height: 24),
          Text(
            'Your bag is empty',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: AppColors.textMain,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Products you own will appear here.',
            style: TextStyle(fontSize: 14, color: AppColors.textMuted),
          ),
          const SizedBox(height: 20),
          ElevatedButton.icon(
            onPressed: _openAddProducts,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            icon: const Icon(Icons.add),
            label: const Text('Add products'),
          ),
        ],
      ),
    );
  }

  Widget _buildGrid(List<Map<String, dynamic>> items) {
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 16,
        crossAxisSpacing: 16,
        childAspectRatio: 0.75,
      ),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        final productKey = item['product_key'] as String;
        final shadeKey = item['shade_key'] as String;

        final product = ProductsCache.instance.byKey(productKey);
        final title = product?.name ?? productKey.replaceAll('_', ' ').toUpperCase();
        final brand = product?.brand ?? '';
        final imageUrl = product?.imageUrl;

        return Container(
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.border),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.03),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Stack(
                  children: [
                    Container(
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: AppColors.background,
                        borderRadius: const BorderRadius.vertical(top: Radius.circular(15)),
                      ),
                      child: imageUrl != null && imageUrl.isNotEmpty
                          ? ClipRRect(
                              borderRadius: const BorderRadius.vertical(top: Radius.circular(15)),
                              child: CachedNetworkImage(
                                imageUrl: upgradeImageUrl(imageUrl),
                                cacheManager: AppImageCache.manager,
                                memCacheWidth: 400,
                                fit: BoxFit.cover,
                                fadeInDuration: const Duration(milliseconds: 120),
                                placeholder: (context, url) => Container(
                                  color: AppColors.background,
                                ),
                                errorWidget: (context, url, error) => _fallbackIcon(),
                              ),
                            )
                          : _fallbackIcon(),
                    ),
                    // Extra options entry point (View details / Refill / Remove)
                    Positioned(
                      top: 6,
                      right: 6,
                      child: GestureDetector(
                        onTap: () => _showItemOptions(item, title),
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.35),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.more_horiz, size: 18, color: Colors.white),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (brand.isNotEmpty) ...[
                      Text(
                        brand.toUpperCase(),
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: AppColors.primary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                    ],
                    Text(
                      title,
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                        color: AppColors.textMain,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      shadeKey.isEmpty ? 'Default Shade' : shadeKey.replaceAll('_', ' ').toUpperCase(),
                      style: TextStyle(fontSize: 11, color: AppColors.textMuted),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        GestureDetector(
                          onTap: () => MakeupBagCache.instance.toggleInBag(productKey, shadeKey),
                          child: Icon(Icons.delete_outline, size: 20, color: Colors.redAccent),
                        ),
                        GestureDetector(
                          onTap: () => _openRefill(productKey, shadeKey),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                            decoration: BoxDecoration(
                              color: AppColors.primary,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: const Text(
                              'Refill',
                              style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _fallbackIcon() {
    return Center(
      child: Icon(Icons.shopping_bag, size: 48, color: AppColors.primary.withValues(alpha: 0.3)),
    );
  }
}