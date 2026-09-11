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
      RecognizedText? devanagariRecognized;
      ExtractedPaymentInfo? info;

      // Pass 1: Try Devanagari first because it natively recognizes the Indian Rupee symbol (₹)
      // and standard Latin digits / English words.
      try {
        textRecognizer = TextRecognizer(script: TextRecognitionScript.devanagiri);
        devanagariRecognized = await textRecognizer.processImage(inputImage);
        debugPrint('[PaymentOcrService] Devanagari OCR returned ${devanagariRecognized.text.length} chars');
        if (devanagariRecognized.text.trim().isNotEmpty) {
          final lines = _extractLinesFromRecognizedText(devanagariRecognized);
          info = _parsePaymentDetails(lines, devanagariRecognized.text);
        }
      } catch (e) {
        debugPrint('[PaymentOcrService] Devanagari OCR error: $e');
      } finally {
        await textRecognizer?.close();
        textRecognizer = null;
      }

      // Pass 2: If Devanagari did not detect an amount or failed, run Latin OCR
      if (info == null || info.amount == null || info.amount! <= 0) {
        try {
          textRecognizer = TextRecognizer(script: TextRecognitionScript.latin);
          final latinRecognized = await textRecognizer.processImage(inputImage);
          debugPrint('[PaymentOcrService] Latin OCR returned ${latinRecognized.text.length} chars');
          if (latinRecognized.text.trim().isNotEmpty) {
            final latinLines = _extractLinesFromRecognizedText(latinRecognized);
            final latinInfo = _parsePaymentDetails(latinLines, latinRecognized.text);
            if (latinInfo.amount != null && latinInfo.amount! > 0) {
              if (info != null) {
                // Merge amount and other detected fields
                info = info.copyWith(
                  amount: latinInfo.amount,
                  confidence: latinInfo.confidence,
                  appName: info.appName ?? latinInfo.appName,
                  receiverName: info.receiverName ?? latinInfo.receiverName,
                  upiId: info.upiId ?? latinInfo.upiId,
                  transactionRef: info.transactionRef ?? latinInfo.transactionRef,
                  date: info.date ?? latinInfo.date,
                  dateString: info.dateString ?? latinInfo.dateString,
                );
              } else {
                info = latinInfo;
              }
            } else {
              info ??= latinInfo;
            }
          }
        } catch (e) {
          debugPrint('[PaymentOcrService] Latin OCR error: $e');
        } finally {
          await textRecognizer?.close();
          textRecognizer = null;
        }
      }

      return info ??
          ExtractedPaymentInfo(
            status: PaymentStatus.unclear,
            statusDescription: 'Failed to read image',
            rawText: devanagariRecognized?.text ?? '',
          );
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

  List<String> _extractLinesFromRecognizedText(RecognizedText recognizedText) {
    final lines = <String>[];
    for (final block in recognizedText.blocks) {
      for (final line in block.lines) {
        final trimmed = line.text.trim();
        if (trimmed.isNotEmpty) {
          lines.add(trimmed);
        }
      }
    }
    return lines;
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
    // Normalize any Devanagari numerals (०-९) across all lines and raw text to standard digits (0-9)
    final normalizedLines = lines.map((l) => AmountParser.normalizeNumerals(l)).toList();
    final normalizedRaw = AmountParser.normalizeNumerals(rawText);
    final lowerRaw = normalizedRaw.toLowerCase();

    // 1. Identify Payment App / Source (returns null if not confidently identified)
    final appName = _detectAppName(lowerRaw);

    // 2. Identify Payment Status
    final statusResult = _detectStatus(lowerRaw);
    final status = statusResult.$1;
    final statusDesc = statusResult.$2;

    // 3. Extract Paid Amount
    final amountResult = _extractAmount(normalizedLines, normalizedRaw);
    final amount = amountResult.$1;
    final confidence = amountResult.$2;

    // 4. Extract UPI ID
    final upiId = _extractUpiId(normalizedLines, normalizedRaw);

    // 5. Extract UTR / Transaction Reference
    final transactionRef = _extractTransactionRef(normalizedLines, normalizedRaw);

    // 6. Extract Date
    final dateResult = _extractDate(normalizedLines, normalizedRaw);

    // 7. Extract Receiver / Merchant Name
    final receiverName = _extractReceiverName(normalizedLines, normalizedRaw);

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
        lowerRaw.contains('transferred from') ||
        lowerRaw.contains('received from') ||
        lowerRaw.contains('credited to') ||
        lowerRaw.contains('paid to') ||
        lowerRaw.contains('sent to') ||
        lowerRaw.contains('debited from') ||
        RegExp(r'\bsuccess(?:ful(?:ly)?)?\b', caseSensitive: false).hasMatch(lowerRaw);

    // Pattern for "Paid ₹X", "Paid X", "Sent ₹X", "Payment of ₹X"
    final paidAmountPattern = RegExp(
      r'\b(?:paid|sent|transferred|received|payment of)\s*(?:[₹\u20B9\u20A8]|rs\.?|inr)?\s*[0-9]+',
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
      final isCurrOnly = RegExp(r'^(?:[₹\u20B9\u20A8]|rs\.?|inr|re\.?|\*)$', caseSensitive: false).hasMatch(line);
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

    // 1. Currency Regex matching on lines
    // Requires that the currency indicator is not part of an alphabetic word
    // Matches Indian Rupee symbols (₹, Rs, INR, Re, and OCR glyph *)
    final currencyRegex = RegExp(
      r'(?<![a-zA-Z0-9])(?:[₹\u20B9\u20A8]|rs\.?|inr|re\.?|\*)\s*([0-9]+(?:,[0-9]+)*(?:\.[0-9]{1,2})?)(?!\d)',
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
          if (_isCommonNonAmountNumber(val, line)) {
            continue;
          }

          double score = 150.0;

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
              lowerLine.contains('received') ||
              lowerLine.contains('credited') ||
              lowerLine.contains('payment')) {
            score += 100.0;
          }

          // Contextual boost: nearby lines above contain payment/transfer indicators
          // (e.g. "Received from", "Paid to", "Credited to", "Transfer Details")
          for (int offset = 1; offset <= 4; offset++) {
            if (i - offset >= 0) {
              final prevNearby = processedLines[i - offset].toLowerCase().trim();
              if (prevNearby.contains('received from') ||
                  prevNearby.contains('received') ||
                  prevNearby.contains('credited to') ||
                  prevNearby.contains('credited') ||
                  prevNearby.contains('paid to') ||
                  prevNearby.contains('sent to') ||
                  prevNearby.contains('transferred to') ||
                  prevNearby.startsWith('to ') ||
                  prevNearby == 'to' ||
                  prevNearby.contains('transfer details')) {
                score += (160.0 - (offset * 15.0));
                break;
              }
            }
          }

          // Contextual boost: nearby lines below contain payment terms
          for (int offset = 1; offset <= 3; offset++) {
            if (i + offset < processedLines.length) {
              final nextNearby = processedLines[i + offset].toLowerCase().trim();
              if (nextNearby.startsWith('paid to') ||
                  nextNearby.startsWith('sent to') ||
                  nextNearby.startsWith('to ') ||
                  nextNearby == 'to' ||
                  nextNearby.contains('banking name') ||
                  nextNearby.contains('credited to')) {
                score += (160.0 - (offset * 15.0));
                break;
              }
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
          if (RegExp(r'^[₹\u20B9\u20A8*]?\s*[0-9,]+(?:\.[0-9]{1,2})?$', caseSensitive: false).hasMatch(line.trim())) {
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

      // Check if the entire line is a clean standalone numeric amount
      // (Even if OCR dropped the currency symbol completely, e.g. "200.00" or "98,000.00" or "12")
      final standaloneVal = AmountParser.parseAmount(line);
      if (standaloneVal != null && standaloneVal > 0 && standaloneVal < 10000000) {
        if (!_isCommonNonAmountNumber(standaloneVal, line)) {
          double score = 60.0;

          // Nearby lines above contain payment/transfer indicators
          for (int offset = 1; offset <= 4; offset++) {
            if (i - offset >= 0) {
              final prevNearby = processedLines[i - offset].toLowerCase().trim();
              if (prevNearby.contains('received from') ||
                  prevNearby.contains('received') ||
                  prevNearby.contains('credited to') ||
                  prevNearby.contains('credited') ||
                  prevNearby.contains('paid to') ||
                  prevNearby.contains('sent to') ||
                  prevNearby.contains('transferred to') ||
                  prevNearby.startsWith('to ') ||
                  prevNearby == 'to' ||
                  prevNearby.contains('transfer details')) {
                score += (160.0 - (offset * 15.0));
                break;
              }
            }
          }

          // Nearby lines below contain payment terms
          for (int offset = 1; offset <= 3; offset++) {
            if (i + offset < processedLines.length) {
              final nextNearby = processedLines[i + offset].toLowerCase().trim();
              if (nextNearby.startsWith('paid to') ||
                  nextNearby.startsWith('sent to') ||
                  nextNearby.startsWith('to ') ||
                  nextNearby == 'to' ||
                  nextNearby.contains('banking name') ||
                  nextNearby.contains('credited to')) {
                score += (160.0 - (offset * 15.0));
                break;
              }
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
          if (RegExp(r'^[₹\u20B9\u20A8*]?\s*[0-9,]+(?:\.[0-9]{1,2})?$', caseSensitive: false).hasMatch(line.trim())) {
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

      // Check embedded number tokens on lines that contain receiver names or payment terms
      // (e.g. "Divyanshu 12" or "UPI • XXXXXX5649@sic 12")
      final embeddedMatches = RegExp(
        r'(?<![a-zA-Z0-9])([0-9]+(?:,[0-9]+)*(?:\.[0-9]{1,2})?)(?!\d)',
      ).allMatches(line);
      for (final em in embeddedMatches) {
        final rawNum = em.group(1);
        final emVal = AmountParser.parseAmount(rawNum);
        if (emVal != null && emVal > 0 && emVal < 10000000 && !_isCommonNonAmountNumber(emVal, line)) {
          // Reject if this specific number is part of a masked account or UPI ID
          final matchStart = em.start;
          final matchEnd = em.end;
          if (matchEnd < line.length && line[matchEnd] == '@') continue;
          final prefix = line.substring(0, matchStart);
          if (RegExp(r'[xX*•]{2,}\s*$').hasMatch(prefix)) continue;

          double score = 40.0;
          bool hasPaymentContext = false;
          for (int offset = 1; offset <= 3; offset++) {
            if (i - offset >= 0) {
              final prev = processedLines[i - offset].toLowerCase();
              if (prev.contains('received') ||
                  prev.contains('credited') ||
                  prev.contains('paid') ||
                  prev.contains('transferred') ||
                  prev.contains('transfer details')) {
                score += (140.0 - (offset * 15.0));
                hasPaymentContext = true;
                break;
              }
            }
            if (i + offset < processedLines.length) {
              final next = processedLines[i + offset].toLowerCase();
              if (next.contains('banking name') || next.contains('credited') || next.contains('paid to')) {
                score += (140.0 - (offset * 15.0));
                hasPaymentContext = true;
                break;
              }
            }
          }
          if (hasPaymentContext && score >= 80.0) {
            candidates.add(_AmountCandidate(amount: emVal, score: score));
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
      // Deduplicate by amount, aggregating frequency bonus
      final scoreMap = <double, double>{};
      final countMap = <double, int>{};
      for (final c in candidates) {
        countMap[c.amount] = (countMap[c.amount] ?? 0) + 1;
        if (!scoreMap.containsKey(c.amount) || scoreMap[c.amount]! < c.score) {
          scoreMap[c.amount] = c.score;
        }
      }

      // If an amount appears multiple times (e.g. amount in body + amount in transfer details),
      // boost its score (+40 per additional occurrence)
      for (final entry in countMap.entries) {
        if (entry.value > 1) {
          scoreMap[entry.key] = (scoreMap[entry.key] ?? 0) + ((entry.value - 1) * 40.0);
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
    final hasExplicitCurrency = line.contains('₹') || lower.contains('rs.') || lower.contains('rs ') || lower.contains('inr');

    // 1. Promotional, ads, reward and cashback banners (e.g. "Get up to 1,000 on every payment 1 = 1 paisa")
    if (lower.contains('get up to') ||
        lower.contains('save up to') ||
        lower.contains('earn up to') ||
        lower.contains('paisa') ||
        lower.contains('cashback') ||
        lower.contains('scratch card') ||
        lower.contains('securely on') ||
        lower.contains('discount') ||
        lower.contains('reward') ||
        lower.contains('win up to')) {
      return true;
    }

    // 2. Account balance lines
    if (lower.contains('balance') ||
        lower.contains('bal:') ||
        lower.contains('avail') ||
        lower.contains('a/c') ||
        lower.contains('account no') ||
        lower.contains('battery') ||
        lower.contains('%')) {
      return true;
    }

    // 3. Receiver or sender name lines without explicit currency
    // (e.g. "to B M MOBILE 1", "from Sandeep Dewasi", "paid to Alice", "sent to Bob")
    // Prevents numbers in names (like "1" in "B M MOBILE 1") from being extracted as amounts!
    if (!hasExplicitCurrency) {
      if (lower.startsWith('to ') ||
          lower.startsWith('from ') ||
          lower.startsWith('paid to ') ||
          lower.startsWith('received from ') ||
          lower.startsWith('sent to ')) {
        return true;
      }
    }

    // 4. Masked bank account lines or UPI handle lines WITHOUT trailing numbers or currency
    // e.g. "WL0502560A0030816@unionbank", "XXXXXX5649@sic"
    // BUT if the line has a trailing amount like "UPI • XXXXXX5649@sic 12", do not reject the line!
    if ((lower.contains('@') || RegExp(r'[xX*•]{2,}').hasMatch(line)) && !hasExplicitCurrency) {
      final hasTrailingNumber = RegExp(r'\s+([0-9]+(?:\.[0-9]{1,2})?)\s*$').hasMatch(line);
      if (!hasTrailingNumber) {
        return true;
      }
    }

    // 5. Phone numbers: safely check for phone labels WITHOUT matching 'phonepe'
    final cleanForPhone = lower.replaceAll('phonepe', '').replaceAll('phone pe', '');
    if (RegExp(r'\b(?:phone|mob|contact)\s*(?:no|number|#)?\s*[:\-]').hasMatch(cleanForPhone)) {
      if (!hasExplicitCurrency) return true;
    }

    // 6. Identifiers & References (unless line has explicit currency)
    if (lower.contains('upi ref') ||
        lower.contains('ref no') ||
        lower.contains('transaction id') ||
        lower.contains('order id') ||
        lower.contains('utr:')) {
      if (!hasExplicitCurrency) return true;
    }

    // 7. Pure phone number line like "+917499752312" (without trailing amounts)
    final digitsOnly = line.replaceAll(RegExp(r'[^0-9]'), '');
    if ((digitsOnly.length == 10 || digitsOnly.length == 12) &&
        (line.startsWith('+') || RegExp(r'^[6-9]').hasMatch(digitsOnly)) &&
        !hasExplicitCurrency &&
        !line.trim().contains(' ')) {
      return true;
    }

    // 8. Filter date and timestamp lines unless they contain explicit currency symbols
    // e.g. "09:16 pm on 11 Sept 2026", "28 August 2026, 3:12 am"
    final hasTimeOrDate = (lower.contains('am') || lower.contains('pm') || lower.contains(':')) &&
        (RegExp(r'\b(?:jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)\b', caseSensitive: false).hasMatch(lower) ||
            RegExp(r'\b20[2-3][0-9]\b').hasMatch(lower));
    if (hasTimeOrDate && !hasExplicitCurrency) {
      return true;
    }

    return false;
  }

  bool _isCommonNonAmountNumber(double val, String line) {
    final lower = line.toLowerCase();
    final digitsOnly = line.replaceAll(RegExp(r'[^0-9]'), '');
    final valIntStr = val.truncate().toString();

    // 1. Masked bank account digits (e.g. 5649 in XXXXXX5649 or ••••5649 or A/c **5649)
    final maskedMatches = RegExp(r'[xX*•]{2,}\s*([0-9]{3,6})').allMatches(line);
    for (final m in maskedMatches) {
      if (m.group(1) == valIntStr) {
        return true;
      }
    }

    // 2. UPI handle prefix digits (e.g. 837870957272 in 837870957272@upi or 5649@sic)
    final upiHandleMatches = RegExp(r'\b([0-9]{3,})@[a-zA-Z]').allMatches(line);
    for (final m in upiHandleMatches) {
      if (m.group(1) == valIntStr) {
        return true;
      }
    }

    // 3. Phone number (10 digits starting with 6-9, e.g. 9876543210 or +91...)
    if (digitsOnly.length == 10 && RegExp(r'^[6-9]').hasMatch(digitsOnly) && valIntStr == digitsOnly) {
      return true;
    }
    if (digitsOnly.length == 12 && line.startsWith('+91') && valIntStr == digitsOnly.substring(2)) {
      return true;
    }
    // Entire line is a phone number
    if ((digitsOnly.length == 10 || digitsOnly.length == 12) &&
        (line.startsWith('+') || RegExp(r'^[6-9]').hasMatch(digitsOnly)) &&
        !line.contains('₹') && !lower.contains('rs')) {
      if (val >= 6000000000) {
        return true;
      }
    }

    // 4. UTR / Txn Reference (standalone 12-digit number without decimals)
    if (digitsOnly.length == 12 && !line.contains('.') && !line.contains('₹') && val >= 100000000000) {
      return true;
    }

    // 5. Year (2020-2035) on a date line without currency
    if (digitsOnly.length == 4 && val >= 2020 && val <= 2035 && !line.contains('₹') && !lower.contains('rs')) {
      return true;
    }

    // 6. Timestamp line (e.g. "09:16 pm on 11 Sept 2026")
    final isTimestampLine = RegExp(r'\b[012]?[0-9]:[0-5][0-9]\s*(?:am|pm)?\b', caseSensitive: false).hasMatch(lower) ||
        RegExp(r'\b(?:am|pm)\b', caseSensitive: false).hasMatch(lower);
    if (isTimestampLine && !line.contains('₹') && !lower.contains('rs') && !lower.contains('inr')) {
      return true;
    }

    // 7. Date month names on lines without currency
    final hasMonthName = RegExp(r'\b(?:jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)\b', caseSensitive: false).hasMatch(lower);
    if (hasMonthName && !line.contains('₹') && !lower.contains('rs') && !lower.contains('inr')) {
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
    // 1. Check for explicit "Banking Name : <Name>" or "Banking Name: <Name>"
    for (final line in lines) {
      final lower = line.toLowerCase().trim();
      if (lower.contains('banking name')) {
        final colonIdx = line.indexOf(':');
        if (colonIdx != -1 && colonIdx + 1 < line.length) {
          final candidate = line.substring(colonIdx + 1).trim();
          if (!_isNonNameLine(candidate)) {
            return candidate;
          }
        }
      }
    }

    // 2. Looks for lines immediately after "Paid to", "Transfer to", "Received from", "To: ", "To "
    for (int i = 0; i < lines.length; i++) {
      final line = lines[i];
      final lower = line.toLowerCase().trim();

      if (lower == 'paid to' ||
          lower == 'transfer to' ||
          lower == 'sent to' ||
          lower == 'received from' ||
          lower == 'from' ||
          lower == 'to') {
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
          lower.startsWith('received from ') ||
          lower.startsWith('to ')) {
        final prefix = lower.startsWith('received from ')
            ? 'received from '
            : lower.startsWith('to ')
                ? 'to '
                : 'to ';
        final startIdx = lower.indexOf(prefix) + prefix.length;
        final candidate = line.substring(startIdx).trim();
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
    if (lower.contains('transfer details') || lower.contains('transaction id') || lower.contains('credited to')) return true;
    if (lower.contains('upi') || lower.contains('utr') || lower.contains('@')) return true;
    // Phone numbers like +917499752312
    final digitsOnly = str.replaceAll(RegExp(r'[^0-9]'), '');
    if (digitsOnly.length >= 10 && str.startsWith('+')) return true;
    if (RegExp(r'^[0-9]+$').hasMatch(str)) return true;
    return false;
  }
}

class _AmountCandidate {
  final double amount;
  final double score;

  _AmountCandidate({required this.amount, required this.score});
}
