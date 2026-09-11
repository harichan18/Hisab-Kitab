enum PaymentStatus {
  successful,
  failed,
  unclear,
}

class ExtractedPaymentInfo {
  final double? amount;
  final String currency;
  final PaymentStatus status;
  final String? statusDescription;
  final String? appName;
  final String? receiverName;
  final String? senderName;
  final String? upiId;
  final String? transactionRef;
  final DateTime? date;
  final String? dateString;
  final String rawText;
  final double confidence;

  const ExtractedPaymentInfo({
    this.amount,
    this.currency = '₹',
    this.status = PaymentStatus.unclear,
    this.statusDescription,
    this.appName,
    this.receiverName,
    this.senderName,
    this.upiId,
    this.transactionRef,
    this.date,
    this.dateString,
    this.rawText = '',
    this.confidence = 0.0,
  });

  ExtractedPaymentInfo copyWith({
    double? amount,
    String? currency,
    PaymentStatus? status,
    String? statusDescription,
    String? appName,
    String? receiverName,
    String? senderName,
    String? upiId,
    String? transactionRef,
    DateTime? date,
    String? dateString,
    String? rawText,
    double? confidence,
  }) {
    return ExtractedPaymentInfo(
      amount: amount ?? this.amount,
      currency: currency ?? this.currency,
      status: status ?? this.status,
      statusDescription: statusDescription ?? this.statusDescription,
      appName: appName ?? this.appName,
      receiverName: receiverName ?? this.receiverName,
      senderName: senderName ?? this.senderName,
      upiId: upiId ?? this.upiId,
      transactionRef: transactionRef ?? this.transactionRef,
      date: date ?? this.date,
      dateString: dateString ?? this.dateString,
      rawText: rawText ?? this.rawText,
      confidence: confidence ?? this.confidence,
    );
  }
}
