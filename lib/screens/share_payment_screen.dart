import 'dart:io';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import '../theme/app_theme.dart';
import '../database/database_helper.dart';
import '../models/transaction_model.dart';
import '../models/extracted_payment_info.dart';
import '../services/payment_ocr_service.dart';
import '../services/split_calculator.dart';
import '../utils/amount_parser.dart';
import '../utils/receiver_matcher.dart';
import '../main.dart';

typedef FriendRecord = ({
  String name,
  String uid,
  String? email,
  String? friendCode,
  String? upiId,
  String? mobileNumber,
});

class SharePaymentScreen extends StatefulWidget {
  final String imagePath;
  final bool autoAnalyze;

  const SharePaymentScreen({
    super.key,
    required this.imagePath,
    this.autoAnalyze = true,
  });

  @override
  State<SharePaymentScreen> createState() => _SharePaymentScreenState();
}

class _SharePaymentScreenState extends State<SharePaymentScreen> {
  bool _isAnalyzing = true;
  bool _isSaving = false;
  ExtractedPaymentInfo? _extractedInfo;

  // Form controllers
  final TextEditingController _amountController = TextEditingController();
  final TextEditingController _noteController = TextEditingController();
  final TextEditingController _dateController = TextEditingController();
  final TextEditingController _searchController = TextEditingController();

  // Friends & Split State
  List<FriendRecord> _allFriends = [];
  List<FriendRecord> _filteredFriends = [];
  List<FriendMatchCandidate<FriendRecord>> _matchedCandidates = [];
  final Set<String> _selectedFriendUids = {};
  SplitType _splitType = SplitType.equal;

  // Custom & Percentage Controllers keyed by friend UID
  final Map<String, TextEditingController> _customControllers = {};
  final Map<String, TextEditingController> _percentageControllers = {};

  // Step: 0 = Edit & Select Friends, 1 = Review & Confirm
  int _currentStep = 0;
  bool _showImagePreview = true;

  @override
  void initState() {
    super.initState();
    _dateController.text = _formatDate(DateTime.now());
    _loadFriends();
    if (widget.autoAnalyze) {
      _analyzeScreenshot();
    } else {
      _isAnalyzing = false;
    }
  }

  @override
  void dispose() {
    _amountController.dispose();
    _noteController.dispose();
    _dateController.dispose();
    _searchController.dispose();
    for (final c in _customControllers.values) {
      c.dispose();
    }
    for (final c in _percentageControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  String _formatDate(DateTime date) {
    return "${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}";
  }

  Future<void> _loadFriends() async {
    try {
      final currentUser = FirebaseAuth.instance.currentUser;
      final currentUid = currentUser?.uid;

      // Unique map keyed by Firebase UID to guarantee no duplicates or fake fallback users
      final friendMap = <String, FriendRecord>{};

      // 1. Fetch from cached_friends in SQLite
      final cachedRows = await DatabaseHelper.instance.getAllCachedFriends();
      for (final row in cachedRows) {
        final uid = (row['friendUid'] as String? ?? '').trim();
        final name = (row['friendName'] as String? ?? '').trim();
        final email = (row['email'] as String? ?? '').trim();
        final friendCode = (row['friendCode'] as String? ?? '').trim();
        final upiId = (row['upiId'] as String? ?? '').trim();
        final mobileNumber = (row['mobileNumber'] as String? ?? '').trim();

        // Must have a valid UID and MUST NOT be the currently authenticated user
        if (uid.isNotEmpty && (currentUid == null || uid != currentUid)) {
          friendMap[uid] = (
            name: name.isNotEmpty ? name : (friendCode.isNotEmpty ? friendCode : 'Friend'),
            uid: uid,
            email: email.isNotEmpty ? email : null,
            friendCode: friendCode.isNotEmpty ? friendCode : null,
            upiId: upiId.isNotEmpty ? upiId : null,
            mobileNumber: mobileNumber.isNotEmpty ? mobileNumber : null,
          );
        }
      }

      // 2. Query Firestore directly if authenticated to ensure fresh friendship state
      if (currentUid != null && currentUid.isNotEmpty) {
        try {
          final friendsCol = FirebaseFirestore.instance.collection('friends');
          final user1Snap = await friendsCol.where('user1', isEqualTo: currentUid).get();
          final user2Snap = await friendsCol.where('user2', isEqualTo: currentUid).get();

          final friendshipDocs = {
            for (final doc in user1Snap.docs) doc.id: doc,
            for (final doc in user2Snap.docs) doc.id: doc,
          }.values.toList();

          final friendUids = <String>{};
          for (final doc in friendshipDocs) {
            final data = doc.data();
            final u1 = data['user1'] as String? ?? '';
            final u2 = data['user2'] as String? ?? '';
            final fUid = (u1 == currentUid ? u2 : u1).trim();

            if (fUid.isNotEmpty && fUid != currentUid) {
              friendUids.add(fUid);
            }
          }

          for (final fUid in friendUids) {
            if (!friendMap.containsKey(fUid) || friendMap[fUid]!.name.isEmpty) {
              try {
                final userDoc = await FirebaseFirestore.instance
                    .collection('users')
                    .doc(fUid)
                    .get();
                if (userDoc.exists && userDoc.data() != null) {
                  final data = userDoc.data()!;
                  final fName = (data['name'] as String? ?? '').trim();
                  final fEmail = (data['email'] as String? ?? '').trim();
                  final fCode = (data['friendCode'] as String? ?? '').trim();
                  final fUpi = (data['upiId'] as String? ?? '').trim();
                  final fMobile = (data['mobileNumber'] as String? ?? '').trim();

                  final resolvedName = fName.isNotEmpty
                      ? fName
                      : (fCode.isNotEmpty ? fCode : (fEmail.isNotEmpty ? fEmail : 'Friend'));

                  friendMap[fUid] = (
                    name: resolvedName,
                    uid: fUid,
                    email: fEmail.isNotEmpty ? fEmail : null,
                    friendCode: fCode.isNotEmpty ? fCode : null,
                    upiId: fUpi.isNotEmpty ? fUpi : null,
                    mobileNumber: fMobile.isNotEmpty ? fMobile : null,
                  );

                  await DatabaseHelper.instance.saveCachedFriend(
                    friendUid: fUid,
                    friendName: resolvedName,
                    email: fEmail,
                    friendCode: fCode,
                    photoUrl: data['photoUrl'] as String? ?? '',
                    upiId: fUpi,
                    mobileNumber: fMobile,
                  );
                }
              } catch (e) {
                debugPrint('[SharePaymentScreen] Error fetching user profile for $fUid: $e');
              }
            }
          }
        } catch (e) {
          debugPrint('[SharePaymentScreen] Firestore live query error: $e');
        }
      }

      // DO NOT query local transactions table to synthesize fake/temporary friends.
      // Friends must strictly be genuine verified friends.
      final list = friendMap.values.toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

      if (mounted) {
        setState(() {
          _allFriends = list;
          _filteredFriends = _applySearchFilter(_searchController.text, list);
        });
        _matchSuggestedReceiver();
      }
    } catch (e) {
      debugPrint('[SharePaymentScreen] Error loading friends: $e');
    }
  }

  void _onSearchChanged(String query) {
    setState(() {
      _filteredFriends = _applySearchFilter(query, _allFriends);
    });
  }

  List<FriendRecord> _applySearchFilter(
    String query,
    List<FriendRecord> source,
  ) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) {
      return source;
    }
    return source.where((f) {
      return f.name.toLowerCase().contains(q) ||
          (f.email?.toLowerCase().contains(q) ?? false) ||
          (f.friendCode?.toLowerCase().contains(q) ?? false) ||
          (f.upiId?.toLowerCase().contains(q) ?? false) ||
          (f.mobileNumber?.toLowerCase().contains(q) ?? false);
    }).toList();
  }

  Future<void> _analyzeScreenshot() async {
    final previousAmount = AmountParser.parseAmount(_amountController.text);

    setState(() {
      _isAnalyzing = true;
    });

    final info = await PaymentOcrService.instance.processScreenshot(widget.imagePath);

    if (mounted) {
      setState(() {
        _extractedInfo = info;
        _isAnalyzing = false;

        // If new extraction extracted a valid positive amount, update the field.
        // If it failed/returned null, preserve previous valid amount instead of resetting to 0.
        if (info.amount != null && info.amount! > 0) {
          _amountController.text = AmountParser.formatForInput(info.amount);
          _syncSplitInputs();
        } else if (previousAmount != null && previousAmount > 0) {
          _amountController.text = AmountParser.formatForInput(previousAmount);
          _syncSplitInputs();
        }

        if (info.dateString != null && info.dateString!.isNotEmpty) {
          _dateController.text = info.dateString!;
        }

        // Build prefilled note cleanly without fake placeholders
        final parts = <String>[];
        if (info.appName != null && info.appName!.isNotEmpty) {
          parts.add("${info.appName!} Payment");
        } else {
          parts.add("Payment");
        }
        if (info.receiverName != null && info.receiverName!.isNotEmpty) {
          parts.add("to ${info.receiverName}");
        }
        if (info.transactionRef != null && info.transactionRef!.isNotEmpty) {
          parts.add("(Ref: ${info.transactionRef})");
        }
        _noteController.text = parts.join(" ");
      });

      _matchSuggestedReceiver();
    }
  }

  void _matchSuggestedReceiver() {
    final receiver = _extractedInfo?.receiverName?.trim();
    final upi = _extractedInfo?.upiId?.trim();
    if ((receiver == null || receiver.isEmpty) && (upi == null || upi.isEmpty)) {
      if (mounted) {
        setState(() {
          _matchedCandidates = [];
        });
      }
      return;
    }

    final matches = ReceiverMatcher.matchReceiver<FriendRecord>(
      receiverName: receiver,
      upiId: upi,
      friends: _allFriends,
      getName: (f) => f.name,
      getUpiId: (f) => f.upiId,
      getFriendCode: (f) => f.friendCode,
    );

    if (mounted) {
      setState(() {
        _matchedCandidates = matches;
        // If there is exactly ONE high-confidence match and nothing is selected yet,
        // safely pre-suggest/select it for convenience
        if (matches.isNotEmpty &&
            matches.first.confidence == MatchConfidence.high &&
            (matches.length == 1 || matches[1].score < matches.first.score) &&
            _selectedFriendUids.isEmpty) {
          _selectedFriendUids.add(matches.first.friend.uid);
          _syncSplitInputs();
        }
      });
    }
  }

  void _toggleFriendSelection(String uid) {
    setState(() {
      if (_selectedFriendUids.contains(uid)) {
        _selectedFriendUids.remove(uid);
        _customControllers[uid]?.dispose();
        _customControllers.remove(uid);
        _percentageControllers[uid]?.dispose();
        _percentageControllers.remove(uid);
      } else {
        _selectedFriendUids.add(uid);
        _customControllers[uid] = TextEditingController();
        _percentageControllers[uid] = TextEditingController();
      }
      _syncSplitInputs();
    });
  }

  void _syncSplitInputs() {
    final totalAmount = AmountParser.parseAmount(_amountController.text) ?? 0.0;
    if (_selectedFriendUids.isEmpty || totalAmount <= 0) return;

    final selected = _allFriends.where((f) => _selectedFriendUids.contains(f.uid)).toList();

    if (_splitType == SplitType.equal) {
      final shares = SplitCalculator.calculateEqualSplit(
        totalAmount: totalAmount,
        friends: selected.map((f) => (name: f.name, uid: f.uid as String?)).toList(),
      );
      for (final s in shares) {
        if (s.friendUid != null) {
          _customControllers[s.friendUid!]?.text = s.amount.toStringAsFixed(2);
          _percentageControllers[s.friendUid!]?.text = s.percentage?.toStringAsFixed(1) ?? '';
        }
      }
    } else if (_splitType == SplitType.percentage) {
      final equalPct = (100.0 / selected.length).toStringAsFixed(1);
      for (final f in selected) {
        if (_percentageControllers[f.uid]?.text.isEmpty ?? true) {
          _percentageControllers[f.uid]?.text = equalPct;
        }
      }
    }
  }

  List<FriendSplitShare> _computeCurrentShares() {
    final totalAmount = AmountParser.parseAmount(_amountController.text) ?? 0.0;
    if (totalAmount <= 0 || _selectedFriendUids.isEmpty) return [];

    final selected = _allFriends.where((f) => _selectedFriendUids.contains(f.uid)).toList();

    switch (_splitType) {
      case SplitType.equal:
        return SplitCalculator.calculateEqualSplit(
          totalAmount: totalAmount,
          friends: selected.map((f) => (name: f.name, uid: f.uid as String?)).toList(),
        );

      case SplitType.custom:
        final shares = <FriendSplitShare>[];
        for (final f in selected) {
          final amt = AmountParser.parseAmount(_customControllers[f.uid]?.text) ?? 0.0;
          shares.add(FriendSplitShare(
            friendName: f.name,
            friendUid: f.uid,
            amount: amt,
            percentage: (amt / totalAmount) * 100,
          ));
        }
        return shares;

      case SplitType.percentage:
        final pcts = <({String name, String? uid, double percentage})>[];
        for (final f in selected) {
          final pct = double.tryParse(_percentageControllers[f.uid]?.text ?? '') ?? 0.0;
          pcts.add((name: f.name, uid: f.uid, percentage: pct));
        }
        return SplitCalculator.calculatePercentageSplit(
          totalAmount: totalAmount,
          friends: pcts,
        );
    }
  }

  String? _validateInputs() {
    final amount = AmountParser.parseAmount(_amountController.text);
    if (amount == null || amount <= 0) {
      return 'Please enter a valid payment amount.';
    }

    if (_selectedFriendUids.isEmpty) {
      return 'Please select at least one friend to split with.';
    }

    if (_splitType == SplitType.custom) {
      final amounts = <double>[];
      for (final uid in _selectedFriendUids) {
        final val = AmountParser.parseAmount(_customControllers[uid]?.text);
        final friend = _allFriends.firstWhere((f) => f.uid == uid, orElse: () => (name: 'Friend', uid: uid, email: null, friendCode: null, upiId: null, mobileNumber: null));
        if (val == null || val < 0) {
          return 'Enter a valid custom amount for ${friend.name}.';
        }
        amounts.add(val);
      }
      return SplitCalculator.validateCustomSplit(
        totalAmount: amount,
        customAmounts: amounts,
      );
    }

    if (_splitType == SplitType.percentage) {
      double sumPct = 0;
      for (final uid in _selectedFriendUids) {
        final val = double.tryParse(_percentageControllers[uid]?.text ?? '');
        final friend = _allFriends.firstWhere((f) => f.uid == uid, orElse: () => (name: 'Friend', uid: uid, email: null, friendCode: null, upiId: null, mobileNumber: null));
        if (val == null || val < 0) {
          return 'Enter a valid percentage for ${friend.name}.';
        }
        sumPct += val;
      }
      if ((sumPct - 100.0).abs() > 0.5) {
        return 'Percentages must add up to 100% (currently ${sumPct.toStringAsFixed(1)}%).';
      }
    }

    return null;
  }

  Future<void> _onProceedToReview() async {
    final error = _validateInputs();
    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error), backgroundColor: const Color(0xFFEF4444)),
      );
      return;
    }

    if (_extractedInfo?.status == PaymentStatus.failed) {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.cancel_rounded, color: Color(0xFFEF4444)),
              SizedBox(width: 8),
              Text("Payment Failed"),
            ],
          ),
          content: const Text(
            "This payment screenshot appears to indicate a Failed or Declined payment. Do you still want to proceed with recording this expense?",
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text("Cancel"),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFEF4444),
                foregroundColor: Colors.white,
              ),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text("Proceed Anyway"),
            ),
          ],
        ),
      );
      if (confirm != true) return;
    }

    setState(() {
      _currentStep = 1;
    });
  }

  Future<void> _confirmAndSaveTransactions() async {
    final error = _validateInputs();
    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error), backgroundColor: const Color(0xFFEF4444)),
      );
      return;
    }

    setState(() {
      _isSaving = true;
    });

    final currentUser = FirebaseAuth.instance.currentUser;
    final currentUid = currentUser?.uid;
    final shares = _computeCurrentShares();
    final date = _dateController.text.trim();
    final note = _noteController.text.trim();
    final totalAmount = AmountParser.parseAmount(_amountController.text)!;

    int savedCount = 0;
    try {
      for (final share in shares) {
        final friend = _allFriends.firstWhere(
          (f) => f.uid == share.friendUid,
          orElse: () => (name: share.friendName, uid: share.friendUid ?? '', email: null, friendCode: null, upiId: null, mobileNumber: null),
        );
        final peerUserId = friend.uid.isNotEmpty ? friend.uid : null;

        // Auto-generate firebaseId for cloud sync
        String? firebaseId;
        if (currentUid != null) {
          firebaseId = FirebaseFirestore.instance
              .collection('users')
              .doc(currentUid)
              .collection('transactions')
              .doc()
              .id;
        }

        final tx = TransactionModel(
          firebaseId: firebaseId,
          peerUserId: peerUserId,
          createdBy: currentUid,
          receiptPath: widget.imagePath,
          friendName: friend.name,
          amount: share.amount,
          note: shares.length > 1
              ? '$note (Split share of ₹${totalAmount.toStringAsFixed(totalAmount % 1 == 0 ? 0 : 2)})'
              : note,
          date: date,
          iGave: true, // User paid -> friends owe user ("You Gave")
        );

        // Save locally in SQLite
        await DatabaseHelper.instance.insertTransaction(tx);

        // Save mirrored in Firestore if authenticated
        if (currentUid != null) {
          await FirebaseDataService.saveTransaction(tx, firebaseId: firebaseId);
        }

        savedCount++;
      }

      if (currentUid != null) {
        await FirebaseDataService.updateSummary();
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Successfully recorded $savedCount transaction${savedCount > 1 ? 's' : ''} (₹${totalAmount.toStringAsFixed(2)})',
            ),
            backgroundColor: const Color(0xFF10B981),
          ),
        );
        Navigator.pop(context, true);
      }
    } catch (e) {
      debugPrint('[SharePaymentScreen] Error saving split transactions: $e');
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to save transactions: $e'),
            backgroundColor: const Color(0xFFEF4444),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? AppColors.backgroundDark : AppColors.background;
    final textPrimary = isDark ? AppColors.textPrimaryDark : AppColors.textPrimary;
    final textSecondary = isDark ? AppColors.textSecondaryDark : AppColors.textSecondary;
    final cardBg = isDark ? AppColors.surfaceDark : Colors.white;
    final cardBorder = isDark ? AppColors.borderDark : AppColors.borderLight;

    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        title: Text(
          _currentStep == 0 ? "Process Payment" : "Review Split",
          style: TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 18,
            color: textPrimary,
          ),
        ),
        centerTitle: true,
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_rounded, color: textPrimary),
          onPressed: () {
            if (_currentStep > 0) {
              setState(() {
                _currentStep = 0;
              });
            } else {
              Navigator.pop(context);
            }
          },
        ),
        actions: [
          if (!_isAnalyzing && _currentStep == 0)
            IconButton(
              icon: Icon(Icons.refresh_rounded, color: textPrimary),
              tooltip: 'Re-analyze',
              onPressed: _analyzeScreenshot,
            ),
        ],
      ),
      body: _isAnalyzing
          ? _buildAnalyzingState(isDark, textPrimary, textSecondary, cardBg, cardBorder)
          : (_currentStep == 0
              ? _buildDetailsAndFriendsStep(isDark, textPrimary, textSecondary, cardBg, cardBorder)
              : _buildReviewStep(isDark, textPrimary, textSecondary, cardBg, cardBorder)),
    );
  }

  // 1. Analyzing State Widget
  Widget _buildAnalyzingState(
    bool isDark,
    Color textPrimary,
    Color textSecondary,
    Color cardBg,
    Color cardBorder,
  ) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 140,
              height: 180,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: cardBorder),
                image: DecorationImage(
                  image: ResizeImage(FileImage(File(widget.imagePath)), width: 360),
                  fit: BoxFit.cover,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: isDark ? 0.3 : 0.08),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            CircularProgressIndicator(
              strokeWidth: 3,
              color: isDark ? Colors.white : const Color(0xFF111827),
            ),
            const SizedBox(height: 18),
            Text(
              "Analyzing Payment...",
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: textPrimary,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              "Extracting amount, status, and transaction details",
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusCard({
    required bool isDark,
    required Color cardBg,
    required Color cardBorder,
    required Color textPrimary,
    required Color textSecondary,
  }) {
    final status = _extractedInfo?.status ?? PaymentStatus.unclear;
    final isSuccess = status == PaymentStatus.successful;
    final isFailed = status == PaymentStatus.failed;
    final appName = _extractedInfo?.appName;

    final Color statusColor = isSuccess
        ? const Color(0xFF10B981)
        : (isFailed ? const Color(0xFFEF4444) : const Color(0xFFF59E0B));

    final IconData statusIcon = isSuccess
        ? Icons.check_circle_rounded
        : (isFailed ? Icons.cancel_rounded : Icons.warning_amber_rounded);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: statusColor.withValues(alpha: isDark ? 0.15 : 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: statusColor.withValues(alpha: 0.4),
          width: 0.8,
        ),
      ),
      child: Row(
        children: [
          Icon(statusIcon, size: 20, color: statusColor),
          const SizedBox(width: 10),
          Expanded(
            child: isSuccess
                ? Text(
                    "Payment Successful",
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: statusColor,
                    ),
                  )
                : isFailed
                    ? Text(
                        "Payment Failed",
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: statusColor,
                        ),
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            "Payment Status Unclear",
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: statusColor,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            "Please verify the payment status.",
                            style: TextStyle(
                              fontSize: 12,
                              color: isDark ? Colors.white70 : const Color(0xFF92400E),
                            ),
                          ),
                        ],
                      ),
          ),
          if (appName != null && appName.isNotEmpty) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF1F2937) : Colors.white,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: cardBorder, width: 0.5),
              ),
              child: Text(
                appName,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: textPrimary,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // 2. Step 0: Review Detected Details & Select Friends
  Widget _buildDetailsAndFriendsStep(
    bool isDark,
    Color textPrimary,
    Color textSecondary,
    Color cardBg,
    Color cardBorder,
  ) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Image Preview Toggle Bar
          InkWell(
            onTap: () => setState(() => _showImagePreview = !_showImagePreview),
            borderRadius: BorderRadius.circular(12),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: cardBg,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: cardBorder, width: 0.8),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.image_outlined,
                    size: 18,
                    color: isDark ? Colors.white70 : const Color(0xFF111827),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _showImagePreview ? "Hide Screenshot" : "Show Screenshot",
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: textPrimary,
                    ),
                  ),
                  const Spacer(),
                  Icon(
                    _showImagePreview
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    size: 20,
                    color: textSecondary,
                  ),
                ],
              ),
            ),
          ),

          if (_showImagePreview) ...[
            const SizedBox(height: 10),
            Container(
              height: 180,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: cardBorder),
                image: DecorationImage(
                  image: ResizeImage(FileImage(File(widget.imagePath)), width: 480),
                  fit: BoxFit.contain,
                ),
                color: isDark ? const Color(0xFF0F1216) : const Color(0xFFF3F4F6),
              ),
            ),
          ],
          const SizedBox(height: 14),

          // Status & App Badge
          _buildStatusCard(
            isDark: isDark,
            cardBg: cardBg,
            cardBorder: cardBorder,
            textPrimary: textPrimary,
            textSecondary: textSecondary,
          ),
          const SizedBox(height: 14),

          // Amount Card (Editable)
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: cardBg,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: cardBorder, width: 0.8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      "Paid Amount",
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: textSecondary,
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (_amountController.text.trim().isEmpty)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF59E0B).withValues(alpha: isDark ? 0.2 : 0.1),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: const Color(0xFFF59E0B).withValues(alpha: 0.5),
                            width: 0.6,
                          ),
                        ),
                        child: const Text(
                          "Not detected",
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFFF59E0B),
                          ),
                        ),
                      ),
                    const Spacer(),
                    Text(
                      "Editable",
                      style: TextStyle(fontSize: 11, color: textSecondary),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Text(
                      "₹",
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w800,
                        color: textPrimary,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextFormField(
                        controller: _amountController,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w800,
                          color: textPrimary,
                        ),
                        decoration: InputDecoration(
                          border: InputBorder.none,
                          isDense: true,
                          contentPadding: EdgeInsets.zero,
                          hintText: "Enter amount",
                          hintStyle: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w500,
                            color: textSecondary.withValues(alpha: 0.4),
                          ),
                        ),
                        onChanged: (_) => setState(() {
                          _syncSplitInputs();
                        }),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),

          // Note & Date Fields
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: cardBg,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: cardBorder, width: 0.8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Note Input
                Text(
                  "Note / Description",
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: textSecondary),
                ),
                const SizedBox(height: 6),
                TextFormField(
                  controller: _noteController,
                  style: TextStyle(fontSize: 13, color: textPrimary),
                  decoration: InputDecoration(
                    hintText: "What was this for?",
                    hintStyle: TextStyle(fontSize: 12, color: textSecondary),
                    prefixIcon: Icon(Icons.notes_rounded, size: 18, color: textSecondary),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(color: cardBorder),
                    ),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                  ),
                ),
                const SizedBox(height: 14),

                // Date Picker Input
                Text(
                  "Date",
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: textSecondary),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _dateController,
                        readOnly: true,
                        onTap: () async {
                          final current = DateTime.tryParse(_dateController.text) ?? DateTime.now();
                          final picked = await showDatePicker(
                            context: context,
                            initialDate: current,
                            firstDate: DateTime(2000),
                            lastDate: DateTime(2100),
                          );
                          if (picked != null) {
                            setState(() {
                              _dateController.text = _formatDate(picked);
                            });
                          }
                        },
                        style: TextStyle(fontSize: 13, color: textPrimary),
                        decoration: InputDecoration(
                          prefixIcon: Icon(Icons.calendar_today_rounded, size: 16, color: textSecondary),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: BorderSide(color: cardBorder),
                          ),
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),

          // Friend Selection Header
          Row(
            children: [
              Text(
                "Who should this payment be added to?",
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: textPrimary,
                ),
              ),
              const Spacer(),
              if (_selectedFriendUids.isNotEmpty)
                Text(
                  "${_selectedFriendUids.length} selected",
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: isDark ? Colors.white70 : const Color(0xFF111827),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),

          // Receiver & Suggested Matches Section
          if (_extractedInfo?.receiverName != null &&
              _extractedInfo!.receiverName!.isNotEmpty) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: cardBg,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: cardBorder, width: 0.8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.auto_awesome, size: 14, color: isDark ? Colors.white70 : const Color(0xFF111827)),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          "Detected Receiver: ${_extractedInfo!.receiverName}",
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: textPrimary,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (_matchedCandidates.length == 1 && _matchedCandidates.first.confidence == MatchConfidence.high) ...[
                    Text(
                      "Possible match:",
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: textSecondary),
                    ),
                    const SizedBox(height: 4),
                    Builder(builder: (context) {
                      final c = _matchedCandidates.first;
                      final isSelected = _selectedFriendUids.contains(c.friend.uid);
                      return InkWell(
                        onTap: () => _toggleFriendSelection(c.friend.uid),
                        borderRadius: BorderRadius.circular(8),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color: isSelected
                                ? (isDark ? const Color(0xFF064E3B) : const Color(0xFFD1FAE5))
                                : (isDark ? const Color(0xFF1F2937) : const Color(0xFFF3F4F6)),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: isSelected
                                  ? const Color(0xFF10B981)
                                  : cardBorder,
                              width: 0.8,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                isSelected ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                                size: 14,
                                color: isSelected ? const Color(0xFF10B981) : textSecondary,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                c.friend.name,
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: textPrimary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }),
                  ] else if (_matchedCandidates.isNotEmpty) ...[
                    Text(
                      "Possible matches:",
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: textSecondary),
                    ),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: _matchedCandidates.map((c) {
                        final isSelected = _selectedFriendUids.contains(c.friend.uid);
                        return InkWell(
                          onTap: () => _toggleFriendSelection(c.friend.uid),
                          borderRadius: BorderRadius.circular(8),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? (isDark ? const Color(0xFF064E3B) : const Color(0xFFD1FAE5))
                                  : (isDark ? const Color(0xFF1F2937) : const Color(0xFFF3F4F6)),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: isSelected
                                    ? const Color(0xFF10B981)
                                    : cardBorder,
                                width: 0.8,
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  isSelected ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                                  size: 14,
                                  color: isSelected ? const Color(0xFF10B981) : textSecondary,
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  c.friend.name,
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: textPrimary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ] else ...[
                    Text(
                      "No matching friend found.",
                      style: TextStyle(
                        fontSize: 12,
                        fontStyle: FontStyle.italic,
                        color: textSecondary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],

          // Search Friends Bar
          Container(
            decoration: BoxDecoration(
              color: cardBg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: cardBorder, width: 0.8),
            ),
            child: TextField(
              controller: _searchController,
              onChanged: _onSearchChanged,
              style: TextStyle(fontSize: 13, color: textPrimary),
              decoration: InputDecoration(
                hintText: "Search friends...",
                hintStyle: TextStyle(fontSize: 12, color: textSecondary),
                prefixIcon: Icon(Icons.search_rounded, size: 18, color: textSecondary),
                border: InputBorder.none,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
            ),
          ),
          const SizedBox(height: 10),

          // Friends List
          if (_allFriends.isEmpty) ...[
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: cardBg,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: cardBorder),
              ),
              child: Column(
                children: [
                  Icon(Icons.people_outline_rounded, size: 36, color: textSecondary),
                  const SizedBox(height: 8),
                  Text(
                    "No Friends Found",
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: textPrimary),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    "Add friends in Hisab Kitab first to split payments with them.",
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: textSecondary),
                  ),
                  const SizedBox(height: 14),
                  OutlinedButton.icon(
                    onPressed: () async {
                      await Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const AddFriendPage()),
                      );
                      _loadFriends();
                    },
                    icon: const Icon(Icons.person_add_rounded, size: 16),
                    label: const Text("Add Friend"),
                  ),
                ],
              ),
            ),
          ] else ...[
            Container(
              constraints: const BoxConstraints(maxHeight: 220),
              decoration: BoxDecoration(
                color: cardBg,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: cardBorder, width: 0.8),
              ),
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: _filteredFriends.length,
                separatorBuilder: (context, index) => Divider(height: 1, color: cardBorder),
                itemBuilder: (context, index) {
                  final f = _filteredFriends[index];
                  final isSelected = _selectedFriendUids.contains(f.uid);

                  return InkWell(
                    onTap: () => _toggleFriendSelection(f.uid),
                    borderRadius: BorderRadius.circular(16),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      child: Row(
                        children: [
                          CircleAvatar(
                            radius: 16,
                            backgroundColor: isDark
                                ? AppColors.surfaceVariantDark
                                : AppColors.surfaceVariant,
                            child: Text(
                              f.name.isNotEmpty ? f.name[0].toUpperCase() : '?',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: textPrimary,
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  f.name,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: textPrimary,
                                  ),
                                ),
                                if (f.friendCode != null && f.friendCode!.isNotEmpty)
                                  Text(
                                    f.friendCode!,
                                    style: TextStyle(fontSize: 11, color: textSecondary),
                                  ),
                              ],
                            ),
                          ),
                          Checkbox(
                            value: isSelected,
                            onChanged: (_) => _toggleFriendSelection(f.uid),
                            activeColor: isDark ? Colors.white : const Color(0xFF111827),
                            checkColor: isDark ? Colors.black : Colors.white,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
          const SizedBox(height: 18),

          // Split Method Selector (when 2+ friends selected)
          if (_selectedFriendUids.length > 1) ...[
            Text(
              "Split Method",
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                _buildSplitTypeTab("Equal Split", SplitType.equal, isDark),
                const SizedBox(width: 8),
                _buildSplitTypeTab("Custom Split", SplitType.custom, isDark),
                const SizedBox(width: 8),
                _buildSplitTypeTab("Percentage", SplitType.percentage, isDark),
              ],
            ),
            const SizedBox(height: 12),

            // Live Breakdown Table
            _buildBreakdownTable(isDark, textPrimary, textSecondary, cardBg, cardBorder),
            const SizedBox(height: 20),
          ],

          // Proceed Button
          SizedBox(
            height: 48,
            child: ElevatedButton(
              onPressed: _selectedFriendUids.isEmpty ? null : _onProceedToReview,
              style: ElevatedButton.styleFrom(
                backgroundColor: isDark ? Colors.white : const Color(0xFF111827),
                foregroundColor: isDark ? Colors.black87 : Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                elevation: 0,
              ),
              child: const Text(
                "Review Split",
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSplitTypeTab(String label, SplitType type, bool isDark) {
    final isSelected = _splitType == type;
    return Expanded(
      child: InkWell(
        onTap: () {
          setState(() {
            _splitType = type;
            _syncSplitInputs();
          });
        },
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: isSelected
                ? (isDark ? Colors.white : const Color(0xFF111827))
                : (isDark ? const Color(0xFF1E222A) : const Color(0xFFF3F4F6)),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isSelected
                  ? (isDark ? Colors.white : const Color(0xFF111827))
                  : (isDark ? const Color(0xFF3A4150) : const Color(0xFFE5E7EB)),
              width: 0.8,
            ),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: isSelected
                  ? (isDark ? Colors.black87 : Colors.white)
                  : (isDark ? Colors.white70 : const Color(0xFF111827)),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBreakdownTable(
    bool isDark,
    Color textPrimary,
    Color textSecondary,
    Color cardBg,
    Color cardBorder,
  ) {
    final totalAmount = double.tryParse(_amountController.text) ?? 0.0;
    final shares = _computeCurrentShares();
    final selectedFriends = _allFriends.where((f) => _selectedFriendUids.contains(f.uid)).toList();

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: cardBorder, width: 0.8),
      ),
      child: Column(
        children: [
          for (final friend in selectedFriends) ...[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      friend.name,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: textPrimary,
                      ),
                    ),
                  ),
                  if (_splitType == SplitType.equal) ...[
                    Text(
                      "₹${shares.firstWhere((s) => s.friendUid == friend.uid, orElse: () => FriendSplitShare(friendName: friend.name, friendUid: friend.uid, amount: 0)).amount.toStringAsFixed(2)}",
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: textPrimary,
                      ),
                    ),
                  ] else if (_splitType == SplitType.custom) ...[
                    SizedBox(
                      width: 90,
                      height: 36,
                      child: TextFormField(
                        controller: _customControllers[friend.uid],
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        style: TextStyle(fontSize: 12, color: textPrimary),
                        decoration: InputDecoration(
                          prefixText: "₹ ",
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                  ] else if (_splitType == SplitType.percentage) ...[
                    SizedBox(
                      width: 70,
                      height: 36,
                      child: TextFormField(
                        controller: _percentageControllers[friend.uid],
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        style: TextStyle(fontSize: 12, color: textPrimary),
                        decoration: InputDecoration(
                          suffixText: "%",
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
          const Divider(height: 16),
          Row(
            children: [
              Text(
                "Total Amount",
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: textSecondary),
              ),
              const Spacer(),
              Text(
                "₹${totalAmount.toStringAsFixed(2)}",
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: textPrimary),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // 3. Step 1: Review Split & Confirm Step
  Widget _buildReviewStep(
    bool isDark,
    Color textPrimary,
    Color textSecondary,
    Color cardBg,
    Color cardBorder,
  ) {
    final totalAmount = double.parse(_amountController.text);
    final shares = _computeCurrentShares();

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: cardBg,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: cardBorder, width: 0.8),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.04),
                  blurRadius: 10,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: isDark ? const Color(0xFF1E222A) : const Color(0xFFF3F4F6),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(
                        Icons.receipt_long_rounded,
                        size: 20,
                        color: isDark ? Colors.white : const Color(0xFF111827),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          "Total Paid by You",
                          style: TextStyle(fontSize: 12, color: textSecondary),
                        ),
                        Text(
                          "₹${totalAmount.toStringAsFixed(2)}",
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w800,
                            color: textPrimary,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                const Divider(height: 1),
                const SizedBox(height: 14),

                Text(
                  "You paid for:",
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: textSecondary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _allFriends
                      .where((f) => _selectedFriendUids.contains(f.uid))
                      .map((f) => f.name)
                      .join(", "),
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: textPrimary,
                  ),
                ),
                const SizedBox(height: 12),

                Row(
                  children: [
                    Text(
                      "Split Method: ",
                      style: TextStyle(fontSize: 12, color: textSecondary),
                    ),
                    Text(
                      _splitType == SplitType.equal
                          ? "Equal Split"
                          : (_splitType == SplitType.custom ? "Custom Split" : "Percentage Split"),
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: textPrimary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                Text(
                  "Their individual shares (owed to you):",
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: textSecondary,
                  ),
                ),
                const SizedBox(height: 8),

                for (final share in shares) ...[
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        Text(
                          share.friendName,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: textPrimary,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          "₹${share.amount.toStringAsFixed(2)}",
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                            color: isDark ? Colors.white : const Color(0xFF111827),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],

                const SizedBox(height: 12),
                const Divider(height: 1),
                const SizedBox(height: 10),

                Row(
                  children: [
                    Text(
                      "Total Owed:",
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: textSecondary,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      "₹${shares.fold<double>(0.0, (acc, s) => acc + s.amount).toStringAsFixed(2)}",
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: textPrimary,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // Action Buttons
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 48,
                  child: OutlinedButton(
                    onPressed: _isSaving
                        ? null
                        : () {
                            setState(() {
                              _currentStep = 0;
                            });
                          },
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(color: cardBorder, width: 1.0),
                      foregroundColor: textPrimary,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                    child: const Text(
                      "Edit",
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: SizedBox(
                  height: 48,
                  child: ElevatedButton(
                    onPressed: _isSaving ? null : _confirmAndSaveTransactions,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: isDark ? Colors.white : const Color(0xFF111827),
                      foregroundColor: isDark ? Colors.black87 : Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                    child: _isSaving
                        ? SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: isDark ? Colors.black87 : Colors.white,
                            ),
                          )
                        : const Text(
                            "Confirm & Add",
                            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                          ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
