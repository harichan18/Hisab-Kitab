enum SplitType {
  equal,
  custom,
  percentage,
}

class FriendSplitShare {
  final String friendName;
  final String? friendUid;
  final double amount;
  final double? percentage;

  const FriendSplitShare({
    required this.friendName,
    this.friendUid,
    required this.amount,
    this.percentage,
  });

  FriendSplitShare copyWith({
    String? friendName,
    String? friendUid,
    double? amount,
    double? percentage,
  }) {
    return FriendSplitShare(
      friendName: friendName ?? this.friendName,
      friendUid: friendUid ?? this.friendUid,
      amount: amount ?? this.amount,
      percentage: percentage ?? this.percentage,
    );
  }
}

class SplitCalculator {
  /// Calculates equal split among [friends] for [totalAmount] in integer paise.
  /// Guarantees that the sum of shares always equals [totalAmount] down to the penny/paise.
  static List<FriendSplitShare> calculateEqualSplit({
    required double totalAmount,
    required List<({String name, String? uid})> friends,
  }) {
    if (friends.isEmpty || totalAmount <= 0) {
      return [];
    }

    final int totalPaise = (totalAmount * 100).round();
    final int count = friends.length;
    final int basePaise = totalPaise ~/ count;
    final int remainderPaise = totalPaise % count;

    final result = <FriendSplitShare>[];
    for (int i = 0; i < count; i++) {
      // Give the extra 1 paise to the first [remainderPaise] friends
      final int friendPaise = basePaise + (i < remainderPaise ? 1 : 0);
      final double friendAmount = friendPaise / 100.0;
      final double friendPercentage = (friendAmount / totalAmount) * 100;

      result.add(
        FriendSplitShare(
          friendName: friends[i].name,
          friendUid: friends[i].uid,
          amount: friendAmount,
          percentage: double.parse(friendPercentage.toStringAsFixed(2)),
        ),
      );
    }

    return result;
  }

  /// Calculates percentage-based split.
  /// Adjusts for any penny rounding discrepancy so that the sum strictly equals [totalAmount].
  static List<FriendSplitShare> calculatePercentageSplit({
    required double totalAmount,
    required List<({String name, String? uid, double percentage})> friends,
  }) {
    if (friends.isEmpty || totalAmount <= 0) {
      return [];
    }

    final int totalPaise = (totalAmount * 100).round();
    final sharesPaise = <int>[];

    for (final f in friends) {
      final int allocated = (totalPaise * (f.percentage / 100.0)).round();
      sharesPaise.add(allocated);
    }

    // Check difference and adjust on the first share
    final int sumPaise = sharesPaise.fold<int>(0, (prev, val) => prev + val);
    final int diff = totalPaise - sumPaise;
    if (diff != 0 && sharesPaise.isNotEmpty) {
      sharesPaise[0] += diff;
    }

    final result = <FriendSplitShare>[];
    for (int i = 0; i < friends.length; i++) {
      result.add(
        FriendSplitShare(
          friendName: friends[i].name,
          friendUid: friends[i].uid,
          amount: sharesPaise[i] / 100.0,
          percentage: friends[i].percentage,
        ),
      );
    }

    return result;
  }

  /// Validates if custom split amounts equal [totalAmount].
  /// Returns null if valid, or an error message if invalid.
  static String? validateCustomSplit({
    required double totalAmount,
    required List<double> customAmounts,
  }) {
    final int totalPaise = (totalAmount * 100).round();
    int sumPaise = 0;
    for (final amount in customAmounts) {
      if (amount < 0) {
        return 'Amounts cannot be negative.';
      }
      sumPaise += (amount * 100).round();
    }

    final int diff = totalPaise - sumPaise;
    if (diff > 0) {
      final remaining = (diff / 100.0).toStringAsFixed(2);
      return '₹$remaining remaining to be assigned.';
    } else if (diff < 0) {
      final excess = ((-diff) / 100.0).toStringAsFixed(2);
      return 'Total exceeds by ₹$excess.';
    }

    return null;
  }
}
