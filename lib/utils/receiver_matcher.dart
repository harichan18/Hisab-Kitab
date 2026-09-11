/// Centralized receiver and friend matching utility for Hisab Kitab.
/// Matches detected receiver name and UPI against existing genuine friends
/// with confidence scoring (exact, first+last, partial/single-token, UPI).
/// NEVER creates fake friends or mutates friend data.
library;

enum MatchConfidence {
  high,
  medium,
  none,
}

class FriendMatchCandidate<T> {
  final T friend;
  final double score;
  final MatchConfidence confidence;
  final String reason;

  const FriendMatchCandidate({
    required this.friend,
    required this.score,
    required this.confidence,
    required this.reason,
  });
}

class ReceiverMatcher {
  ReceiverMatcher._();

  /// Normalizes a string for comparison:
  /// - converts to lowercase
  /// - replaces non-alphanumeric chars with spaces
  /// - collapses consecutive spaces to single space
  /// - trims leading/trailing spaces
  static String normalize(String? input) {
    if (input == null) return '';
    return input
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9\s]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  /// Matches a detected receiver against the user's existing friends.
  /// Returns a list of candidates sorted by descending match score.
  /// Only candidates meeting minimum confidence threshold are returned.
  static List<FriendMatchCandidate<T>> matchReceiver<T>({
    required String? receiverName,
    String? upiId,
    required List<T> friends,
    required String Function(T) getName,
    String? Function(T)? getUpiId,
    String? Function(T)? getFriendCode,
  }) {
    final normReceiver = normalize(receiverName);
    final normUpi = upiId?.trim().toLowerCase();

    if (normReceiver.isEmpty && (normUpi == null || normUpi.isEmpty)) {
      return const [];
    }

    final rTokens = normReceiver
        .split(' ')
        .where((t) => t.isNotEmpty)
        .toList();

    final candidates = <FriendMatchCandidate<T>>[];

    for (final friend in friends) {
      final fRawName = getName(friend);
      final normFriend = normalize(fRawName);
      if (normFriend.isEmpty) continue;

      final fTokens = normFriend
          .split(' ')
          .where((t) => t.isNotEmpty)
          .toList();

      double score = 0.0;
      String reason = '';

      // 1. UPI Identifier Match (highest fidelity signal)
      if (normUpi != null && normUpi.isNotEmpty && getUpiId != null) {
        final fUpi = getUpiId(friend)?.trim().toLowerCase();
        if (fUpi != null && fUpi.isNotEmpty && fUpi == normUpi) {
          score = 1.0;
          reason = 'UPI ID match';
        }
      }

      // 2. Exact Normalized Name Match
      if (score < 1.0 && normFriend == normReceiver) {
        score = 1.0;
        reason = 'Exact name match';
      }

      // 3. Friend Code Match
      if (score < 1.0 && getFriendCode != null) {
        final code = normalize(getFriendCode(friend));
        if (code.isNotEmpty && normReceiver.contains(code)) {
          score = 0.95;
          reason = 'Friend code match';
        }
      }

      // 4. First + Last Name Match
      // e.g. Detected "DIVYANSHU NAGO THAKARE" (first: divyanshu, last: thakare)
      // vs Friend "Divyanshu Thakare" (first: divyanshu, last: thakare)
      if (score < 0.9 && rTokens.length >= 2 && fTokens.length >= 2) {
        if (rTokens.first == fTokens.first && rTokens.last == fTokens.last) {
          score = 0.9;
          reason = 'First and last name match';
        }
      }

      // 5. Multi-token Subset Match
      // All tokens of friend name are present in detected receiver name
      if (score < 0.85 && fTokens.length >= 2) {
        final allMatched = fTokens.every((t) => rTokens.contains(t));
        if (allMatched) {
          score = 0.85;
          reason = 'Full name contained in detected receiver';
        }
      }

      // 6. Single Token / First Name Only Match
      // e.g. Friend is just "Divyanshu" while detected is "DIVYANSHU NAGO THAKARE"
      // As per requirement: "do not treat 'Divyanshu' and 'Divyanshu Thakare' as automatically identical"
      // Hence single-token match gets MEDIUM confidence (0.6) so it is suggested for user confirmation
      if (score < 0.6 && fTokens.length == 1 && rTokens.isNotEmpty) {
        if (rTokens.contains(fTokens.first)) {
          score = 0.6;
          reason = 'First/single name match';
        }
      }

      // 7. Single Token in Reverse (Detected is 1 word, Friend is multi-word)
      if (score < 0.55 && rTokens.length == 1 && fTokens.isNotEmpty) {
        if (fTokens.contains(rTokens.first)) {
          score = 0.55;
          reason = 'Partial name match';
        }
      }

      if (score >= 0.5) {
        final confidence = score >= 0.85
            ? MatchConfidence.high
            : MatchConfidence.medium;

        candidates.add(FriendMatchCandidate(
          friend: friend,
          score: score,
          confidence: confidence,
          reason: reason,
        ));
      }
    }

    // Sort highest score first
    candidates.sort((a, b) => b.score.compareTo(a.score));
    return candidates;
  }
}
