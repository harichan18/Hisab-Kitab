import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../theme/app_theme.dart';
import '../models/expense_model.dart';
import '../services/expense_service.dart';

class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key});

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  String _selectedPeriod = 'This Month';
  List<ExpenseModel> _expenses = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadExpenses();
  }

  Future<void> _loadExpenses() async {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? 'offline_user';
    final data = await ExpenseService.getExpensesOnce(uid);
    if (mounted) {
      setState(() {
        _expenses = data;
        _isLoading = false;
      });
    }
  }

  double get _totalSpending {
    final now = DateTime.now();
    if (_selectedPeriod == 'This Month') {
      return _expenses
          .where((e) => e.expenseDate.year == now.year && e.expenseDate.month == now.month)
          .fold(0.0, (sum, e) => sum + e.amount);
    } else if (_selectedPeriod == 'This Week') {
      final startOfWeek = now.subtract(Duration(days: now.weekday - 1));
      final startOfDay = DateTime(startOfWeek.year, startOfWeek.month, startOfWeek.day);
      return _expenses
          .where((e) => e.expenseDate.isAfter(startOfDay) || e.expenseDate.isAtSameMomentAs(startOfDay))
          .fold(0.0, (sum, e) => sum + e.amount);
    } else {
      return _expenses.fold(0.0, (sum, e) => sum + e.amount);
    }
  }

  Map<String, double> get _categorySpending {
    final Map<String, double> map = {
      'Food': 0,
      'Travel': 0,
      'Shopping': 0,
      'Others': 0,
    };
    final now = DateTime.now();
    final filtered = _expenses.where((e) {
      if (_selectedPeriod == 'This Month') {
        return e.expenseDate.year == now.year && e.expenseDate.month == now.month;
      }
      return true;
    });

    for (final e in filtered) {
      if (map.containsKey(e.category)) {
        map[e.category] = (map[e.category] ?? 0) + e.amount;
      } else {
        map['Others'] = (map['Others'] ?? 0) + e.amount;
      }
    }
    return map;
  }

  @override
  Widget build(BuildContext context) {
    final catSpending = _categorySpending;
    final total = _totalSpending;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark ? AppColors.backgroundDark : AppColors.background,
      appBar: AppBar(
        title: Text(
          'Reports',
          style: TextStyle(
            color: isDark ? AppColors.textPrimaryDark : AppColors.textPrimary,
            fontWeight: FontWeight.w700,
          ),
        ),
        centerTitle: true,
        leading: IconButton(
          icon: Icon(
            Icons.arrow_back_ios_new_rounded,
            size: 20,
            color: isDark ? AppColors.textPrimaryDark : AppColors.textPrimary,
          ),
          onPressed: () => Navigator.pop(context),
          tooltip: 'Back',
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Container(
              height: 34,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: isDark ? AppColors.surfaceDark : Colors.white,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: isDark ? AppColors.borderDark : AppColors.borderLight,
                  width: 0.8,
                ),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: _selectedPeriod,
                  dropdownColor: isDark ? AppColors.surfaceDark : Colors.white,
                  icon: Icon(
                    Icons.keyboard_arrow_down_rounded,
                    size: 18,
                    color: isDark ? AppColors.textPrimaryDark : AppColors.textPrimary,
                  ),
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: isDark ? AppColors.textPrimaryDark : AppColors.textPrimary,
                  ),
                  items: const [
                    DropdownMenuItem(value: 'This Month', child: Text('This Month')),
                    DropdownMenuItem(value: 'This Week', child: Text('This Week')),
                    DropdownMenuItem(value: 'All Time', child: Text('All Time')),
                  ],
                  onChanged: (val) {
                    if (val != null) setState(() => _selectedPeriod = val);
                  },
                ),
              ),
            ),
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Column(
                children: [
                  // Total Spending Card
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: isDark ? AppColors.surfaceDark : Colors.white,
                      borderRadius: BorderRadius.circular(22),
                      border: Border.all(
                        color: isDark ? AppColors.borderDark : AppColors.borderLight,
                        width: 0.8,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.02),
                          blurRadius: 10,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(6),
                                  decoration: BoxDecoration(
                                    color: isDark ? AppColors.surfaceVariantDark : AppColors.surfaceVariant,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Icon(
                                    Icons.account_balance_wallet_outlined,
                                    size: 16,
                                    color: isDark ? AppColors.textSecondaryDark : AppColors.textSecondary,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  "Total Spending",
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: isDark ? AppColors.textSecondaryDark : AppColors.textSecondary,
                                  ),
                                ),
                              ],
                            ),
                            Icon(
                              Icons.bar_chart_rounded,
                              size: 20,
                              color: isDark ? AppColors.textSecondaryDark : AppColors.textSecondary,
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Text(
                          "₹${total.toStringAsFixed(0)}",
                          style: TextStyle(
                            fontSize: 32,
                            fontWeight: FontWeight.w800,
                            color: isDark ? AppColors.textPrimaryDark : AppColors.textPrimary,
                            letterSpacing: -0.5,
                          ),
                        ),
                        const SizedBox(height: 24),
                        // Minimal bar chart
                        SizedBox(
                          height: 90,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              _buildChartBar('1', 0.25, isDark),
                              _buildChartBar('5', 0.45, isDark),
                              _buildChartBar('10', 0.2, isDark),
                              _buildChartBar('15', 0.65, isDark),
                              _buildChartBar('20', 0.35, isDark),
                              _buildChartBar('25', 0.5, isDark),
                              _buildChartBar('30', 0.3, isDark),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Category Wise Card
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: isDark ? AppColors.surfaceDark : Colors.white,
                      borderRadius: BorderRadius.circular(22),
                      border: Border.all(
                        color: isDark ? AppColors.borderDark : AppColors.borderLight,
                        width: 0.8,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.02),
                          blurRadius: 10,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.pie_chart_outline_rounded,
                              size: 18,
                              color: isDark ? AppColors.textPrimaryDark : AppColors.textPrimary,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              "Category Wise",
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                                color: isDark ? AppColors.textPrimaryDark : AppColors.textPrimary,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 24),
                        Row(
                          children: [
                            // Custom Donut Chart
                            SizedBox(
                              width: 120,
                              height: 120,
                              child: CustomPaint(
                                painter: _DonutChartPainter(
                                  data: catSpending,
                                  total: total > 0 ? total : 1.0,
                                  isDark: isDark,
                                ),
                              ),
                            ),
                            const SizedBox(width: 32),
                            // Legend
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  _buildLegendItem("Food", const Color(0xFF4F46E5), isDark),
                                  const SizedBox(height: 8),
                                  _buildLegendItem("Travel", const Color(0xFFEF4444), isDark),
                                  const SizedBox(height: 8),
                                  _buildLegendItem("Shopping", const Color(0xFFF59E0B), isDark),
                                  const SizedBox(height: 8),
                                  _buildLegendItem(
                                    "Others",
                                    isDark ? const Color(0xFF94A3B8) : const Color(0xFF1E293B),
                                    isDark,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _buildChartBar(String label, double factor, bool isDark) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Container(
          width: 22,
          height: 60 * factor,
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF27272A) : const Color(0xFFE5E7EB),
            borderRadius: BorderRadius.circular(6),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            color: isDark ? AppColors.textMutedDark : AppColors.textMuted,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  Widget _buildLegendItem(String label, Color color, bool isDark) {
    return Row(
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 8),
        Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: isDark ? AppColors.textSecondaryDark : AppColors.textSecondary,
          ),
        ),
      ],
    );
  }
}

class _DonutChartPainter extends CustomPainter {
  final Map<String, double> data;
  final double total;
  final bool isDark;

  _DonutChartPainter({required this.data, required this.total, required this.isDark});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;
    const strokeWidth = 16.0;

    final colors = {
      'Food': const Color(0xFF4F46E5),
      'Travel': const Color(0xFFEF4444),
      'Shopping': const Color(0xFFF59E0B),
      'Others': isDark ? const Color(0xFF94A3B8) : const Color(0xFF1E293B),
    };

    final bgPaint = Paint()
      ..color = isDark ? const Color(0xFF252932) : const Color(0xFFF3F4F6)
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke;

    canvas.drawCircle(center, radius - strokeWidth / 2, bgPaint);

    double startAngle = -1.5708; // -pi/2
    final hasData = data.values.any((v) => v > 0);

    if (!hasData) {
      final placeholderPaint = Paint()
        ..color = isDark ? const Color(0xFF2E333D) : const Color(0xFFE5E7EB)
        ..strokeWidth = strokeWidth
        ..style = PaintingStyle.stroke;
      canvas.drawCircle(center, radius - strokeWidth / 2, placeholderPaint);
      return;
    }

    data.forEach((cat, amount) {
      if (amount <= 0) return;
      final sweepAngle = (amount / total) * 2 * 3.14159265;
      final paint = Paint()
        ..color = colors[cat] ?? const Color(0xFF6B7280)
        ..strokeWidth = strokeWidth
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round;

      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius - strokeWidth / 2),
        startAngle,
        sweepAngle - 0.05,
        false,
        paint,
      );
      startAngle += sweepAngle;
    });
  }

  @override
  bool shouldRepaint(covariant _DonutChartPainter oldDelegate) => true;
}
