import 'package:flutter_test/flutter_test.dart';
import 'package:hisab_kitab/models/extracted_payment_info.dart';
import 'package:hisab_kitab/services/payment_ocr_service.dart';
import 'package:hisab_kitab/services/split_calculator.dart';
import 'package:hisab_kitab/utils/amount_parser.dart';
import 'package:hisab_kitab/utils/receiver_matcher.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Payment OCR Tests - Real Regression Screenshots', () {
    // TEST 1: Google Pay - Chandan D Kushwaha (₹200.00)
    test('TEST 1: ₹200.00 -> Amount = 200.0, Receiver = CHANDAN D KUSHWAHA', () {
      const rawText = '''
₹200.00
Paid to
CHANDAN D KUSHWAHA
Banking name: CHANDAN D KUSHWAHA
28 August 2026, 3:12 am
''';
      final result = PaymentOcrService.instance.parseExtractedText(rawText);
      expect(result.status, PaymentStatus.successful);
      expect(result.amount, 200.0);
      expect(result.receiverName?.toUpperCase(), 'CHANDAN D KUSHWAHA');
      expect(result.dateString, '2026-08-28');
    });

    // TEST 2: Google Pay - Binay Kushwaha (₹98,000.00 with comma & decimals)
    test('TEST 2: ₹98,000.00 -> Amount = 98000.0, Receiver = BINAY KUSHWAHA', () {
      const rawText = '''
₹98,000.00
Paid to
BINAY KUSHWAHA
Banking name: BINAY KUSHWAHA
6 July 2026, 10:21 pm
''';
      final result = PaymentOcrService.instance.parseExtractedText(rawText);
      expect(result.status, PaymentStatus.successful);
      expect(result.amount, 98000.0);
      expect(result.receiverName?.toUpperCase(), 'BINAY KUSHWAHA');
      expect(result.dateString, '2026-07-06');
    });

    // TEST 2 (Variant): OCR dropped currency symbol completely -> "98,000.00"
    test('TEST 2 (Dropped symbol): 98,000.00 -> Amount = 98000.0, Receiver = BINAY KUSHWAHA', () {
      const rawText = '''
98,000.00
Paid to
BINAY KUSHWAHA
Banking name: BINAY KUSHWAHA
6 July 2026, 10:21 pm
''';
      final result = PaymentOcrService.instance.parseExtractedText(rawText);
      expect(result.status, PaymentStatus.successful);
      expect(result.amount, 98000.0);
      expect(result.receiverName?.toUpperCase(), 'BINAY KUSHWAHA');
    });

    // TEST 3: Slice - Divyanshu Nago Thakare (Paid ₹1)
    test('TEST 3: Paid ₹1 -> Amount = 1.0, Receiver = DIVYANSHU NAGO THAKARE', () {
      const rawText = '''
Paid ₹1
To DIVYANSHU NAGO THAKARE
11 September 26, 07:55 pm • UPI
View details
Done
''';
      final result = PaymentOcrService.instance.parseExtractedText(rawText);
      expect(result.status, PaymentStatus.successful);
      expect(result.amount, 1.0);
      expect(result.receiverName?.toUpperCase(), contains('DIVYANSHU'));
      expect(result.dateString, '2026-09-11');
    });

    // TEST 4: PhonePe - Received from Divyanshu (₹12) with date and timestamp
    test('TEST 4: PhonePe Received from Divyanshu ₹12 -> Amount = 12.0, Receiver = DIVYANSHU NAGO THAKARE, NOT 202', () {
      const rawText = '''
Transaction Successful
09:16 pm on 11 Sept 2026
Received from
Divyanshu
+917499752312
₹12
Banking Name : Divyanshu Nago Thakare
Transfer Details
PhonePe Transaction ID
T2609112116182791351026
Credited to
UPI • XXXXXX5649@sic
₹12
UTR: 837870957272
''';
      final result = PaymentOcrService.instance.parseExtractedText(rawText);
      expect(result.status, PaymentStatus.successful);
      expect(result.amount, 12.0);
      expect(result.appName, 'PhonePe');
      expect(result.receiverName?.toUpperCase(), contains('DIVYANSHU'));
      expect(result.dateString, '2026-09-11');
      expect(result.transactionRef, '837870957272');
    });

    // TEST 5: Date string "09:16 pm on 11 Sept 2026" does not produce 202 or 2026 as amount
    test('TEST 5: Date line "09:16 pm on 11 Sept 2026" is never parsed as amount 202', () {
      const rawText = '''
Transaction Successful
09:16 pm on 11 Sept 2026
Paid to
Rahul Kumar
₹500
''';
      final result = PaymentOcrService.instance.parseExtractedText(rawText);
      expect(result.amount, 500.0);
    });

    // TEST 6: PhonePe - Dropped rupee symbol (line is just "12")
    test('TEST 6: PhonePe with dropped currency symbol (standalone "12") -> Amount = 12.0', () {
      const rawText = '''
Transaction Successful
09:16 pm on 11 Sept 2026
Received from
Divyanshu
+917499752312
12
Banking Name : Divyanshu Nago Thakare
Transfer Details
PhonePe Transaction ID
T2609112116182791351026
Credited to
UPI • XXXXXX5649@sic
12
UTR: 837870957272
''';
      final result = PaymentOcrService.instance.parseExtractedText(rawText);
      expect(result.status, PaymentStatus.successful);
      expect(result.amount, 12.0);
      expect(result.appName, 'PhonePe');
      expect(result.receiverName?.toUpperCase(), contains('DIVYANSHU'));
    });

    // TEST 7: PhonePe - Embedded name + amount "Divyanshu 12"
    test('TEST 7: PhonePe with embedded name and amount "Divyanshu 12" -> Amount = 12.0', () {
      const rawText = '''
Transaction Successful
09:16 pm on 11 Sept 2026
Received from
Divyanshu 12
+917499752312
Banking Name : Divyanshu Nago Thakare
Transfer Details
PhonePe Transaction ID
T2609112116182791351026
Credited to
UPI • XXXXXX5649@sic 12
UTR: 837870957272
''';
      final result = PaymentOcrService.instance.parseExtractedText(rawText);
      expect(result.status, PaymentStatus.successful);
      expect(result.amount, 12.0);
      expect(result.receiverName?.toUpperCase(), contains('DIVYANSHU'));
    });

    // TEST 8: PhonePe - Masked UPI handle (XXXXXX5649@sic) is NEVER extracted as amount 5649
    test('TEST 8: Masked account 5649 in XXXXXX5649@sic is rejected, amount 12 is extracted', () {
      const rawText = '''
Transaction Successful
09:16 pm on 11 Sept 2026
Received from
Divyanshu
+917499752312
₹12
Banking Name : Divyanshu Nago Thakare
Transfer Details
PhonePe Transaction ID
T2609112116182791351026
Credited to
UPI • XXXXXX5649@sic
₹12
UTR: 837870957272
''';
      final result = PaymentOcrService.instance.parseExtractedText(rawText);
      expect(result.amount, 12.0);
      expect(result.amount, isNot(5649.0));
      expect(result.amount, isNot(202.0));
    });

    // TEST 9: Devanagari numerals (₹१२) normalized and extracted accurately as 12.0
    test('TEST 9: Devanagari numerals ₹१२ are normalized to 12.0', () {
      const rawText = '''
Transaction Successful
Received from
Divyanshu
₹१२
Banking Name : Divyanshu Nago Thakare
''';
      final result = PaymentOcrService.instance.parseExtractedText(rawText);
      expect(result.amount, 12.0);
    });

    // TEST 10: Navi UPI - ₹149 to B M MOBILE 1 (should NOT extract 1 from MOBILE 1)
    test('TEST 10: Navi UPI ₹149 -> Amount = 149.0, NOT 1.0 from B M MOBILE 1', () {
      const rawText = '''
Paid securely on
navi UPI
Get up to 1,000 on every payment 1 = 1 paisa
Payment successful
to B M MOBILE 1
WL0502560A0030816@unionbank
₹149
Paid via Navi UPI
8 Oct 2025, 8:00 PM
from Sandeep Dewasi
State Bank of India - 8590
UPI txn ID : 564711273729
''';
      final result = PaymentOcrService.instance.parseExtractedText(rawText);
      expect(result.amount, 149.0);
      expect(result.receiverName, 'B M MOBILE 1');
    });

    // TEST 11: PhonePe - Only occurrence of amount is on the Credited to line with masked account
    test('TEST 11: PhonePe amount 12 extracted when only on Credited to line with masked account', () {
      const rawText = '''
Transaction Successful
09:16 pm on 11 Sept 2026
Received from
Divyanshu
+917499752312
Banking Name : Divyanshu Nago Thakare
Transfer Details
PhonePe Transaction ID
T2609112116182791351026
Credited to
UPI • XXXXXX5649@sic ₹12
UTR: 837870957272
''';
      final result = PaymentOcrService.instance.parseExtractedText(rawText);
      expect(result.amount, 12.0);
      expect(result.receiverName?.toUpperCase(), contains('DIVYANSHU'));
      expect(result.appName, 'PhonePe');
    });

    // TEST 12: PhonePe - Dropped currency symbol across both occurrences (Divyanshu 12 & XXXXXX5649@sic 12)
    test('TEST 12: PhonePe dropped rupee symbols across both lines -> Amount = 12.0', () {
      const rawText = '''
Transaction Successful
09:16 pm on 11 Sept 2026
Received from
Divyanshu 12
+917499752312
Banking Name : Divyanshu Nago Thakare
Transfer Details
PhonePe Transaction ID
T2609112116182791351026
Credited to
UPI • XXXXXX5649@sic 12
UTR: 837870957272
''';
      final result = PaymentOcrService.instance.parseExtractedText(rawText);
      expect(result.amount, 12.0);
      expect(result.receiverName?.toUpperCase(), contains('DIVYANSHU'));
    });
  });

  group('Indian Currency Formats and AmountParser Tests', () {
    test('AmountParser handles Indian comma formatting and diverse notations', () {
      expect(AmountParser.parseAmount('₹1'), 1.0);
      expect(AmountParser.parseAmount('₹10'), 10.0);
      expect(AmountParser.parseAmount('₹100'), 100.0);
      expect(AmountParser.parseAmount('₹200.00'), 200.0);
      expect(AmountParser.parseAmount('₹500'), 500.0);
      expect(AmountParser.parseAmount('₹1,000'), 1000.0);
      expect(AmountParser.parseAmount('₹10,000'), 10000.0);
      expect(AmountParser.parseAmount('₹98,000.00'), 98000.0);
      expect(AmountParser.parseAmount('₹1,00,000'), 100000.0);
      expect(AmountParser.parseAmount('₹1,25,500.50'), 125500.50);
      expect(AmountParser.parseAmount('Rs 500'), 500.0);
      expect(AmountParser.parseAmount('Rs. 500'), 500.0);
      expect(AmountParser.parseAmount('INR 500'), 500.0);
      expect(AmountParser.parseAmount('INR 1,000'), 1000.0);
      expect(AmountParser.parseAmount('500.00'), 500.0);
      expect(AmountParser.parseAmount('1,25,500'), 125500.0);
    });

    test('AmountParser converts accurately to/from integer paise', () {
      expect(AmountParser.toPaise(200.00), 20000);
      expect(AmountParser.toPaise(98000.00), 9800000);
      expect(AmountParser.toPaise(1.0), 100);
      expect(AmountParser.toPaise(125500.50), 12550050);

      expect(AmountParser.fromPaise(20000), 200.0);
      expect(AmountParser.fromPaise(9800000), 98000.0);
      expect(AmountParser.fromPaise(100), 1.0);
    });

    test('AmountParser NEVER silently converts invalid text into 0', () {
      expect(AmountParser.parseAmount(''), isNull);
      expect(AmountParser.parseAmount(null), isNull);
      expect(AmountParser.parseAmount('abc'), isNull);
      expect(AmountParser.parseAmount('₹0'), isNull);
      expect(AmountParser.parseAmount('₹-50'), isNull);
      expect(AmountParser.parseAmount('None'), isNull);
    });
  });

  group('Receiver Matcher & Confidence-Based Friend Matching Tests', () {
    final friends = [
      (name: 'Divyanshu Thakare', uid: 'u1', email: 'dt@example.com', friendCode: 'DT35', upiId: 'divya@okhdfcbank', mobileNumber: '9876543210'),
      (name: 'Divyanshu', uid: 'u2', email: null, friendCode: null, upiId: null, mobileNumber: null),
      (name: 'Rahul Kumar', uid: 'u3', email: 'rahul@example.com', friendCode: 'RK01', upiId: null, mobileNumber: null),
      (name: 'Chandan D Kushwaha', uid: 'u4', email: null, friendCode: 'CK01', upiId: null, mobileNumber: null),
      (name: 'Binay Kushwaha', uid: 'u5', email: null, friendCode: 'BK01', upiId: null, mobileNumber: null),
    ];

    test('High confidence match: First + Last name match (DIVYANSHU NAGO THAKARE -> Divyanshu Thakare)', () {
      final matches = ReceiverMatcher.matchReceiver(
        receiverName: 'DIVYANSHU NAGO THAKARE',
        friends: friends,
        getName: (f) => f.name,
        getUpiId: (f) => f.upiId,
        getFriendCode: (f) => f.friendCode,
      );

      expect(matches.isNotEmpty, isTrue);
      expect(matches.first.friend.name, 'Divyanshu Thakare');
      expect(matches.first.confidence, MatchConfidence.high);
      expect(matches.first.score >= 0.85, isTrue);

      // 'Divyanshu' (single token) has lower score than 'Divyanshu Thakare'
      final divyanshuMatch = matches.firstWhere((m) => m.friend.name == 'Divyanshu');
      expect(divyanshuMatch.confidence, MatchConfidence.medium);
      expect(divyanshuMatch.score < matches.first.score, isTrue);
    });

    test('Exact match for Chandan D Kushwaha and Binay Kushwaha', () {
      final matchChandan = ReceiverMatcher.matchReceiver(
        receiverName: 'CHANDAN D KUSHWAHA',
        friends: friends,
        getName: (f) => f.name,
      );
      expect(matchChandan.first.friend.name, 'Chandan D Kushwaha');
      expect(matchChandan.first.confidence, MatchConfidence.high);

      final matchBinay = ReceiverMatcher.matchReceiver(
        receiverName: 'BINAY KUSHWAHA',
        friends: friends,
        getName: (f) => f.name,
      );
      expect(matchBinay.first.friend.name, 'Binay Kushwaha');
      expect(matchBinay.first.confidence, MatchConfidence.high);
    });

    test('No matching friend found returns empty candidate list without creating any records', () {
      final matches = ReceiverMatcher.matchReceiver(
        receiverName: 'UNKNOWN PERSON ABCD',
        friends: friends,
        getName: (f) => f.name,
      );
      expect(matches.isEmpty, isTrue);
    });
  });

  group('Integer Paise Split Calculation Tests', () {
    test('₹500 / 3 becomes 166.67, 166.67, 166.66 summing exactly to ₹500', () {
      final friends = [
        (name: 'Friend A', uid: 'a'),
        (name: 'Friend B', uid: 'b'),
        (name: 'Friend C', uid: 'c'),
      ];

      final shares = SplitCalculator.calculateEqualSplit(
        totalAmount: 500.0,
        friends: friends,
      );

      expect(shares.length, 3);
      expect(shares[0].amount, 166.67);
      expect(shares[1].amount, 166.67);
      expect(shares[2].amount, 166.66);

      final sumPaise = shares.fold<int>(0, (sum, s) => sum + AmountParser.toPaise(s.amount)!);
      expect(sumPaise, 50000); // 50000 paise = ₹500.00
    });
  });
}
