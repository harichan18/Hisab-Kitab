# Hisab Kitab

### A simple personal money and transaction tracker built with Flutter

**Hisab Kitab** is a personal finance management application designed to make it easy to track money given to friends, money received from friends, daily expenses, and personal balances in one place.

The goal is simple:

> **Know where your money is going, who owes you, and how much you actually have.**

---

## Overview

Managing small transactions between friends can quickly become confusing.

You might give ₹500 to a friend, receive ₹200 back, spend ₹150 on food, and later forget exactly how much is still pending.

Hisab Kitab solves this by keeping a structured record of transactions and providing a clear overview of your financial activity.

---

## Features

### Friend-wise Money Tracking

Keep a separate transaction history for every friend.

Track:

* Money you gave
* Money you received
* Transaction notes
* Transaction date
* Current balance with each friend

### Give and Receive Transactions

Quickly record transactions using simple actions.

```text
        Friend
          |
     +----+----+
     |         |
   Give     Receive
     |         |
     +----+----+
          |
     Transaction
          |
       History
```

### Bank Balance

Keep track of your current bank balance directly inside the application.

The dashboard provides a quick overview of:

* Current bank balance
* Money given
* Money received
* Overall financial position

### Daily Expense Tracking

Record everyday expenses and understand where your money is being spent.

Examples:

* Food
* Travel
* Shopping
* Snacks
* College expenses
* Other expenses

### Transaction History

Every transaction is stored with useful information such as:

```text
Date
Amount
Type
Friend
Note
```

This makes it easy to review previous transactions.

### Friend Profiles

Each friend can have their own profile containing:

* Name
* Profile picture
* UPI ID
* Transaction history
* Current balance

### UPI Screenshot Attachment

Attach a UPI payment screenshot to a transaction for easier reference and verification.

### Financial Summary

Get a quick overview of your finances without manually calculating everything.

```text
Total Given
Total Received
Total Expenses
Bank Balance
Net Balance
```

### PDF Export

Export transaction information into a PDF for:

* Personal records
* Sharing
* Reviewing transactions
* Maintaining financial history

### App Security

The application is designed with privacy and security in mind, with support for features such as:

* Fingerprint authentication
* App lock
* Secure local storage

### Cloud Backup

Cloud backup allows important financial records to be restored across devices.

The project is designed to support synchronization between local storage and cloud services.

---

## Tech Stack

| Technology                | Purpose                                |
| ------------------------- | -------------------------------------- |
| Flutter                   | Cross-platform application development |
| Dart                      | Application programming language       |
| SQLite                    | Local transaction database             |
| sqflite                   | SQLite integration with Flutter        |
| Firebase / Cloud Services | Cloud backup and synchronization       |
| PDF Generation            | Transaction report export              |
| Local Authentication      | Fingerprint / biometric security       |

---

## Application Architecture

```text
                 HISAB KITAB
                      |
        +-------------+-------------+
        |             |             |
        v             v             v
     Friends       Expenses      Balance
        |             |             |
        +-------------+-------------+
                      |
                      v
              Transaction Layer
                      |
          +-----------+-----------+
          |                       |
          v                       v
     Local SQLite           Cloud Backup
          |                       |
          +-----------+-----------+
                      |
                      v
                Reports / PDF
```

---

## Project Structure

```text
hisab_kitab/
|
+-- android/
+-- ios/
+-- web/
+-- windows/
+-- linux/
+-- macos/
|
+-- lib/
|   |
|   +-- main.dart
|   |
|   +-- screens/
|   |   +-- home_screen.dart
|   |   +-- friend_screen.dart
|   |   +-- transaction_screen.dart
|   |   +-- settings_screen.dart
|   |
|   +-- models/
|   |   +-- friend.dart
|   |   +-- transaction.dart
|   |
|   +-- database/
|   |   +-- database_helper.dart
|   |
|   +-- services/
|   |   +-- pdf_service.dart
|   |   +-- backup_service.dart
|   |
|   +-- widgets/
|
+-- assets/
|   +-- images/
|   +-- icons/
|
+-- test/
|
+-- pubspec.yaml
+-- README.md
+-- .gitignore
```

> The exact folder structure may differ depending on the current implementation.

---

## Getting Started

### Prerequisites

Make sure you have the following installed:

* Flutter SDK
* Dart SDK
* Android Studio or VS Code
* Android Emulator or physical Android device
* Git

Check your Flutter installation:

```bash
flutter doctor
```

### Installation

Clone the repository:

```bash
git clone https://github.com/harichan18/Hisab-Kitab.git
```

Navigate into the project:

```bash
cd hisab_kitab
```

Install dependencies:

```bash
flutter pub get
```

Run the application:

```bash
flutter run
```

For Chrome:

```bash
flutter run -d chrome
```

For an Android device:

```bash
flutter devices
flutter run
```

---

## Local Database

Hisab Kitab uses SQLite for storing transaction information locally.

A transaction can contain information such as:

```text
Transaction
|
+-- ID
+-- Friend ID
+-- Amount
+-- Type
+-- Note
+-- Date
+-- Attachment
```

This allows the application to work with locally stored financial data without requiring a constant internet connection for basic functionality.

---

## Transaction Logic

The application distinguishes between money given and money received.

For example:

```text
You give Rahul ₹500

Rahul
Balance: +₹500
```

If Rahul returns ₹200:

```text
Rahul
Given:      ₹500
Received:   ₹200
Pending:    ₹300
```

This makes the outstanding amount easy to understand.

---

## UI Design Philosophy

Hisab Kitab focuses on a simple, clean, and practical interface.

The main design goals are:

* Minimal number of steps
* Clear financial information
* Easy transaction entry
* Friend-wise organization
* Mobile-first interface
* Easy-to-read balances
* Consistent visual hierarchy

---

## Future Improvements

* [ ] Advanced monthly analytics
* [ ] Expense categories
* [ ] Spending charts
* [ ] Monthly financial reports
* [ ] Automatic cloud synchronization
* [ ] Multi-device synchronization
* [ ] UPI deep links
* [ ] Payment reminders
* [ ] Recurring transactions
* [ ] CSV export
* [ ] Improved biometric security
* [ ] Dark and light themes
* [ ] Search and filter transactions
* [ ] Monthly spending limits
* [ ] Financial insights

---

## Project Goals

Hisab Kitab is being developed to provide a lightweight alternative to complicated expense-management applications.

The primary goals are:

**Simple. Fast. Private. Useful.**

Instead of trying to become a full-scale banking application, Hisab Kitab focuses on solving a common everyday problem:

> **Keeping track of small personal transactions without the headache of maintaining them manually.**

---

## Developer

### Harichan Kushwaha

B.Tech IT Student
Vishwakarma Institute of Technology, Pune

This project is developed as an individual project to explore:

* Flutter application development
* Local database management
* Cloud synchronization
* UI/UX design
* Personal finance management

---

## License

This project is currently intended for educational and personal use.

If you want to reuse or modify the project, please refer to the repository's license.

---

<p align="center">

## Hisab Kitab

**Track your money. Remember every transaction.**

Built with Flutter

</p>
