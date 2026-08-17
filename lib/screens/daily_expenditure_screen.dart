import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:path_provider/path_provider.dart';
import '../widgets/app_drawer.dart';
import '../models/expense_model.dart';
import '../services/expense_service.dart';
import '../main.dart'; // For CustomCachedImage etc.

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
    'Food': Colors.orange,
    'Travel': Colors.blue,
    'Shopping': Colors.pink,
    'Bills': Colors.purple,
    'Entertainment': Colors.red,
    'Health': Colors.teal,
    'Education': Colors.indigo,
    'Other': Colors.blueGrey,
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
      backgroundColor: Colors.grey[900],
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
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
                borderRadius: BorderRadius.circular(12),
                child: CustomCachedImage(
                  url: url,
                  fit: BoxFit.contain,
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close, color: Colors.white, size: 30),
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

    return Scaffold(
      appBar: AppBar(
        title: const Text('Daily Expenditure'),
        centerTitle: true,
        leading: Builder(
          builder: (context) => IconButton(
            icon: const Icon(Icons.menu),
            onPressed: () => Scaffold.of(context).openDrawer(),
          ),
        ),
      ),
      drawer: const AppDrawer(currentRoute: 'daily_expenditure'),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showAddEditExpenseSheet(),
        backgroundColor: Colors.green,
        icon: const Icon(Icons.add, color: Colors.white),
        label: const Text('Add Expense', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
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
                                color: Colors.teal,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: _buildSummaryCard(
                                title: "This Week",
                                amount: weekSpending,
                                color: Colors.indigo,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        _buildSummaryCard(
                          title: "This Month",
                          amount: monthSpending,
                          color: Colors.amber,
                          isFullWidth: true,
                        ),
                      ],
                    ),
                  ),
                ),
                // Expenditure list
                if (expenses.isEmpty)
                  const SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.account_balance_wallet_outlined, size: 64, color: Colors.grey),
                          SizedBox(height: 16),
                          Text(
                            'No expenses recorded yet.',
                            style: TextStyle(color: Colors.grey, fontSize: 16),
                          ),
                          SizedBox(height: 8),
                          Text(
                            "Tap '+ Add Expense' to begin tracking.",
                            style: TextStyle(color: Colors.grey, fontSize: 12),
                          ),
                        ],
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
                              _buildDateHeader(group.dateLabel),
                              const SizedBox(height: 8),
                              ...group.expenses.map((exp) {
                                final color = categoryColors[exp.category] ?? Colors.blueGrey;
                                final icon = categoryIcons[exp.category] ?? Icons.category_rounded;

                                return Card(
                                  color: Colors.grey[900],
                                  margin: const EdgeInsets.only(bottom: 12),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                    side: BorderSide(
                                      color: Colors.grey[850] ?? const Color(0xFF212121),
                                      width: 1,
                                    ),
                                  ),
                                  child: ListTile(
                                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                    leading: CircleAvatar(
                                      backgroundColor: color.withValues(alpha: 0.15),
                                      child: Icon(icon, color: color),
                                    ),
                                    title: Text(
                                      "${exp.category}${exp.description.isNotEmpty ? ' - ${exp.description}' : ''}",
                                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                                    ),
                                    subtitle: Padding(
                                      padding: const EdgeInsets.only(top: 4.0),
                                      child: Text(
                                        _formatTime(exp.expenseDate),
                                        style: const TextStyle(color: Colors.grey, fontSize: 12),
                                      ),
                                    ),
                                    trailing: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          "\u20B9${exp.amount.toStringAsFixed(0)}",
                                          style: const TextStyle(
                                            fontWeight: FontWeight.bold,
                                            fontSize: 16,
                                            color: Colors.white,
                                          ),
                                        ),
                                        if (exp.receiptUrl != null && exp.receiptUrl!.isNotEmpty) ...[
                                          const SizedBox(width: 8),
                                          IconButton(
                                            icon: const Icon(Icons.receipt_long, size: 20, color: Colors.grey),
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
    required Color color,
    bool isFullWidth = false,
  }) {
    return Container(
      width: isFullWidth ? double.infinity : null,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.25), width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title.toUpperCase(),
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 11,
              color: color,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            "\u20B9${amount.toStringAsFixed(0)}",
            style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDateHeader(String formattedDate) {
    return Row(
      children: [
        const Expanded(
          child: Divider(
            color: Colors.white12,
            thickness: 1,
            endIndent: 12,
          ),
        ),
        Text(
          formattedDate,
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            color: Colors.white54,
            fontSize: 12,
            letterSpacing: 0.5,
          ),
        ),
        const Expanded(
          child: Divider(
            color: Colors.white12,
            thickness: 1,
            indent: 12,
          ),
        ),
      ],
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
      widget.onSaved();
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(widget.expense == null ? 'Expense added.' : 'Expense updated.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to save expense: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, MediaQuery.of(context).viewInsets.bottom + 16),
      child: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.expense == null ? 'Add Expense' : 'Edit Expense',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _amountController,
                keyboardType: TextInputType.number,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  labelText: 'Amount (Required)',
                  prefixText: '\u20B9',
                  border: OutlineInputBorder(),
                ),
                validator: (val) {
                  if (val == null || val.isEmpty) return 'Please enter amount';
                  if (double.tryParse(val) == null) return 'Please enter valid number';
                  return null;
                },
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: _selectedCategory,
                dropdownColor: Colors.grey[900],
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  labelText: 'Category',
                  border: OutlineInputBorder(),
                ),
                items: _categories.map((cat) {
                  return DropdownMenuItem<String>(
                    value: cat,
                    child: Text(cat),
                  );
                }).toList(),
                onChanged: (val) {
                  if (val != null) {
                    setState(() => _selectedCategory = val);
                  }
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _descController,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  labelText: 'Description (Optional)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      "Date: ${_selectedDate.day.toString().padLeft(2, '0')}/${_selectedDate.month.toString().padLeft(2, '0')}/${_selectedDate.year}",
                      style: const TextStyle(color: Colors.white70),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () async {
                      final selected = await showDatePicker(
                        context: context,
                        initialDate: _selectedDate,
                        firstDate: DateTime(2000),
                        lastDate: DateTime(2100),
                      );
                      if (selected != null) {
                        setState(() {
                          _selectedDate = DateTime(
                            selected.year,
                            selected.month,
                            selected.day,
                            _selectedDate.hour,
                            _selectedDate.minute,
                          );
                        });
                      }
                    },
                    icon: const Icon(Icons.calendar_month, color: Colors.amber),
                    label: const Text('Change', style: TextStyle(color: Colors.amber)),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              const Text('Receipt Image (Optional)', style: TextStyle(color: Colors.grey, fontSize: 13)),
              const SizedBox(height: 8),
              if (_receiptImage != null || _existingReceiptUrl != null) ...[
                Row(
                  children: [
                    Expanded(
                      child: Container(
                        height: 100,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.white24),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: _receiptImage != null
                              ? Image.file(File(_receiptImage!.path), fit: BoxFit.cover)
                              : CustomCachedImage(url: _existingReceiptUrl!, fit: BoxFit.cover),
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    IconButton(
                      icon: const Icon(Icons.delete, color: Colors.redAccent),
                      onPressed: () {
                        setState(() {
                          _receiptImage = null;
                          _existingReceiptUrl = null;
                        });
                      },
                    ),
                  ],
                ),
              ] else ...[
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => _pickImage(ImageSource.camera),
                        icon: const Icon(Icons.camera_alt),
                        label: const Text('Camera'),
                        style: OutlinedButton.styleFrom(foregroundColor: Colors.white),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => _pickImage(ImageSource.gallery),
                        icon: const Icon(Icons.photo_library),
                        label: const Text('Gallery'),
                        style: OutlinedButton.styleFrom(foregroundColor: Colors.white),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 24),
              if (_isSaving)
                const Center(child: CircularProgressIndicator())
              else
                ElevatedButton(
                  onPressed: _save,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text(
                    'Save',
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}
