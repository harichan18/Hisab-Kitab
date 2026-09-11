import 'package:flutter/material.dart';
import '../widgets/app_drawer.dart';
import '../theme/app_theme.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? AppColors.textPrimaryDark : AppColors.textPrimary;
    final subtextColor = isDark ? AppColors.textSecondaryDark : AppColors.textSecondary;
    final cardBg = isDark ? AppColors.surfaceDark : Colors.white;
    final cardBorder = isDark ? AppColors.borderDark : AppColors.borderLight;

    return Scaffold(
      backgroundColor: isDark ? AppColors.backgroundDark : AppColors.background,
      appBar: AppBar(
        title: Text(
          'About Hisab Kitab',
          style: TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 18,
            color: textColor,
          ),
        ),
        centerTitle: true,
        leading: Navigator.canPop(context)
            ? IconButton(
                icon: Icon(
                  Icons.arrow_back_ios_new_rounded,
                  color: textColor,
                  size: 20,
                ),
                onPressed: () => Navigator.of(context).pop(),
              )
            : Builder(
                builder: (context) => IconButton(
                  icon: Icon(Icons.menu_rounded, color: textColor),
                  onPressed: () => Scaffold.of(context).openDrawer(),
                ),
              ),
      ),
      drawer: const AppDrawer(currentRoute: 'about'),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(28.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: cardBg,
                  shape: BoxShape.circle,
                  border: Border.all(color: cardBorder),
                ),
                child: Icon(Icons.info_outline_rounded, size: 48, color: textColor),
              ),
              const SizedBox(height: 20),
              Text(
                'Hisab Kitab',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: textColor),
              ),
              const SizedBox(height: 6),
              Text(
                'Version 1.0.0',
                style: TextStyle(color: subtextColor, fontWeight: FontWeight.w500, fontSize: 13),
              ),
              const SizedBox(height: 24),
              Text(
                'Hisab Kitab is your ultimate companion for managing both shared debts with friends and your personal daily spending in one integrated, easy-to-use application.',
                textAlign: TextAlign.center,
                style: TextStyle(color: subtextColor, height: 1.5, fontSize: 14),
              ),
              const SizedBox(height: 40),
              Text(
                '© 2026 Hisab Kitab Team',
                style: TextStyle(color: isDark ? AppColors.textMutedDark : AppColors.textMuted, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
