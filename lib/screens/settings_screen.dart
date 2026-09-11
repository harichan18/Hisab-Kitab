import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../main.dart'; // For ProfilePage
import 'daily_expenditure_screen.dart';
import 'reports_screen.dart';
import 'deleted_transactions_screen.dart';
import 'about_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late bool _isDarkMode;

  @override
  void initState() {
    super.initState();
    _isDarkMode = themeModeNotifier.value == ThemeMode.dark;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark ? AppColors.backgroundDark : AppColors.background,
      appBar: AppBar(
        title: Text(
          'Settings',
          style: TextStyle(
            color: isDark ? AppColors.textPrimaryDark : AppColors.textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
        centerTitle: true,
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: Icon(
            Icons.arrow_back_ios_new_rounded,
            size: 20,
            color: isDark ? AppColors.textPrimaryDark : AppColors.textPrimary,
          ),
          onPressed: () => Navigator.pop(context),
          tooltip: 'Back',
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Appearance Section
              _buildSectionHeader('Appearance', isDark),
              _buildCardContainer([
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
                  leading: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: isDark ? const Color(0xFF1E222A) : const Color(0xFFFEF3C7),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                      _isDarkMode ? Icons.dark_mode_rounded : Icons.light_mode_rounded,
                      color: const Color(0xFFF59E0B),
                      size: 18,
                    ),
                  ),
                  title: Text(
                    'Theme Mode',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: isDark ? AppColors.textPrimaryDark : AppColors.textPrimary,
                    ),
                  ),
                  subtitle: Text(
                    _isDarkMode ? 'Dark Mode' : 'Light Mode',
                    style: TextStyle(
                      fontSize: 12,
                      color: isDark ? AppColors.textSecondaryDark : AppColors.textSecondary,
                    ),
                  ),
                  trailing: Switch.adaptive(
                    value: _isDarkMode,
                    activeTrackColor: const Color(0xFF10B981),
                    activeThumbColor: Colors.white,
                    onChanged: (value) async {
                      setState(() {
                        _isDarkMode = value;
                      });
                      await AppPrefs.setDarkMode(value);
                      themeModeNotifier.value = value ? ThemeMode.dark : ThemeMode.light;
                    },
                  ),
                ),
              ], isDark),
              const SizedBox(height: 18),

              // Activity & Tracking Section
              _buildSectionHeader('Activity & Records', isDark),
              _buildCardContainer([
                _buildSettingsTile(
                  icon: Icons.receipt_long_rounded,
                  iconBg: isDark ? const Color(0xFF1E222A) : const Color(0xFFF3F4F6),
                  iconColor: isDark ? const Color(0xFF94A3B8) : AppColors.textPrimary,
                  title: 'Daily Expenditure',
                  subtitle: 'Track your personal daily spending & budget',
                  isDark: isDark,
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const DailyExpenditureScreen()),
                    );
                  },
                ),
                _buildTileDivider(isDark),
                _buildSettingsTile(
                  icon: Icons.bar_chart_rounded,
                  iconBg: isDark ? const Color(0xFF1E222A) : const Color(0xFFF3F4F6),
                  iconColor: isDark ? const Color(0xFF94A3B8) : AppColors.textPrimary,
                  title: 'Reports & Analytics',
                  subtitle: 'Income, spending patterns & analytics',
                  isDark: isDark,
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const ReportsScreen()),
                    );
                  },
                ),
                _buildTileDivider(isDark),
                _buildSettingsTile(
                  icon: Icons.delete_outline_rounded,
                  iconBg: isDark ? const Color(0xFF26181A) : AppColors.payBg,
                  iconColor: AppColors.payText,
                  title: 'Deleted Transactions',
                  subtitle: 'View and restore removed entries',
                  isDark: isDark,
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const DeletedTransactionsScreen()),
                    );
                  },
                ),
              ], isDark),
              const SizedBox(height: 18),

              // Account Section
              _buildSectionHeader('Account & Profile', isDark),
              _buildCardContainer([
                _buildSettingsTile(
                  icon: Icons.person_outline_rounded,
                  iconBg: isDark ? const Color(0xFF1E222A) : const Color(0xFFF3F4F6),
                  iconColor: isDark ? const Color(0xFF94A3B8) : AppColors.textPrimary,
                  title: 'Profile & Payment Details',
                  subtitle: 'Manage name, photo, UPI ID & mobile number',
                  isDark: isDark,
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const ProfilePage()),
                    );
                  },
                ),
              ], isDark),
              const SizedBox(height: 18),

              // App Info Section
              _buildSectionHeader('Information', isDark),
              _buildCardContainer([
                _buildSettingsTile(
                  icon: Icons.info_outline_rounded,
                  iconBg: isDark ? const Color(0xFF1E222A) : const Color(0xFFF3F4F6),
                  iconColor: isDark ? const Color(0xFF94A3B8) : AppColors.textSecondary,
                  title: 'About Hisab Kitab',
                  subtitle: 'Version 1.0.0 • Terms & Credits',
                  isDark: isDark,
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const AboutScreen()),
                    );
                  },
                ),
              ], isDark),
              const SizedBox(height: 24),

              // Sign Out Tile
              InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const ProfilePage()),
                  );
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  decoration: BoxDecoration(
                    color: isDark ? AppColors.surfaceDark : Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: isDark ? AppColors.borderDark : AppColors.borderLight,
                      width: 0.8,
                    ),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.logout_rounded, color: AppColors.payText, size: 20),
                      SizedBox(width: 12),
                      Text(
                        'Manage Account & Sign Out',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: AppColors.payText,
                        ),
                      ),
                      Spacer(),
                      Icon(Icons.chevron_right_rounded, color: AppColors.textMuted, size: 20),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title, bool isDark) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(
        title.toUpperCase(),
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: isDark ? AppColors.textMutedDark : AppColors.textMuted,
          letterSpacing: 0.8,
        ),
      ),
    );
  }

  Widget _buildCardContainer(List<Widget> children, bool isDark) {
    return Container(
      decoration: BoxDecoration(
        color: isDark ? AppColors.surfaceDark : Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: isDark ? AppColors.borderDark : AppColors.borderLight,
          width: 0.8,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.02),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        children: children,
      ),
    );
  }

  Widget _buildSettingsTile({
    required IconData icon,
    required Color iconBg,
    required Color iconColor,
    required String title,
    required String subtitle,
    required bool isDark,
    required VoidCallback onTap,
  }) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: iconBg,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Center(
          child: Icon(icon, color: iconColor, size: 18),
        ),
      ),
      title: Text(
        title,
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: isDark ? AppColors.textPrimaryDark : AppColors.textPrimary,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: TextStyle(
          fontSize: 12,
          color: isDark ? AppColors.textSecondaryDark : AppColors.textSecondary,
        ),
      ),
      trailing: Icon(
        Icons.chevron_right_rounded,
        color: isDark ? AppColors.textMutedDark : AppColors.textMuted,
        size: 20,
      ),
      onTap: onTap,
    );
  }

  Widget _buildTileDivider(bool isDark) {
    return Divider(
      height: 1,
      thickness: 0.8,
      indent: 54,
      endIndent: 16,
      color: isDark ? AppColors.dividerDark : AppColors.divider,
    );
  }
}
