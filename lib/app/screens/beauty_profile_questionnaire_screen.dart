// lib/app/screens/beauty_profile_questionnaire_screen.dart
//
// 4-step Beauty Profile questionnaire
// Step 1: Skin Type
// Step 2: Undertone (3-question heuristic)
// Step 3: Depth Level (swatch picker)
// Step 4: Skin Concerns (multi-select)

import 'package:flutter/material.dart';

import '../cache/beauty_profile_model.dart';
import '../services/beauty_profile_service.dart';
import '../utils/app_colors.dart';
import '../widgets/app_loader.dart';

// ── SCREEN ────────────────────────────────────────────────────────────────────

class BeautyProfileQuestionnaireScreen extends StatefulWidget {
  const BeautyProfileQuestionnaireScreen({
    super.key,
    this.isEditing = false,
  });

  final bool isEditing;

  @override
  State<BeautyProfileQuestionnaireScreen> createState() =>
      _BeautyProfileQuestionnaireScreenState();
}

class _BeautyProfileQuestionnaireScreenState
    extends State<BeautyProfileQuestionnaireScreen> with TickerProviderStateMixin {
  // ── State ──────────────────────────────────────────────────────────────────

  int _currentStep = 0; // 0-3 for steps 1-4
  bool _isLoading = false;
  bool _isPrefillLoading = true;
  String? _errorMessage;

  // Step 1: Skin Type
  String? _selectedSkinType;

  // Step 2: Undertone quiz
  String? _veinColor;
  String? _jewelryPreference;
  String? _sunReaction;
  bool _isOlive = false;
  String? _calculatedUndertone;

  // Step 3: Depth Level
  String? _selectedDepth;

  // Step 4: Concerns
  final Set<String> _selectedConcerns = {};

  // Animation
  late AnimationController _fadeCtrl;
  late Animation<double> _fadeAnim;

  @override
  void initState() {
    super.initState();

    _fadeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _fadeAnim = CurvedAnimation(parent: _fadeCtrl, curve: Curves.easeOut);
    _fadeCtrl.forward();

    // Load pre-fill data from web if available
    _loadPreFillData();
  }

  @override
  void dispose() {
    _fadeCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadPreFillData() async {
    try {
      final preFill = await BeautyProfileService.fetchPreFillData();

      if (!mounted) return;

      setState(() {
        if (preFill['skin_type'] != null) {
          _selectedSkinType = preFill['skin_type'] as String;
        }
        if (preFill['undertone'] != null) {
          _calculatedUndertone = preFill['undertone'] as String;
        }
        if (preFill['depth_level'] != null) {
          _selectedDepth = preFill['depth_level'] as String;
        }
        if (preFill['concerns'] != null) {
          final concerns = preFill['concerns'] as List;
          _selectedConcerns.addAll(concerns.cast<String>());
        }
      });
    } catch (_) {
      // The questionnaire remains available if saved answers cannot be loaded.
    } finally {
      if (mounted) setState(() => _isPrefillLoading = false);
    }
  }

  // ── STEP NAVIGATION ───────────────────────────────────────────────────────

  void _nextStep() {
    // Validate current step
    if (!_validateStep(_currentStep)) {
      return;
    }

    if (_currentStep < 3) {
      setState(() => _currentStep++);
      _fadeCtrl.reset();
      _fadeCtrl.forward();
    }
  }

  void _previousStep() {
    if (_currentStep > 0) {
      setState(() => _currentStep--);
      _fadeCtrl.reset();
      _fadeCtrl.forward();
    }
  }

  bool _validateStep(int step) {
    setState(() => _errorMessage = null);

    switch (step) {
      case 0: // Skin Type
        if (_selectedSkinType == null) {
          setState(() => _errorMessage = 'Please select your skin type');
          return false;
        }
        return true;

      case 1: // Undertone
        if (_veinColor == null) {
          setState(() => _errorMessage = 'Please answer all undertone questions');
          return false;
        }
        if (_jewelryPreference == null && !_isOlive) {
          setState(() => _errorMessage = 'Please answer all undertone questions');
          return false;
        }
        if (_sunReaction == null && !_isOlive) {
          setState(() => _errorMessage = 'Please answer all undertone questions');
          return false;
        }
        return true;

      case 2: // Depth Level
        if (_selectedDepth == null) {
          setState(() => _errorMessage = 'Please select your depth level');
          return false;
        }
        return true;

      case 3: // Concerns
        if (_selectedConcerns.isEmpty) {
          setState(() => _errorMessage = 'Please select at least one concern');
          return false;
        }
        return true;

      default:
        return true;
    }
  }

  // ── SAVE PROFILE ───────────────────────────────────────────────────────────

  Future<void> _saveProfile() async {
    if (!_validateStep(3)) {
      return;
    }

    setState(() => _isLoading = true);

    try {
      // Build profile
      final existingProfile = BeautyProfileService.getCachedProfile();
      final profile = UserBeautyProfile(
        skinType: _selectedSkinType,
        undertone: _calculatedUndertone,
        depthLevel: _selectedDepth,
        skinToneHex: BeautyProfileService.depthToHex(_selectedDepth) ??
            existingProfile?.skinToneHex,
        monkScale: existingProfile?.monkScale,
        coveragePreference: existingProfile?.coveragePreference,
        finishPreference: existingProfile?.finishPreference,
        allergies: existingProfile?.allergies,
        concerns: _selectedConcerns.toList(),
        source: 'manual',
        updatedAt: DateTime.now().toUtc(),
      );

      // Save to backend
      final success = await BeautyProfileService.saveProfile(profile);

      if (!mounted) return;

      setState(() => _isLoading = false);

      if (success) {
        // Cache the profile
        BeautyProfileService.setCachedProfile(profile);

        // Show success and return
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('✨ Beauty Profile saved!'),
            duration: Duration(seconds: 2),
          ),
        );

        Future.delayed(const Duration(milliseconds: 500), () {
          if (mounted) {
            Navigator.pop(context, profile);
          }
        });
      } else {
        setState(() => _errorMessage = BeautyProfileService.lastSaveError ??
            'Could not save your beauty profile.');
      }
    } catch (_) {
      setState(() {
        _isLoading = false;
        _errorMessage = 'Could not save your beauty profile.';
      });
    }
  }

  // ── BUILD STEPS ────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    AppColors.watch(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(
          '${widget.isEditing ? 'Update profile' : 'Beauty profile'} · '
          'Step ${_currentStep + 1} of 4',
        ),
        centerTitle: true,
      ),
      body: FadeTransition(
        opacity: _fadeAnim,
        child: Column(
          children: [
            // Progress indicator
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: List.generate(4, (i) {
                  final isActive = i <= _currentStep;
                  final isDone = i < _currentStep;
                  return Expanded(
                    child: Container(
                      height: 4,
                      margin: EdgeInsets.only(right: i < 3 ? 8 : 0),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(2),
                        color: isDone
                            ? AppColors.accentPink
                            : isActive
                                ? AppColors.accentPink.withOpacity(0.5)
                                : AppColors.neutral300,
                      ),
                    ),
                  );
                }),
              ),
            ),

            // Error message
            if (_errorMessage != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.red.withOpacity(0.1),
                    border: Border.all(color: Colors.red.withOpacity(0.3)),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.error_outline, color: Colors.red, size: 20),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          _errorMessage!,
                          style: const TextStyle(color: Colors.red, fontSize: 14),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

            // Step content
            Expanded(
              child: _isPrefillLoading
                  ? const Center(child: AppLoader(size: 32))
                  : SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child: switch (_currentStep) {
                        0 => _buildStep1SkinType(),
                        1 => _buildStep2Undertone(),
                        2 => _buildStep3Depth(),
                        3 => _buildStep4Concerns(),
                        _ => const SizedBox(),
                      },
                    ),
            ),

          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
          decoration: BoxDecoration(
            color: Theme.of(context).scaffoldBackgroundColor,
            border: Border(
              top: BorderSide(color: AppColors.neutral300),
            ),
          ),
          child: Row(
            children: [
              if (_currentStep > 0)
                Expanded(
                  child: OutlinedButton(
                    onPressed: (_isLoading || _isPrefillLoading)
                        ? null
                        : _previousStep,
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                    ),
                    child: const Text('Back'),
                  ),
                ),
              if (_currentStep > 0) const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton(
                  onPressed: (_isLoading || _isPrefillLoading)
                      ? null
                      : (_currentStep == 3 ? _saveProfile : _nextStep),
                  style: ElevatedButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                    backgroundColor: AppColors.accentPink,
                    foregroundColor: Colors.white,
                  ),
                  child: _isLoading
                      ? const AppLoader.inline(
                          size: 20,
                          strokeWidth: 2,
                          color: Colors.white,
                        )
                      : Text(
                          _isPrefillLoading
                              ? 'Loading profile…'
                              : _currentStep == 3
                                  ? (widget.isEditing ? 'Save changes' : 'Save profile')
                                  : 'Next',
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── STEP 1: SKIN TYPE ──────────────────────────────────────────────────────

  Widget _buildStep1SkinType() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'What is your skin type?',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 8),
        Text(
          'This helps us recommend products suited to your skin\'s needs.',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: AppColors.neutral700,
              ),
        ),
        const SizedBox(height: 24),
        ...SkinType.all.map((skinType) {
          final isSelected = _selectedSkinType == skinType.id;
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Material(
              child: InkWell(
                onTap: () => setState(() => _selectedSkinType = skinType.id),
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: isSelected
                          ? AppColors.accentPink
                          : AppColors.neutral300,
                      width: isSelected ? 2 : 1,
                    ),
                    borderRadius: BorderRadius.circular(12),
                    color: isSelected
                        ? AppColors.accentPink.withOpacity(0.05)
                        : Colors.transparent,
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 24,
                        height: 24,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: isSelected
                                ? AppColors.accentPink
                                : AppColors.neutral300,
                            width: 2,
                          ),
                        ),
                        child: isSelected
                            ? Center(
                                child: Container(
                                  width: 12,
                                  height: 12,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: AppColors.accentPink,
                                  ),
                                ),
                              )
                            : null,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              skinType.label,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 16,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              skinType.description,
                              style: TextStyle(
                                fontSize: 14,
                                color: AppColors.neutral700,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        }),
      ],
    );
  }

  // ── STEP 2: UNDERTONE ──────────────────────────────────────────────────────

  Widget _buildStep2Undertone() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'What is your undertone?',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 8),
        Text(
          'Answer 3 quick questions — this is an established method for determining undertone.',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: AppColors.neutral700,
              ),
        ),
        const SizedBox(height: 24),

        // Q1: Vein color
        _buildUndertoneQuestion(
          'Q1: Look at the veins on your wrist in natural light. What color are they?',
          [
            ('blue_purple', '🔵 Blue/Purple → Cool'),
            ('green', '💚 Green → Warm'),
            ('unsure', '❓ Hard to tell'),
          ],
          _veinColor,
          (val) => setState(() => _veinColor = val),
        ),

        const SizedBox(height: 20),

        // Q2: Jewelry
        _buildUndertoneQuestion(
          'Q2: Which metal looks better on you?',
          [
            ('silver', '✨ Silver/Platinum → Cool'),
            ('gold', '✨ Gold/Rose Gold → Warm'),
            ('no_preference', '🤝 Both look good'),
          ],
          _jewelryPreference,
          (val) => setState(() => _jewelryPreference = val),
          enabled: !_isOlive,
        ),

        const SizedBox(height: 20),

        // Q3: Sun reaction
        _buildUndertoneQuestion(
          'Q3: In the sun, your skin...?',
          [
            ('burns', '🔴 Burns easily'),
            ('tans', '🟠 Tans easily'),
            ('mixed', '🟡 Both'),
          ],
          _sunReaction,
          (val) => setState(() => _sunReaction = val),
          enabled: !_isOlive,
        ),

        const SizedBox(height: 20),

        // Olive self-identification
        Material(
          child: InkWell(
            onTap: () {
              setState(() {
                _isOlive = !_isOlive;
                if (_isOlive) {
                  _calculatedUndertone = 'olive';
                }
              });
            },
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                border: Border.all(
                  color: _isOlive
                      ? AppColors.accentPink
                      : AppColors.neutral300,
                ),
                borderRadius: BorderRadius.circular(8),
                color: _isOlive
                    ? AppColors.accentPink.withOpacity(0.05)
                    : Colors.transparent,
              ),
              child: Row(
                children: [
                  Checkbox(
                    value: _isOlive,
                    onChanged: (v) {
                      setState(() {
                        _isOlive = v ?? false;
                        if (_isOlive) {
                          _calculatedUndertone = 'olive';
                        }
                      });
                    },
                  ),
                  const Expanded(
                    child: Text('I have an olive undertone'),
                  ),
                ],
              ),
            ),
          ),
        ),

        const SizedBox(height: 24),

        // Result
        if (!_isOlive && _veinColor != null)
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.accentPink.withOpacity(0.1),
              border: Border.all(color: AppColors.accentPink.withOpacity(0.3)),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Your undertone:',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                Text(
                  _calculateDisplayUndertone(),
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Colors.pink,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildUndertoneQuestion(
    String question,
    List<(String, String)> options,
    String? selectedValue,
    ValueChanged<String> onChanged, {
    bool enabled = true,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          question,
          style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 15),
        ),
        const SizedBox(height: 12),
        ...options.map((opt) {
          final (value, label) = opt;
          final isSelected = selectedValue == value;
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Material(
              child: InkWell(
                onTap: enabled ? () => onChanged(value) : null,
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: isSelected
                          ? AppColors.accentPink
                          : AppColors.neutral300,
                    ),
                    borderRadius: BorderRadius.circular(8),
                    color: isSelected
                        ? AppColors.accentPink.withOpacity(0.05)
                        : Colors.transparent,
                  ),
                  child: Text(
                    label,
                    style: TextStyle(
                      color: enabled ? null : AppColors.neutral500,
                      fontWeight: isSelected ? FontWeight.w600 : null,
                    ),
                  ),
                ),
              ),
            ),
          );
        }),
      ],
    );
  }

  String _calculateDisplayUndertone() {
    final quiz = UndertoneQuizResult(
      veinColor: _veinColor,
      jewelryPreference: _jewelryPreference,
      sunReaction: _sunReaction,
      isSelfIdentifiedOlive: _isOlive,
    );
    final calculated = BeautyProfileService.calculateUndertone(quiz);
    _calculatedUndertone = calculated;
    return '${calculated[0].toUpperCase()}${calculated.substring(1)} Undertone';
  }

  // ── STEP 3: DEPTH LEVEL ────────────────────────────────────────────────────

  Widget _buildStep3Depth() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'What is your depth level?',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 8),
        Text(
          'Choose the swatch that best matches your skin tone.',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: AppColors.neutral700,
              ),
        ),
        const SizedBox(height: 24),
        ...DepthSwatch.all.map((swatch) {
          final isSelected = _selectedDepth == swatch.level;
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Material(
              child: InkWell(
                onTap: () => setState(() => _selectedDepth = swatch.level),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: isSelected
                          ? AppColors.accentPink
                          : AppColors.neutral300,
                      width: isSelected ? 2 : 1,
                    ),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 64,
                        height: 64,
                        decoration: BoxDecoration(
                          color: Color(int.parse(
                              '0xFF${swatch.hex.replaceFirst('#', '')}')),
                          borderRadius: BorderRadius.circular(8),
                          border: isSelected
                              ? Border.all(
                                  color: AppColors.accentPink,
                                  width: 2,
                                )
                              : null,
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              swatch.label,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 16,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              swatch.description,
                              style: TextStyle(
                                fontSize: 14,
                                color: AppColors.neutral700,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        }),
      ],
    );
  }

  // ── STEP 4: CONCERNS ───────────────────────────────────────────────────────

  Widget _buildStep4Concerns() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'What are your skin concerns?',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 8),
        Text(
          'Select all that apply. This helps us recommend suitable makeup.',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: AppColors.neutral700,
              ),
        ),
        const SizedBox(height: 24),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: SkinConcern.all.map((concern) {
            final isSelected = _selectedConcerns.contains(concern.id);
            return Material(
              child: InkWell(
                onTap: () {
                  setState(() {
                    if (isSelected) {
                      _selectedConcerns.remove(concern.id);
                    } else {
                      _selectedConcerns.add(concern.id);
                    }
                  });
                },
                child: Chip(
                  label: Text('${concern.icon} ${concern.label}'),
                  backgroundColor: isSelected
                      ? AppColors.accentPink.withOpacity(0.2)
                      : AppColors.neutral200,
                  side: BorderSide(
                    color: isSelected
                        ? AppColors.accentPink
                        : AppColors.neutral300,
                  ),
                  labelPadding: const EdgeInsets.symmetric(horizontal: 12),
                ),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }
}
