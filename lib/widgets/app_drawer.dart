import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../main.dart'; // For CustomCachedImage, HomePage, etc.
import '../screens/daily_expenditure_screen.dart';
import '../screens/deleted_transactions_screen.dart';
import '../screens/reports_screen.dart';
import '../screens/settings_screen.dart';
import '../screens/about_screen.dart';

class AppDrawer extends StatelessWidget {
  final String currentRoute;

  const AppDrawer({super.key, required this.currentRoute});

  @override
  Widget build(BuildContext context) {
    final currentUser = FirebaseAuth.instance.currentUser;

    return Drawer(
      backgroundColor: Colors.grey[950],
      child: Column(
        children: [
          // Drawer Header
          currentUser != null
              ? StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                  stream: FirebaseFirestore.instance
                      .collection('users')
                      .doc(currentUser.uid)
                      .snapshots(),
                  builder: (context, snapshot) {
                    final data = snapshot.hasData ? snapshot.data!.data() : null;
                    final photoUrl = data?['photoUrl'] as String? ?? currentUser.photoURL ?? '';
                    final name = data?['name'] as String? ?? currentUser.displayName ?? 'Hisab Kitab User';
                    final email = data?['email'] as String? ?? currentUser.email ?? 'Offline / Local Mode';

                    return Container(
                      padding: const EdgeInsets.fromLTRB(16, 48, 16, 20),
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: Colors.grey[900],
                        border: Border(
                          bottom: BorderSide(
                            color: Colors.grey[850] ?? const Color(0xFF212121),
                            width: 1,
                          ),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircleAvatar(
                            radius: 32,
                            backgroundColor: Colors.grey[800],
                            child: photoUrl.isNotEmpty
                                ? ClipOval(
                                    child: CustomCachedImage(
                                      url: photoUrl,
                                      width: 64,
                                      height: 64,
                                      fit: BoxFit.cover,
                                    ),
                                  )
                                : const Icon(
                                    Icons.person,
                                    color: Colors.white,
                                    size: 32,
                                  ),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            name,
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            email,
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey[400],
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 12),
                          InkWell(
                            onTap: () {
                              Navigator.pop(context); // Close drawer
                              Navigator.push(
                                context,
                                MaterialPageRoute(builder: (_) => const ProfilePage()),
                              );
                            },
                            borderRadius: BorderRadius.circular(6),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                              decoration: BoxDecoration(
                                color: const Color(0xFF1E1E1E), // Subtle dark background matching dark theme cards/buttons
                                border: Border.all(
                                  color: Colors.amber.withValues(alpha: 0.6), // Thin accent border
                                  width: 1.0,
                                ),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: const [
                                  Icon(
                                    Icons.person_outline_rounded,
                                    size: 12, // Reduced icon size slightly
                                    color: Colors.amber,
                                  ),
                                  SizedBox(width: 6),
                                  Text(
                                    "View & Edit Profile",
                                    style: TextStyle(
                                      fontSize: 10,
                                      color: Colors.amber,
                                      fontWeight: FontWeight.w500, // Medium font weight
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                )
              : Container(
                  padding: const EdgeInsets.fromLTRB(16, 48, 16, 20),
                  decoration: BoxDecoration(
                    color: Colors.grey[900],
                    border: Border(
                      bottom: BorderSide(
                        color: Colors.grey[850] ?? const Color(0xFF212121),
                        width: 1,
                      ),
                    ),
                  ),
                  child: Row(
                    children: [
                      CircleAvatar(
                        radius: 32,
                        backgroundColor: Colors.grey[800],
                        child: const Icon(
                          Icons.person,
                          color: Colors.white,
                          size: 32,
                        ),
                      ),
                      const SizedBox(width: 16),
                      const Expanded(
                        child: Text(
                          'Guest User',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
          // Navigation Items
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                _buildDrawerItem(
                  context,
                  icon: Icons.dashboard_outlined,
                  title: 'Dashboard',
                  route: 'dashboard',
                  onTap: () {
                    if (currentRoute == 'dashboard') {
                      Navigator.pop(context);
                    } else {
                      Navigator.pushReplacement(
                        context,
                        MaterialPageRoute(builder: (_) => const HomePage()),
                      );
                    }
                  },
                ),
                _buildDrawerItem(
                  context,
                  icon: Icons.account_balance_wallet_outlined,
                  title: 'Daily Expenditure',
                  route: 'daily_expenditure',
                  onTap: () {
                    if (currentRoute == 'daily_expenditure') {
                      Navigator.pop(context);
                    } else {
                      Navigator.pushReplacement(
                        context,
                        MaterialPageRoute(builder: (_) => const DailyExpenditureScreen()),
                      );
                    }
                  },
                ),
                _buildDrawerItem(
                  context,
                  icon: Icons.bar_chart_outlined,
                  title: 'Reports',
                  route: 'reports',
                  onTap: () {
                    if (currentRoute == 'reports') {
                      Navigator.pop(context);
                    } else {
                      Navigator.pushReplacement(
                        context,
                        MaterialPageRoute(builder: (_) => const ReportsScreen()),
                      );
                    }
                  },
                ),
                _buildDrawerItem(
                  context,
                  icon: Icons.delete_outline_rounded,
                  title: 'Deleted Transactions',
                  route: 'deleted_transactions',
                  onTap: () {
                    if (currentRoute == 'deleted_transactions') {
                      Navigator.pop(context);
                    } else {
                      Navigator.pushReplacement(
                        context,
                        MaterialPageRoute(builder: (_) => const DeletedTransactionsScreen()),
                      );
                    }
                  },
                ),
                const Divider(color: Colors.white10),
                _buildDrawerItem(
                  context,
                  icon: Icons.settings_outlined,
                  title: 'Settings',
                  route: 'settings',
                  onTap: () {
                    if (currentRoute == 'settings') {
                      Navigator.pop(context);
                    } else {
                      Navigator.pushReplacement(
                        context,
                        MaterialPageRoute(builder: (_) => const SettingsScreen()),
                      );
                    }
                  },
                ),
                _buildDrawerItem(
                  context,
                  icon: Icons.info_outline_rounded,
                  title: 'About',
                  route: 'about',
                  onTap: () {
                    if (currentRoute == 'about') {
                      Navigator.pop(context);
                    } else {
                      Navigator.pushReplacement(
                        context,
                        MaterialPageRoute(builder: (_) => const AboutScreen()),
                      );
                    }
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDrawerItem(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String route,
    required VoidCallback onTap,
  }) {
    final isSelected = currentRoute == route;
    return ListTile(
      leading: Icon(
        icon,
        color: isSelected ? Colors.amber : Colors.white70,
      ),
      title: Text(
        title,
        style: TextStyle(
          color: isSelected ? Colors.amber : Colors.white,
          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
        ),
      ),
      selected: isSelected,
      selectedTileColor: Colors.amber.withValues(alpha: 0.1),
      onTap: onTap,
    );
  }
}
