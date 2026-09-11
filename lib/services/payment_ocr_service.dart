import 'package:flutter/foundation.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import '../models/extracted_payment_info.dart';
import '../utils/amount_parser.dart';

class PaymentOcrService {
  PaymentOcrService._();
  static final PaymentOcrService instance = PaymentOcrService._();

  Future<ExtractedPaymentInfo> processScreenshot(String imagePath) async {
    TextRecognizer? textRecognizer;
    try {
      final inputImage = InputImage.fromFilePath(imagePath);
      RecognizedText? recognizedText;

      // Try Devanagari first as it natively recognizes the Indian Rupee symbol (₹)
      try {
        textRecognizer = TextRecognizer(script: TextRecognitionScript.devanagiri);
        recognizedText = await textRecognizer.processImage(inputImage);
        debugPrint('[PaymentOcrService] Devanagari OCR returned ${recognizedText.text.length} chars');
        if (recognizedText.text.trim().isEmpty) {
          throw Exception('Devanagari OCR returned empty text');
        }
      } catch (e) {
        debugPrint('[PaymentOcrService] Devanagari OCR unavailable or empty, falling back to Latin: $e');
        await textRecognizer?.close();
        textRecognizer = TextRecognizer(script: TextRecognitionScript.latin);
        recognizedText = await textRecognizer.processImage(inputImage);
      }

      final fullRawText = recognizedText.text;
      debugPrint('[PaymentOcrService] Raw OCR text:\n$fullRawText');

      final allLines = <String>[];
      for (final block in recognizedText.blocks) {
        for (final line in block.lines) {
          final trimmed = line.text.trim();
          if (trimmed.isNotEmpty) {
            allLines.add(trimmed);
          }
        }
      }

      return _parsePaymentDetails(allLines, fullRawText);
    } catch (e, st) {
      debugPrint('[PaymentOcrService] OCR Error: $e\n$st');
      return ExtractedPaymentInfo(
        status: PaymentStatus.unclear,
        statusDescription: 'Failed to read image: $e',
        rawText: '',
      );
    } finally {
      await textRecognizer?.close();
    }
  }

  /// Parses OCR extracted lines and raw text into structured [ExtractedPaymentInfo].
  /// Exposed for testing and internal pipeline processing.
  ExtractedPaymentInfo parseExtractedText(String rawText, {List<String>? lines}) {
    final effectiveLines = lines ??
        rawText
            .split('\n')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList();
    return _parsePaymentDetails(effectiveLines, rawText);
  }

  ExtractedPaymentInfo _parsePaymentDetails(
    List<String> lines,
    String rawText,
  ) {
    final lowerRaw = rawText.toLowerCase();

    // 1. Identify Payment App / Source (returns null if not confidently identified)
    final appName = _detectAppName(lowerRaw);

    // 2. Identify Payment Status
    final statusResult = _detectStatus(lowerRaw);
    final status = statusResult.$1;
    final statusDesc = statusResult.$2;

    // 3. Extract Paid Amount
    final amountResult = _extractAmount(lines, rawText);
    final amount = amountResult.$1;
    final confidence = amountResult.$2;

    // 4. Extract UPI ID
    final upiId = _extractUpiId(lines, rawText);

    // 5. Extract UTR / Transaction Reference
    final transactionRef = _extractTransactionRef(lines, rawText);

    // 6. Extract Date
    final dateResult = _extractDate(lines, rawText);

    // 7. Extract Receiver / Merchant Name
    final receiverName = _extractReceiverName(lines, rawText);

    return ExtractedPaymentInfo(
      amount: amount,
      currency: '₹',
      status: status,
      statusDescription: statusDesc,
      appName: appName,
      receiverName: receiverName,
      upiId: upiId,
      transactionRef: transactionRef,
      date: dateResult.$1,
      dateString: dateResult.$2,
      rawText: rawText,
      confidence: confidence,
    );
  }

  String? _detectAppName(String lowerRaw) {
    if (lowerRaw.contains('google pay') ||
        lowerRaw.contains('gpay') ||
        lowerRaw.contains('google llc') ||
        lowerRaw.contains('tez') ||
        lowerRaw.contains('@oksbi') ||
        lowerRaw.contains('@okhdfcbank') ||
        lowerRaw.contains('@okaxis') ||
        lowerRaw.contains('@okicici')) {
      return 'Google Pay';
    }
    if (lowerRaw.contains('phonepe') ||
        lowerRaw.contains('phone pe') ||
        lowerRaw.contains('@ybl') ||
        lowerRaw.contains('@ibl') ||
        lowerRaw.contains('@axl')) {
      return 'PhonePe';
    }
    if (lowerRaw.contains('paytm') ||
        lowerRaw.contains('one97') ||
        lowerRaw.contains('@paytm')) {
      return 'Paytm';
    }
    if (lowerRaw.contains('bhim')) {
      return 'BHIM';
    }
    if (lowerRaw.contains('slice')) {
      return 'Slice';
    }
    if (lowerRaw.contains('cred')) {
      return 'CRED';
    }
    if (lowerRaw.contains('amazon pay')) {
      return 'Amazon Pay';
    }
    if (lowerRaw.contains('sbi') || lowerRaw.contains('yono')) {
      return 'SBI';
    }
    if (lowerRaw.contains('hdfc')) {
      return 'HDFC Bank';
    }
    if (lowerRaw.contains('icici') || lowerRaw.contains('imobile')) {
      return 'ICICI Bank';
    }
    if (lowerRaw.contains('axis')) {
      return 'Axis Bank';
    }
    if (lowerRaw.contains('kotak')) {
      return 'Kotak Bank';
    }
    // Return null if not identified; never fabricate generic placeholder names
    return null;
  }

  (PaymentStatus, String) _detectStatus(String lowerRaw) {
    // 1. Check failure first
    final hasFailed = lowerRaw.contains('payment failed') ||
        lowerRaw.contains('transaction failed') ||
        lowerRaw.contains('declined') ||
        lowerRaw.contains('failed') ||
        lowerRaw.contains('cancelled') ||
        lowerRaw.contains('canceled') ||
        lowerRaw.contains('unsuccessful') ||
        lowerRaw.contains('rejected') ||
        lowerRaw.contains('reversed');

    if (hasFailed) {
      return (PaymentStatus.failed, 'Payment Failed');
    }

    // 2. Check pending / processing
    if (lowerRaw.contains('pending') || lowerRaw.contains('processing')) {
      return (PaymentStatus.unclear, 'Payment Status Unclear — Please Verify');
    }

    // 3. Check unambiguous success keywords & patterns
    final hasSuccessPhrase = lowerRaw.contains('payment successful') ||
        lowerRaw.contains('transaction successful') ||
        lowerRaw.contains('paid successfully') ||
        lowerRaw.contains('successfully paid') ||
        lowerRaw.contains('payment completed') ||
        lowerRaw.contains('transaction completed') ||
        lowerRaw.contains('payment done') ||
        lowerRaw.contains('successfully') ||
        lowerRaw.contains('completed') ||
        lowerRaw.contains('transferred to') ||
        lowerRaw.contains('paid to') ||
        lowerRaw.contains('sent to') ||
        lowerRaw.contains('debited from') ||
        RegExp(r'\bsuccess(?:ful(?:ly)?)?\b', caseSensitive: false).hasMatch(lowerRaw);

    // Pattern for "Paid ₹X", "Paid X", "Sent ₹X", "Payment of ₹X"
    final paidAmountPattern = RegExp(
      r'\b(?:paid|sent|transferred|payment of)\s*(?:[₹\u20B9\u20A8]|rs\.?|inr)?\s*[0-9]+',
      caseSensitive: false,
    );

    if (hasSuccessPhrase || paidAmountPattern.hasMatch(lowerRaw)) {
      return (PaymentStatus.successful, 'Payment Successful');
    }

    // 4. Default when genuine uncertainty exists
    return (PaymentStatus.unclear, 'Payment Status Unclear — Please Verify');
  }

  (double?, double) _extractAmount(List<String> lines, String rawText) {
    final candidates = <_AmountCandidate>[];

    // Pre-processing: Combine multi-line currency symbol + amount
    // e.g. line[i] is '₹' or 'Rs' and line[i+1] is '98,000.00' -> '₹98,000.00'
    final processedLines = <String>[];
    for (int i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      final isCurrOnly = RegExp(r'^(?:[₹\u20B9\u20A8]|rs\.?|inr|re\.?|[?*fFtT=])$', caseSensitive: false).hasMatch(line);
      if (isCurrOnly && i + 1 < lines.length) {
        final nextLine = lines[i + 1].trim();
        // Allow commas in next line for Indian/international number formatting
        if (RegExp(r'^[0-9,]+(?:\.[0-9]{1,2})?$').hasMatch(nextLine)) {
          processedLines.add('₹$nextLine');
          i++; // Skip next line as it is merged
          continue;
        }
      }
      processedLines.add(line);
    }

    // 1. Currency Regex matching on lines (supports ₹, \u20B9, \u20A8, Rs, INR, Re, and common OCR noise ? * F =)
    final currencyRegex = RegExp(
      r'(?:[₹\u20B9\u20A8]|rs\.?|inr|re\.?|[?*fFtTrR=])\s*([0-9]{1,3}(?:,[0-9]{2,3})*(?:\.[0-9]{1,2})?|[0-9]+(?:\.[0-9]{1,2})?)',
      caseSensitive: false,
    );

    for (int i = 0; i < processedLines.length; i++) {
      final line = processedLines[i];
      final lowerLine = line.toLowerCase();

      if (_isNonAmountLine(line)) {
        continue;
      }

      // Check for explicit currency match in this line
      final matches = currencyRegex.allMatches(line);
      for (final match in matches) {
        final rawNumStr = match.group(1);
        final val = AmountParser.parseAmount(rawNumStr);
        if (val != null && val > 0 && val < 10000000) {
          double score = 120.0;

          // Has standard Indian currency indicator
          if (line.contains('₹') || lowerLine.contains('rs') || lowerLine.contains('inr')) {
            score += 40.0;
          }

          // Contextual boost: line itself contains payment terms
          if (lowerLine.contains('paid') ||
              lowerLine.contains('amount paid') ||
              lowerLine.contains('you paid') ||
              lowerLine.contains('payment of') ||
              lowerLine.contains('total paid') ||
              lowerLine.contains('transfer') ||
              lowerLine.contains('sent') ||
              lowerLine.contains('debited') ||
              lowerLine.contains('payment')) {
            score += 100.0;
          }

          // Contextual boost: next line is "Paid to" or "To" (Google Pay, Slice, etc.)
          if (i + 1 < processedLines.length) {
            final nextLower = processedLines[i + 1].toLowerCase().trim();
            if (nextLower.startsWith('paid to') ||
                nextLower == 'paid to' ||
                nextLower.startsWith('sent to') ||
                nextLower.startsWith('transfer to') ||
                nextLower.startsWith('transferred to')) {
              score += 160.0;
            } else if (nextLower.startsWith('to ') || nextLower == 'to' || nextLower == 'to:') {
              score += 140.0;
            }
          }

          // Contextual boost: preceded by "Payment Successful" / "Completed"
          if (i > 0) {
            final prevLower = processedLines[i - 1].toLowerCase().trim();
            if (prevLower.contains('successful') || prevLower.contains('completed') || prevLower.contains('sent')) {
              score += 120.0;
            }
          }
          if (i > 1) {
            final prevPrevLower = processedLines[i - 2].toLowerCase().trim();
            if (prevPrevLower.contains('successful') || prevPrevLower.contains('completed')) {
              score += 90.0;
            }
          }

          // Line is solely the amount (primary prominent amount)
          if (RegExp(r'^[₹\u20B9\u20A8rRtTfF*?=]?\s*[0-9,]+(?:\.[0-9]{1,2})?$', caseSensitive: false).hasMatch(line.trim())) {
            score += 50.0;
          }

          // Has decimals (e.g. .00, .50)
          if (rawNumStr != null && rawNumStr.contains('.')) {
            score += 20.0;
          }

          // Position heuristic
          if (i <= 3) {
            score += 25.0;
          } else if (i > 10) {
            score -= 30.0;
          }

          candidates.add(_AmountCandidate(amount: val, score: score));
        }
      }

      // Check if the entire line or part of it is a clean standalone numeric amount
      // (Even if OCR dropped the currency symbol completely, e.g. "200.00" or "98,000.00")
      final standaloneVal = AmountParser.parseAmount(line);
      if (standaloneVal != null && standaloneVal > 0 && standaloneVal < 10000000) {
        if (!_isCommonNonAmountNumber(standaloneVal, line)) {
          double score = 50.0;

          // Next line is "Paid to" or "To"
          if (i + 1 < processedLines.length) {
            final nextLower = processedLines[i + 1].toLowerCase().trim();
            if (nextLower.startsWith('paid to') ||
                nextLower == 'paid to' ||
                nextLower.startsWith('sent to') ||
                nextLower.startsWith('transfer to')) {
              score += 160.0;
            } else if (nextLower.startsWith('to ') || nextLower == 'to' || nextLower == 'to:') {
              score += 140.0;
            }
          }

          // Preceded by success
          if (i > 0) {
            final prevLower = processedLines[i - 1].toLowerCase().trim();
            if (prevLower.contains('successful') || prevLower.contains('completed')) {
              score += 120.0;
            }
          }
          if (i > 1) {
            final prevPrevLower = processedLines[i - 2].toLowerCase().trim();
            if (prevPrevLower.contains('successful') || prevPrevLower.contains('completed')) {
              score += 90.0;
            }
          }

          // Clean standalone line
          if (RegExp(r'^[₹\u20B9\u20A8rRtTfF*?=]?\s*[0-9,]+(?:\.[0-9]{1,2})?$', caseSensitive: false).hasMatch(line.trim())) {
            score += 50.0;
          }

          // Has decimals or commas
          if (line.contains('.') || line.contains(',')) {
            score += 25.0;
          }

          if (i <= 3) {
            score += 25.0;
          } else if (i > 10) {
            score -= 30.0;
          }

          if (score >= 80.0) {
            candidates.add(_AmountCandidate(amount: standaloneVal, score: score));
          }
        }
      }
    }

    // 2. Global search in rawText for explicit currency occurrences as fallback
    final globalMatches = currencyRegex.allMatches(rawText);
    for (final match in globalMatches) {
      final val = AmountParser.parseAmount(match.group(1));
      if (val != null && val > 0 && val < 10000000) {
        candidates.add(_AmountCandidate(amount: val, score: 90.0));
      }
    }

    if (candidates.isNotEmpty) {
      // Deduplicate by amount, retaining the highest score for that amount
      final scoreMap = <double, double>{};
      for (final c in candidates) {
        if (!scoreMap.containsKey(c.amount) || scoreMap[c.amount]! < c.score) {
          scoreMap[c.amount] = c.score;
        }
      }

      final sorted = scoreMap.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));

      final best = sorted.first;
      debugPrint('[PaymentOcrService] Detected best amount: ₹${best.key} with score ${best.value}');
      return (best.key, (best.value / 200.0).clamp(0.0, 1.0));
    }

    return (null, 0.0);
  }

  bool _isNonAmountLine(String line) {
    final lower = line.toLowerCase();
    if (lower.contains('balance') ||
        lower.contains('bal:') ||
        lower.contains('avail') ||
        lower.contains('a/c') ||
        lower.contains('account no') ||
        lower.contains('upi ref') ||
        lower.contains('ref no') ||
        lower.contains('txn') ||
        lower.contains('transaction id') ||
        lower.contains('order id') ||
        lower.contains('phone') ||
        lower.contains('mob:') ||
        lower.contains('contact') ||
        lower.contains('battery') ||
        lower.contains('%')) {
      return true;
    }
    return false;
  }

  bool _isCommonNonAmountNumber(double val, String line) {
    final lower = line.toLowerCase();
    final digitsOnly = line.replaceAll(RegExp(r'[^0-9]'), '');

    // Phone number (10 digits starting with 6-9)
    if (digitsOnly.length == 10 && RegExp(r'^[6-9]').hasMatch(digitsOnly)) {
      return true;
    }
    // UTR / Txn Reference (12 digits)
    if (digitsOnly.length == 12) {
      return true;
    }
    // Year (2020-2035)
    if (digitsOnly.length == 4 && val >= 2020 && val <= 2035) {
      return true;
    }
    // Timestamp (e.g. 3:12 am, 10:21 pm)
    if (lower.contains(':') || lower.contains('am') || lower.contains('pm')) {
      return true;
    }
    // Date month names
    if (lower.contains('jan') ||
        lower.contains('feb') ||
        lower.contains('mar') ||
        lower.contains('apr') ||
        lower.contains('may') ||
        lower.contains('jun') ||
        lower.contains('jul') ||
        lower.contains('aug') ||
        lower.contains('sep') ||
        lower.contains('oct') ||
        lower.contains('nov') ||
        lower.contains('dec')) {
      return true;
    }
    return false;
  }

  String? _extractUpiId(List<String> lines, String rawText) {
    final upiRegex = RegExp(
      r'\b[a-zA-Z0-9.\-_]{2,64}@[a-zA-Z]{2,32}\b',
      caseSensitive: false,
    );

    for (final line in lines) {
      final match = upiRegex.firstMatch(line);
      if (match != null) {
        final matched = match.group(0);
        // Exclude common domain emails if needed, but in UPI it's mostly @ok..., @ibl, @ybl, @axl, @paytm, etc.
        if (matched != null && !matched.endsWith('.com') && !matched.endsWith('.in')) {
          return matched;
        }
      }
    }

    final globalMatch = upiRegex.firstMatch(rawText);
    if (globalMatch != null) {
      final matched = globalMatch.group(0);
      if (matched != null && !matched.endsWith('.com') && !matched.endsWith('.in')) {
        return matched;
      }
    }

    return null;
  }

  String? _extractTransactionRef(List<String> lines, String rawText) {
    final refRegex = RegExp(
      r'(?:upi\s*(?:ref|reference|txn)?|txn|transaction\s*(?:id|ref)?|utr|rrn)[\s:#-]*([0-9]{10,22}|[a-zA-Z0-9]{12,24})',
      caseSensitive: false,
    );

    for (final line in lines) {
      final match = refRegex.firstMatch(line);
      if (match != null) {
        return match.group(1);
      }
    }

    final globalMatch = refRegex.firstMatch(rawText);
    if (globalMatch != null) {
      return globalMatch.group(1);
    }

    // Fallback: standalone 12-digit number
    final standalone12 = RegExp(r'\b([0-9]{12})\b');
    for (final line in lines) {
      final match = standalone12.firstMatch(line);
      if (match != null) {
        return match.group(1);
      }
    }

    return null;
  }

  (DateTime?, String?) _extractDate(List<String> lines, String rawText) {
    final now = DateTime.now();

    // Common formats: "11 Sep 2026", "11 September 26", "11/09/2026", "11-09-2026"
    final dateNamedMonthRegex = RegExp(
      r'\b([0-3]?[0-9])\s+(Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|Jun(?:e)?|Jul(?:y)?|Aug(?:ust)?|Sep(?:tember)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)(?:\s*,?\s*([12][0-9]{3}|[0-9]{2}))?\b',
      caseSensitive: false,
    );

    final dateNumericRegex = RegExp(
      r'\b([0-3]?[0-9])[\/\-]([01]?[0-9])[\/\-]([12][0-9]{3})\b',
    );

    for (final line in lines) {
      final match1 = dateNamedMonthRegex.firstMatch(line);
      if (match1 != null) {
        final day = int.tryParse(match1.group(1) ?? '') ?? now.day;
        final monthName = (match1.group(2) ?? '').toLowerCase();
        int year = now.year;
        final rawYear = match1.group(3);
        if (rawYear != null) {
          final parsedYear = int.tryParse(rawYear);
          if (parsedYear != null) {
            year = parsedYear < 100 ? (2000 + parsedYear) : parsedYear;
          }
        }
        final month = _monthNumber(monthName);
        try {
          final dt = DateTime(year, month, day);
          return (dt, '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}');
        } catch (_) {}
      }

      final match2 = dateNumericRegex.firstMatch(line);
      if (match2 != null) {
        final p1 = int.tryParse(match2.group(1) ?? '') ?? 1;
        final p2 = int.tryParse(match2.group(2) ?? '') ?? 1;
        final year = int.tryParse(match2.group(3) ?? '') ?? now.year;
        // In India, DD/MM/YYYY is standard
        final day = p1 <= 31 ? p1 : 1;
        final month = p2 <= 12 ? p2 : 1;
        try {
          final dt = DateTime(year, month, day);
          return (dt, '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}');
        } catch (_) {}
      }
    }

    // Default to today
    final todayStr = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    return (now, todayStr);
  }

  int _monthNumber(String name) {
    if (name.startsWith('jan')) return 1;
    if (name.startsWith('feb')) return 2;
    if (name.startsWith('mar')) return 3;
    if (name.startsWith('apr')) return 4;
    if (name.startsWith('may')) return 5;
    if (name.startsWith('jun')) return 6;
    if (name.startsWith('jul')) return 7;
    if (name.startsWith('aug')) return 8;
    if (name.startsWith('sep')) return 9;
    if (name.startsWith('oct')) return 10;
    if (name.startsWith('nov')) return 11;
    if (name.startsWith('dec')) return 12;
    return 1;
  }

  String? _extractReceiverName(List<String> lines, String rawText) {
    // Looks for lines immediately after "Paid to", "Transfer to", "To: ", "To "
    for (int i = 0; i < lines.length; i++) {
      final line = lines[i];
      final lower = line.toLowerCase().trim();

      if (lower == 'paid to' || lower == 'transfer to' || lower == 'sent to' || lower == 'to') {
        if (i + 1 < lines.length) {
          final candidate = lines[i + 1].trim();
          if (!_isNonNameLine(candidate)) {
            return candidate;
          }
        }
      }

      if (lower.startsWith('paid to ') ||
          lower.startsWith('transfer to ') ||
          lower.startsWith('sent to ') ||
          lower.startsWith('to ')) {
        final candidate = line.substring(line.toLowerCase().indexOf('to ') + 3).trim();
        if (!_isNonNameLine(candidate)) {
          return candidate;
        }
      }
    }

    return null;
  }

  bool _isNonNameLine(String str) {
    final lower = str.toLowerCase();
    if (str.isEmpty) return true;
    if (str.contains('₹') || lower.contains('rs.') || lower.contains('inr')) return true;
    if (lower.contains('successful') || lower.contains('completed') || lower.contains('failed')) return true;
    if (RegExp(r'^[0-9]+$').hasMatch(str)) return true;
    return false;
  }
}

class _AmountCandidate {
  final double amount;
  final double score;

  _AmountCandidate({required this.amount, required this.score});
}
