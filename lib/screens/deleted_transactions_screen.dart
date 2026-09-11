import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../main.dart'; // For FirebaseDataService, CustomCachedImage, etc.
import '../database/database_helper.dart';
import '../models/transaction_model.dart';
import '../theme/app_theme.dart';

class DeletedTransactionsScreen extends StatefulWidget {
  const DeletedTransactionsScreen({super.key});

  @override
  State<DeletedTransactionsScreen> createState() => _DeletedTransactionsScreenState();
}

class _DeletedTransactionsScreenState extends State<DeletedTransactionsScreen> {
  List<DeletedEntryModel> deletedTransactions = [];
  bool isLoading = true;

  @override
  void initState() {
    super.initState();
    loadDeletedTransactions();
  }

  Future<void> loadDeletedTransactions() async {
    setState(() {
      isLoading = true;
    });

    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) {
      // Offline mode
      final deleted = await DatabaseHelper.instance.getAllDeletedEntries();
      if (mounted) {
        setState(() {
          deletedTransactions = deleted;
          isLoading = false;
        });
      }
    } else {
      // Stream is used online, let's subscribe or load once.
      FirebaseDataService.allDeletedEntriesStream().listen((deleted) {
        if (mounted) {
          setState(() {
            deletedTransactions = deleted;
            isLoading = false;
          });
        }
      });
    }
  }

  void _showDeletedTransactionOptions(BuildContext context, DeletedEntryModel entry) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showModalBottomSheet(
      context: context,
      backgroundColor: isDark ? AppColors.surfaceDark : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.symmetric(vertical: 8),
                  decoration: BoxDecoration(
                    color: isDark ? AppColors.borderDark : AppColors.borderLight,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                ListTile(
                  leading: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppColors.collectBg,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.restore_rounded, color: AppColors.collectText, size: 20),
                  ),
                  title: Text(
                    "Restore Transaction",
                    style: TextStyle(
                      color: isDark ? AppColors.textPrimaryDark : AppColors.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  onTap: () async {
                    Navigator.pop(context);
                    setState(() => isLoading = true);
                    try {
                      if (entry.firebaseId != null) {
                        await FirebaseDataService.restoreDeletedEntry(entry);
                      }
                      if (entry.id != null) {
                        await DatabaseHelper.instance.restoreDeletedEntry(entry.id!);
                      }
                      if (FirebaseAuth.instance.currentUser == null) {
                        await loadDeletedTransactions();
                      }
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Transaction restored successfully.')),
                        );
                      }
                    } catch (e) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Failed to restore transaction: $e')),
                        );
                      }
                    } finally {
                      if (mounted) setState(() => isLoading = false);
                    }
                  },
                ),
                ListTile(
                  leading: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppColors.payBg,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.delete_forever_rounded, color: AppColors.payText, size: 20),
                  ),
                  title: const Text(
                    "Permanently Delete",
                    style: TextStyle(color: AppColors.payText, fontWeight: FontWeight.w600),
                  ),
                  onTap: () async {
                    Navigator.pop(context);
                    final confirmed = await showDialog<bool>(
                      context: context,
                      builder: (dialogContext) => AlertDialog(
                        title: const Text('Permanently Delete?'),
                        content: const Text('This action is irreversible. The transaction will be permanently deleted.'),
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

                    if (confirmed != true || !mounted) return;

                    setState(() => isLoading = true);
                    try {
                      if (entry.firebaseId != null) {
                        await FirebaseDataService.permanentlyDeleteEntry(entry);
                      }
                      if (entry.id != null) {
                        await DatabaseHelper.instance.permanentlyDeleteEntry(entry.id!);
                      }
                      if (FirebaseAuth.instance.currentUser == null) {
                        await loadDeletedTransactions();
                      }
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Transaction permanently deleted.')),
                        );
                      }
                    } catch (e) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Failed to delete transaction: $e')),
                        );
                      }
                    } finally {
                      if (mounted) setState(() => isLoading = false);
                    }
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  String _formatDate(String rawDate) {
    final regex = RegExp(r'^(\d{4})-(\d{2})-(\d{2})(.*)$');
    final match = regex.firstMatch(rawDate.trim());
    if (match == null) return rawDate;
    final monthStr = match.group(2)!;
    final dayStr = match.group(3)!;
    var suffix = match.group(4)!.trim();
    final monthVal = int.tryParse(monthStr);
    if (monthVal == null || monthVal < 1 || monthVal > 12) return rawDate;
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final formattedDate = "$dayStr ${months[monthVal - 1]}";
    if (suffix.isNotEmpty) {
      while (suffix.startsWith('-') || suffix.startsWith(':') || suffix.startsWith(' ')) {
        suffix = suffix.substring(1).trim();
      }
      return "$formattedDate ($suffix)";
    }
    return formattedDate;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? AppColors.textPrimaryDark : AppColors.textPrimary;
    final subtextColor = isDark ? AppColors.textSecondaryDark : AppColors.textSecondary;
    final mutedColor = isDark ? AppColors.textMutedDark : AppColors.textMuted;
    final cardBg = isDark ? AppColors.surfaceDark : Colors.white;
    final cardBorder = isDark ? AppColors.borderDark : AppColors.borderLight;

    return Scaffold(
      backgroundColor: isDark ? AppColors.backgroundDark : AppColors.background,
      appBar: AppBar(
        title: Text(
          'Deleted Transactions',
          style: TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 18,
            color: textColor,
          ),
        ),
        centerTitle: true,
        leading: IconButton(
          icon: Icon(
            Icons.arrow_back_ios_new_rounded,
            color: textColor,
            size: 20,
          ),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: isLoading
          ? const Center(child: CircularProgressIndicator())
          : deletedTransactions.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
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
                          child: Icon(Icons.delete_sweep_rounded, size: 48, color: mutedColor),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'No deleted transactions found.',
                          style: TextStyle(color: subtextColor, fontSize: 15, fontWeight: FontWeight.w500),
                        ),
                      ],
                    ),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  itemCount: deletedTransactions.length,
                  itemBuilder: (context, index) {
                    final entry = deletedTransactions[index];
                    final moneyColor = entry.isGiven ? AppColors.collectText : AppColors.payText;

                    return Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(
                        color: cardBg,
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: cardBorder, width: 0.8),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.02),
                            blurRadius: 6,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        onLongPress: () => _showDeletedTransactionOptions(context, entry),
                        title: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Expanded(
                              child: Text(
                                entry.friendName,
                                style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 16,
                                  color: textColor,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            Text(
                              "\u20B9${entry.amount.toStringAsFixed(0)}",
                              style: TextStyle(
                                color: moneyColor,
                                fontWeight: FontWeight.w700,
                                fontSize: 16,
                              ),
                            ),
                          ],
                        ),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (entry.note.isNotEmpty) ...[
                              const SizedBox(height: 4),
                              Text(
                                entry.note,
                                style: TextStyle(color: subtextColor, fontSize: 13),
                              ),
                            ],
                            const SizedBox(height: 8),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  "Tx Date: ${_formatDate(entry.date)}",
                                  style: TextStyle(fontSize: 11, color: mutedColor),
                                ),
                                Text(
                                  "Cleared: ${_formatDate(entry.clearedDate)}",
                                  style: TextStyle(fontSize: 11, color: mutedColor),
                                ),
                              ],
                            ),
                          ],
                        ),
                        trailing: IconButton(
                          icon: Icon(Icons.more_vert, color: subtextColor),
                          onPressed: () => _showDeletedTransactionOptions(context, entry),
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}
