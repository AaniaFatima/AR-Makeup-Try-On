import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../cache/products_cache.dart';
import '../config/app_config.dart';
import '../services/web_bridge.dart';
import '../utils/app_colors.dart';
import '../widgets/app_loader.dart';

/// In-app inbox for the signed-in phone session.
///
/// Reads `orders` and `product_restock_alerts` with the Supabase client the
/// app already holds. It does not call the website's cookie APIs.
class NotificationsInboxScreen extends StatefulWidget {
  const NotificationsInboxScreen({super.key});

  @override
  State<NotificationsInboxScreen> createState() =>
      _NotificationsInboxScreenState();
}

class _InboxLine {
  const _InboxLine({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.at,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final DateTime at;
  final VoidCallback onTap;
}

class _NotificationsInboxScreenState extends State<NotificationsInboxScreen> {
  bool _loading = true;
  String? _notice;
  List<_InboxLine> _lines = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _notice = 'Sign in to see updates.';
        _lines = const [];
      });
      return;
    }

    String? notice;
    final lines = <_InboxLine>[];

    try {
      final orders = await _loadOrders(user.id);
      for (final row in orders) {
        final line = _orderLine(row);
        if (line != null) lines.add(line);
      }
    } catch (e) {
      debugPrint('NotificationsInbox: orders failed: $e');
      notice = 'Order updates could not be loaded.';
    }

    try {
      final alerts = await _loadRestocks(user.id);
      for (final row in alerts) {
        final line = _restockLine(row);
        if (line != null) lines.add(line);
      }
    } catch (e) {
      debugPrint('NotificationsInbox: restocks failed: $e');
      notice = notice == null
          ? 'Restock updates could not be loaded.'
          : 'Updates could not be loaded.';
    }

    lines.sort((a, b) => b.at.compareTo(a.at));

    if (!mounted) return;
    setState(() {
      _loading = false;
      _notice = notice;
      _lines = lines;
    });
  }

  Future<List<Map<String, dynamic>>> _loadOrders(String userId) async {
    final client = Supabase.instance.client;
    try {
      final rows = await client
          .from('orders')
          .select('id,status,created_at,total,currency')
          .eq('user_id', userId)
          .order('created_at', ascending: false)
          .timeout(const Duration(seconds: 10));
      return _asMaps(rows);
    } catch (e) {
      debugPrint('NotificationsInbox: order totals unavailable: $e');
      final rows = await client
          .from('orders')
          .select('id,status,created_at')
          .eq('user_id', userId)
          .order('created_at', ascending: false)
          .timeout(const Duration(seconds: 10));
      return _asMaps(rows);
    }
  }

  Future<List<Map<String, dynamic>>> _loadRestocks(String userId) async {
    final rows = await Supabase.instance.client
        .from('product_restock_alerts')
        .select('product_key,shade_key,notified_at')
        .eq('user_id', userId)
        .not('notified_at', 'is', null)
        .order('notified_at', ascending: false)
        .timeout(const Duration(seconds: 10));
    return _asMaps(rows);
  }

  _InboxLine? _orderLine(Map<String, dynamic> row) {
    final id = row['id']?.toString().trim() ?? '';
    if (id.isEmpty) return null;
    final created = DateTime.tryParse(row['created_at']?.toString() ?? '');
    final status = _statusLabel(row['status']?.toString() ?? '');
    final date = _formatDate(created);
    final total = _formatTotal(row['total'], row['currency']?.toString());
    final subtitle = [
      status,
      ?total,
      if (date.isNotEmpty) date,
    ].join(' · ');

    return _InboxLine(
      icon: Icons.receipt_long_outlined,
      title: 'Order ${_shortId(id)}',
      subtitle: subtitle,
      at: created ?? DateTime.fromMillisecondsSinceEpoch(0),
      onTap: () => WebBridge.openAuthenticated(context, AppConfig.orderPath(id)),
    );
  }

  _InboxLine? _restockLine(Map<String, dynamic> row) {
    final productKey = row['product_key']?.toString().trim() ?? '';
    if (productKey.isEmpty) return null;
    final shadeKey = row['shade_key']?.toString().trim();
    final notified = DateTime.tryParse(row['notified_at']?.toString() ?? '');
    final product = ProductsCache.instance.byKey(productKey);
    final name = (product?.name.trim().isNotEmpty ?? false)
        ? product!.name
        : productKey;
    final shade = (shadeKey == null || shadeKey.isEmpty) ? '' : ' · $shadeKey';
    final date = _formatDate(notified);

    return _InboxLine(
      icon: Icons.inventory_2_outlined,
      title: name,
      subtitle: 'Back in stock$shade${date.isEmpty ? '' : ' · $date'}',
      at: notified ?? DateTime.fromMillisecondsSinceEpoch(0),
      onTap: () => WebBridge.openAuthenticated(
        context,
        AppConfig.productPagePath(
          productKey,
          shadeKey: (shadeKey == null || shadeKey.isEmpty) ? null : shadeKey,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    AppColors.watch(context);
    final showEmpty = !_loading && _lines.isEmpty;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        iconTheme: IconThemeData(color: AppColors.textMain),
        title: Text(
          'Notifications',
          style: TextStyle(
            color: AppColors.textMain,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      body: _loading
          ? const AppLoader.centered()
          : ListView(
              padding: const EdgeInsets.all(24),
              children: [
                if (_notice != null) ...[
                  Text(
                    _notice!,
                    style: TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 14,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
                if (showEmpty && _notice == null)
                  Padding(
                    padding: const EdgeInsets.only(top: 48),
                    child: Text(
                      'No updates yet.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 15,
                      ),
                    ),
                  )
                else if (_lines.isNotEmpty)
                  Container(
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: Column(
                      children: [
                        for (var i = 0; i < _lines.length; i++) ...[
                          if (i > 0) Divider(height: 1, color: AppColors.border),
                          ListTile(
                            leading: Icon(
                              _lines[i].icon,
                              color: AppColors.textMain,
                            ),
                            title: Text(
                              _lines[i].title,
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                color: AppColors.textMain,
                              ),
                            ),
                            subtitle: Text(
                              _lines[i].subtitle,
                              style: TextStyle(
                                fontSize: 12,
                                color: AppColors.textMuted,
                              ),
                            ),
                            trailing: Icon(
                              Icons.open_in_new,
                              color: AppColors.textMuted,
                              size: 18,
                            ),
                            onTap: _lines[i].onTap,
                          ),
                        ],
                      ],
                    ),
                  ),
              ],
            ),
    );
  }
}

List<Map<String, dynamic>> _asMaps(dynamic rows) {
  if (rows is! List) return const [];
  return [
    for (final row in rows)
      if (row is Map) Map<String, dynamic>.from(row),
  ];
}

String _shortId(String id) {
  final compact = id.replaceAll('-', '');
  if (compact.length <= 8) return compact;
  return compact.substring(0, 8);
}

String _statusLabel(String raw) {
  switch (raw.trim().toLowerCase()) {
    case 'paid':
      return 'Paid';
    case 'processing':
      return 'Processing';
    case 'shipped':
      return 'Shipped';
    case 'delivered':
      return 'Delivered';
    case 'failed':
      return 'Failed';
    case 'cancelled':
      return 'Cancelled';
    case 'draft':
      return 'Draft';
    case 'placed':
      return 'Placed';
    default:
      if (raw.trim().isEmpty) return 'Placed';
      final value = raw.trim();
      return value[0].toUpperCase() + value.substring(1);
  }
}

String? _formatTotal(dynamic total, String? currency) {
  if (total == null) return null;
  final amount = total is num ? total.toDouble() : double.tryParse('$total');
  if (amount == null) return null;
  final code = currency?.trim() ?? '';
  final text = amount.toStringAsFixed(2);
  return code.isEmpty ? text : '$code $text';
}

String _formatDate(DateTime? value) {
  if (value == null) return '';
  final local = value.toLocal();
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return '${local.day} ${months[local.month - 1]} ${local.year}';
}
