import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:path_provider/path_provider.dart';
import '../models/expense_model.dart';
import '../services/expense_service.dart';
import '../main.dart'; // For CustomCachedImage etc.
import '../theme/app_theme.dart';

class DailyExpenditureScreen extends StatefulWidget {
  const DailyExpenditureScreen({super.key});

  @override
  State<DailyExpenditureScreen> createState() => _DailyExpenditureScreenState();
}

class _DailyExpenditureScreenState extends State<DailyExpenditureScreen> {
  List<ExpenseModel> expenses = [];
  bool isLoading = true;
  String? currentUserId;

  final Map<String, IconData> categoryIcons = {
    'Food': Icons.restaurant_rounded,
    'Travel': Icons.directions_car_rounded,
    'Shopping': Icons.shopping_bag_rounded,
    'Bills': Icons.receipt_rounded,
    'Entertainment': Icons.sports_esports_rounded,
    'Health': Icons.medical_services_rounded,
    'Education': Icons.school_rounded,
    'Other': Icons.category_rounded,
  };

  final Map<String, Color> categoryColors = {
    'Food': const Color(0xFF4F46E5),
    'Travel': const Color(0xFFEF4444),
    'Shopping': const Color(0xFFF59E0B),
    'Bills': const Color(0xFF8B5CF6),
    'Entertainment': const Color(0xFFEC4899),
    'Health': const Color(0xFF10B981),
    'Education': const Color(0xFF3B82F6),
    'Other': const Color(0xFF6B7280),
  };

  @override
  void initState() {
    super.initState();
    currentUserId = FirebaseAuth.instance.currentUser?.uid ?? 'offline_user';
    _loadExpenses();
  }

  void _loadExpenses() {
    setState(() => isLoading = true);
    ExpenseService.expensesStream(currentUserId!).listen((data) {
      if (mounted) {
        setState(() {
          expenses = data;
          isLoading = false;
        });
      }
    }, onError: (err) {
      if (mounted) {
        setState(() => isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading expenses: $err')),
        );
      }
    });
  }

  double get todaySpending {
    final now = DateTime.now();
    return expenses
        .where((e) => e.expenseDate.year == now.year &&
                      e.expenseDate.month == now.month &&
                      e.expenseDate.day == now.day)
        .fold(0.0, (sum, e) => sum + e.amount);
  }

  double get weekSpending {
    final now = DateTime.now();
    final startOfWeek = now.subtract(Duration(days: now.weekday - 1));
    final startOfDay = DateTime(startOfWeek.year, startOfWeek.month, startOfWeek.day);
    return expenses
        .where((e) => e.expenseDate.isAfter(startOfDay) || e.expenseDate.isAtSameMomentAs(startOfDay))
        .fold(0.0, (sum, e) => sum + e.amount);
  }

  double get monthSpending {
    final now = DateTime.now();
    return expenses
        .where((e) => e.expenseDate.year == now.year &&
                      e.expenseDate.month == now.month)
        .fold(0.0, (sum, e) => sum + e.amount);
  }

  String _formatDateGroupLabel(DateTime date) {
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final day = date.day.toString().padLeft(2, '0');
    final month = months[date.month - 1];
    final year = date.year;
    return "$day $month $year";
  }

  String _formatTime(DateTime dateTime) {
    final hour24 = dateTime.hour;
    final minute = dateTime.minute.toString().padLeft(2, '0');
    final amPm = hour24 >= 12 ? 'PM' : 'AM';
    var hour12 = hour24 % 12;
    if (hour12 == 0) hour12 = 12;
    return "$hour12:$minute $amPm";
  }

  List<_ExpenseGroup> _getGroupedExpenses() {
    final Map<String, List<ExpenseModel>> groups = {};
    final List<String> orderedDates = [];

    for (final exp in expenses) {
      final label = _formatDateGroupLabel(exp.expenseDate);
      if (!groups.containsKey(label)) {
        groups[label] = [];
        orderedDates.add(label);
      }
      groups[label]!.add(exp);
    }

    return orderedDates.map((date) => _ExpenseGroup(date, groups[date]!)).toList();
  }

  Future<void> _deleteExpense(ExpenseModel expense) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete Expense?'),
        content: Text('Are you sure you want to delete this expense of \u20B9${expense.amount.toStringAsFixed(0)}?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmed != true || expense.id == null) return;

    setState(() => isLoading = true);
    try {
      await ExpenseService.deleteExpense(expense.id!);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Expense deleted successfully.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to delete expense: $e')),
      );
    } finally {
      _loadExpenses();
    }
  }

  void _showAddEditExpenseSheet({ExpenseModel? expense}) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => _ExpenseFormSheet(
        expense: expense,
        userId: currentUserId!,
        onSaved: () {
          _loadExpenses();
        },
      ),
    );
  }

  void _viewReceipt(String url) {
    showDialog(
      context: context,
      builder: (dialogContext) => Dialog(
        backgroundColor: Colors.transparent,
        child: Stack(
          alignment: Alignment.topRight,
          children: [
            InteractiveViewer(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: CustomCachedImage(
                  url: url,
                  fit: BoxFit.contain,
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close, color: Colors.white, size: 28),
              onPressed: () => Navigator.pop(dialogContext),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final groupedExpenses = _getGroupedExpenses();
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark ? AppColors.backgroundDark : AppColors.background,
      appBar: AppBar(
        title: Text(
          'Daily Expenditure',
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
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: SizedBox(
            height: 54,
            child: ElevatedButton.icon(
              onPressed: () => _showAddEditExpenseSheet(),
              icon: const Icon(Icons.add, color: Colors.white, size: 20),
              label: const Text(
                'Add Expense',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                ),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: isDark ? const Color(0xFF27272A) : AppColors.darkCard,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(24),
                ),
              ),
            ),
          ),
        ),
      ),
      body: isLoading
          ? const Center(child: CircularProgressIndicator())
          : CustomScrollView(
              slivers: [
                // Summary Cards
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: _buildSummaryCard(
                                title: "Today",
                                amount: todaySpending,
                                bgColor: isDark ? const Color(0xFF064E3B).withValues(alpha: 0.25) : AppColors.collectBg,
                                labelColor: isDark ? const Color(0xFF6EE7B7) : AppColors.collectText,
                                isDark: isDark,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: _buildSummaryCard(
                                title: "This Week",
                                amount: weekSpending,
                                bgColor: isDark ? AppColors.indigoBgDark : AppColors.indigoBg,
                                labelColor: const Color(0xFF818CF8),
                                isDark: isDark,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        _buildSummaryCard(
                          title: "This Month",
                          amount: monthSpending,
                          bgColor: isDark ? AppColors.amberBgDark : AppColors.amberBg,
                          labelColor: const Color(0xFFF59E0B),
                          isFullWidth: true,
                          isDark: isDark,
                        ),
                      ],
                    ),
                  ),
                ),
                // Expenditure list or Empty State
                if (expenses.isEmpty)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Container(
                              padding: const EdgeInsets.all(20),
                              decoration: BoxDecoration(
                                color: isDark ? AppColors.surfaceDark : Colors.white,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: isDark ? AppColors.borderDark : AppColors.borderLight,
                                  width: 1,
                                ),
                              ),
                              child: Icon(
                                Icons.account_balance_wallet_outlined,
                                size: 48,
                                color: isDark ? AppColors.textMutedDark : AppColors.textMuted,
                              ),
                            ),
                            const SizedBox(height: 16),
                            Text(
                              'No expenses recorded yet.',
                              style: TextStyle(
                                color: isDark ? AppColors.textPrimaryDark : AppColors.textPrimary,
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              "Tap '+ Add Expense' to begin tracking.",
                              style: TextStyle(
                                color: isDark ? AppColors.textSecondaryDark : AppColors.textSecondary,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  )
                else
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    sliver: SliverList(
                      delegate: SliverChildBuilderDelegate(
                        (context, groupIndex) {
                          final group = groupedExpenses[groupIndex];
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _buildDateHeader(group.dateLabel, isDark),
                              const SizedBox(height: 8),
                              ...group.expenses.map((exp) {
                                final color = categoryColors[exp.category] ?? Colors.blueGrey;
                                final icon = categoryIcons[exp.category] ?? Icons.category_rounded;

                                return Container(
                                  margin: const EdgeInsets.only(bottom: 10),
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
                                        blurRadius: 6,
                                        offset: const Offset(0, 2),
                                      ),
                                    ],
                                  ),
                                  child: ListTile(
                                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                                    leading: CircleAvatar(
                                      backgroundColor: color.withValues(alpha: 0.12),
                                      child: Icon(icon, color: color, size: 20),
                                    ),
                                    title: Text(
                                      "${exp.category}${exp.description.isNotEmpty ? ' • ${exp.description}' : ''}",
                                      style: TextStyle(
                                        fontWeight: FontWeight.w700,
                                        fontSize: 15,
                                        color: isDark ? AppColors.textPrimaryDark : AppColors.textPrimary,
                                      ),
                                    ),
                                    subtitle: Padding(
                                      padding: const EdgeInsets.only(top: 4.0),
                                      child: Text(
                                        _formatTime(exp.expenseDate),
                                        style: TextStyle(
                                          color: isDark ? AppColors.textSecondaryDark : AppColors.textSecondary,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ),
                                    trailing: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          "\u20B9${exp.amount.toStringAsFixed(0)}",
                                          style: TextStyle(
                                            fontWeight: FontWeight.w700,
                                            fontSize: 16,
                                            color: isDark ? AppColors.textPrimaryDark : AppColors.textPrimary,
                                          ),
                                        ),
                                        if (exp.receiptUrl != null && exp.receiptUrl!.isNotEmpty) ...[
                                          const SizedBox(width: 8),
                                          IconButton(
                                            icon: Icon(
                                              Icons.receipt_long_rounded,
                                              size: 20,
                                              color: isDark ? AppColors.textSecondaryDark : AppColors.textSecondary,
                                            ),
                                            onPressed: () => _viewReceipt(exp.receiptUrl!),
                                            tooltip: 'View Receipt',
                                          ),
                                        ],
                                      ],
                                    ),
                                    onTap: () => _showAddEditExpenseSheet(expense: exp),
                                    onLongPress: () => _deleteExpense(exp),
                                  ),
                                );
                              }),
                              const SizedBox(height: 12),
                            ],
                          );
                        },
                        childCount: groupedExpenses.length,
                      ),
                    ),
                  ),
              ],
            ),
    );
  }

  Widget _buildSummaryCard({
    required String title,
    required double amount,
    required Color bgColor,
    required Color labelColor,
    required bool isDark,
    bool isFullWidth = false,
  }) {
    return Container(
      width: isFullWidth ? double.infinity : null,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: isDark ? bgColor.withValues(alpha: 0.5) : bgColor.withValues(alpha: 0.8),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: 13,
              color: labelColor,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            "\u20B9${amount.toStringAsFixed(0)}",
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w800,
              color: isDark ? Colors.white : AppColors.textPrimary,
              letterSpacing: -0.5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDateHeader(String formattedDate, bool isDark) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Divider(
              color: isDark ? AppColors.dividerDark : AppColors.divider,
              thickness: 1,
              endIndent: 12,
            ),
          ),
          Text(
            formattedDate,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: isDark ? AppColors.textSecondaryDark : AppColors.textSecondary,
              fontSize: 12,
            ),
          ),
          Expanded(
            child: Divider(
              color: isDark ? AppColors.dividerDark : AppColors.divider,
              thickness: 1,
              indent: 12,
            ),
          ),
        ],
      ),
    );
  }
}

class _ExpenseGroup {
  final String dateLabel;
  final List<ExpenseModel> expenses;
  _ExpenseGroup(this.dateLabel, this.expenses);
}

class _ExpenseFormSheet extends StatefulWidget {
  final ExpenseModel? expense;
  final String userId;
  final VoidCallback onSaved;

  const _ExpenseFormSheet({
    this.expense,
    required this.userId,
    required this.onSaved,
  });

  @override
  State<_ExpenseFormSheet> createState() => _ExpenseFormSheetState();
}

class _ExpenseFormSheetState extends State<_ExpenseFormSheet> {
  final _formKey = GlobalKey<FormState>();
  final _amountController = TextEditingController();
  final _descController = TextEditingController();
  String _selectedCategory = 'Food';
  DateTime _selectedDate = DateTime.now();
  XFile? _receiptImage;
  bool _isSaving = false;
  String? _existingReceiptUrl;

  final List<String> _categories = [
    'Food',
    'Travel',
    'Shopping',
    'Bills',
    'Entertainment',
    'Health',
    'Education',
    'Other',
  ];

  @override
  void initState() {
    super.initState();
    if (widget.expense != null) {
      _amountController.text = widget.expense!.amount.toStringAsFixed(0);
      _descController.text = widget.expense!.description;
      _selectedCategory = widget.expense!.category;
      _selectedDate = widget.expense!.expenseDate;
      _existingReceiptUrl = widget.expense!.receiptUrl;
    }
  }

  Future<void> _pickImage(ImageSource source) async {
    try {
      final picked = await ImagePicker().pickImage(source: source, imageQuality: 80);
      if (picked != null) {
        setState(() {
          _receiptImage = picked;
        });
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to pick image: $e')),
      );
    }
  }

  Future<String?> _compressAndUploadReceipt(File file) async {
    try {
      final tempDir = await getTemporaryDirectory();
      final targetPath = '${tempDir.path}/${DateTime.now().millisecondsSinceEpoch}_exp.jpg';
      final compressed = await FlutterImageCompress.compressAndGetFile(
        file.path,
        targetPath,
        quality: 75,
      );
      if (compressed == null) return null;

      final compressedFile = File(compressed.path);
      final uri = Uri.parse('https://api.cloudinary.com/v1_1/dxwf10vjg/image/upload');
      final request = http.MultipartRequest('POST', uri)
        ..fields['upload_preset'] = 'receipt_upload'
        ..files.add(await http.MultipartFile.fromPath('file', compressedFile.path));

      final streamedResponse = await request.send();
      final responseBody = await streamedResponse.stream.bytesToString();

      if (streamedResponse.statusCode == 200) {
        final jsonResponse = jsonDecode(responseBody) as Map<String, dynamic>;
        return jsonResponse['secure_url'] as String?;
      }
    } catch (e) {
      debugPrint('Error uploading receipt: $e');
    }
    return null;
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isSaving = true);
    String? receiptUrl = _existingReceiptUrl;

    if (_receiptImage != null) {
      final uploadedUrl = await _compressAndUploadReceipt(File(_receiptImage!.path));
      if (uploadedUrl != null) {
        receiptUrl = uploadedUrl;
      }
    }

    final expense = ExpenseModel(
      id: widget.expense?.id,
      userId: widget.userId,
      amount: double.parse(_amountController.text),
      category: _selectedCategory,
      description: _descController.text.trim(),
      expenseDate: _selectedDate,
      receiptUrl: receiptUrl,
      createdAt: widget.expense?.createdAt ?? DateTime.now(),
    );

    try {
      if (widget.expense == null) {
        await ExpenseService.createExpense(expense);
      } else {
        await ExpenseService.updateExpense(expense);
      }

      if (!mounted) return;
      widget.onSaved();
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to save expense: $e')),
      );
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
        left: 20,
        right: 20,
        top: 20,
      ),
      child: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.borderLight,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                widget.expense == null ? 'Add Expense' : 'Edit Expense',
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _amountController,
                keyboardType: TextInputType.number,
                style: const TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.bold),
                decoration: const InputDecoration(
                  labelText: 'Amount',
                  prefixText: '₹ ',
                  prefixIcon: Icon(Icons.currency_rupee_rounded),
                ),
                validator: (val) {
                  if (val == null || val.trim().isEmpty) return 'Please enter amount';
                  if (double.tryParse(val) == null) return 'Invalid number';
                  return null;
                },
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _selectedCategory,
                style: const TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.w500),
                dropdownColor: Colors.white,
                decoration: const InputDecoration(
                  labelText: 'Category',
                  prefixIcon: Icon(Icons.category_rounded),
                ),
                items: _categories.map((c) => DropdownMenuItem(value: c, child: Text(c))).toList(),
                onChanged: (val) {
                  if (val != null) setState(() => _selectedCategory = val);
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _descController,
                style: const TextStyle(color: AppColors.textPrimary),
                decoration: const InputDecoration(
                  labelText: 'Description (optional)',
                  prefixIcon: Icon(Icons.description_outlined),
                ),
              ),
              const SizedBox(height: 16),
              // Receipt pickers
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _pickImage(ImageSource.camera),
                      icon: const Icon(Icons.camera_alt_outlined, size: 18),
                      label: const Text('Camera'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _pickImage(ImageSource.gallery),
                      icon: const Icon(Icons.photo_library_outlined, size: 18),
                      label: const Text('Gallery'),
                    ),
                  ),
                ],
              ),
              if (_receiptImage != null) ...[
                const SizedBox(height: 12),
                Stack(
                  alignment: Alignment.topRight,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.file(
                        File(_receiptImage!.path),
                        height: 100,
                        width: double.infinity,
                        fit: BoxFit.cover,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.cancel, color: Colors.red),
                      onPressed: () => setState(() => _receiptImage = null),
                    ),
                  ],
                ),
              ] else if (_existingReceiptUrl != null && _existingReceiptUrl!.isNotEmpty) ...[
                const SizedBox(height: 12),
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: CustomCachedImage(
                    url: _existingReceiptUrl!,
                    height: 100,
                    width: double.infinity,
                    fit: BoxFit.cover,
                  ),
                ),
              ],
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton(
                  onPressed: _isSaving ? null : _save,
                  child: _isSaving
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                        )
                      : Text(
                          widget.expense == null ? 'Save Expense' : 'Update Expense',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                ),
              ),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }
}
