import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../models/expense_model.dart';
import '../database/database_helper.dart';

class ExpenseService {
  static CollectionReference<Map<String, dynamic>> get _firestoreRef =>
      FirebaseFirestore.instance.collection('expenses');

  static String? get _currentUserId => FirebaseAuth.instance.currentUser?.uid;

  // Create
  static Future<void> createExpense(ExpenseModel expense) async {
    final uid = _currentUserId;
    final docId = _firestoreRef.doc().id;
    final updatedExpense = expense.copyWith(
      id: expense.id ?? docId,
      userId: expense.userId.isNotEmpty ? expense.userId : (uid ?? 'offline_user'),
    );

    // Save locally
    await DatabaseHelper.instance.insertExpense(updatedExpense);

    // Save to Firestore if online
    if (uid != null) {
      await _firestoreRef.doc(updatedExpense.id).set(updatedExpense.toFirestoreMap());
    }
  }

  // Read (Future for one-time fetch)
  static Future<List<ExpenseModel>> getExpensesOnce(String userId) async {
    final uid = _currentUserId;
    if (uid != null) {
      try {
        final snapshot = await _firestoreRef.where('userId', isEqualTo: userId).get();
        final list = snapshot.docs
            .map((doc) => ExpenseModel.fromFirestore(doc.id, doc.data()))
            .toList();
        // Update local cache
        for (final exp in list) {
          await DatabaseHelper.instance.insertExpense(exp);
        }
        list.sort((a, b) => b.expenseDate.compareTo(a.expenseDate));
        return list;
      } catch (e) {
        // Fallback to local
        return await DatabaseHelper.instance.getExpenses(userId);
      }
    } else {
      return await DatabaseHelper.instance.getExpenses(userId);
    }
  }

  // Read (Stream for real-time updates)
  static Stream<List<ExpenseModel>> expensesStream(String userId) {
    final uid = _currentUserId;
    if (uid != null) {
      return _firestoreRef
          .where('userId', isEqualTo: userId)
          .snapshots()
          .map((snapshot) {
        final list = snapshot.docs
            .map((doc) => ExpenseModel.fromFirestore(doc.id, doc.data()))
            .toList();
        // Cache in background
        for (final exp in list) {
          DatabaseHelper.instance.insertExpense(exp);
        }
        list.sort((a, b) => b.expenseDate.compareTo(a.expenseDate));
        return list;
      });
    } else {
      // Offline mode: Emit once from SQLite
      return Stream.fromFuture(DatabaseHelper.instance.getExpenses(userId));
    }
  }

  // Update
  static Future<void> updateExpense(ExpenseModel expense) async {
    final uid = _currentUserId;
    
    // Update locally
    await DatabaseHelper.instance.updateExpense(expense);

    // Update in Firestore if online and expense has Firestore ID
    if (uid != null && expense.id != null) {
      await _firestoreRef.doc(expense.id).update(expense.toFirestoreMap());
    }
  }

  // Delete
  static Future<void> deleteExpense(String expenseId) async {
    final uid = _currentUserId;

    // Delete locally
    await DatabaseHelper.instance.deleteExpense(expenseId);

    // Delete in Firestore if online
    if (uid != null) {
      await _firestoreRef.doc(expenseId).delete();
    }
  }
}
