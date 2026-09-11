/// Centralized amount parsing and formatting utility for Hisab Kitab.
/// Supports Indian number systems (lakhs, crores), comma separation,
/// and integer paise conversion.
class AmountParser {
  AmountParser._();

  /// Parses a string representation of an amount into a validated [double].
  ///
  /// Examples:
  /// - "₹200.00" -> 200.0
  /// - "₹98,000.00" -> 98000.0
  /// - "₹1,00,000" -> 100000.0
  /// - "₹1,25,500.50" -> 125500.50
  /// - "Rs. 500" -> 500.0
  /// - "INR 1,000" -> 1000.0
  /// - "Paid ₹1" -> 1.0
  ///
  /// Returns `null` if the input is null, empty, or cannot be parsed into a positive number.
  /// NEVER returns 0.0 as a fallback for invalid input.
  static double? parseAmount(String? raw) {
    if (raw == null) return null;
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;

    // Reject negative numbers
    if (trimmed.contains('-')) return null;

    // Remove currency indicators: ₹, \u20B9, \u20A8, Rs, INR, Re
    var cleaned = trimmed.replaceAll(
      RegExp(r'(?:[₹\u20B9\u20A8]|rs\.?|inr|re\.?|paid|amount|you paid|sent)', caseSensitive: false),
      '',
    );

    // Remove noise symbols like ?, *, :, #, -
    cleaned = cleaned.replaceAll(RegExp(r'[^0-9.,]'), '').trim();
    if (cleaned.isEmpty) return null;

    // Handle commas (both standard international 1,000 and Indian 1,00,000)
    // Remove all commas used as thousands separators
    cleaned = cleaned.replaceAll(',', '');

    final value = double.tryParse(cleaned);
    if (value == null || value <= 0 || value.isNaN || value.isInfinite) {
      return null;
    }

    return value;
  }

  /// Converts a double rupee amount into integer paise.
  /// E.g. 200.00 -> 20000, 98000.00 -> 9800000, 1.0 -> 100.
  static int? toPaise(double? amount) {
    if (amount == null || amount <= 0) return null;
    return (amount * 100).round();
  }

  /// Converts integer paise back into double rupee amount.
  /// E.g. 20000 -> 200.0, 9800000 -> 98000.0.
  static double fromPaise(int paise) {
    return paise / 100.0;
  }

  /// Formats an amount cleanly for display.
  /// If [preserveDecimals] is true and amount has decimal paise, shows 2 decimals.
  /// If amount is whole (e.g. 200.0), returns "200.00" or "200" based on [forceTwoDecimals].
  static String formatForInput(double? amount) {
    if (amount == null) return '';
    if (amount % 1 == 0) {
      return amount.toStringAsFixed(0);
    }
    return amount.toStringAsFixed(2);
  }

  /// Formats amount for display with commas if desired.
  static String formatDisplay(double amount, {bool showPaise = true}) {
    if (!showPaise && amount % 1 == 0) {
      return amount.toStringAsFixed(0);
    }
    return amount.toStringAsFixed(2);
  }
}
