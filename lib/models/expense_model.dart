import 'package:cloud_firestore/cloud_firestore.dart';

class ExpenseModel {
  final String? id;
  final String userId;
  final double amount;
  final String category;
  final String description;
  final DateTime expenseDate;
  final String? receiptUrl;
  final DateTime createdAt;

  ExpenseModel({
    this.id,
    required this.userId,
    required this.amount,
    required this.category,
    required this.description,
    required this.expenseDate,
    this.receiptUrl,
    required this.createdAt,
  });

  Map<String, dynamic> toFirestoreMap() {
    return {
      'userId': userId,
      'amount': amount,
      'category': category,
      'description': description,
      'expenseDate': Timestamp.fromDate(expenseDate),
      if (receiptUrl != null) 'receiptUrl': receiptUrl,
      'createdAt': Timestamp.fromDate(createdAt),
    };
  }

  factory ExpenseModel.fromFirestore(String id, Map<String, dynamic> map) {
    DateTime parseDate(dynamic val) {
      if (val is Timestamp) {
        return val.toDate();
      } else if (val is String) {
        return DateTime.tryParse(val) ?? DateTime.now();
      } else {
        return DateTime.now();
      }
    }

    return ExpenseModel(
      id: id,
      userId: map['userId'] as String? ?? '',
      amount: (map['amount'] as num?)?.toDouble() ?? 0.0,
      category: map['category'] as String? ?? 'Other',
      description: map['description'] as String? ?? '',
      expenseDate: parseDate(map['expenseDate']),
      receiptUrl: map['receiptUrl'] as String?,
      createdAt: parseDate(map['createdAt']),
    );
  }

  ExpenseModel copyWith({
    String? id,
    String? userId,
    double? amount,
    String? category,
    String? description,
    DateTime? expenseDate,
    String? receiptUrl,
    DateTime? createdAt,
  }) {
    return ExpenseModel(
      id: id ?? this.id,
      userId: userId ?? this.userId,
      amount: amount ?? this.amount,
      category: category ?? this.category,
      description: description ?? this.description,
      expenseDate: expenseDate ?? this.expenseDate,
      receiptUrl: receiptUrl ?? this.receiptUrl,
      createdAt: createdAt ?? this.createdAt,
    );
  }
}
