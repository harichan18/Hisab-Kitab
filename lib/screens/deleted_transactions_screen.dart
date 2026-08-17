import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../widgets/app_drawer.dart';
import '../main.dart'; // For FirebaseDataService, CustomCachedImage, etc.
import '../database/database_helper.dart';
import '../models/transaction_model.dart';

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
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey[900],
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.restore, color: Colors.green),
                title: const Text("Restore Transaction", style: TextStyle(color: Colors.white)),
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
                leading: const Icon(Icons.delete_forever, color: Colors.red),
                title: const Text("Permanently Delete", style: TextStyle(color: Colors.red)),
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('Deleted Transactions'),
        centerTitle: true,
        leading: Builder(
          builder: (context) => IconButton(
            icon: const Icon(Icons.menu),
            onPressed: () => Scaffold.of(context).openDrawer(),
          ),
        ),
      ),
      drawer: const AppDrawer(currentRoute: 'deleted_transactions'),
      body: isLoading
          ? const Center(child: CircularProgressIndicator())
          : deletedTransactions.isEmpty
              ? const Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.delete_sweep_rounded, size: 64, color: Colors.grey),
                      SizedBox(height: 16),
                      Text(
                        'No deleted transactions found.',
                        style: TextStyle(color: Colors.grey, fontSize: 16),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: deletedTransactions.length,
                  itemBuilder: (context, index) {
                    final entry = deletedTransactions[index];
                    final moneyColor = entry.isGiven ? Colors.green : Colors.red;

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
                        onLongPress: () => _showDeletedTransactionOptions(context, entry),
                        title: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Expanded(
                              child: Text(
                                entry.friendName,
                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            Text(
                              "\u20B9${entry.amount.toStringAsFixed(0)}",
                              style: TextStyle(
                                color: moneyColor,
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                              ),
                            ),
                          ],
                        ),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const SizedBox(height: 4),
                            Text(entry.note, style: const TextStyle(color: Colors.white70)),
                            const SizedBox(height: 8),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  "Tx Date: ${_formatDate(entry.date)}",
                                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                                ),
                                Text(
                                  "Cleared: ${_formatDate(entry.clearedDate)}",
                                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                                ),
                              ],
                            ),
                          ],
                        ),
                        trailing: IconButton(
                          icon: const Icon(Icons.more_vert),
                          onPressed: () => _showDeletedTransactionOptions(context, entry),
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}
