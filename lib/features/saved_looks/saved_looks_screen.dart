import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

// ── Change this URL whenever your ngrok/hosting changes ──────────────────────
const _kWebBaseUrl = 'https://tommie-mushy-noumenally.ngrok-free.dev';
// ─────────────────────────────────────────────────────────────────────────────

class SavedLook {
  final String id;
  final String lookName;
  final String previewImageUrl;
  final DateTime createdAt;

  SavedLook({
    required this.id,
    required this.lookName,
    required this.previewImageUrl,
    required this.createdAt,
  });

  factory SavedLook.fromMap(Map<String, dynamic> map) {
    return SavedLook(
      id: map['id'] as String? ?? '',
      lookName: map['look_name'] as String? ?? 'Saved Look',
      previewImageUrl: map['preview_image_url'] as String? ?? '',
      createdAt: map['created_at'] != null
          ? DateTime.parse(map['created_at'] as String)
          : DateTime.now(),
    );
  }

  Uint8List? get imageBytes {
    try {
      if (previewImageUrl.startsWith('data:image')) {
        return base64Decode(previewImageUrl.split(',').last);
      }
    } catch (_) {}
    return null;
  }

  String get formattedDate {
    final now = DateTime.now();
    final diff = now.difference(createdAt);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${createdAt.day}/${createdAt.month}/${createdAt.year}';
  }
}

class SavedLooksScreen extends StatefulWidget {
  const SavedLooksScreen({super.key});

  @override
  State<SavedLooksScreen> createState() => _SavedLooksScreenState();
}

class _SavedLooksScreenState extends State<SavedLooksScreen>
    with SingleTickerProviderStateMixin {
  List<SavedLook> _looks = [];
  bool _isLoading = true;
  String? _error;
  late AnimationController _animController;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    _fetchLooks();
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  Future<void> _fetchLooks() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final response = await Supabase.instance.client
          .from('saved_looks')
          .select('id, look_name, preview_image_url, created_at')
          .order('created_at', ascending: false);

      final rows = response as List<dynamic>;
      setState(() {
        _looks = rows
            .map((e) => SavedLook.fromMap(e as Map<String, dynamic>))
            .toList();
        _isLoading = false;
      });
      _animController.forward(from: 0);
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _deleteLook(SavedLook look) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 8, sigmaY: 8),
        child: AlertDialog(
          backgroundColor: const Color(0xFF1A1A1A),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          title: const Text(
            'Delete Look?',
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
              fontSize: 17,
            ),
          ),
          content: const Text(
            'This look will be permanently deleted.',
            style: TextStyle(color: Colors.white60, fontSize: 14),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text(
                'Cancel',
                style: TextStyle(color: Colors.white54),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text(
                'Delete',
                style: TextStyle(
                  color: Colors.redAccent,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true) return;

    try {
      await Supabase.instance.client
          .from('saved_looks')
          .delete()
          .eq('id', look.id);
      setState(() => _looks.removeWhere((l) => l.id == look.id));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Row(
            children: [
              Icon(Icons.delete_outline, color: Colors.white, size: 16),
              SizedBox(width: 8),
              Text(
                'Look deleted',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ],
          ),
          backgroundColor: Colors.black87,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (_) {}
  }

  Future<void> _shareLook(SavedLook look) async {
    final webLink = '$_kWebBaseUrl/looks/${look.id}';
    final shareText = '✨ Check out my look: ${look.lookName}\n\n$webLink';
    try {
      await Share.share(shareText, subject: look.lookName);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not share: ${e.toString()}')),
      );
    }
  }

  void _showCopyLinkDialog(SavedLook look) {
    final webLink = '$_kWebBaseUrl/looks/${look.id}';
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _CopyLinkSheet(link: webLink, lookName: look.lookName),
    );
  }

  Future<void> _openInWeb(SavedLook look) async {
    final url = Uri.parse('$_kWebBaseUrl/looks/${look.id}');
    try {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not open link: ${e.toString()}'),
          backgroundColor: Colors.red.shade800,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      );
    }
  }

  void _showOptionsMenu(BuildContext context, SavedLook look) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => _OptionsSheet(
        look: look,
        onShareImage: () {
          Navigator.pop(context);
          _shareLook(look);
        },
        onShareLink: () {
          Navigator.pop(context);
          _shareLook(look);
        },
        onCopyLink: () {
          Navigator.pop(context);
          _showCopyLinkDialog(look);
        },
        onOpenInWeb: () {
          Navigator.pop(context);
          _openInWeb(look);
        },
        onDelete: () {
          Navigator.pop(context);
          _deleteLook(look);
        },
        onPreview: () {
          Navigator.pop(context);
          _openPreview(look);
        },
      ),
    );
  }

  void _openPreview(SavedLook look) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _LookPreviewSheet(look: look),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            // Top bar
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Row(
                children: [
                  _GlassCircleButton(
                    icon: Icons.arrow_back_ios_new,
                    onTap: () => Navigator.maybePop(context),
                  ),
                  const Spacer(),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(20),
                    child: BackdropFilter(
                      filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.18),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: Colors.white.withOpacity(0.10),
                          ),
                        ),
                        child: const Text(
                          'Saved Looks',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.3,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const Spacer(),
                  const SizedBox(width: 42),
                ],
              ),
            ),

            const SizedBox(height: 20),

            Expanded(
              child: _isLoading
                  ? const Center(
                      child: CircularProgressIndicator(color: Colors.white54),
                    )
                  : _error != null
                  ? _ErrorView(onRetry: _fetchLooks)
                  : _looks.isEmpty
                  ? _EmptyView(onBack: () => Navigator.maybePop(context))
                  : RefreshIndicator(
                      onRefresh: _fetchLooks,
                      color: Colors.white,
                      backgroundColor: Colors.black87,
                      child: GridView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 2,
                              mainAxisSpacing: 14,
                              crossAxisSpacing: 14,
                              childAspectRatio: 0.72,
                            ),
                        itemCount: _looks.length,
                        itemBuilder: (context, i) {
                          final look = _looks[i];
                          return _AnimatedLookCard(
                            look: look,
                            animController: _animController,
                            delay: Duration(milliseconds: i * 60),
                            onTap: () => _openPreview(look),
                            onOptions: () => _showOptionsMenu(context, look),
                          );
                        },
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Options Bottom Sheet ─────────────────────────────────────────────────────

class _OptionsSheet extends StatelessWidget {
  final SavedLook look;
  final VoidCallback onShareImage;
  final VoidCallback onShareLink;
  final VoidCallback onCopyLink;
  final VoidCallback onOpenInWeb;
  final VoidCallback onDelete;
  final VoidCallback onPreview;

  const _OptionsSheet({
    required this.look,
    required this.onShareImage,
    required this.onShareLink,
    required this.onCopyLink,
    required this.onOpenInWeb,
    required this.onDelete,
    required this.onPreview,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          padding: const EdgeInsets.fromLTRB(0, 12, 0, 32),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.80),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
            border: Border(
              top: BorderSide(color: Colors.white.withOpacity(0.10), width: 1),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Handle
              Center(
                child: Container(
                  width: 42,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Look name header
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  children: [
                    Text(
                      look.lookName,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Divider(color: Colors.white.withOpacity(0.08)),

              // Share options
              _OptionTile(
                icon: Icons.image_outlined,
                label: 'Share Image',
                onTap: onShareImage,
              ),
              _OptionTile(
                icon: Icons.share_outlined,
                label: 'Share Link',
                onTap: onShareLink,
              ),
              _OptionTile(
                icon: Icons.link_rounded,
                label: 'Copy Link',
                onTap: onCopyLink,
              ),
              _OptionTile(
                icon: Icons.open_in_browser_outlined,
                label: 'Open in Web',
                onTap: onOpenInWeb,
              ),
              Divider(color: Colors.white.withOpacity(0.08)),
              _OptionTile(
                icon: Icons.delete_outline_rounded,
                label: 'Delete Look',
                color: Colors.redAccent,
                onTap: onDelete,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OptionTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color color;

  const _OptionTile({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color = Colors.white,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(
          children: [
            Icon(icon, color: color, size: 22),
            const SizedBox(width: 16),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 15,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Animated card ────────────────────────────────────────────────────────────

class _AnimatedLookCard extends StatelessWidget {
  final SavedLook look;
  final AnimationController animController;
  final Duration delay;
  final VoidCallback onTap;
  final VoidCallback onOptions;

  const _AnimatedLookCard({
    required this.look,
    required this.animController,
    required this.delay,
    required this.onTap,
    required this.onOptions,
  });

  @override
  Widget build(BuildContext context) {
    final animation = CurvedAnimation(
      parent: animController,
      curve: Interval(
        (delay.inMilliseconds / 500).clamp(0.0, 0.8),
        1.0,
        curve: Curves.easeOutCubic,
      ),
    );

    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) => Opacity(
        opacity: animation.value,
        child: Transform.translate(
          offset: Offset(0, 20 * (1 - animation.value)),
          child: child,
        ),
      ),
      child: GestureDetector(
        onTap: onTap,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Image
              _LookImage(look: look),

              // Bottom gradient + info
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(10, 28, 10, 10),
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [Colors.black87, Colors.transparent],
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        look.lookName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        look.formattedDate,
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.45),
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // Three dots button — top right
              Positioned(
                top: 6,
                right: 6,
                child: GestureDetector(
                  onTap: onOptions,
                  child: ClipOval(
                    child: BackdropFilter(
                      filter: ui.ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                      child: Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.45),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: Colors.white.withOpacity(0.15),
                          ),
                        ),
                        child: const Icon(
                          Icons.more_vert_rounded,
                          color: Colors.white,
                          size: 17,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Look image ───────────────────────────────────────────────────────────────

class _LookImage extends StatelessWidget {
  final SavedLook look;
  const _LookImage({required this.look});

  @override
  Widget build(BuildContext context) {
    final url = look.previewImageUrl;

    // Real URL (Supabase Storage)
    if (url.startsWith('http')) {
      return Image.network(
        url,
        fit: BoxFit.cover,
        // Cache at thumbnail size — loads/decodes much faster in grid
        cacheWidth: 400,
        cacheHeight: 560,
        loadingBuilder: (ctx, child, progress) =>
            progress == null ? child : _placeholder(loading: true),
        errorBuilder: (_, __, ___) => _placeholder(),
      );
    }

    // Legacy base64
    final bytes = look.imageBytes;
    if (bytes != null) {
      return Image.memory(
        bytes,
        fit: BoxFit.cover,
        cacheWidth: 400,
        cacheHeight: 560,
      );
    }

    return _placeholder();
  }

  Widget _placeholder({bool loading = false}) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Colors.white.withOpacity(0.08), Colors.black87],
        ),
      ),
      child: Center(
        child: loading
            ? const CircularProgressIndicator(
                color: Colors.white24,
                strokeWidth: 2,
              )
            : Icon(
                Icons.face_retouching_natural,
                color: Colors.white.withOpacity(0.3),
                size: 48,
              ),
      ),
    );
  }
}

// ─── Preview sheet ────────────────────────────────────────────────────────────

class _LookPreviewSheet extends StatelessWidget {
  final SavedLook look;
  const _LookPreviewSheet({required this.look});

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.88,
      maxChildSize: 0.95,
      minChildSize: 0.5,
      builder: (_, scrollController) {
        return ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20),
            child: Container(
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.80),
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(28),
                ),
                border: Border(
                  top: BorderSide(
                    color: Colors.white.withOpacity(0.10),
                    width: 1,
                  ),
                ),
              ),
              child: ListView(
                controller: scrollController,
                padding: const EdgeInsets.fromLTRB(0, 12, 0, 32),
                children: [
                  Center(
                    child: Container(
                      width: 42,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.white24,
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(20),
                      child: AspectRatio(
                        aspectRatio: 0.85,
                        child: _LookImage(look: look),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          look.lookName,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          look.formattedDate,
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.40),
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

// ─── Empty state ──────────────────────────────────────────────────────────────

class _EmptyView extends StatelessWidget {
  final VoidCallback onBack;
  const _EmptyView({required this.onBack});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withOpacity(0.06),
                border: Border.all(color: Colors.white.withOpacity(0.10)),
              ),
              child: Icon(
                Icons.collections_bookmark_outlined,
                color: Colors.white.withOpacity(0.4),
                size: 36,
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              'No saved looks yet',
              style: TextStyle(
                color: Colors.white,
                fontSize: 17,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Try on a makeup look and tap the camera button to save it here.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white.withOpacity(0.45),
                fontSize: 13,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 28),
            GestureDetector(
              onTap: onBack,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: const Text(
                  'Try On Now',
                  style: TextStyle(
                    color: Colors.black,
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Error state ──────────────────────────────────────────────────────────────

class _ErrorView extends StatelessWidget {
  final VoidCallback onRetry;
  const _ErrorView({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.wifi_off_rounded, color: Colors.white38, size: 40),
          const SizedBox(height: 12),
          const Text(
            'Could not load looks',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 16),
          GestureDetector(
            onTap: onRetry,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.1),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: Colors.white24),
              ),
              child: const Text(
                'Retry',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Glass circle button ──────────────────────────────────────────────────────

class _GlassCircleButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _GlassCircleButton({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return ClipOval(
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Material(
          color: Colors.black.withOpacity(0.18),
          child: InkWell(
            onTap: onTap,
            child: Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white.withOpacity(0.10)),
              ),
              child: Icon(icon, color: Colors.white, size: 19),
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
// Premium Copy Link Sheet
// ─────────────────────────────────────────────
class _CopyLinkSheet extends StatefulWidget {
  final String link;
  final String lookName;
  const _CopyLinkSheet({required this.link, required this.lookName});

  @override
  State<_CopyLinkSheet> createState() => _CopyLinkSheetState();
}

class _CopyLinkSheetState extends State<_CopyLinkSheet>
    with SingleTickerProviderStateMixin {
  bool _copied = false;
  late final AnimationController _anim;
  late final Animation<double> _fade;
  late final Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 380),
    );
    _fade = CurvedAnimation(parent: _anim, curve: Curves.easeOut);
    _slide = Tween<Offset>(
      begin: const Offset(0, 0.1),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _anim, curve: Curves.easeOutCubic));
    _anim.forward();
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  void _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.link));
    setState(() => _copied = true);
    await Future.delayed(const Duration(seconds: 2));
    if (mounted) setState(() => _copied = false);
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fade,
      child: SlideTransition(
        position: _slide,
        child: Container(
          margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 28),
          decoration: BoxDecoration(
            color: const Color(0xFF0E0E0E),
            borderRadius: BorderRadius.circular(28),
            border: Border.all(color: Colors.white.withOpacity(0.07)),
            boxShadow: [
              BoxShadow(color: Colors.black.withOpacity(0.5), blurRadius: 40),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Handle
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 20),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),

              // Title row
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(9),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.07),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      Icons.link_rounded,
                      color: Colors.white,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Share Link',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.3,
                        ),
                      ),
                      Text(
                        widget.lookName,
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.4),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ],
              ),

              const SizedBox(height: 20),

              // URL box
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 14,
                ),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.05),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: Colors.white.withOpacity(0.1)),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.link,
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.75),
                          fontSize: 12.5,
                          fontFamily: 'monospace',
                          letterSpacing: 0.1,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 16),

              // Action buttons
              Row(
                children: [
                  // Copy button
                  Expanded(
                    flex: 2,
                    child: GestureDetector(
                      onTap: _copy,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        height: 52,
                        decoration: BoxDecoration(
                          color: _copied
                              ? const Color(0xFF1DB954)
                              : Colors.white,
                          borderRadius: BorderRadius.circular(16),
                          boxShadow: [
                            BoxShadow(
                              color:
                                  (_copied
                                          ? const Color(0xFF1DB954)
                                          : Colors.white)
                                      .withOpacity(0.15),
                              blurRadius: 20,
                            ),
                          ],
                        ),
                        child: Center(
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              AnimatedSwitcher(
                                duration: const Duration(milliseconds: 200),
                                child: Icon(
                                  _copied
                                      ? Icons.check_rounded
                                      : Icons.copy_rounded,
                                  key: ValueKey(_copied),
                                  color: Colors.black,
                                  size: 18,
                                ),
                              ),
                              const SizedBox(width: 8),
                              AnimatedSwitcher(
                                duration: const Duration(milliseconds: 200),
                                child: Text(
                                  _copied ? 'Copied!' : 'Copy Link',
                                  key: ValueKey(_copied),
                                  style: const TextStyle(
                                    color: Colors.black,
                                    fontSize: 15,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  // Close button
                  GestureDetector(
                    onTap: () => Navigator.of(context).pop(),
                    child: Container(
                      height: 52,
                      width: 52,
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.06),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: Colors.white.withOpacity(0.1),
                        ),
                      ),
                      child: Icon(
                        Icons.close_rounded,
                        color: Colors.white.withOpacity(0.5),
                        size: 20,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
