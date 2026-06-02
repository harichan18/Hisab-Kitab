// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:photo_view/photo_view.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'database/database_helper.dart';
import 'firebase_options.dart';
import 'models/transaction_model.dart';

const String _googleServerClientId =
    '614565157950-q0vb676dva84bp5eg102ca1spv6nh0os.apps.googleusercontent.com';

void _receiptLog(String scope, String message) {}

Future<XFile?> _pickReceiptImage({
  required ImageSource source,
  required String scope,
}) async {
  _receiptLog(scope, 'Opening image picker. source=$source');
  try {
    final result = await ImagePicker().pickImage(
      source: source,
      imageQuality: 80,
    );
    if (result == null) {
      _receiptLog(scope, 'Image picker returned null.');
      return null;
    }

    _receiptLog(scope, 'Image selected: path=${result.path}');
    return result;
  } catch (e, st) {
    _receiptLog(scope, 'Image picker failed: $e\n$st');
    rethrow;
  }
}

Future<XFile?> _compressReceiptImage(File file, {required String scope}) async {
  _receiptLog(scope, 'Compressing image: path=${file.path}');
  try {
    final tempDir = await getTemporaryDirectory();
    final targetPath =
        '${tempDir.path}/${DateTime.now().millisecondsSinceEpoch}.jpg';
    final compressed = await FlutterImageCompress.compressAndGetFile(
      file.path,
      targetPath,
      quality: 75,
    );
    _receiptLog(
      scope,
      compressed == null
          ? 'Compression returned null.'
          : 'Compression complete: path=${compressed.path}',
    );
    return compressed;
  } catch (e, st) {
    _receiptLog(scope, 'Compression failed: $e\n$st');
    rethrow;
  }
}

Future<String?> _saveReceiptLocally({
  required File sourceFile,
  required String firebaseId,
  required String scope,
}) async {
  _receiptLog(scope, 'Saving receipt locally for firebaseId=$firebaseId');
  try {
    final directory = await getApplicationSupportDirectory();
    final receiptsDir = Directory(p.join(directory.path, 'receipts'));
    if (!await receiptsDir.exists()) {
      await receiptsDir.create(recursive: true);
    }

    final destinationPath = p.join(receiptsDir.path, '$firebaseId.jpg');
    await sourceFile.copy(destinationPath);
    _receiptLog(scope, 'Receipt saved locally at $destinationPath');
    return destinationPath;
  } catch (e, st) {
    _receiptLog(scope, 'Local receipt save failed: $e\n$st');
    return null;
  }
}

Future<void> _deleteLocalReceipt(String? receiptPath, {required String scope}) async {
  if (receiptPath == null || receiptPath.isEmpty) {
    return;
  }

  try {
    final file = File(receiptPath);
    if (await file.exists()) {
      await file.delete();
      _receiptLog(scope, 'Deleted local receipt file: $receiptPath');
    }
  } catch (e, st) {
    _receiptLog(scope, 'Local receipt delete failed: $e\n$st');
  }
}

String _currentUserDisplayName() {
  final user = FirebaseAuth.instance.currentUser;
  final displayName = user?.displayName?.trim() ?? '';
  if (displayName.isNotEmpty) {
    return displayName;
  }

  final email = user?.email?.trim() ?? '';
  if (email.isNotEmpty) {
    return email;
  }

  return user?.uid ?? '';
}

TransactionModel _normalizeTransactionPerspective(TransactionModel transaction) {
  return transaction;
}

String _transactionDisplayFriendName(TransactionModel transaction) {
  final currentUser = FirebaseAuth.instance.currentUser;
  if (currentUser == null) {
    return transaction.friendName;
  }

  final currentDisplayName = _currentUserDisplayName();
  if (currentDisplayName.isEmpty) {
    return transaction.friendName;
  }

  if (transaction.peerUserId == currentUser.uid &&
      transaction.friendName.trim().toLowerCase() !=
          currentDisplayName.trim().toLowerCase()) {
    return currentDisplayName;
  }

  return transaction.friendName;
}

bool _transactionDisplayIsGiven(TransactionModel transaction) {
  final currentUser = FirebaseAuth.instance.currentUser;
  if (currentUser == null) {
    return transaction.iGave;
  }

  final currentDisplayName = _currentUserDisplayName();
  if (currentDisplayName.isEmpty) {
    return transaction.iGave;
  }

  if (transaction.peerUserId == currentUser.uid &&
      transaction.friendName.trim().toLowerCase() !=
          currentDisplayName.trim().toLowerCase()) {
    return !transaction.iGave;
  }

  return transaction.iGave;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(),
      home: const AuthGate(),
    );
  }
}

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  Future<bool> _hasValidFirebaseSession(User user) async {
    try {
      await user.reload();
      return FirebaseAuth.instance.currentUser != null;
    } on FirebaseAuthException catch (e) {
      final invalidSessionCodes = {
        'user-not-found',
        'user-disabled',
        'invalid-user-token',
        'user-token-expired',
      };

      if (invalidSessionCodes.contains(e.code)) {
        FirebaseDataService.clearCachedSessionData();
        await GoogleSignIn().signOut();
        await FirebaseAuth.instance.signOut();
        return false;
      }

      rethrow;
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        if (snapshot.hasData) {
          return FutureBuilder<bool>(
            future: _hasValidFirebaseSession(snapshot.data!),
            builder: (context, sessionSnapshot) {
              if (sessionSnapshot.connectionState == ConnectionState.waiting) {
                return const Scaffold(
                  body: Center(child: CircularProgressIndicator()),
                );
              }

              if (sessionSnapshot.hasError) {
                return Scaffold(
                  body: Center(
                    child: Text(
                      "Unable to verify your session. Please try again.",
                      textAlign: TextAlign.center,
                    ),
                  ),
                );
              }

              if (sessionSnapshot.data == true) {
                return const SplashScreen();
              }

              return const LoginPage();
            },
          );
        }

        return const LoginPage();
      },
    );
  }
}

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  bool isLoading = false;

  Future<T> _runSignInStep<T>(String label, Future<T> Function() action) async {
    debugPrint('[GoogleSignIn] START $label');
    try {
      final result = await action();
      debugPrint('[GoogleSignIn] END $label');
      return result;
    } catch (error, stackTrace) {
      debugPrint('[GoogleSignIn] STOP $label: ${_debugAuthError(error)}');
      debugPrintStack(
        label: '[GoogleSignIn] STACK $label',
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  Future<void> signInWithGoogle() async {
    debugPrint('[GoogleSignIn] Button pressed');
    setState(() {
      isLoading = true;
    });

    try {
      debugPrint('[GoogleSignIn] serverClientId=$_googleServerClientId');
      final GoogleSignIn googleSignIn = GoogleSignIn(
        serverClientId: _googleServerClientId,
      );
      final googleUser = await _runSignInStep<GoogleSignInAccount?>(
        'GoogleSignIn.signIn()',
        googleSignIn.signIn,
      );

      if (googleUser == null) {
        debugPrint('[GoogleSignIn] User cancelled sign-in');
        return;
      }

      _debugGoogleAccount(googleUser);
      await _signInToFirebaseWithGoogle(googleUser);
      debugPrint('[GoogleSignIn] Completed successfully');
    } catch (error, stackTrace) {
      debugPrint('[GoogleSignIn] Handler caught: ${_debugAuthError(error)}');
      debugPrintStack(
        label: '[GoogleSignIn] Handler stack',
        stackTrace: stackTrace,
      );
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(_friendlyAuthError(error))));
      }
    } finally {
      debugPrint('[GoogleSignIn] Handler finally');
      if (mounted) {
        setState(() {
          isLoading = false;
        });
      }
    }
  }

  Future<void> _signInToFirebaseWithGoogle(
    GoogleSignInAccount googleUser,
  ) async {
    debugPrint('[GoogleSignIn] START GoogleSignInAccount.authentication');
    final googleAuth = await googleUser.authentication;
    debugPrint(
      '[GoogleSignIn] END GoogleSignInAccount.authentication '
      'idToken=${googleAuth.idToken == null ? 'missing' : 'present'} '
      'accessToken=${googleAuth.accessToken == null ? 'missing' : 'present'}',
    );
    _debugGoogleAuthentication(googleAuth);

    if (googleAuth.idToken == null) {
      throw FirebaseAuthException(
        code: 'missing-google-id-token',
        message: 'Google did not return an ID token.',
      );
    }

    final credential = GoogleAuthProvider.credential(
      idToken: googleAuth.idToken,
    );
    final userCredential = await _runSignInStep<UserCredential>(
      'FirebaseAuth.signInWithCredential()',
      () => FirebaseAuth.instance.signInWithCredential(credential),
    );
    final user = userCredential.user;

    if (user == null) {
      throw FirebaseAuthException(
        code: 'missing-firebase-user',
        message: 'Firebase did not return a signed-in user.',
      );
    }

    final friendCode = await _runSignInStep<String>(
      'Firestore users/${user.uid} friendCode',
      () => _getOrCreateFriendCode(user.uid),
    );

    await _runSignInStep<void>(
      'Firestore users/${user.uid} upsert',
      () async {
        final userDocRef = FirebaseFirestore.instance.collection('users').doc(user.uid);
        final existingDoc = await userDocRef.get();
        final existingPhotoUrl = existingDoc.data()?['photoUrl'] as String?;
        final existingUpiId = existingDoc.data()?['upiId'] as String?;
        final photoUrl = (existingPhotoUrl != null && existingPhotoUrl.isNotEmpty)
            ? existingPhotoUrl
            : (user.photoURL ?? googleUser.photoUrl);
        await userDocRef.set({
          'uid': user.uid,
          'name': user.displayName ?? googleUser.displayName ?? '',
          'email': user.email ?? googleUser.email,
          'photoUrl': photoUrl,
          'friendCode': friendCode,
          'upiId': existingUpiId ?? '',
          'provider': 'google',
          'updatedAt': FieldValue.serverTimestamp(),
          'createdAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      },
    );
  }

  void _debugGoogleAccount(GoogleSignInAccount googleUser) {
    debugPrint(
      '[GoogleSignIn] Account response: '
      'id=${googleUser.id}, '
      'email=${googleUser.email}, '
      'displayName=${googleUser.displayName}, '
      'photoUrl=${googleUser.photoUrl}',
    );
  }

  void _debugGoogleAuthentication(GoogleSignInAuthentication googleAuth) {
    debugPrint(
      '[GoogleSignIn] Authentication response: '
      'idToken=${googleAuth.idToken}, '
      'accessToken=${googleAuth.accessToken}',
    );
  }

  Future<String> _getOrCreateFriendCode(String uid) async {
    final userRef = FirebaseFirestore.instance.collection('users').doc(uid);
    final snapshot = await userRef.get();
    final existingCode = snapshot.data()?['friendCode'];

    if (existingCode is String && existingCode.isNotEmpty) {
      return existingCode;
    }

    return _generateUniqueFriendCode();
  }

  Future<String> _generateUniqueFriendCode() async {
    final random = Random.secure();

    for (var attempt = 0; attempt < 20; attempt++) {
      final digits = random.nextInt(1000000).toString().padLeft(6, '0');
      final code = 'HK$digits';
      final existing = await FirebaseFirestore.instance
          .collection('users')
          .where('friendCode', isEqualTo: code)
          .limit(1)
          .get();

      if (existing.docs.isEmpty) {
        return code;
      }
    }

    throw FirebaseAuthException(
      code: 'friend-code-generation-failed',
      message: 'Could not generate a unique friend code. Please try again.',
    );
  }

  String _debugAuthError(Object error) {
    return '${error.runtimeType}: $error';
  }

  String _friendlyAuthError(Object error) {
    final message = error.toString();
    if (message.contains('serverClientId') ||
        message.contains('clientConfigurationError')) {
      return 'Google Sign-In needs a web OAuth client in google-services.json.';
    }
    if (message.contains('canceled')) {
      return 'Google Sign-In was cancelled.';
    }
    if (error is FirebaseAuthException && error.message != null) {
      return error.message!;
    }
    return 'Google Sign-In failed. Please try again.';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(24),
                  child: Image.asset(
                    'assets/images/logo.png',
                    width: 120,
                    height: 120,
                    fit: BoxFit.cover,
                  ),
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                'Hisab Kitab',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              const Text(
                'Sign in to keep your account connected.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey),
              ),
              const SizedBox(height: 36),
              SizedBox(
                height: 54,
                child: ElevatedButton.icon(
                  onPressed: isLoading ? null : signInWithGoogle,
                  icon: isLoading
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.login),
                  label: const Text('Continue with Google'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: Colors.black,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _fadeAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeIn));
    _controller.forward();

    _navigateToHome();
  }

  Future<void> _navigateToHome() async {
    await Future.delayed(const Duration(milliseconds: 2000));
    if (mounted) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const HomePage()),
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: FadeTransition(
          opacity: _fadeAnimation,
          child: Stack(
            children: [
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(24),
                      child: Image.asset(
                        'assets/images/logo.png',
                        width: 140,
                        height: 140,
                        fit: BoxFit.cover,
                      ),
                    ),
                    const SizedBox(height: 24),
                    const Text(
                      "Hisab Kitab",
                      style: TextStyle(
                        fontSize: 32,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
              Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 24),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: const [
                      Text(
                        "made by ",
                        style: TextStyle(fontSize: 16, color: Colors.grey),
                      ),
                      Text(
                        "Harichan Kushwaha",
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                      Text(" \u2764", style: TextStyle(fontSize: 18)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  bool _isUploading = false;
  Future<DocumentSnapshot<Map<String, dynamic>>>? _profileFuture;
  bool _isSavingUpi = false;
  final TextEditingController _upiController = TextEditingController();
  bool _upiInitialized = false;

  @override
  void dispose() {
    _upiController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _profileFuture = _loadProfile();
  }

  Future<DocumentSnapshot<Map<String, dynamic>>> _loadProfile() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw FirebaseAuthException(
        code: 'no-current-user',
        message: 'No user is currently signed in.',
      );
    }

    debugPrint('[Profile] current uid: ${user.uid}');

    final userDoc = FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid);
    final snapshot = await userDoc.get();

    debugPrint('[Profile] document exists: ${snapshot.exists}');

    if (snapshot.exists) {
      return snapshot;
    }

    final friendCode = await _generateUniqueFriendCode();
    await userDoc.set({
      'uid': user.uid,
      'email': user.email ?? '',
      'name': user.displayName ?? '',
      'friendCode': friendCode,
      'upiId': '',
      'createdAt': FieldValue.serverTimestamp(),
    });

    return userDoc.get();
  }

  Future<String> _generateUniqueFriendCode() async {
    final random = Random.secure();

    for (var attempt = 0; attempt < 20; attempt++) {
      final digits = random.nextInt(1000000).toString().padLeft(6, '0');
      final code = 'HK$digits';
      final existing = await FirebaseFirestore.instance
          .collection('users')
          .where('friendCode', isEqualTo: code)
          .limit(1)
          .get();

      if (existing.docs.isEmpty) {
        return code;
      }
    }

    throw FirebaseAuthException(
      code: 'friend-code-generation-failed',
      message: 'Could not generate a unique friend code. Please try again.',
    );
  }

  Future<void> _logout(BuildContext context) async {
    FirebaseDataService.clearCachedSessionData();
    await GoogleSignIn().signOut();
    await FirebaseAuth.instance.signOut();

    if (context.mounted) {
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (_) => const AuthGate()),
        (route) => false,
      );
    }
  }

  Future<void> _pickAndUploadProfilePhoto() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    // 1. Pick image from gallery
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      imageQuality: 80,
    );
    if (picked == null || !mounted) return;

    setState(() => _isUploading = true);

    try {
      // 2. Compress the image
      final tempDir = await getTemporaryDirectory();
      final targetPath =
          '${tempDir.path}/profile_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final compressed = await FlutterImageCompress.compressAndGetFile(
        picked.path,
        targetPath,
        quality: 75,
      );
      final fileToUpload = compressed != null ? File(compressed.path) : File(picked.path);

      // 3. Upload to Cloudinary
      final uri = Uri.parse(
        'https://api.cloudinary.com/v1_1/dxwf10vjg/image/upload',
      );
      final request = http.MultipartRequest('POST', uri)
        ..fields['upload_preset'] = 'receipt_upload'
        ..files.add(await http.MultipartFile.fromPath('file', fileToUpload.path));

      final streamedResponse = await request.send();
      final responseBody = await streamedResponse.stream.bytesToString();

      if (streamedResponse.statusCode != 200) {
        throw Exception('Cloudinary upload failed: ${streamedResponse.statusCode}');
      }

      final jsonResponse = jsonDecode(responseBody) as Map<String, dynamic>;
      final secureUrl = jsonResponse['secure_url'] as String?;

      if (secureUrl == null || secureUrl.isEmpty) {
        throw Exception('Cloudinary response missing secure_url');
      }

      // 4. Update Firestore
      await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .update({'photoUrl': secureUrl});

      // 5. Refresh profile UI
      if (mounted) {
        setState(() {
          _isUploading = false;
          _profileFuture = _loadProfile();
        });
      }
    } catch (e) {
      debugPrint('[Profile] Photo upload failed: $e');
      if (mounted) {
        setState(() => _isUploading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to update profile photo.')),
        );
      }
    }
  }

  Future<void> _saveUpi() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    setState(() {
      _isSavingUpi = true;
    });

    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .update({'upiId': _upiController.text.trim()});

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('UPI ID updated successfully.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to update UPI ID: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSavingUpi = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Profile"), centerTitle: true),
      body: FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        future: _profileFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          if (snapshot.hasError) {
            return const Center(child: Text("Unable to load profile."));
          }

          final data = snapshot.data?.data() ?? {};
          if (!_upiInitialized) {
            _upiController.text = data['upiId'] as String? ?? '';
            _upiInitialized = true;
          }
          final name = data['name'] as String? ?? '';
          final email = data['email'] as String? ?? '';
          final photoUrl = data['photoUrl'] as String?;
          final friendCode = data['friendCode'] as String? ?? '';

          return SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 24),
                  Center(
                    child: GestureDetector(
                      onTap: _isUploading ? null : _pickAndUploadProfilePhoto,
                      child: Stack(
                        children: [
                          CircleAvatar(
                            radius: 56,
                            backgroundImage: photoUrl == null || photoUrl.isEmpty
                                ? null
                                : NetworkImage(photoUrl),
                            child: photoUrl == null || photoUrl.isEmpty
                                ? const Icon(Icons.person, size: 56)
                                : null,
                          ),
                          Positioned(
                            bottom: 0,
                            right: 0,
                            child: Container(
                              padding: const EdgeInsets.all(6),
                              decoration: BoxDecoration(
                                color: Theme.of(context).colorScheme.primary,
                                shape: BoxShape.circle,
                              ),
                              child: _isUploading
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white,
                                      ),
                                    )
                                  : const Icon(
                                      Icons.camera_alt,
                                      size: 18,
                                      color: Colors.white,
                                    ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Center(
                    child: Text(
                      name,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Center(
                    child: Text(
                      email,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.grey),
                    ),
                  ),
                  const SizedBox(height: 32),
                  const Text(
                    "Friend Code",
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    friendCode,
                    style: const TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.5,
                    ),
                  ),
                  const SizedBox(height: 32),
                  const Text(
                    "UPI ID",
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: _upiController,
                          decoration: const InputDecoration(
                            hintText: "Enter UPI ID (e.g., name@okbank)",
                            border: OutlineInputBorder(),
                            contentPadding: EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 12,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton(
                        onPressed: _isSavingUpi ? null : _saveUpi,
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 16,
                          ),
                          backgroundColor: Colors.amber,
                          foregroundColor: Colors.black,
                        ),
                        child: _isSavingUpi
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.black,
                                ),
                              )
                            : const Text("Save"),
                      ),
                    ],
                  ),
                  const SizedBox(height: 48),
                  SizedBox(
                    height: 52,
                    child: ElevatedButton.icon(
                      onPressed: () => _logout(context),
                      icon: const Icon(Icons.logout),
                      label: const Text("Logout"),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red,
                        foregroundColor: Colors.white,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class AddFriendPage extends StatefulWidget {
  const AddFriendPage({super.key});

  @override
  State<AddFriendPage> createState() => _AddFriendPageState();
}

class _AddFriendPageState extends State<AddFriendPage> {
  final friendCodeController = TextEditingController();
  DocumentSnapshot<Map<String, dynamic>>? foundUser;
  bool isSearching = false;
  bool isAdding = false;

  FirebaseFirestore get _firestore => FirebaseFirestore.instance;

  String _friendDocumentId(String uid1, String uid2) {
    final ids = [uid1, uid2]..sort();
    return '${ids[0]}_${ids[1]}';
  }

  Future<void> searchFriend() async {
    final code = friendCodeController.text.trim();
    if (code.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Please enter a friend code.")),
      );
      return;
    }

    setState(() {
      isSearching = true;
      foundUser = null;
    });

    try {
      final result = await _firestore
          .collection('users')
          .where('friendCode', isEqualTo: code)
          .limit(1)
          .get();

      if (!mounted) {
        return;
      }

      setState(() {
        foundUser = result.docs.isEmpty ? null : result.docs.first;
      });

      if (result.docs.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("No user found for this friend code.")),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text("Unable to search friend: $e")));
      }
    } finally {
      if (mounted) {
        setState(() {
          isSearching = false;
        });
      }
    }
  }

  Future<bool> _friendshipExists(
    String currentUserUid,
    String friendUid,
  ) async {
    final currentUserFriends = await _firestore
        .collection('friends')
        .where('user1', isEqualTo: currentUserUid)
        .get();
    final currentUserAsSecond = await _firestore
        .collection('friends')
        .where('user2', isEqualTo: currentUserUid)
        .get();

    final firstDirection = currentUserFriends.docs.any(
      (doc) => doc.data()['user2'] == friendUid,
    );
    final secondDirection = currentUserAsSecond.docs.any(
      (doc) => doc.data()['user1'] == friendUid,
    );

    return firstDirection || secondDirection;
  }

  Future<void> addFriend() async {
    final currentUser = FirebaseAuth.instance.currentUser;
    final friend = foundUser;

    if (currentUser == null || friend == null) {
      return;
    }

    final friendUid = friend.id;
    if (friendUid == currentUser.uid) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("You cannot add yourself as a friend.")),
      );
      return;
    }

    setState(() {
      isAdding = true;
    });

    try {
      final exists = await _friendshipExists(currentUser.uid, friendUid);
      if (exists) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("This friend is already added.")),
          );
        }
        return;
      }

      final friendRef = _firestore
          .collection('friends')
          .doc(_friendDocumentId(currentUser.uid, friendUid));

      await _firestore.runTransaction((transaction) async {
        final snapshot = await transaction.get(friendRef);
        if (snapshot.exists) {
          throw StateError('duplicate-friend');
        }

        transaction.set(friendRef, {
          'user1': currentUser.uid,
          'user2': friendUid,
          'createdAt': FieldValue.serverTimestamp(),
        });
      });

      final friendData = friend.data() ?? {};
      await FirebaseDataService.saveFriendProfile(
        FirestoreFriendProfile(
          uid: friendUid,
          name: friendData['name'] as String? ?? '',
          email: friendData['email'] as String? ?? '',
          friendCode: friendData['friendCode'] as String? ?? '',
        ),
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Friend added successfully.")),
        );
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (mounted) {
        final message = e is StateError && e.message == 'duplicate-friend'
            ? "This friend is already added."
            : "Unable to add friend: $e";
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));
      }
    } finally {
      if (mounted) {
        setState(() {
          isAdding = false;
        });
      }
    }
  }

  @override
  void dispose() {
    friendCodeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final data = foundUser?.data();
    final name = data?['name'] as String? ?? '';
    final email = data?['email'] as String? ?? '';
    final friendCode = data?['friendCode'] as String? ?? '';
    final photoUrl = data?['photoUrl'] as String?;

    return Scaffold(
      appBar: AppBar(title: const Text("Add Friend"), centerTitle: true),
      body: SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
              TextField(
                controller: friendCodeController,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(
                  labelText: "Friend Code",
                  prefixIcon: Icon(Icons.badge),
                ),
                onSubmitted: (_) => searchFriend(),
              ),
              const SizedBox(height: 16),
              SizedBox(
                height: 52,
                child: ElevatedButton.icon(
                  onPressed: isSearching ? null : searchFriend,
                  icon: isSearching
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.search),
                  label: const Text("Search"),
                ),
              ),
              const SizedBox(height: 24),
              if (foundUser != null)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: CircleAvatar(
                            backgroundImage:
                                photoUrl != null && photoUrl.isNotEmpty
                                    ? NetworkImage(photoUrl)
                                    : null,
                            child:
                                photoUrl == null || photoUrl.isEmpty
                                    ? const Icon(Icons.person)
                                    : null,
                          ),
                          title: Text(
                            name.isEmpty ? "No name" : name,
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          subtitle: Text(email),
                        ),
                        const Divider(),
                        const Text(
                          "Friend Code",
                          style: TextStyle(color: Colors.grey),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          friendCode,
                          style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 1.2,
                          ),
                        ),
                        const SizedBox(height: 20),
                        SizedBox(
                          height: 52,
                          child: ElevatedButton.icon(
                            onPressed: isAdding ? null : addFriend,
                            icon: isAdding
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.person_add),
                            label: const Text("Add Friend"),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.green,
                              foregroundColor: Colors.white,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      ),
    );
  }
}

class FirestoreFriendProfile {
  const FirestoreFriendProfile({
    required this.uid,
    required this.name,
    required this.email,
    required this.friendCode,
  });

  final String uid;
  final String name;
  final String email;
  final String friendCode;

  String get displayName {
    if (name.trim().isNotEmpty) {
      return name.trim();
    }
    if (email.trim().isNotEmpty) {
      return email.trim();
    }
    if (friendCode.trim().isNotEmpty) {
      return friendCode.trim();
    }
    return uid;
  }
}

class FriendListItem {
  const FriendListItem({
    required this.name,
    this.uid,
    this.email = '',
    this.friendCode = '',
    this.fromFirestore = false,
    this.nickname,
  });

  final String name;
  final String? uid;
  final String email;
  final String friendCode;
  final bool fromFirestore;
  final String? nickname;

  String get displayName {
    if (nickname != null && nickname!.trim().isNotEmpty) {
      return nickname!.trim();
    }
    return name;
  }
}

class FirebaseDataService {
  static User? get _user => FirebaseAuth.instance.currentUser;

  static String? get currentUid => _user?.uid;

  static DocumentReference<Map<String, dynamic>>? get _userRef {
    final uid = currentUid;
    if (uid == null) {
      return null;
    }
    return FirebaseFirestore.instance.collection('users').doc(uid);
  }

  static CollectionReference<Map<String, dynamic>>? get transactionsRef =>
      _userRef?.collection('transactions');

  static CollectionReference<Map<String, dynamic>>? _transactionsRefForUid(
    String? uid,
  ) {
    if (uid == null || uid.isEmpty) {
      return null;
    }
    return FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .collection('transactions');
  }

  static CollectionReference<Map<String, dynamic>>? _deletedRefForUid(
    String? uid,
  ) {
    if (uid == null || uid.isEmpty) {
      return null;
    }
    return FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .collection('deletedTransactions');
  }

  static Future<String?> resolvePeerUserIdByFriendName(String friendName) async {
    final uid = currentUid;
    if (uid == null) {
      return null;
    }

    final normalizedFriendName = friendName.trim().toLowerCase();
    if (normalizedFriendName.isEmpty) {
      return null;
    }

    final friendsCollection = FirebaseFirestore.instance.collection('friends');
    final user1Docs =
        await friendsCollection.where('user1', isEqualTo: uid).get();
    final user2Docs =
        await friendsCollection.where('user2', isEqualTo: uid).get();

    final friendUids = <String>{};
    for (final doc in [...user1Docs.docs, ...user2Docs.docs]) {
      final data = doc.data();
      final user1 = data['user1'] as String? ?? '';
      final user2 = data['user2'] as String? ?? '';
      final friendUid = user1 == uid ? user2 : user1;
      if (friendUid.isNotEmpty && friendUid != uid) {
        friendUids.add(friendUid);
      }
    }

    for (final friendUid in friendUids) {
      final friendDoc =
          await FirebaseFirestore.instance.collection('users').doc(friendUid).get();
      final data = friendDoc.data();
      if (data == null) {
        continue;
      }

      final displayName = (data['name'] as String? ?? '').trim().toLowerCase();
      if (displayName == normalizedFriendName) {
        return friendUid;
      }
    }

    return null;
  }

  static Future<String?> resolveEffectivePeerUserId(
    TransactionModel transaction,
  ) async {
    final uid = currentUid;
    if (uid == null) {
      return transaction.peerUserId ??
          await resolvePeerUserIdByFriendName(transaction.friendName);
    }

    if (transaction.peerUserId != null && transaction.peerUserId != uid) {
      return transaction.peerUserId;
    }

    return await resolvePeerUserIdByFriendName(transaction.friendName);
  }

  static Future<void> saveMirroredTransaction(
    TransactionModel transaction, {
    required String firebaseId,
    String? peerUserId,
  }) async {
    final uid = currentUid;
    if (uid == null) {
      return;
    }

    final currentTransactionsRef = _transactionsRefForUid(uid);
    if (currentTransactionsRef == null) {
      return;
    }

    final resolvedPeerUid = peerUserId ??
        await resolvePeerUserIdByFriendName(transaction.friendName);
    final peerTransactionsRef = _transactionsRefForUid(resolvedPeerUid);
    final currentDisplayName = _currentUserDisplayName();

    final ownerData = {
      ...transaction.toFirestoreMap(),
      'firebaseId': firebaseId,
      'peerUserId': resolvedPeerUid,
      'updatedAt': FieldValue.serverTimestamp(),
    };

    final mirroredData = {
      ...transaction
          .copyWith(
            friendName: currentDisplayName.isNotEmpty
                ? currentDisplayName
                : transaction.friendName,
            iGave: !transaction.iGave,
            peerUserId: uid,
          )
          .toFirestoreMap(),
      'firebaseId': firebaseId,
      'peerUserId': uid,
      'updatedAt': FieldValue.serverTimestamp(),
    };

    final batch = FirebaseFirestore.instance.batch();
    batch.set(
      currentTransactionsRef.doc(firebaseId),
      ownerData,
      SetOptions(merge: true),
    );

    if (peerTransactionsRef != null && resolvedPeerUid != null && resolvedPeerUid != uid) {
      batch.set(
        peerTransactionsRef.doc(firebaseId),
        mirroredData,
        SetOptions(merge: true),
      );
    }

    await batch.commit();
  }

  static Future<void> deleteMirroredTransaction({
    required String firebaseId,
    String? peerUserId,
  }) async {
    final uid = currentUid;
    if (uid == null) {
      return;
    }

    final currentTransactionsRef = _transactionsRefForUid(uid);
    if (currentTransactionsRef == null) {
      return;
    }

    final batch = FirebaseFirestore.instance.batch();
    batch.delete(currentTransactionsRef.doc(firebaseId));

    final peerTransactionsRef = _transactionsRefForUid(peerUserId);
    if (peerTransactionsRef != null && peerUserId != null && peerUserId != uid) {
      batch.delete(peerTransactionsRef.doc(firebaseId));
    }

    await batch.commit();
  }

  static CollectionReference<Map<String, dynamic>>? get deletedRef =>
      _userRef?.collection('deletedTransactions');

  static CollectionReference<Map<String, dynamic>>? get friendsRef =>
      _userRef?.collection('friends');

  static DocumentReference<Map<String, dynamic>>? get summaryRef =>
      _userRef?.collection('summary').doc('main');

  static Stream<List<TransactionModel>> transactionsStream() {
    final ref = transactionsRef;
    if (ref == null) {
      return const Stream.empty();
    }
    return ref.snapshots().map(
      (snapshot) =>
          snapshot.docs
              .map(
                (doc) => _normalizeTransactionPerspective(
                  TransactionModel.fromFirestore(doc.id, doc.data()),
                ),
              )
              .toList()
            ..sort((a, b) => b.date.compareTo(a.date)),
    );
  }

  static Stream<double> bankBalanceStream() {
    final ref = summaryRef;
    if (ref == null) {
      return const Stream.empty();
    }
    return ref.snapshots().map(
      (snapshot) =>
          (snapshot.data()?['bankBalance'] as num?)?.toDouble() ?? 0.0,
    );
  }

  static Stream<List<DeletedEntryModel>> deletedEntriesStream(
    String friendName,
  ) {
    final ref = deletedRef;
    if (ref == null) {
      return const Stream.empty();
    }
    final personId = DatabaseHelper.personIdForName(friendName);
    return ref
        .where('personId', isEqualTo: personId)
        .snapshots()
        .map(
          (snapshot) =>
              snapshot.docs
                  .map(
                    (doc) =>
                        DeletedEntryModel.fromFirestore(doc.id, doc.data()),
                  )
                  .toList()
                ..sort((a, b) => b.clearedDate.compareTo(a.clearedDate)),
        );
  }

  static Future<String?> saveTransaction(
    TransactionModel transaction, {
    String? firebaseId,
  }) async {
    final scope = 'FirebaseDataService.saveTransaction';
    _receiptLog(
      scope,
      'Saving transaction: firebaseId=$firebaseId data=${transaction.toFirestoreMap()}',
    );
    final ref = transactionsRef;
    if (ref == null) {
      _receiptLog(scope, 'transactionsRef is null. Save skipped.');
      return null;
    }

    final resolvedFirebaseId = firebaseId ?? transaction.firebaseId ?? ref.doc().id;
    final peerUserId = await resolveEffectivePeerUserId(transaction);
    _receiptLog(
      scope,
      'Writing mirrored transaction id=$resolvedFirebaseId peerUserId=$peerUserId',
    );

    await saveMirroredTransaction(
      transaction.copyWith(
        firebaseId: resolvedFirebaseId,
        peerUserId: peerUserId,
      ),
      firebaseId: resolvedFirebaseId,
      peerUserId: peerUserId,
    );

    _receiptLog(scope, 'Updating summary after transaction save.');
    await updateSummary();
    _receiptLog(scope, 'Transaction save finished.');
    return resolvedFirebaseId;
  }

  static Future<void> deleteTransaction(TransactionModel transaction) async {
    final firebaseId = transaction.firebaseId;
    if (firebaseId == null) {
      return;
    }
    final peerUserId = await resolveEffectivePeerUserId(transaction);
    await _deleteLocalReceipt(transaction.receiptPath, scope: 'FirebaseDataService.deleteTransaction');
    await deleteMirroredTransaction(
      firebaseId: firebaseId,
      peerUserId: peerUserId,
    );
    await updateSummary();
  }

  static Future<void> clearTransaction(TransactionModel transaction) async {
    final firebaseId = transaction.firebaseId;
    final txRef = transactionsRef;
    final deleted = deletedRef;
    if (txRef == null || deleted == null || firebaseId == null) {
      return;
    }

    final uid = currentUid;
    final peerUserId = await resolveEffectivePeerUserId(transaction);
    final peerTxRef = _transactionsRefForUid(peerUserId);
    final peerDeletedRef = _deletedRefForUid(peerUserId);
    final currentDisplayName = _currentUserDisplayName();

    final ownerDeletedEntry = DeletedEntryModel(
      originalEntryId: transaction.id ?? 0,
      originalFirebaseId: firebaseId,
      peerUserId: peerUserId,
      personId: DatabaseHelper.personIdForName(transaction.friendName),
      friendName: transaction.friendName,
      date: transaction.date,
      note: transaction.note,
      amount: transaction.amount,
      isGiven: transaction.iGave,
      clearedDate: _formatDate(DateTime.now()),
      receiptUrl: transaction.receiptUrl,
      receiptPath: transaction.receiptPath,
    );

    final mirroredDeletedEntry = DeletedEntryModel(
      originalEntryId: transaction.id ?? 0,
      originalFirebaseId: firebaseId,
      peerUserId: uid,
      personId: DatabaseHelper.personIdForName(
        currentDisplayName.isNotEmpty ? currentDisplayName : transaction.friendName,
      ),
      friendName: currentDisplayName.isNotEmpty
          ? currentDisplayName
          : transaction.friendName,
      date: transaction.date,
      note: transaction.note,
      amount: transaction.amount,
      isGiven: !transaction.iGave,
      clearedDate: _formatDate(DateTime.now()),
      receiptUrl: transaction.receiptUrl,
      receiptPath: transaction.receiptPath,
    );

    final batch = FirebaseFirestore.instance.batch();
    batch.set(deleted.doc(firebaseId), {
      ...ownerDeletedEntry.toFirestoreMap(),
      'createdAt': FieldValue.serverTimestamp(),
    });
    if (peerDeletedRef != null && peerUserId != null && peerUserId != uid) {
      batch.set(peerDeletedRef.doc(firebaseId), {
        ...mirroredDeletedEntry.toFirestoreMap(),
        'createdAt': FieldValue.serverTimestamp(),
      });
    }
    batch.delete(txRef.doc(firebaseId));
    if (peerTxRef != null && peerUserId != null && peerUserId != uid) {
      batch.delete(peerTxRef.doc(firebaseId));
    }
    await batch.commit();
    await updateSummary();
  }

  static Future<void> restoreDeletedEntry(DeletedEntryModel entry) async {
    final deletedId = entry.firebaseId;
    final txRef = transactionsRef;
    final deleted = deletedRef;
    if (txRef == null || deleted == null || deletedId == null) {
      return;
    }

    final uid = currentUid;
    final peerUserId = entry.peerUserId == uid
        ? await resolvePeerUserIdByFriendName(entry.friendName)
        : entry.peerUserId ?? await resolvePeerUserIdByFriendName(entry.friendName);
    final peerTxRef = _transactionsRefForUid(peerUserId);
    final peerDeletedRef = _deletedRefForUid(peerUserId);
    final restoredFirebaseId = entry.originalFirebaseId ?? txRef.doc().id;
    final currentDisplayName = _currentUserDisplayName();

    final transaction = TransactionModel(
      peerUserId: entry.peerUserId,
      friendName: entry.friendName,
      amount: entry.amount,
      note: entry.note,
      date: entry.date,
      iGave: entry.isGiven,
      receiptUrl: entry.receiptUrl,
      receiptPath: entry.receiptPath,
    );

    final batch = FirebaseFirestore.instance.batch();
    batch.set(txRef.doc(restoredFirebaseId), {
      ...transaction.toFirestoreMap(),
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
    if (peerTxRef != null && peerUserId != null && peerUserId != uid) {
      batch.set(peerTxRef.doc(restoredFirebaseId), {
        ...transaction
            .copyWith(
              friendName: currentDisplayName.isNotEmpty
                  ? currentDisplayName
                  : transaction.friendName,
              iGave: !transaction.iGave,
              peerUserId: uid,
            )
            .toFirestoreMap(),
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    }
    batch.delete(deleted.doc(deletedId));
    if (peerDeletedRef != null && peerUserId != null && peerUserId != uid) {
      batch.delete(peerDeletedRef.doc(entry.originalFirebaseId ?? deletedId));
    }
    await batch.commit();
    await updateSummary();
  }

  static Future<void> permanentlyDeleteEntry(DeletedEntryModel entry) async {
    final deletedId = entry.firebaseId;
    final deleted = deletedRef;
    if (deleted == null || deletedId == null) {
      return;
    }
    final peerDeletedRef = _deletedRefForUid(entry.peerUserId);
    await _deleteLocalReceipt(entry.receiptPath, scope: 'FirebaseDataService.permanentlyDeleteEntry');
    await deleted.doc(deletedId).delete();
    if (peerDeletedRef != null && entry.peerUserId != null && entry.peerUserId != currentUid) {
      await peerDeletedRef.doc(entry.originalFirebaseId ?? deletedId).delete();
    }
  }

  static Future<void> saveBankBalance(double amount) async {
    final ref = summaryRef;
    if (ref == null) {
      return;
    }
    await ref.set({
      'bankBalance': amount,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  static Future<void> saveFriendProfile(FirestoreFriendProfile friend) async {
    final ref = friendsRef;
    if (ref == null) {
      return;
    }
    await ref.doc(friend.uid).set({
      'uid': friend.uid,
      'name': friend.name,
      'email': friend.email,
      'friendCode': friend.friendCode,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  static Future<void> deleteFriendData({
    required String friendName,
    String? friendUid,
  }) async {
    final uid = currentUid;
    final txRef = transactionsRef;
    final deleted = deletedRef;
    if (uid == null || txRef == null || deleted == null) {
      return;
    }

    final normalizedName = friendName.trim().toLowerCase();
    final personId = DatabaseHelper.personIdForName(friendName);
    final batch = FirebaseFirestore.instance.batch();

    final transactionDocs = await txRef.get();
    for (final doc in transactionDocs.docs) {
      final transactionFriend =
          (doc.data()['friendName'] as String? ?? '').trim().toLowerCase();
      if (transactionFriend == normalizedName) {
        batch.delete(doc.reference);
      }
    }

    final deletedDocs = await deleted.where('personId', isEqualTo: personId).get();
    for (final doc in deletedDocs.docs) {
      batch.delete(doc.reference);
    }

    if (friendUid != null && friendUid.isNotEmpty) {
      final friendsCollection = FirebaseFirestore.instance.collection('friends');
      final user1Docs = await friendsCollection
          .where('user1', isEqualTo: uid)
          .where('user2', isEqualTo: friendUid)
          .get();
      final user2Docs = await friendsCollection
          .where('user1', isEqualTo: friendUid)
          .where('user2', isEqualTo: uid)
          .get();

      for (final doc in [...user1Docs.docs, ...user2Docs.docs]) {
        batch.delete(doc.reference);
      }

      final profileRef = friendsRef?.doc(friendUid);
      if (profileRef != null) {
        batch.delete(profileRef);
      }
    }

    await batch.commit();
    await updateSummary();
  }

  static Future<void> updateSummary() async {
    final txRef = transactionsRef;
    final ref = summaryRef;
    if (txRef == null || ref == null) {
      return;
    }

    final transactions = await txRef.get();
    double toGet = 0;
    double toGive = 0;

    for (final doc in transactions.docs) {
      final data = doc.data();
      final amount = (data['amount'] as num?)?.toDouble() ?? 0.0;
      if (data['iGave'] == true) {
        toGet += amount;
      } else {
        toGive += amount;
      }
    }

    await ref.set({
      'toGet': toGet,
      'toGive': toGive,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  static Future<void> migrateSQLiteCacheToFirestoreIfNeeded() async {
    final uid = currentUid;
    if (uid == null) {
      return;
    }

    const migrationKey = 'legacy_sqlite_imported_uid';
    final importedUid = await DatabaseHelper.instance.getMigrationMeta(
      migrationKey,
    );
    if (importedUid != null && importedUid.isNotEmpty) {
      debugPrint('[Migration] Legacy SQLite already imported for $importedUid');
      return;
    }

    final txRef = transactionsRef;
    final deleted = deletedRef;
    final summary = summaryRef;
    if (txRef == null || deleted == null || summary == null) {
      return;
    }

    final existingTransactions = await txRef.limit(1).get();
    if (existingTransactions.docs.isNotEmpty) {
      await DatabaseHelper.instance.setMigrationMeta(migrationKey, uid);
      debugPrint(
        '[Migration] Firestore already has data. Marked local import for $uid.',
      );
      return;
    }

    final localTransactions = await DatabaseHelper.instance.getTransactions();
    final localDeletedEntries = await DatabaseHelper.instance
        .getAllDeletedEntries();
    final localBankBalance = await DatabaseHelper.instance.getBankBalance();

    final batch = FirebaseFirestore.instance.batch();

    for (final transaction in localTransactions) {
      batch.set(txRef.doc(), {
        ...transaction.toFirestoreMap(),
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    }

    for (final entry in localDeletedEntries) {
      batch.set(deleted.doc(), {
        ...entry.toFirestoreMap(),
        'createdAt': FieldValue.serverTimestamp(),
      });
    }

    batch.set(summary, {
      'bankBalance': localBankBalance,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    await batch.commit();
    await updateSummary();
    await DatabaseHelper.instance.setMigrationMeta(migrationKey, uid);

    debugPrint(
      '[Migration] Imported ${localTransactions.length} transactions, '
      '${localDeletedEntries.length} cleared transactions, '
      'bank balance $localBankBalance for $uid.',
    );
  }

  static void clearCachedSessionData() {
    debugPrint('[Session] Cleared in-memory cached session data.');
  }

  static String _formatDate(DateTime date) {
    return "${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}";
  }
}

class ReceiptAttachmentSection extends StatelessWidget {
  const ReceiptAttachmentSection({
    super.key,
    required this.receiptImage,
    required this.receiptUploadProgress,
    required this.onPick,
    required this.onClear,
  });

  final XFile? receiptImage;
  final double receiptUploadProgress;
  final void Function(ImageSource source) onPick;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          "Receipt (optional)",
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => onPick(ImageSource.camera),
                icon: const Icon(Icons.camera_alt),
                label: const Text("Camera"),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => onPick(ImageSource.gallery),
                icon: const Icon(Icons.photo_library),
                label: const Text("Gallery"),
              ),
            ),
          ],
        ),
        if (receiptImage != null) ...[
          const SizedBox(height: 12),
          SizedBox(
            height: 140,
            child: Stack(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.file(
                    File(receiptImage!.path),
                    fit: BoxFit.cover,
                    width: double.infinity,
                  ),
                ),
                Positioned(
                  top: 8,
                  right: 8,
                  child: GestureDetector(
                    onTap: onClear,
                    child: Container(
                      decoration: const BoxDecoration(
                        color: Colors.black54,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.close, color: Colors.white),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
        if (receiptUploadProgress > 0 && receiptUploadProgress < 1)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: LinearProgressIndicator(value: receiptUploadProgress),
          ),
      ],
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  List<TransactionModel> transactions = [];
  List<FirestoreFriendProfile> firestoreFriends = [];
  Map<String, String> localNicknames = {};

  Future<void> loadLocalNicknames() async {
    final nicks = await DatabaseHelper.instance.getAllNicknames();
    if (!mounted) return;
    setState(() {
      localNicknames = nicks;
    });
  }
  double bankBalance = 0.0;
  bool isLoading = false;
  StreamSubscription<List<TransactionModel>>? _transactionsSubscription;
  StreamSubscription<double>? _bankBalanceSubscription;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>?
  _user1FriendsSubscription;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>?
  _user2FriendsSubscription;

  @override
  void initState() {
    super.initState();
    initializeHome();
  }

  @override
  void dispose() {
    _transactionsSubscription?.cancel();
    _bankBalanceSubscription?.cancel();
    _user1FriendsSubscription?.cancel();
    _user2FriendsSubscription?.cancel();
    super.dispose();
  }

  Future<void> loadData() async {
    await loadLocalNicknames();
    if (FirebaseAuth.instance.currentUser == null) {
      await Future.wait([loadTransactions(), loadBankBalance()]);
    } else {
      await FirebaseDataService.migrateSQLiteCacheToFirestoreIfNeeded();
      await loadFirestoreFriends();
    }
    debugPrint('[Home] total friends loaded: ${visibleFriends.length}');
  }

  Future<void> initializeHome() async {
    await loadData();
    if (mounted) {
      startRealtimeSync();
    }
  }

  void startRealtimeSync() {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) {
      return;
    }

    _transactionsSubscription = FirebaseDataService.transactionsStream().listen(
      (data) {
        if (!mounted) {
          return;
        }
        setState(() {
          transactions = data;
        });
        debugPrint('[Home] transactions snapshot loaded: ${data.length}');
        debugPrint('[Home] total friends loaded: ${visibleFriends.length}');
      },
    );

    _bankBalanceSubscription = FirebaseDataService.bankBalanceStream().listen((
      amount,
    ) {
      if (!mounted) {
        return;
      }
      setState(() {
        bankBalance = amount;
      });
      debugPrint('[Home] bank balance snapshot loaded: $amount');
    });

    final friendsCollection = FirebaseFirestore.instance.collection('friends');
    _user1FriendsSubscription = friendsCollection
        .where('user1', isEqualTo: currentUser.uid)
        .snapshots()
        .listen((_) => loadFirestoreFriends());
    _user2FriendsSubscription = friendsCollection
        .where('user2', isEqualTo: currentUser.uid)
        .snapshots()
        .listen((_) => loadFirestoreFriends());
  }

  Future<void> loadTransactions() async {
    final data = await DatabaseHelper.instance.getTransactions();
    if (!mounted) {
      return;
    }
    setState(() {
      transactions = data.reversed.toList();
    });
  }

  Future<void> loadBankBalance() async {
    final amount = await DatabaseHelper.instance.getBankBalance();
    if (!mounted) {
      return;
    }
    setState(() {
      bankBalance = amount;
    });
  }

  Future<void> refreshDashboard() async {
    await loadLocalNicknames();
    if (FirebaseAuth.instance.currentUser == null) {
      await Future.wait([loadTransactions(), loadBankBalance()]);
    } else {
      await loadFirestoreFriends();
    }
  }

  Future<void> loadFirestoreFriends() async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) {
      debugPrint('[Home] No current user. Skipping Firestore friends load.');
      return;
    }

    final currentUid = currentUser.uid;
    debugPrint('[Home] current uid: $currentUid');

    final friendsCollection = FirebaseFirestore.instance.collection('friends');
    final user1Query = await friendsCollection
        .where('user1', isEqualTo: currentUid)
        .get();
    final user2Query = await friendsCollection
        .where('user2', isEqualTo: currentUid)
        .get();

    final friendshipDocs = {
      for (final doc in user1Query.docs) doc.id: doc,
      for (final doc in user2Query.docs) doc.id: doc,
    }.values.toList();

    debugPrint('[Home] friendship documents found: ${friendshipDocs.length}');

    final friendUids = <String>{};
    for (final doc in friendshipDocs) {
      final data = doc.data();
      final user1 = data['user1'] as String? ?? '';
      final user2 = data['user2'] as String? ?? '';
      final friendUid = user1 == currentUid ? user2 : user1;

      if (friendUid.isNotEmpty && friendUid != currentUid) {
        friendUids.add(friendUid);
      }
    }

    debugPrint('[Home] friend UIDs found: ${friendUids.toList()}');

    final loadedFriends = <FirestoreFriendProfile>[];
    for (final friendUid in friendUids) {
      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(friendUid)
          .get();
      final data = userDoc.data();

      if (!userDoc.exists || data == null) {
        debugPrint('[Home] user missing for friend uid: $friendUid');
        continue;
      }

      final friendProfile = FirestoreFriendProfile(
        uid: data['uid'] as String? ?? friendUid,
        name: data['name'] as String? ?? '',
        email: data['email'] as String? ?? '',
        friendCode: data['friendCode'] as String? ?? '',
      );
      loadedFriends.add(friendProfile);
      await FirebaseDataService.saveFriendProfile(friendProfile);
    }

    debugPrint(
      '[Home] users loaded: ${loadedFriends.map((friend) => friend.uid).toList()}',
    );
    debugPrint('[Home] Firestore friends loaded: ${loadedFriends.length}');

    if (!mounted) {
      return;
    }

    setState(() {
      firestoreFriends = loadedFriends;
    });
  }

  double get totalToGet {
    double total = 0;
    for (var t in transactions) {
      if (t.iGave) {
        total += t.amount;
      }
    }
    return total;
  }

  double get totalToGive {
    double total = 0;
    for (var t in transactions) {
      if (!t.iGave) {
        total += t.amount;
      }
    }
    return total;
  }

  double get netWorth {
    return bankBalance + totalToGet - totalToGive;
  }

  Future<void> syncBankBalance() async {
    setState(() {
      isLoading = true;
    });
    try {
      if (FirebaseAuth.instance.currentUser == null) {
        await loadBankBalance();
      } else {
        await loadFirestoreFriends();
      }
    } catch (e) {
      debugPrint('Error loading bank balance: $e');
    } finally {
      if (mounted) {
        setState(() {
          isLoading = false;
        });
      }
    }
  }

  String formatAmount(double amount) {
    return amount
        .toStringAsFixed(0)
        .replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+(?!\d))'), (m) => '${m[1]},');
  }

  Future<void> showBankBalanceDialog() async {
    final controller = TextEditingController(
      text: bankBalance == 0 ? '' : bankBalance.toStringAsFixed(0),
    );
    final formKey = GlobalKey<FormState>();

    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text("Enter Bank Balance"),
          content: Form(
            key: formKey,
            child: TextFormField(
              controller: controller,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(
                labelText: "Amount",
                prefixText: "\u20B9",
              ),
              validator: (value) {
                if (value == null || value.trim().isEmpty) {
                  return "Please enter bank balance";
                }
                if (double.tryParse(value.trim()) == null) {
                  return "Please enter a valid amount";
                }
                return null;
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text("Cancel"),
            ),
            ElevatedButton(
              onPressed: () async {
                if (formKey.currentState?.validate() ?? false) {
                  final amount = double.parse(controller.text.trim());
                  await DatabaseHelper.instance.saveBankBalance(amount);
                  await FirebaseDataService.saveBankBalance(amount);
                  if (dialogContext.mounted) {
                    Navigator.pop(dialogContext, true);
                  }
                }
              },
              child: const Text("Save"),
            ),
          ],
        );
      },
    );

    if (saved == true) {
      await refreshDashboard();
    }
  }

  Future<void> openProfilePage() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const ProfilePage()),
    );
  }

  Future<void> openAddFriendPage() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const AddFriendPage()),
    );
    if (result == true) {
      await refreshDashboard();
      debugPrint('[Home] total friends loaded: ${visibleFriends.length}');
    }
  }

  // Group transactions by friendName (case-insensitive key, original case preserved)
  Map<String, List<TransactionModel>> get groupedTransactions {
    final Map<String, List<TransactionModel>> map = {};
    final Map<String, String> originalNames = {};
    for (var t in transactions) {
      final name = _transactionDisplayFriendName(t).trim();
      if (name.isEmpty) continue;
      final key = name.toLowerCase();
      if (!originalNames.containsKey(key)) {
        originalNames[key] = name;
      }
      map.putIfAbsent(originalNames[key]!, () => []).add(t);
    }
    return map;
  }

  // Sorted list of unique friend names
  List<String> get uniqueFriends {
    final friends = groupedTransactions.keys.toList();
    friends.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return friends;
  }

  List<FriendListItem> get visibleFriends {
    final items = <FriendListItem>[];
    final existingNames = <String>{};

    for (final friendName in uniqueFriends) {
      final key = friendName.trim().toLowerCase();
      final nickname = localNicknames[key];
      items.add(FriendListItem(name: friendName, nickname: nickname));
      existingNames.add(key);
    }

    for (final firestoreFriend in firestoreFriends) {
      final displayName = firestoreFriend.displayName;
      final key = displayName.toLowerCase();
      final nickname = localNicknames[key];
      if (existingNames.contains(key)) {
        final index = items.indexWhere(
          (item) => item.name.trim().toLowerCase() == key,
        );
        if (index != -1) {
          items[index] = FriendListItem(
            name: items[index].name,
            uid: firestoreFriend.uid,
            email: firestoreFriend.email,
            friendCode: firestoreFriend.friendCode,
            fromFirestore: true,
            nickname: nickname,
          );
        }
        continue;
      }

      items.add(
        FriendListItem(
          name: displayName,
          uid: firestoreFriend.uid,
          email: firestoreFriend.email,
          friendCode: firestoreFriend.friendCode,
          fromFirestore: true,
          nickname: nickname,
        ),
      );
      existingNames.add(key);
    }

    items.sort((a, b) => a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));
    return items;
  }

  List<TransactionModel> transactionsForFriend(String friendName) {
    final normalizedName = friendName.trim().toLowerCase();
    return transactions
        .where(
          (t) =>
              _transactionDisplayFriendName(t).trim().toLowerCase() ==
              normalizedName,
        )
        .toList();
  }

  double totalGivenForFriend(String friendName) {
    double total = 0;
    for (final t in transactionsForFriend(friendName)) {
      if (_transactionDisplayIsGiven(t)) {
        total += t.amount;
      }
    }
    return total;
  }

  double totalTakenForFriend(String friendName) {
    double total = 0;
    for (final t in transactionsForFriend(friendName)) {
      if (!_transactionDisplayIsGiven(t)) {
        total += t.amount;
      }
    }
    return total;
  }

  // Matches PersonDetailPage: netBalance = totalGiven - totalTaken.
  double getFriendBalance(String friendName) {
    return totalGivenForFriend(friendName) - totalTakenForFriend(friendName);
  }

  Future<void> deleteEntireFriend(FriendListItem friend) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text("Delete friend and all transactions?"),
          content: Text(
            "This will delete ${friend.name}, all active transactions, and deleted transaction history.",
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text("Cancel"),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
              ),
              child: const Text("Delete"),
            ),
          ],
        );
      },
    );

    if (confirmed != true) {
      return;
    }

    if (FirebaseAuth.instance.currentUser == null) {
      await DatabaseHelper.instance.deleteTransactionsForFriend(friend.name);
      await DatabaseHelper.instance.deleteDeletedEntriesForFriend(friend.name);
    } else {
      await FirebaseDataService.deleteFriendData(
        friendName: friend.name,
        friendUid: friend.uid,
      );
    }

    await refreshDashboard();
  }

  // Quick dialog to add a transaction for a friend when clicking + or -
  Future<void> quickAddTransaction(String friendName, bool isPlus) async {
    final amountController = TextEditingController();
    final noteController = TextEditingController();
    final today = DateTime.now();
    final dateController = TextEditingController(
      text:
          "${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}",
    );

    final formKey = GlobalKey<FormState>();
    XFile? receiptImage;
    double receiptUploadProgress = 0;
    bool isSaving = false;
    late StateSetter setDialogState;

    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        Future<void> handlePick(ImageSource source) async {
          const scope = 'Home.quickAddTransaction.pickReceipt';
          final picked = await _pickReceiptImage(source: source, scope: scope);
          if (picked == null) {
            return;
          }
          if (!dialogContext.mounted) {
            return;
          }
          _receiptLog(scope, 'Applying picked image to quick-add dialog.');
          receiptImage = picked;
          receiptUploadProgress = 0;
          setDialogState(() {});
        }

        Future<void> handleSave() async {
          const scope = 'Home.quickAddTransaction.save';
          _receiptLog(scope, 'Save pressed. receiptSelected=${receiptImage != null}');
          if (!(formKey.currentState?.validate() ?? false)) {
            _receiptLog(scope, 'Form validation failed.');
            return;
          }

          try {
            isSaving = true;
            if (dialogContext.mounted) {
              setDialogState(() {});
            }

            final currentUser = FirebaseAuth.instance.currentUser;
            _receiptLog(
              scope,
              'Current user=${currentUser?.uid ?? 'null'} existingReceipt=${receiptImage != null}',
            );

            String? firebaseId;
            String? receiptPath;
            String? receiptUrl;

            if (receiptImage != null) {
              if (currentUser == null) {
                _receiptLog(
                  scope,
                  'No signed-in user; local receipt save skipped and transaction will still be saved.',
                );
              } else {
                firebaseId = FirebaseFirestore.instance
                    .collection('users')
                    .doc(currentUser.uid)
                    .collection('transactions')
                    .doc()
                    .id;
                _receiptLog(scope, 'Generated firebaseId=$firebaseId for local receipt save.');

                final compressedImage = await _compressReceiptImage(
                  File(receiptImage!.path),
                  scope: scope,
                );
                if (compressedImage != null) {
                  final compressedFile = File(compressedImage.path);
                  receiptPath = await _saveReceiptLocally(
                    sourceFile: compressedFile,
                    firebaseId: firebaseId,
                    scope: scope,
                  );

                  // Upload to Cloudinary
                  try {
                    final uri = Uri.parse(
                      'https://api.cloudinary.com/v1_1/dxwf10vjg/image/upload',
                    );
                    final request = http.MultipartRequest('POST', uri)
                      ..fields['upload_preset'] = 'receipt_upload'
                      ..files.add(await http.MultipartFile.fromPath('file', compressedFile.path));

                    final streamedResponse = await request.send();
                    final responseBody = await streamedResponse.stream.bytesToString();

                    if (streamedResponse.statusCode == 200) {
                      final jsonResponse = jsonDecode(responseBody) as Map<String, dynamic>;
                      receiptUrl = jsonResponse['secure_url'] as String?;
                      _receiptLog(scope, 'Cloudinary upload succeeded: $receiptUrl');
                    } else {
                      _receiptLog(scope, 'Cloudinary upload failed: ${streamedResponse.statusCode}');
                    }
                  } catch (cloudinaryError, cloudinarySt) {
                    _receiptLog(scope, 'Cloudinary upload failed with exception: $cloudinaryError\n$cloudinarySt');
                  }
                } else {
                  _receiptLog(
                    scope,
                    'Compression returned null; continuing without local receipt path.',
                  );
                }
              }
            }

            final transaction = TransactionModel(
              friendName: friendName,
              amount: double.parse(amountController.text.trim()),
              note: noteController.text.trim(),
              date: dateController.text.trim(),
              iGave: isPlus,
              firebaseId: firebaseId,
              createdBy: FirebaseAuth.instance.currentUser?.uid,
              receiptPath: receiptPath,
              receiptUrl: receiptUrl,
            );

            _receiptLog(
              scope,
              'Built transaction payload: ${transaction.toFirestoreMap()}',
            );

            _receiptLog(scope, 'Writing new transaction to local DB.');
            await DatabaseHelper.instance.insertTransaction(transaction);
            _receiptLog(scope, 'Writing new transaction to Firestore.');
            await FirebaseDataService.saveTransaction(
              transaction,
              firebaseId: firebaseId,
            );

            _receiptLog(scope, 'Save finished successfully.');
            if (dialogContext.mounted) {
              Navigator.pop(dialogContext, true);
            }
          } catch (e, st) {
            _receiptLog(scope, 'Save failed: $e\n$st');
            if (dialogContext.mounted) {
              ScaffoldMessenger.of(dialogContext).showSnackBar(
                SnackBar(content: Text('Failed to save transaction: $e')),
              );
            }
          } finally {
            isSaving = false;
            if (dialogContext.mounted) {
              setDialogState(() {});
            }
          }
        }

        return StatefulBuilder(
          builder: (context, stateSetter) {
            setDialogState = stateSetter;
            return AlertDialog(
              title: Text(
                isPlus
                    ? "Give Money to $friendName"
                    : "Take Money from $friendName",
                style: TextStyle(
                  color: isPlus ? Colors.green : Colors.red,
                  fontWeight: FontWeight.bold,
                ),
              ),
              content: Form(
                key: formKey,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextFormField(
                        controller: amountController,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: "Money (Amount)",
                          prefixText: "\u20B9",
                        ),
                        validator: (val) {
                          if (val == null || val.isEmpty) {
                            return "Please enter amount";
                          }
                          if (double.tryParse(val) == null) {
                            return "Please enter a valid number";
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: noteController,
                        decoration: const InputDecoration(labelText: "Note"),
                        validator: (val) {
                          if (val == null || val.isEmpty) {
                            return "Please enter a note";
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: TextFormField(
                              controller: dateController,
                              decoration:
                                  const InputDecoration(labelText: "Date"),
                              validator: (val) {
                                if (val == null || val.isEmpty) {
                                  return "Please enter date";
                                }
                                return null;
                              },
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.calendar_month),
                            onPressed: () async {
                              final selected = await showDatePicker(
                                context: dialogContext,
                                initialDate: DateTime.now(),
                                firstDate: DateTime(2000),
                                lastDate: DateTime(2100),
                              );
                              if (selected != null) {
                                dateController.text =
                                    "${selected.year}-${selected.month.toString().padLeft(2, '0')}-${selected.day.toString().padLeft(2, '0')}";
                                setDialogState(() {});
                              }
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      ReceiptAttachmentSection(
                        receiptImage: receiptImage,
                        receiptUploadProgress: receiptUploadProgress,
                        onPick: (source) async {
                          await handlePick(source);
                        },
                        onClear: () {
                          _receiptLog(
                            'Home.quickAddTransaction.clearReceipt',
                            'Clearing selected receipt image.',
                          );
                          receiptImage = null;
                          receiptUploadProgress = 0;
                          setDialogState(() {});
                        },
                      ),
                      if (isSaving) ...[
                        const SizedBox(height: 12),
                        const LinearProgressIndicator(),
                      ],
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: isSaving
                      ? null
                      : () => Navigator.pop(dialogContext, false),
                  child: const Text("Cancel"),
                ),
                ElevatedButton(
                  onPressed: isSaving ? null : handleSave,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: isPlus ? Colors.green : Colors.red,
                    foregroundColor: Colors.white,
                  ),
                  child: const Text("Save"),
                ),
              ],
            );
          },
        );
      },
    );

    if (saved == true) {
      await refreshDashboard();
    }
  }

  @override
  Widget build(BuildContext context) {
    final friends = visibleFriends;

    return Scaffold(
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        title: const Text("Hisab Kitab"),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.person),
            tooltip: "Profile",
            onPressed: openProfilePage,
          ),
          IconButton(
            icon: const Icon(Icons.account_balance),
            tooltip: "Bank Balance",
            onPressed: showBankBalanceDialog,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: Colors.green,
        onPressed: () async {
          final result = await Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const AddPage()),
          );
          if (result == true) {
            await refreshDashboard();
          }
        },
        child: const Icon(Icons.add),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            LayoutBuilder(
              builder: (context, constraints) {
                final cardWidth = (constraints.maxWidth - 12) / 2;
                final cardHeight = cardWidth / 1.9;
                final gridHeight = (cardHeight * 2) + 12;
                return SizedBox(
                  height: gridHeight,
                  child: GridView.count(
                    padding: EdgeInsets.zero,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    crossAxisCount: 2,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                    childAspectRatio: 1.9,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: Colors.green,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              "TO GET",
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Expanded(
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    "\u20B9${formatAmount(totalToGet)}",
                                    style: const TextStyle(
                                      fontSize: 24,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: Colors.red,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              "TO GIVE",
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Expanded(
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    "\u20B9${formatAmount(totalToGive)}",
                                    style: const TextStyle(
                                      fontSize: 24,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: Colors.blue,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              "BANK BALANCE",
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Expanded(
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    "\u20B9${formatAmount(bankBalance)}",
                                    style: const TextStyle(
                                      fontSize: 24,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: Colors.amber,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              "NET BALANCE",
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: Colors.black,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Expanded(
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    "\u20B9${formatAmount(netWorth)}",
                                    style: const TextStyle(
                                      fontSize: 24,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.black,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              height: 52,
              child: ElevatedButton.icon(
                onPressed: openAddFriendPage,
                icon: const Icon(Icons.person_add),
                label: const Text("Add Friend"),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: Colors.black,
                ),
              ),
            ),
            const SizedBox(height: 20),
            Expanded(
              child: RefreshIndicator(
                onRefresh: syncBankBalance,
                color: Colors.amber,
                child: friends.isEmpty
                    ? ListView(
                        // Wrapping in a ListView so pull-to-refresh works even on empty state
                        children: const [
                          SizedBox(height: 80),
                          Center(
                            child: Text(
                              "No friends added yet. Tap '+' to add a transaction.",
                              style: TextStyle(color: Colors.grey),
                            ),
                          ),
                        ],
                      )
                    : ListView.builder(
                        itemCount: friends.length,
                        itemBuilder: (context, index) {
                          final friend = friends[index];
                          final friendName = friend.name;
                          final balance = getFriendBalance(friendName);
                          final status = balance >= 0 ? "To Get" : "To Give";
                          final statusColor = balance >= 0
                              ? Colors.green
                              : Colors.red;
                          return Card(
                            margin: const EdgeInsets.only(bottom: 12),
                            child: ListTile(
                              leading: friend.uid == null || friend.uid!.isEmpty
                                  ? CircleAvatar(
                                      backgroundColor: balance >= 0
                                          ? Colors.green.withValues(alpha: 0.2)
                                          : Colors.red.withValues(alpha: 0.2),
                                      child: Text(
                                        friend.displayName.isNotEmpty
                                            ? friend.displayName[0].toUpperCase()
                                            : '?',
                                        style: TextStyle(
                                          color: balance >= 0
                                              ? Colors.green
                                              : Colors.red,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    )
                                  : FutureBuilder<DocumentSnapshot>(
                                      future: FirebaseFirestore.instance
                                          .collection('users')
                                          .doc(friend.uid)
                                          .get(),
                                      builder: (context, snapshot) {
                                        final data = snapshot.data?.data() as Map<String, dynamic>?;
                                        final photoUrl = data?['photoUrl'] as String?;
                                        if (photoUrl != null && photoUrl.isNotEmpty) {
                                          return CircleAvatar(
                                            backgroundImage: NetworkImage(photoUrl),
                                          );
                                        }
                                        return CircleAvatar(
                                          backgroundColor: balance >= 0
                                              ? Colors.green.withValues(alpha: 0.2)
                                              : Colors.red.withValues(alpha: 0.2),
                                          child: Text(
                                            friend.displayName.isNotEmpty
                                                ? friend.displayName[0].toUpperCase()
                                                : '?',
                                            style: TextStyle(
                                              color: balance >= 0
                                                  ? Colors.green
                                                  : Colors.red,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        );
                                      },
                                    ),
                              title: Text(
                                friend.displayName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16,
                                ),
                              ),
                              isThreeLine: true,
                          subtitle: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  FittedBox(
                                    fit: BoxFit.scaleDown,
                                    alignment: Alignment.centerLeft,
                                    child: Text(
                                      "Net Amount: \u20B9${formatAmount(balance.abs())}",
                                      style: TextStyle(
                                        color: statusColor,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    "Status: $status",
                                    style: TextStyle(
                                      color: statusColor,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ],
                              ),
                              trailing: SizedBox(
                                width: 96,
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.end,
                                  children: [
                                    IconButton(
                                      visualDensity: VisualDensity.compact,
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(
                                        minWidth: 36,
                                        minHeight: 36,
                                      ),
                                      icon: const Icon(
                                        Icons.add_circle_outline,
                                        color: Colors.green,
                                      ),
                                      tooltip: "Give Money (+)",
                                      onPressed: () {
                                        quickAddTransaction(friendName, true);
                                      },
                                    ),
                                    IconButton(
                                      visualDensity: VisualDensity.compact,
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(
                                        minWidth: 36,
                                        minHeight: 36,
                                      ),
                                      icon: const Icon(
                                        Icons.remove_circle_outline,
                                        color: Colors.red,
                                      ),
                                      tooltip: "Take Money (-)",
                                      onPressed: () {
                                        quickAddTransaction(friendName, false);
                                      },
                                    ),
                                  ],
                                ),
                              ),
                               onTap: () async {
                                 await Navigator.push(
                                   context,
                                   MaterialPageRoute(
                                     builder: (_) => PersonDetailPage(
                                       friendName: friendName,
                                       peerUserId: friend.uid,
                                     ),
                                   ),
                                 );
                                await refreshDashboard();
                              },
                              onLongPress: () {
                                deleteEntireFriend(friend);
                              },
                            ),
                          );
                        },
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class AddPage extends StatefulWidget {
  final TransactionModel? transaction;

  const AddPage({super.key, this.transaction});

  @override
  State<AddPage> createState() => _AddPageState();
}

class _AddPageState extends State<AddPage> {
  final friendController = TextEditingController();
  final amountController = TextEditingController();
  final noteController = TextEditingController();
  final dateController = TextEditingController();
  bool iGave = true;
  XFile? receiptImage;
  double receiptUploadProgress = 0;

  String formatDate(DateTime date) {
    return "${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}";
  }

  @override
  void initState() {
    super.initState();
    if (widget.transaction != null) {
      friendController.text = widget.transaction!.friendName;
      amountController.text = widget.transaction!.amount.toString();
      noteController.text = widget.transaction!.note;
      dateController.text = widget.transaction!.date;
      iGave = widget.transaction!.iGave;
    } else {
      dateController.text = formatDate(DateTime.now());
    }
  }

  Future<void> pickDate() async {
    final currentDate =
        DateTime.tryParse(dateController.text) ?? DateTime.now();
    final selected = await showDatePicker(
      context: context,
      initialDate: currentDate,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );

    if (selected != null) {
      setState(() {
        dateController.text = formatDate(selected);
      });
    }
  }

  Future<void> saveTransaction() async {
    const scope = 'AddPage.saveTransaction';
    _receiptLog(scope, 'Save pressed. receiptSelected=${receiptImage != null}');
    try {
      final currentUser = FirebaseAuth.instance.currentUser;
      _receiptLog(
        scope,
        'Current user=${currentUser?.uid ?? 'null'} existingFirebaseId=${widget.transaction?.firebaseId}',
      );

      String? firebaseId = widget.transaction?.firebaseId;
      String? receiptPath = widget.transaction?.receiptPath;
      String? receiptUrl = widget.transaction?.receiptUrl;

      if (receiptImage != null) {
        if (currentUser == null) {
          _receiptLog(
            scope,
            'No signed-in user; local receipt save will be skipped and transaction will still be saved.',
          );
        } else {
          firebaseId ??= FirebaseFirestore.instance
              .collection('users')
              .doc(currentUser.uid)
              .collection('transactions')
              .doc()
              .id;
          _receiptLog(scope, 'Using firebaseId=$firebaseId for local receipt save.');

          final compressedImage =
              await _compressReceiptImage(File(receiptImage!.path), scope: scope);
          if (compressedImage != null) {
            final compressed = File(compressedImage.path);
            receiptPath = await _saveReceiptLocally(
              sourceFile: compressed,
              firebaseId: firebaseId,
              scope: scope,
            );

            // Upload to Cloudinary
            try {
              final uri = Uri.parse(
                'https://api.cloudinary.com/v1_1/dxwf10vjg/image/upload',
              );
              final request = http.MultipartRequest('POST', uri)
                ..fields['upload_preset'] = 'receipt_upload'
                ..files.add(await http.MultipartFile.fromPath('file', compressed.path));

              final streamedResponse = await request.send();
              final responseBody = await streamedResponse.stream.bytesToString();

              if (streamedResponse.statusCode == 200) {
                final jsonResponse = jsonDecode(responseBody) as Map<String, dynamic>;
                receiptUrl = jsonResponse['secure_url'] as String?;
                _receiptLog(scope, 'Cloudinary upload succeeded: $receiptUrl');
              } else {
                _receiptLog(scope, 'Cloudinary upload failed: ${streamedResponse.statusCode}');
              }
            } catch (cloudinaryError, cloudinarySt) {
              _receiptLog(scope, 'Cloudinary upload failed with exception: $cloudinaryError\n$cloudinarySt');
            }
          } else {
            _receiptLog(
              scope,
              'Compression returned null; continuing without local receipt path.',
            );
          }
        }
      }

      final transaction = TransactionModel(
        id: widget.transaction?.id,
        firebaseId: widget.transaction?.firebaseId ?? firebaseId,
        peerUserId: widget.transaction?.peerUserId,
        createdBy: widget.transaction?.createdBy ?? currentUser?.uid,
        receiptUrl: receiptUrl,
        receiptPath: receiptPath,
        friendName: friendController.text.trim(),
        amount: double.parse(amountController.text),
        note: noteController.text.trim(),
        date: dateController.text.trim(),
        iGave: iGave,
      );

      _receiptLog(scope, 'Built transaction payload: ${transaction.toFirestoreMap()}');

      if (widget.transaction == null) {
        _receiptLog(scope, 'Writing new transaction to local DB.');
        await DatabaseHelper.instance.insertTransaction(transaction);
        _receiptLog(scope, 'Writing new transaction to Firestore.');
        await FirebaseDataService.saveTransaction(
          transaction,
          firebaseId: firebaseId,
        );
      } else {
        if (transaction.id != null) {
          _receiptLog(scope, 'Updating transaction in local DB.');
          await DatabaseHelper.instance.updateTransaction(transaction);
        }
        _receiptLog(scope, 'Writing updated transaction to Firestore.');
        await FirebaseDataService.saveTransaction(
          transaction,
          firebaseId: transaction.firebaseId,
        );
      }

      _receiptLog(scope, 'Save finished successfully.');
      if (mounted) {
        Navigator.pop(context, true);
      }
    } catch (e, st) {
      _receiptLog(scope, 'Save failed: $e\n$st');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to save transaction: $e')),
        );
      }
    }
  }

  @override
  void dispose() {
    friendController.dispose();
    amountController.dispose();
    noteController.dispose();
    dateController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.transaction == null ? "Add Transaction" : "Edit Transaction",
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: SingleChildScrollView(
          child: Column(
            children: [
              TextField(
                controller: friendController,
                decoration: const InputDecoration(labelText: "Friend Name"),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: amountController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: "Amount"),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: noteController,
                decoration: const InputDecoration(labelText: "Note"),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: dateController,
                readOnly: true,
                onTap: pickDate,
                decoration: const InputDecoration(
                  labelText: "Date",
                  suffixIcon: Icon(Icons.calendar_month),
                ),
              ),
              const SizedBox(height: 16),
              ReceiptAttachmentSection(
                receiptImage: receiptImage,
                receiptUploadProgress: receiptUploadProgress,
                onPick: (source) async {
                  final result = await _pickReceiptImage(
                    source: source,
                    scope: 'AddPage.pickReceipt',
                  );
                  if (result == null || !mounted) {
                    return;
                  }
                  setState(() {
                    receiptImage = result;
                  });
                },
                onClear: () {
                  _receiptLog('AddPage.pickReceipt', 'Receipt cleared.');
                  setState(() {
                    receiptImage = null;
                    receiptUploadProgress = 0;
                  });
                },
              ),
              const SizedBox(height: 16),
              SwitchListTile(
                title: Text(iGave ? "I Gave Money" : "I Took Money"),
                value: iGave,
                onChanged: (value) {
                  setState(() {
                    iGave = value;
                  });
                },
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                height: 55,
                child: ElevatedButton(
                  onPressed: saveTransaction,
                  child: Text(
                    widget.transaction == null
                        ? "Save Transaction"
                        : "Update Transaction",
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class TransactionDetailPage extends StatelessWidget {
  const TransactionDetailPage({super.key, required this.transaction});

  final TransactionModel transaction;

  Widget? _buildReceiptWidget(BuildContext context) {
    final receiptPath = transaction.receiptPath;
    final receiptUrl = transaction.receiptUrl;

    if (receiptPath != null && receiptPath.isNotEmpty) {
      final file = File(receiptPath);
      if (file.existsSync()) {
        return GestureDetector(
          onTap: () {
            showDialog(
              context: context,
              builder: (_) {
                return Dialog(
                  insetPadding: const EdgeInsets.all(16),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: PhotoView(
                      imageProvider: FileImage(file),
                      backgroundDecoration:
                          const BoxDecoration(color: Colors.black),
                    ),
                  ),
                );
              },
            );
          },
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Image.file(
              file,
              fit: BoxFit.cover,
              width: double.infinity,
            ),
          ),
        );
      }
    }

    if (receiptUrl != null && receiptUrl.isNotEmpty) {
      return GestureDetector(
        onTap: () {
          showDialog(
            context: context,
            builder: (_) {
              return Dialog(
                insetPadding: const EdgeInsets.all(16),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: PhotoView(
                    imageProvider: NetworkImage(receiptUrl),
                    backgroundDecoration:
                        const BoxDecoration(color: Colors.black),
                  ),
                ),
              );
            },
          );
        },
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Image.network(
            receiptUrl,
            fit: BoxFit.cover,
            width: double.infinity,
            errorBuilder: (_, _, _) => const SizedBox(
              height: 180,
              child: Center(
                child: Icon(Icons.broken_image, size: 48, color: Colors.grey),
              ),
            ),
          ),
        ),
      );
    }

    return null;
  }

  Widget _detailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: const TextStyle(
                color: Colors.grey,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isGiven = _transactionDisplayIsGiven(transaction);
    final amountColor = isGiven ? Colors.green : Colors.red;
    final receiptWidget = _buildReceiptWidget(context);
    final statusText = isGiven ? 'To Get' : 'To Give';
    final displayFriendName = _transactionDisplayFriendName(transaction);

    return Scaffold(
      appBar: AppBar(title: const Text('Transaction Details'), centerTitle: true),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Card(
              color: Colors.grey[900],
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      displayFriendName,
                      style: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text('Status: $statusText', style: TextStyle(color: amountColor)),
                    const SizedBox(height: 16),
                    Text(
                      '\u20B9${transaction.amount.toStringAsFixed(0)}',
                      style: TextStyle(
                        fontSize: 32,
                        fontWeight: FontWeight.bold,
                        color: amountColor,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (receiptWidget != null) ...[
              const SizedBox(height: 16),
              receiptWidget,
              const SizedBox(height: 16),
            ],
            Card(
              color: Colors.grey[900],
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Transaction Info',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    _detailRow('Date', transaction.date),
                    _detailRow('Note', transaction.note),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class PersonDetailPage extends StatefulWidget {
  final String friendName;
  final String? peerUserId;

  const PersonDetailPage({
    super.key,
    required this.friendName,
    this.peerUserId,
  });

  @override
  State<PersonDetailPage> createState() => _PersonDetailPageState();
}

class _PersonDetailPageState extends State<PersonDetailPage> with WidgetsBindingObserver {
  List<TransactionModel> personTransactions = [];
  List<DeletedEntryModel> deletedTransactions = [];
  bool isLoading = true;
  StreamSubscription<List<TransactionModel>>? _transactionsSubscription;
  StreamSubscription<List<DeletedEntryModel>>? _deletedSubscription;
  Future<String?>? _friendPhotoFuture;
  Future<String?>? _friendUpiFuture;
  String? _localNickname;
  bool _launchedUpiPayment = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadNickname();
    if (FirebaseAuth.instance.currentUser == null) {
      loadPersonTransactions();
    } else {
      startRealtimeSync();
      _friendPhotoFuture = _fetchFriendPhotoUrl();
      _friendUpiFuture = _fetchFriendUpiId();
    }
  }

  Future<void> _loadNickname() async {
    final nick = await DatabaseHelper.instance.getFriendNickname(widget.friendName);
    if (mounted) {
      setState(() {
        _localNickname = nick;
      });
    }
  }

  String get _displayName {
    if (_localNickname != null && _localNickname!.trim().isNotEmpty) {
      return _localNickname!.trim();
    }
    return widget.friendName;
  }

  Future<void> _renameFriend() async {
    final controller = TextEditingController(text: _localNickname ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Rename Friend'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Original Name: ${widget.friendName}',
                style: const TextStyle(color: Colors.grey, fontSize: 14),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: controller,
                decoration: const InputDecoration(
                  labelText: 'Nickname',
                  hintText: 'Enter local nickname',
                  border: OutlineInputBorder(),
                ),
                autofocus: true,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: const Text('Save'),
            ),
          ],
        );
      },
    );

    if (result != null) {
      await DatabaseHelper.instance.saveFriendNickname(widget.friendName, result);
      await _loadNickname();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              result.isEmpty
                  ? 'Nickname cleared.'
                  : 'Nickname updated to "$result".',
            ),
          ),
        );
      }
    }
  }

  Future<String?> _fetchFriendPhotoUrl() async {
    try {
      String? uid = widget.peerUserId;
      if (uid == null || uid.isEmpty) {
        uid = await FirebaseDataService.resolvePeerUserIdByFriendName(widget.friendName);
      }
      if (uid == null || uid.isEmpty) {
        return null;
      }
      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .get();
      final data = userDoc.data();
      return data?['photoUrl'] as String?;
    } catch (e) {
      debugPrint('Error fetching friend photo url: $e');
      return null;
    }
  }

  Future<String?> _fetchFriendUpiId() async {
    try {
      String? uid = widget.peerUserId;
      if (uid == null || uid.isEmpty) {
        uid = await FirebaseDataService.resolvePeerUserIdByFriendName(widget.friendName);
      }
      if (uid == null || uid.isEmpty) {
        return null;
      }
      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .get();
      final data = userDoc.data();
      return data?['upiId'] as String?;
    } catch (e) {
      debugPrint('Error fetching friend UPI ID: $e');
      return null;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _transactionsSubscription?.cancel();
    _deletedSubscription?.cancel();
    super.dispose();
  }

  void startRealtimeSync() {
    _transactionsSubscription = FirebaseDataService.transactionsStream().listen(
      (all) {
        if (!mounted) {
          return;
        }
          setState(() {
            personTransactions = all
              .where(
                (t) =>
                    _transactionDisplayFriendName(t).trim().toLowerCase() ==
                    widget.friendName.trim().toLowerCase(),
              )
              .toList();
            isLoading = false;
        });
      },
    );

    _deletedSubscription =
        FirebaseDataService.deletedEntriesStream(widget.friendName).listen((
          deleted,
        ) {
          if (!mounted) {
            return;
          }
          setState(() {
            deletedTransactions = deleted;
            isLoading = false;
          });
        });
  }

  Future<void> loadPersonTransactions() async {
    setState(() {
      isLoading = true;
    });
    final all = await DatabaseHelper.instance.getTransactions();
    final deleted = await DatabaseHelper.instance.getDeletedEntries(
      DatabaseHelper.personIdForName(widget.friendName),
    );
    if (!mounted) {
      return;
    }
      setState(() {
        personTransactions = all
          .where(
            (t) =>
                _transactionDisplayFriendName(t).trim().toLowerCase() ==
                widget.friendName.trim().toLowerCase(),
          )
          .toList()
          .reversed
          .toList();
      deletedTransactions = deleted;
      isLoading = false;
    });
  }

  double get totalGiven {
    double total = 0;
    for (var t in personTransactions) {
      if (_transactionDisplayIsGiven(t)) {
        total += t.amount;
      }
    }
    return total;
  }

  double get totalTaken {
    double total = 0;
    for (var t in personTransactions) {
      if (!_transactionDisplayIsGiven(t)) {
        total += t.amount;
      }
    }
    return total;
  }

  double get netBalance {
    return totalGiven - totalTaken;
  }

  Future<void> _executeSettleAccount() async {
    final transactionsToProcess = List<TransactionModel>.from(personTransactions);

    for (final t in transactionsToProcess) {
      if (t.firebaseId != null) {
        await FirebaseDataService.clearTransaction(t);
      }
      if (t.id != null) {
        await DatabaseHelper.instance.clearEntry(t.id!);
      }
    }

    if (FirebaseAuth.instance.currentUser == null) {
      await loadPersonTransactions();
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Account cleared successfully.')),
      );
    }
  }

  Future<void> _clearAccount() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear Account?'),
        content: const Text(
          'This will move all active transactions with this friend to Deleted Transactions.\n'
          'You can restore them later from Deleted Transactions.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear Account'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    await _executeSettleAccount();
  }

  Future<void> _showUpiSettlementDialog() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Payment Completed?'),
        content: const Text('Did you successfully complete the UPI payment?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Not Now'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Settle Account'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      await _executeSettleAccount();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _launchedUpiPayment) {
      _launchedUpiPayment = false;
      _showUpiSettlementDialog();
    }
  }

  void _showTransactionOptions(BuildContext context, TransactionModel t) {
    final currentUid = FirebaseAuth.instance.currentUser?.uid;
    final canEdit = t.createdBy == null || t.createdBy == currentUid;
    showModalBottomSheet(
      context: context,
      builder: (_) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (canEdit)
                ListTile(
                  leading: const Icon(Icons.edit),
                  title: const Text("Edit"),
                  onTap: () async {
                    Navigator.pop(context);
                    final result = await Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => AddPage(transaction: t)),
                    );
                    if (result == true &&
                        FirebaseAuth.instance.currentUser == null) {
                      loadPersonTransactions();
                    }
                  },
                ),
              ListTile(
                leading: const Icon(Icons.cleaning_services),
                title: const Text("Clear Transaction"),
                onTap: () async {
                  Navigator.pop(context);
                  if (t.firebaseId != null) {
                    await FirebaseDataService.clearTransaction(t);
                  }
                  if (t.id != null) {
                    await DatabaseHelper.instance.clearEntry(t.id!);
                  }
                  if (FirebaseAuth.instance.currentUser == null) {
                    loadPersonTransactions();
                  }
                },
              ),
              ListTile(
                leading: const Icon(Icons.delete, color: Colors.red),
                title: const Text(
                  "Delete",
                  style: TextStyle(color: Colors.red),
                ),
                onTap: () async {
                  Navigator.pop(context);
                  if (t.firebaseId != null) {
                    await FirebaseDataService.deleteTransaction(t);
                  }
                  if (t.id != null) {
                    await DatabaseHelper.instance.deleteTransaction(t.id!);
                  }
                  if (FirebaseAuth.instance.currentUser == null) {
                    loadPersonTransactions();
                  }
                },
              ),
            ],
          ),
        );
      },
    );
  }

  void _showDeletedTransactionOptions(
    BuildContext context,
    DeletedEntryModel entry,
  ) {
    showModalBottomSheet(
      context: context,
      builder: (_) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.restore),
                title: const Text("Restore Transaction"),
                onTap: () async {
                  Navigator.pop(context);
                  if (entry.firebaseId != null) {
                    await FirebaseDataService.restoreDeletedEntry(entry);
                  }
                  if (entry.id != null) {
                    await DatabaseHelper.instance.restoreDeletedEntry(
                      entry.id!,
                    );
                  }
                  if (FirebaseAuth.instance.currentUser == null) {
                    loadPersonTransactions();
                  }
                },
              ),
              ListTile(
                leading: const Icon(Icons.delete_forever, color: Colors.red),
                title: const Text(
                  "Permanently Delete",
                  style: TextStyle(color: Colors.red),
                ),
                onTap: () async {
                  Navigator.pop(context);
                  if (entry.firebaseId != null) {
                    await FirebaseDataService.permanentlyDeleteEntry(entry);
                  }
                  if (entry.id != null) {
                    await DatabaseHelper.instance.permanentlyDeleteEntry(
                      entry.id!,
                    );
                  }
                  if (FirebaseAuth.instance.currentUser == null) {
                    loadPersonTransactions();
                  }
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildTransactionsTable() {
    if (personTransactions.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 20),
        child: Text(
          "No active transactions found.",
          style: TextStyle(fontSize: 16, color: Colors.grey),
        ),
      );
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: DataTable(
          headingRowColor: WidgetStateProperty.all(Colors.grey[850]),
          dataRowMinHeight: 48,
          dataRowMaxHeight: 60,
          horizontalMargin: 12,
          columnSpacing: 24,
          columns: const [
            DataColumn(
              label: Text(
                'Date',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            DataColumn(
              label: Text(
                'Note',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            DataColumn(
              label: Text(
                'Money',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            DataColumn(
              label: Text(
                'Receipt',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ],
          rows: personTransactions.map((t) {
            final isGiven = _transactionDisplayIsGiven(t);
            final rowBgColor = isGiven
                ? Colors.green.withValues(alpha: 0.15)
                : Colors.red.withValues(alpha: 0.15);
            final moneyColor = isGiven ? Colors.green : Colors.red;

            Widget buildCell(
              Widget child, {
              Alignment alignment = Alignment.centerLeft,
            }) {
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => TransactionDetailPage(transaction: t),
                    ),
                  );
                },
                onLongPress: () => _showTransactionOptions(context, t),
                child: Container(
                  alignment: alignment,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: child,
                ),
              );
            }

            return DataRow(
              color: WidgetStateProperty.all(rowBgColor),
              cells: [
                DataCell(buildCell(Text(t.date))),
                DataCell(buildCell(Text(t.note))),
                DataCell(
                  buildCell(
                    Text(
                      "\u20B9${t.amount.toStringAsFixed(0)}",
                      style: TextStyle(
                        color: moneyColor,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    alignment: Alignment.centerRight,
                  ),
                ),
                DataCell(
                  buildCell(
                    (() {
                      final hasLocal = t.receiptPath != null &&
                          t.receiptPath!.isNotEmpty &&
                          File(t.receiptPath!).existsSync();
                      if (hasLocal) {
                        return ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.file(
                            File(t.receiptPath!),
                            width: 64,
                            height: 48,
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => const Icon(
                              Icons.broken_image,
                              size: 20,
                              color: Colors.grey,
                            ),
                          ),
                        );
                      } else if (t.receiptUrl != null && t.receiptUrl!.isNotEmpty) {
                        return ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.network(
                            t.receiptUrl!,
                            width: 64,
                            height: 48,
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => const Icon(
                              Icons.broken_image,
                              size: 20,
                              color: Colors.grey,
                            ),
                          ),
                        );
                      } else {
                        return const Icon(
                          Icons.receipt_long,
                          size: 20,
                          color: Colors.grey,
                        );
                      }
                    })(),
                    alignment: Alignment.center,
                  ),
                ),
              ],
            );
          }).toList(),
        ),
      ),
    );
  }

  Widget _buildDeletedTransactionsSection() {
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      title: const Text(
        "Cleared Transactions",
        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
      ),
      children: [
        if (deletedTransactions.isEmpty)
          const Padding(
            padding: EdgeInsets.only(bottom: 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                "No cleared transactions.",
                style: TextStyle(color: Colors.grey),
              ),
            ),
          )
        else
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: DataTable(
                headingRowColor: WidgetStateProperty.all(Colors.grey[850]),
                dataRowMinHeight: 48,
                dataRowMaxHeight: 60,
                horizontalMargin: 12,
                columnSpacing: 24,
                columns: const [
                  DataColumn(
                    label: Text(
                      'Date',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                  DataColumn(
                    label: Text(
                      'Note',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                  DataColumn(
                    label: Text(
                      'Money',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                  DataColumn(
                    label: Text(
                      'Cleared Date',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
                rows: deletedTransactions.map((entry) {
                  final moneyColor = entry.isGiven ? Colors.green : Colors.red;

                  return DataRow(
                    color: WidgetStateProperty.all(Colors.grey[900]),
                    cells: [
                      DataCell(Text(entry.date)),
                      DataCell(Text(entry.note)),
                      DataCell(
                        Text(
                          "\u20B9${entry.amount.toStringAsFixed(0)}",
                          style: TextStyle(
                            color: moneyColor,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      DataCell(Text(entry.clearedDate)),
                    ],
                    onLongPress: () {
                      _showDeletedTransactionOptions(context, entry);
                    },
                  );
                }).toList(),
              ),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.friendName),
        centerTitle: true,
        actions: [
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'rename_friend') {
                _renameFriend();
              } else if (value == 'clear_account') {
                _clearAccount();
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem<String>(
                value: 'rename_friend',
                child: Text('Rename Friend'),
              ),
              const PopupMenuItem<String>(
                value: 'clear_account',
                child: Text('Clear Account'),
              ),
            ],
          ),
        ],
      ),
      body: isLoading
          ? const Center(child: CircularProgressIndicator())
          : personTransactions.isEmpty && deletedTransactions.isEmpty
          ? const Center(
              child: Text(
                "No transactions found.",
                style: TextStyle(fontSize: 16, color: Colors.grey),
              ),
            )
          : Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  if (_friendPhotoFuture != null)
                    FutureBuilder<String?>(
                      future: _friendPhotoFuture,
                      builder: (context, snapshot) {
                        if (snapshot.connectionState == ConnectionState.done &&
                            snapshot.hasData &&
                            snapshot.data != null &&
                            snapshot.data!.isNotEmpty) {
                          final photoUrl = snapshot.data!;
                          return Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              CircleAvatar(
                                radius: 40,
                                backgroundImage: NetworkImage(photoUrl),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                _displayName,
                                style: const TextStyle(
                                  fontSize: 22,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 16),
                            ],
                          );
                        }
                        return const SizedBox.shrink();
                      },
                    ),
                  // Summary Card for this Person
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.grey[900],
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.grey[850]!),
                    ),
                    child: Column(
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  "Given (+)",
                                  style: TextStyle(
                                    color: Colors.grey,
                                    fontSize: 14,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  "\u20B9${totalGiven.toStringAsFixed(0)}",
                                  style: const TextStyle(
                                    color: Colors.green,
                                    fontSize: 20,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                const Text(
                                  "Taken (-)",
                                  style: TextStyle(
                                    color: Colors.grey,
                                    fontSize: 14,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  "\u20B9${totalTaken.toStringAsFixed(0)}",
                                  style: const TextStyle(
                                    color: Colors.red,
                                    fontSize: 20,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                        const Divider(height: 24, color: Colors.grey),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text(
                              "Net Balance",
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            Text(
                              "${netBalance >= 0 ? '' : '-'}\u20B9${netBalance.abs().toStringAsFixed(0)}",
                              style: TextStyle(
                                color: netBalance >= 0
                                    ? Colors.green
                                    : Colors.red,
                                fontSize: 22,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (netBalance != 0) ...[
                    const SizedBox(height: 16),
                    if (netBalance < 0) ...[
                      if (_friendUpiFuture != null)
                        FutureBuilder<String?>(
                          future: _friendUpiFuture,
                          builder: (context, snapshot) {
                            if (snapshot.connectionState == ConnectionState.waiting) {
                              return const Padding(
                                padding: EdgeInsets.only(top: 8),
                                child: SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                ),
                              );
                            }
                            final upiId = snapshot.data;
                            final hasUpi = upiId != null && upiId.trim().isNotEmpty;
                            return Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                ElevatedButton.icon(
                                  onPressed: hasUpi
                                      ? () async {
                                          final upiUri = Uri.parse(
                                            'upi://pay?pa=${upiId.trim()}&pn=${Uri.encodeComponent(_displayName)}&am=${netBalance.abs().toStringAsFixed(2)}&cu=INR',
                                          );
                                          try {
                                            final launched = await launchUrl(
                                              upiUri,
                                              mode: LaunchMode.externalApplication,
                                            );
                                            if (launched) {
                                              setState(() {
                                                _launchedUpiPayment = true;
                                              });
                                            } else {
                                              if (context.mounted) {
                                                ScaffoldMessenger.of(context).showSnackBar(
                                                  const SnackBar(
                                                    content: Text('No UPI app available to handle this payment.'),
                                                  ),
                                                );
                                              }
                                            }
                                          } catch (e) {
                                            if (context.mounted) {
                                              ScaffoldMessenger.of(context).showSnackBar(
                                                SnackBar(
                                                  content: Text('Could not launch UPI payment: $e'),
                                                ),
                                              );
                                            }
                                          }
                                        }
                                      : null,
                                  icon: const Icon(Icons.payment),
                                  label: const Text("Pay via UPI"),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.blueAccent,
                                    foregroundColor: Colors.white,
                                    minimumSize: const Size(double.infinity, 50),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  hasUpi
                                      ? "UPI ID: $upiId"
                                      : "Friend has not added a UPI ID.",
                                  style: const TextStyle(
                                    color: Colors.grey,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ],
                            );
                          },
                        )
                      else
                        Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            ElevatedButton.icon(
                              onPressed: null,
                              icon: const Icon(Icons.payment),
                              label: const Text("Pay via UPI"),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.blueAccent,
                                foregroundColor: Colors.white,
                                minimumSize: const Size(double.infinity, 50),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            const Text(
                              "UPI ID: Not available offline",
                              style: TextStyle(color: Colors.grey, fontSize: 14),
                            ),
                          ],
                        ),
                    ] else if (netBalance > 0) ...[
                      ElevatedButton.icon(
                        onPressed: () {
                          final amountText = netBalance.toStringAsFixed(0);
                          final message = 'Hi $_displayName,\n\n'
                              'According to Hisab Kitab, you currently owe ₹$amountText.\n\n'
                              'You can settle it whenever convenient.\n\n'
                              'Thanks 🙂';
                          // ignore: deprecated_member_use
                          Share.share(message);
                        },
                        icon: const Icon(Icons.notifications_active),
                        label: const Text("Send Reminder"),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.orangeAccent,
                          foregroundColor: Colors.white,
                          minimumSize: const Size(double.infinity, 50),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                    ],
                  ],
                  const SizedBox(height: 20),
                  Expanded(
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            "Transaction History",
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 10),
                          _buildTransactionsTable(),
                          const SizedBox(height: 16),
                          _buildDeletedTransactionsSection(),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}
