import 'package:flutter/material.dart';

import '../cache/beauty_profile_model.dart';
import '../services/beauty_profile_service.dart';
import '../utils/app_colors.dart';
import '../widgets/app_loader.dart';
import 'beauty_profile_questionnaire_screen.dart';

/// Saved Beauty Profile overview. First-time users can start the questionnaire;
/// returning users can review their saved details and edit them.
class BeautyProfileOverviewScreen extends StatefulWidget {
  const BeautyProfileOverviewScreen({super.key});

  @override
  State<BeautyProfileOverviewScreen> createState() =>
      _BeautyProfileOverviewScreenState();
}

class _BeautyProfileOverviewScreenState
    extends State<BeautyProfileOverviewScreen> {
  UserBeautyProfile? _profile;
  bool _loading = true;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  Future<void> _loadProfile() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _failed = false;
      });
    }
    try {
      final profile = await BeautyProfileService.fetchCompleteProfile();
      BeautyProfileService.setCachedProfile(profile);
      if (!mounted) return;
      setState(() {
        _profile = profile;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _failed = true;
        _loading = false;
      });
    }
  }

  Future<void> _openQuestionnaire() async {
    final existing = _profile;
    final result = await Navigator.push<UserBeautyProfile>(
      context,
      MaterialPageRoute(
        builder: (_) => BeautyProfileQuestionnaireScreen(
          isEditing: existing != null && !existing.isEmpty,
        ),
      ),
    );
    if (!mounted) return;
    if (result != null) {
      setState(() => _profile = result);
      BeautyProfileService.setCachedProfile(result);
    } else {
      await _loadProfile();
    }
  }

  @override
  Widget build(BuildContext context) {
    AppColors.watch(context);
    final profile = _profile;
    final hasProfile = profile != null && !profile.isEmpty;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Beauty profile'),
        centerTitle: true,
        backgroundColor: AppColors.background,
        foregroundColor: AppColors.textMain,
        elevation: 0,
        actions: [
          if (!_loading && !_failed && hasProfile)
            IconButton(
              tooltip: 'Edit beauty profile',
              onPressed: _openQuestionnaire,
              icon: const Icon(Icons.edit_outlined),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: AppLoader(size: 36))
          : _failed
              ? _buildLoadError()
              : hasProfile
                  ? _buildSavedProfile(profile)
                  : _buildEmptyProfile(),
    );
  }

  Widget _buildSavedProfile(UserBeautyProfile profile) {
    final concernLabels = (profile.concerns ?? const <String>[])
        .map(_concernLabel)
        .toList(growable: false);
    final allergyLabels = (profile.allergies ?? const <String>[])
        .map(_humanize)
        .whereType<String>()
        .toList(growable: false);

    return RefreshIndicator(
      onRefresh: _loadProfile,
      color: AppColors.primary,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(
          parent: BouncingScrollPhysics(),
        ),
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: [
          _ProfileHero(profile: profile),
          const SizedBox(height: 24),
          _SectionHeading(
            title: 'Skin profile',
            subtitle: 'Your saved skin details at a glance',
          ),
          const SizedBox(height: 12),
          _ProfileCard(
            children: [
              _ProfileValueRow(
                icon: Icons.water_drop_outlined,
                label: 'Skin type',
                value: _humanize(profile.skinType),
              ),
              _ProfileValueRow(
                icon: Icons.palette_outlined,
                label: 'Undertone',
                value: _humanize(profile.undertone),
              ),
              _ProfileValueRow(
                icon: Icons.color_lens_outlined,
                label: 'Skin depth',
                value: _depthLabel(profile.depthLevel),
                last: profile.skinToneHex == null && profile.monkScale == null,
              ),
              if (profile.skinToneHex != null)
                _ProfileValueRow(
                  icon: Icons.circle,
                  label: 'Saved skin tone',
                  value: profile.skinToneHex!.toUpperCase(),
                  swatch: _parseColor(profile.skinToneHex),
                  last: profile.monkScale == null,
                ),
              if (profile.monkScale != null)
                _ProfileValueRow(
                  icon: Icons.tune_rounded,
                  label: 'Monk skin tone scale',
                  value: '${profile.monkScale} of 10',
                  last: true,
                ),
            ],
          ),
          const SizedBox(height: 22),
          _SectionHeading(
            title: 'Skin concerns',
            subtitle: 'Used to tailor product suggestions',
          ),
          const SizedBox(height: 12),
          _ProfileCard(
            child: concernLabels.isEmpty
                ? _EmptyValue('No concerns added yet')
                : Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: concernLabels.map((label) => _ProfileTag(label)).toList(),
                  ),
          ),
          if (profile.coveragePreference != null ||
              profile.finishPreference != null ||
              allergyLabels.isNotEmpty) ...[
            const SizedBox(height: 22),
            _SectionHeading(
              title: 'Product preferences',
              subtitle: 'Your makeup preferences and sensitivities',
            ),
            const SizedBox(height: 12),
            _ProfileCard(
              children: [
                if (profile.coveragePreference != null)
                  _ProfileValueRow(
                    icon: Icons.layers_outlined,
                    label: 'Coverage',
                    value: _humanize(profile.coveragePreference),
                    last: profile.finishPreference == null && allergyLabels.isEmpty,
                  ),
                if (profile.finishPreference != null)
                  _ProfileValueRow(
                    icon: Icons.auto_awesome_outlined,
                    label: 'Finish',
                    value: _humanize(profile.finishPreference),
                    last: allergyLabels.isEmpty,
                  ),
                if (allergyLabels.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Ingredients to avoid',
                          style: TextStyle(
                            color: AppColors.textMuted,
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: allergyLabels
                              .map((label) => _ProfileTag(label))
                              .toList(),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ],
          if (profile.updatedAgoText != null) ...[
            const SizedBox(height: 18),
            Center(
              child: Text(
                'Last updated ${profile.updatedAgoText}',
                style: TextStyle(color: AppColors.textMuted, fontSize: 12),
              ),
            ),
          ],
          const SizedBox(height: 20),
          _PrimaryProfileButton(
            label: 'Edit beauty profile',
            icon: Icons.edit_outlined,
            onPressed: _openQuestionnaire,
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyProfile() {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(
        parent: BouncingScrollPhysics(),
      ),
      padding: const EdgeInsets.fromLTRB(24, 18, 24, 32),
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(24, 30, 24, 28),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                AppColors.primary,
                AppColors.primary.withOpacity(AppColors.isDark ? 0.68 : 0.82),
              ],
            ),
            borderRadius: BorderRadius.circular(28),
          ),
          child: Column(
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.16),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.face_retouching_natural_outlined,
                  color: Colors.white,
                  size: 34,
                ),
              ),
              const SizedBox(height: 18),
              const Text(
                'Your beauty profile, made for you',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 21,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Add your skin details and preferences for more personal recommendations.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white.withOpacity(0.88),
                  fontSize: 14,
                  height: 1.45,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        _ProfileCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'What you can add',
                style: TextStyle(
                  color: AppColors.textMain,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 14),
              const _IntroLine(icon: Icons.water_drop_outlined, text: 'Skin type and undertone'),
              const _IntroLine(icon: Icons.palette_outlined, text: 'Skin depth and tone'),
              const _IntroLine(icon: Icons.favorite_border, text: 'Skin concerns and preferences'),
            ],
          ),
        ),
        const SizedBox(height: 24),
        _PrimaryProfileButton(
          label: 'Set up beauty profile',
          icon: Icons.arrow_forward_rounded,
          onPressed: _openQuestionnaire,
        ),
      ],
    );
  }

  Widget _buildLoadError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_outlined, size: 42, color: AppColors.textMuted),
            const SizedBox(height: 14),
            Text(
              'Your profile couldn’t be loaded',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.textMain,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Check your connection and try again.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textMuted, height: 1.4),
            ),
            const SizedBox(height: 18),
            OutlinedButton.icon(
              onPressed: _loadProfile,
              icon: const Icon(Icons.refresh),
              label: const Text('Try again'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProfileHero extends StatelessWidget {
  const _ProfileHero({required this.profile});

  final UserBeautyProfile profile;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            AppColors.primary,
            AppColors.primary.withOpacity(AppColors.isDark ? 0.68 : 0.82),
          ],
        ),
        borderRadius: BorderRadius.circular(26),
        boxShadow: [
          BoxShadow(
            color: AppColors.primary.withOpacity(0.18),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 62,
            height: 62,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.17),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.face_retouching_natural_outlined,
              color: Colors.white,
              size: 31,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'YOUR BEAUTY PROFILE',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.82),
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.4,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '${_humanize(profile.skinType) ?? 'Skin'} · ${_depthLabel(profile.depthLevel) ?? 'Tone'}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  'Personalised to your skin and preferences',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.88),
                    fontSize: 12,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionHeading extends StatelessWidget {
  const _SectionHeading({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              color: AppColors.textMain,
              fontSize: 17,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            subtitle,
            style: TextStyle(color: AppColors.textMuted, fontSize: 12),
          ),
        ],
      );
}

class _ProfileCard extends StatelessWidget {
  const _ProfileCard({this.children, this.child});

  final List<Widget>? children;
  final Widget? child;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: child == null ? EdgeInsets.zero : const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: AppColors.border),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(AppColors.isDark ? 0.08 : 0.025),
              blurRadius: 18,
              offset: const Offset(0, 5),
            ),
          ],
        ),
        child: child ?? Column(mainAxisSize: MainAxisSize.min, children: children ?? const []),
      );
}

class _ProfileValueRow extends StatelessWidget {
  const _ProfileValueRow({
    required this.icon,
    required this.label,
    required this.value,
    this.swatch,
    this.last = false,
  });

  final IconData icon;
  final String label;
  final String? value;
  final Color? swatch;
  final bool last;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: last
            ? null
            : BoxDecoration(
                border: Border(bottom: BorderSide(color: AppColors.border)),
              ),
        child: Row(
          children: [
            Icon(icon, size: 19, color: AppColors.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: TextStyle(color: AppColors.textMuted, fontSize: 13),
              ),
            ),
            if (swatch != null) ...[
              Container(
                width: 17,
                height: 17,
                decoration: BoxDecoration(
                  color: swatch,
                  shape: BoxShape.circle,
                  border: Border.all(color: AppColors.border),
                ),
              ),
              const SizedBox(width: 7),
            ],
            Text(
              value ?? 'Not set',
              style: TextStyle(
                color: value == null ? AppColors.textMuted : AppColors.textMain,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      );
}

class _ProfileTag extends StatelessWidget {
  const _ProfileTag(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.accentPink.withOpacity(AppColors.isDark ? 0.16 : 0.09),
          borderRadius: BorderRadius.circular(30),
          border: Border.all(color: AppColors.accentPink.withOpacity(0.25)),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: AppColors.isDark ? AppColors.textMain : AppColors.primary,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
}

class _EmptyValue extends StatelessWidget {
  const _EmptyValue(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Text(
        label,
        style: TextStyle(color: AppColors.textMuted, fontSize: 13),
      );
}

class _IntroLine extends StatelessWidget {
  const _IntroLine({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Row(
          children: [
            Icon(icon, size: 18, color: AppColors.primary),
            const SizedBox(width: 10),
            Text(text, style: TextStyle(color: AppColors.textMuted, fontSize: 13)),
          ],
        ),
      );
}

class _PrimaryProfileButton extends StatelessWidget {
  const _PrimaryProfileButton({
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => FilledButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 18),
        label: Text(label),
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.primary,
          foregroundColor: Colors.white,
          minimumSize: const Size.fromHeight(52),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
        ),
      );
}

String? _humanize(String? value) {
  if (value == null || value.trim().isEmpty) return null;
  return value
      .replaceAll('_', ' ')
      .split(' ')
      .map((part) => part.isEmpty
          ? part
          : '${part[0].toUpperCase()}${part.substring(1).toLowerCase()}')
      .join(' ');
}

String? _depthLabel(String? level) => level == null
    ? null
    : DepthSwatch.fromLevel(level.toLowerCase())?.label ?? _humanize(level);

String _concernLabel(String id) =>
    SkinConcern.fromId(id)?.label ?? _humanize(id) ?? id;

Color? _parseColor(String? hex) {
  if (hex == null) return null;
  final value = hex.replaceFirst('#', '');
  final parsed = int.tryParse(value, radix: 16);
  if (parsed == null) return null;
  return Color(value.length == 6 ? 0xFF000000 | parsed : parsed);
}
