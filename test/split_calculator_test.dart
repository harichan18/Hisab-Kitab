import 'package:flutter_test/flutter_test.dart';
import 'package:hisab_kitab/services/split_calculator.dart';

void main() {
  group('SplitCalculator Equal Split Tests', () {
    test('₹500 split equally among 3 friends', () {
      final friends = [
        (name: 'Rahul', uid: 'u1'),
        (name: 'Aman', uid: 'u2'),
        (name: 'Priya', uid: 'u3'),
      ];

      final shares = SplitCalculator.calculateEqualSplit(
        totalAmount: 500.0,
        friends: friends,
      );

      expect(shares.length, 3);
      expect(shares[0].amount, 166.67);
      expect(shares[1].amount, 166.67);
      expect(shares[2].amount, 166.66);

      final total = shares.fold<double>(0.0, (sum, s) => sum + s.amount);
      expect(double.parse(total.toStringAsFixed(2)), 500.0);
    });

    test('₹100 split equally among 3 friends', () {
      final friends = [
        (name: 'Rahul', uid: 'u1'),
        (name: 'Aman', uid: 'u2'),
        (name: 'Priya', uid: 'u3'),
      ];

      final shares = SplitCalculator.calculateEqualSplit(
        totalAmount: 100.0,
        friends: friends,
      );

      expect(shares.length, 3);
      expect(shares[0].amount, 33.34);
      expect(shares[1].amount, 33.33);
      expect(shares[2].amount, 33.33);

      final total = shares.fold<double>(0.0, (sum, s) => sum + s.amount);
      expect(double.parse(total.toStringAsFixed(2)), 100.0);
    });

    test('₹1000 split equally between 2 friends', () {
      final friends = [
        (name: 'Rahul', uid: 'u1'),
        (name: 'Aman', uid: 'u2'),
      ];

      final shares = SplitCalculator.calculateEqualSplit(
        totalAmount: 1000.0,
        friends: friends,
      );

      expect(shares.length, 2);
      expect(shares[0].amount, 500.0);
      expect(shares[1].amount, 500.0);

      final total = shares.fold<double>(0.0, (sum, s) => sum + s.amount);
      expect(total, 1000.0);
    });

    test('Single friend ₹250', () {
      final friends = [(name: 'Rahul', uid: 'u1')];

      final shares = SplitCalculator.calculateEqualSplit(
        totalAmount: 250.0,
        friends: friends,
      );

      expect(shares.length, 1);
      expect(shares[0].amount, 250.0);
    });
  });

  group('SplitCalculator Custom and Percentage Split Tests', () {
    test('Validate custom split amounts', () {
      expect(
        SplitCalculator.validateCustomSplit(
          totalAmount: 500.0,
          customAmounts: [200.0, 150.0, 150.0],
        ),
        isNull,
      );

      expect(
        SplitCalculator.validateCustomSplit(
          totalAmount: 500.0,
          customAmounts: [200.0, 100.0, 150.0],
        ),
        isNotNull,
      );
    });

    test('Percentage split 40%, 30%, 30% for ₹500', () {
      final friends = [
        (name: 'Rahul', uid: 'u1', percentage: 40.0),
        (name: 'Aman', uid: 'u2', percentage: 30.0),
        (name: 'Priya', uid: 'u3', percentage: 30.0),
      ];

      final shares = SplitCalculator.calculatePercentageSplit(
        totalAmount: 500.0,
        friends: friends,
      );

      expect(shares[0].amount, 200.0);
      expect(shares[1].amount, 150.0);
      expect(shares[2].amount, 150.0);

      final total = shares.fold<double>(0.0, (sum, s) => sum + s.amount);
      expect(total, 500.0);
    });
  });
}
