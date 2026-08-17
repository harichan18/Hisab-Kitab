// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:dio/dio.dart';
import 'package:open_file/open_file.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:photo_view/photo_view.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shimmer/shimmer.dart';
import 'package:url_launcher/url_launcher.dart';
import 'database/database_helper.dart';
import 'firebase_options.dart';
import 'models/transaction_model.dart';
import 'models/expense_model.dart';
import 'services/expense_service.dart';
import 'widgets/app_drawer.dart';
import 'screens/daily_expenditure_screen.dart';

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

String? _getCloudinaryPublicId(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return null;
  final pathSegments = uri.pathSegments;
  if (pathSegments.isEmpty) return null;

  final uploadIndex = pathSegments.indexOf('upload');
  if (uploadIndex == -1 || uploadIndex >= pathSegments.length - 1) {
    return null;
  }

  var startIndex = uploadIndex + 1;
  if (startIndex < pathSegments.length &&
      pathSegments[startIndex].startsWith('v') &&
      RegExp(r'^v\d+$').hasMatch(pathSegments[startIndex])) {
    startIndex++;
  }

  if (startIndex >= pathSegments.length) return null;

  final remainingPath = pathSegments.sublist(startIndex).join('/');
  final dotIndex = remainingPath.lastIndexOf('.');
  if (dotIndex != -1) {
    return remainingPath.substring(0, dotIndex);
  }
  return remainingPath;
}

Future<void> _deleteFromCloudinary(String url, {required String scope}) async {
  try {
    final publicId = _getCloudinaryPublicId(url);
    if (publicId == null) {
      _receiptLog(scope, 'Cloudinary delete skipped: unable to extract publicId from $url');
      return;
    }

    _receiptLog(scope, 'Attempting to delete Cloudinary asset publicId=$publicId');
    final uri = Uri.parse('https://api.cloudinary.com/v1_1/dxwf10vjg/image/destroy');
    final response = await http.post(
      uri,
      body: {
        'public_id': publicId,
      },
    );

    _receiptLog(
      scope,
      'Cloudinary destroy response: status=${response.statusCode} body=${response.body}',
    );
  } catch (e, st) {
    _receiptLog(scope, 'Cloudinary delete failed: $e\n$st');
  }
}

class CustomCacheManager {
  static final CustomCacheManager instance = CustomCacheManager._();
  CustomCacheManager._();

  String _generateKey(String input) {
    int hash = 5381;
    for (int i = 0; i < input.length; i++) {
      hash = ((hash << 5) + hash) + input.codeUnitAt(i);
    }
    return hash.abs().toString();
  }

  Future<File?> getFile(String url) async {
    try {
      if (url.isEmpty) return null;
      final cacheDir = await getTemporaryDirectory();
      final key = _generateKey(url);
      final file = File('${cacheDir.path}/$key');
      if (await file.exists()) {
        return file;
      }
      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        await file.writeAsBytes(response.bodyBytes);
        return file;
      }
    } catch (e) {
      debugPrint('Error caching image $url: $e');
    }
    return null;
  }
}

// ---------------------------------------------------------------------------
// AppPrefs — SharedPreferences cache for instant startup reads
// ---------------------------------------------------------------------------
class AppPrefs {
  static SharedPreferences? _prefs;

  static Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
  }

  // Bank balance
  static double getBankBalance() => _prefs?.getDouble('bank_balance') ?? 0.0;
  static Future<void> setBankBalance(double value) async {
    await _prefs?.setDouble('bank_balance', value);
  }

  // Profile completion
  static bool isProfileComplete() => _prefs?.getBool('profile_complete') ?? false;
  static Future<void> setProfileComplete(bool value) async {
    await _prefs?.setBool('profile_complete', value);
  }
}

class CustomCachedImage extends StatefulWidget {
  final String url;
  final double? width;
  final double? height;
  final BoxFit fit;
  final Widget Function(BuildContext, Object, StackTrace?)? errorBuilder;

  const CustomCachedImage({
    super.key,
    required this.url,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.errorBuilder,
  });

  @override
  State<CustomCachedImage> createState() => _CustomCachedImageState();
}

class _CustomCachedImageState extends State<CustomCachedImage> {
  File? _localFile;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadImage();
  }

  @override
  void didUpdateWidget(CustomCachedImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _loadImage();
    }
  }

  Future<void> _loadImage() async {
    if (mounted) setState(() => _isLoading = true);
    final file = await CustomCacheManager.instance.getFile(widget.url);
    if (mounted) {
      setState(() {
        _localFile = file;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_localFile != null) {
      return Image.file(
        _localFile!,
        width: widget.width,
        height: widget.height,
        fit: widget.fit,
        errorBuilder: widget.errorBuilder,
      );
    }
    if (_isLoading) {
      // Shimmer placeholder instead of spinner for a polished loading feel
      return Shimmer.fromColors(
        baseColor: Colors.grey[850] ?? const Color(0xFF212121),
        highlightColor: Colors.grey[700] ?? const Color(0xFF616161),
        child: Container(
          width: widget.width ?? 40,
          height: widget.height ?? 40,
          color: Colors.grey[850],
        ),
      );
    }
    return Image.network(
      widget.url,
      width: widget.width,
      height: widget.height,
      fit: widget.fit,
      errorBuilder: widget.errorBuilder,
    );
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

// ---------------------------------------------------------------------------
// Smooth page route — 175 ms fade + subtle slide, replaces MaterialPageRoute
// ---------------------------------------------------------------------------
PageRouteBuilder<T> _smoothRoute<T>(WidgetBuilder builder) {
  return PageRouteBuilder<T>(
    pageBuilder: (context, animation, secondaryAnimation) => builder(context),
    transitionDuration: const Duration(milliseconds: 175),
    reverseTransitionDuration: const Duration(milliseconds: 150),
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      final fade = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
      final slide = Tween<Offset>(
        begin: const Offset(0, 0.04),
        end: Offset.zero,
      ).animate(fade);
      return FadeTransition(
        opacity: fade,
        child: SlideTransition(position: slide, child: child),
      );
    },
  );
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  // Init SharedPreferences cache before runApp so data is available synchronously
  await AppPrefs.init();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        popupMenuTheme: PopupMenuThemeData(
          color: Colors.grey[900],
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: BorderSide(
              color: Colors.grey[800]?.withValues(alpha: 0.5) ?? const Color(0x80424242),
              width: 1,
            ),
          ),
          elevation: 8,
          shadowColor: Colors.black.withValues(alpha: 0.4),
          surfaceTintColor: Colors.transparent,
          menuPadding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        ),
      ),
      home: const AuthGate(),
    );
  }
}

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  // Validates session in the background — does NOT block UI
  static void _validateSessionBackground(User user) {
    Future<void>(() async {
      try {
        await user.reload();
        final stillValid = FirebaseAuth.instance.currentUser != null;
        if (!stillValid) {
          FirebaseDataService.clearCachedSessionData();
          await GoogleSignIn().signOut();
          await FirebaseAuth.instance.signOut();
        }
      } on FirebaseAuthException catch (e) {
        const invalidCodes = {
          'user-not-found',
          'user-disabled',
          'invalid-user-token',
          'user-token-expired',
        };
        if (invalidCodes.contains(e.code)) {
          FirebaseDataService.clearCachedSessionData();
          await GoogleSignIn().signOut();
          await FirebaseAuth.instance.signOut();
        }
      } catch (_) {
        // Network error: keep user signed in, will retry next launch
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        // While stream is initialising show the branded splash — no spinner
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const SplashScreen();
        }

        if (snapshot.hasData) {
          // Kick off background session check without blocking UI
          _validateSessionBackground(snapshot.data!);
          return ProfileCompletionGate(child: const SplashScreen());
        }

        return const LoginPage();
      },
    );
  }
}

class ProfileCompletionGate extends StatelessWidget {
  final Widget child;
  const ProfileCompletionGate({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return const LoginPage();
    }

    // If cache says profile is complete, show child immediately — no Firestore wait
    if (AppPrefs.isProfileComplete()) {
      // Still listen in background to catch profile becoming incomplete
      _listenProfileCompletionBackground(user.uid);
      return child;
    }

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .snapshots(),
      builder: (context, snapshot) {
        // Show child (SplashScreen) while waiting — no blocking spinner
        if (snapshot.connectionState == ConnectionState.waiting) {
          return child;
        }

        if (snapshot.hasError) {
          // On error, fall through to show child rather than blocking
          return child;
        }

        final data = snapshot.data?.data();
        if (data == null) {
          return child;
        }

        final upiId = data['upiId'] as String? ?? '';
        final mobileNumber = data['mobileNumber'] as String? ?? '';

        final isUpiValid = upiId.contains('@');
        final digitsCount = mobileNumber.replaceAll(RegExp(r'\D'), '').length;
        final isMobileValid = digitsCount >= 10;

        final isComplete = upiId.isNotEmpty &&
            mobileNumber.isNotEmpty &&
            isUpiValid &&
            isMobileValid;

        // Update cache for next launch
        AppPrefs.setProfileComplete(isComplete);

        if (!isComplete) {
          return CompleteProfilePage(
            currentUpiId: upiId,
            currentMobileNumber: mobileNumber,
          );
        }

        return child;
      },
    );
  }

  static void _listenProfileCompletionBackground(String uid) {
    FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .snapshots()
        .take(1)
        .listen((snap) {
      final data = snap.data();
      if (data == null) return;
      final upiId = data['upiId'] as String? ?? '';
      final mobile = data['mobileNumber'] as String? ?? '';
      final isComplete = upiId.contains('@') &&
          mobile.replaceAll(RegExp(r'\D'), '').length >= 10;
      AppPrefs.setProfileComplete(isComplete);
    });
  }
}

class CompleteProfilePage extends StatefulWidget {
  final String currentUpiId;
  final String currentMobileNumber;

  const CompleteProfilePage({
    super.key,
    required this.currentUpiId,
    required this.currentMobileNumber,
  });

  @override
  State<CompleteProfilePage> createState() => _CompleteProfilePageState();
}

class _CompleteProfilePageState extends State<CompleteProfilePage> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _upiController;
  late final TextEditingController _mobileController;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _upiController = TextEditingController(text: widget.currentUpiId);
    _mobileController = TextEditingController(text: widget.currentMobileNumber);
  }

  @override
  void dispose() {
    _upiController.dispose();
    _mobileController.dispose();
    super.dispose();
  }

  Future<void> _saveProfile() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    setState(() {
      _isSaving = true;
    });

    try {
      await FirebaseFirestore.instance.collection('users').doc(user.uid).update({
        'upiId': _upiController.text.trim(),
        'mobileNumber': _mobileController.text.trim(),
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to complete profile: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  Future<void> _logout() async {
    try {
      FirebaseDataService.clearCachedSessionData();
      await GoogleSignIn().signOut();
      await FirebaseAuth.instance.signOut();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Logout failed: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Scaffold(
        appBar: AppBar(
          title: const Text("Complete Profile"),
          centerTitle: true,
          automaticallyImplyLeading: false,
        ),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 16),
                  const Icon(
                    Icons.account_circle,
                    size: 96,
                    color: Colors.amber,
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    "Profile Setup Required",
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    "To use Hisab Kitab, please complete your profile by providing your UPI ID and Mobile Number. This information is required for settlements and payment reminders.",
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey),
                  ),
                  const SizedBox(height: 32),
                  const Text(
                    "UPI ID",
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  TextFormField(
                    key: const ValueKey('complete_upi_field'),
                    controller: _upiController,
                    decoration: const InputDecoration(
                      hintText: "Enter UPI ID (e.g., name@okbank)",
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 12,
                      ),
                    ),
                    validator: (value) {
                      if (value == null || value.trim().isEmpty) {
                        return "UPI ID is required";
                      }
                      if (!value.contains('@')) {
                        return "UPI ID must contain '@'";
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    "Mobile Number",
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  TextFormField(
                    key: const ValueKey('complete_mobile_field'),
                    controller: _mobileController,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(
                      hintText: "Enter mobile number (e.g., 9876543210)",
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 12,
                      ),
                    ),
                    validator: (value) {
                      if (value == null || value.trim().isEmpty) {
                        return "Mobile number is required";
                      }
                      final digitsCount = value.replaceAll(RegExp(r'\D'), '').length;
                      if (digitsCount < 10) {
                        return "Mobile number must contain at least 10 digits";
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 40),
                  SizedBox(
                    height: 52,
                    child: ElevatedButton(
                      key: const ValueKey('complete_save_btn'),
                      onPressed: _isSaving ? null : _saveProfile,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.amber,
                        foregroundColor: Colors.black,
                      ),
                      child: _isSaving
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.black,
                              ),
                            )
                          : const Text("Save & Continue"),
                    ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    height: 52,
                    child: OutlinedButton.icon(
                      key: const ValueKey('complete_logout_btn'),
                      onPressed: _isSaving ? null : _logout,
                      icon: const Icon(Icons.logout),
                      label: const Text("Logout"),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.redAccent,
                        side: const BorderSide(color: Colors.redAccent),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
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
        final existingMobileNumber = existingDoc.data()?['mobileNumber'] as String?;
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
          'mobileNumber': existingMobileNumber ?? '',
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
      return error.message ?? 'Authentication failed. Please try again.';
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
    // 800ms: enough to appreciate the logo, fast enough to feel instant
    await Future.delayed(const Duration(milliseconds: 800));
    if (mounted) {
      Navigator.pushReplacement(
        context,
        _smoothRoute((_) => const HomePage()),
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
  bool _isSavingMobile = false;
  final TextEditingController _mobileController = TextEditingController();
  bool _mobileInitialized = false;

  @override
  void dispose() {
    _upiController.dispose();
    _mobileController.dispose();
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
      'mobileNumber': '',
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

    final upi = _upiController.text.trim();
    if (upi.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('UPI ID cannot be empty.')),
      );
      return;
    }
    if (!upi.contains('@')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('UPI ID must contain "@".')),
      );
      return;
    }

    setState(() {
      _isSavingUpi = true;
    });

    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .update({'upiId': upi});

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

  Future<void> _saveMobile() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final mobile = _mobileController.text.trim();
    if (mobile.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Mobile number cannot be empty.')),
      );
      return;
    }
    final digitsCount = mobile.replaceAll(RegExp(r'\D'), '').length;
    if (digitsCount < 10) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Mobile number must contain at least 10 digits.')),
      );
      return;
    }

    setState(() {
      _isSavingMobile = true;
    });

    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .update({'mobileNumber': mobile});

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Mobile number updated successfully.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to update mobile number: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSavingMobile = false;
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
          if (!_mobileInitialized) {
            _mobileController.text = data['mobileNumber'] as String? ?? '';
            _mobileInitialized = true;
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
                            backgroundColor: Colors.grey[800],
                            child: photoUrl == null || photoUrl.isEmpty
                                ? const Icon(Icons.person, size: 56)
                                : ClipOval(
                                    child: CustomCachedImage(
                                      url: photoUrl,
                                      width: 112,
                                      height: 112,
                                      fit: BoxFit.cover,
                                    ),
                                  ),
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
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      OutlinedButton.icon(
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: friendCode));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Friend code copied to clipboard!')),
                          );
                        },
                        icon: const Icon(Icons.copy_rounded, size: 16),
                        label: const Text("Copy Code"),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.amber,
                          side: const BorderSide(color: Colors.amber),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      OutlinedButton.icon(
                        onPressed: () {
                          SharePlus.instance.share(
                            ShareParams(
                              text: "My Hisab Kitab Friend Code is: $friendCode",
                            ),
                          );
                        },
                        icon: const Icon(Icons.share_rounded, size: 16),
                        label: const Text("Share Code"),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.amber,
                          side: const BorderSide(color: Colors.amber),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                      ),
                    ],
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
                  const SizedBox(height: 24),
                  const Text(
                    "Mobile Number",
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: _mobileController,
                          keyboardType: TextInputType.phone,
                          decoration: const InputDecoration(
                            hintText: "Enter mobile number (e.g., 9876543210)",
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
                        onPressed: _isSavingMobile ? null : _saveMobile,
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 16,
                          ),
                          backgroundColor: Colors.amber,
                          foregroundColor: Colors.black,
                        ),
                        child: _isSavingMobile
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
                            backgroundColor: Colors.grey[800],
                            child: photoUrl == null || photoUrl.isEmpty
                                ? const Icon(Icons.person)
                                : ClipOval(
                                    child: CustomCachedImage(
                                      url: photoUrl,
                                      width: 40,
                                      height: 40,
                                      fit: BoxFit.cover,
                                    ),
                                  ),
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
    final cached = await DatabaseHelper.instance.getCachedFriendByName(friendName);
    if (cached != null) {
      final uid = cached['friendUid'] as String?;
      if (uid != null && uid.isNotEmpty) {
        return uid;
      }
    }

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
      'receiptPath': transaction.receiptPath ?? FieldValue.delete(),
      'receiptUrl': transaction.receiptUrl ?? FieldValue.delete(),
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
      'receiptPath': transaction.receiptPath ?? FieldValue.delete(),
      'receiptUrl': transaction.receiptUrl ?? FieldValue.delete(),
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

  static CollectionReference<Map<String, dynamic>>? get settlementsRef =>
      _userRef?.collection('settlements');

  static Future<void> recordSettlement({
    required String friendName,
    required double amount,
  }) async {
    final ref = settlementsRef;
    if (ref == null) return;

    final docRef = ref.doc();
    final user = _user;
    final userEmail = user?.email ?? '';
    final settledBy = _currentUserDisplayName();
    final createdBy = currentUid ?? '';

    await docRef.set({
      'settlementId': docRef.id,
      'friendName': friendName,
      'amount': amount,
      'settledBy': settledBy,
      'settledAt': Timestamp.now(),
      'createdBy': createdBy,
      'userEmail': userEmail,
    });
  }

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

  static Stream<List<DeletedEntryModel>> allDeletedEntriesStream() {
    final ref = deletedRef;
    if (ref == null) {
      return const Stream.empty();
    }
    return ref.snapshots().map(
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
    this.existingReceiptPath,
    this.existingReceiptUrl,
    this.isReceiptRemoved = false,
    this.onRemoveExisting,
  });

  final XFile? receiptImage;
  final double receiptUploadProgress;
  final void Function(ImageSource source) onPick;
  final VoidCallback onClear;
  final String? existingReceiptPath;
  final String? existingReceiptUrl;
  final bool isReceiptRemoved;
  final VoidCallback? onRemoveExisting;

  Widget _buildPickButtons() {
    return Row(
      children: [
        Expanded(
          child: OutlinedButton(
            onPressed: () => onPick(ImageSource.camera),
            child: const FittedBox(
              fit: BoxFit.scaleDown,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.camera_alt),
                  SizedBox(width: 8),
                  Text(
                    "Camera",
                    maxLines: 1,
                    softWrap: false,
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: OutlinedButton(
            onPressed: () => onPick(ImageSource.gallery),
            child: const FittedBox(
              fit: BoxFit.scaleDown,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.photo_library),
                  SizedBox(width: 8),
                  Text(
                    "Gallery",
                    maxLines: 1,
                    softWrap: false,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPreview() {
    if (receiptImage != null) {
      return SizedBox(
        height: 140,
        width: double.infinity,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Image.file(
            File(receiptImage!.path),
            fit: BoxFit.cover,
          ),
        ),
      );
    } else {
      final hasLocal = existingReceiptPath != null &&
          existingReceiptPath!.isNotEmpty &&
          File(existingReceiptPath!).existsSync();
      return SizedBox(
        height: 140,
        width: double.infinity,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: hasLocal
              ? Image.file(
                  File(existingReceiptPath!),
                  fit: BoxFit.cover,
                )
              : CustomCachedImage(
                  url: existingReceiptUrl!,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => const Center(
                    child: Icon(Icons.broken_image, size: 40, color: Colors.grey),
                  ),
                ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasReceipt = receiptImage != null ||
        (((existingReceiptPath != null && existingReceiptPath!.isNotEmpty) ||
          (existingReceiptUrl != null && existingReceiptUrl!.isNotEmpty)) &&
         !isReceiptRemoved);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          "Receipt",
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        if (hasReceipt) ...[
          _buildPreview(),
          const SizedBox(height: 12),
          _buildPickButtons(),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            key: const ValueKey('remove_receipt_btn'),
            onPressed: () {
              if (receiptImage != null) {
                onClear();
              } else {
                onRemoveExisting?.call();
              }
            },
            icon: const Icon(Icons.delete, color: Colors.redAccent),
            label: const Text(
              "Remove Receipt",
              style: TextStyle(color: Colors.redAccent),
            ),
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: Colors.redAccent),
              minimumSize: const Size(double.infinity, 44),
            ),
          ),
        ] else ...[
          _buildPickButtons(),
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

class InstallPermissionService {
  static const MethodChannel _channel = MethodChannel('hisab_kitab/install_permission');

  static Future<bool> canRequestPackageInstalls() async {
    try {
      final bool? result = await _channel.invokeMethod<bool>('canRequestPackageInstalls');
      return result ?? false;
    } on PlatformException catch (e) {
      debugPrint('Error checking canRequestPackageInstalls: $e');
      return false;
    }
  }

  static Future<bool> openInstallPermissionSettings() async {
    try {
      final bool? result = await _channel.invokeMethod<bool>('openInstallPermissionSettings');
      return result ?? false;
    } on PlatformException catch (e) {
      debugPrint('Error opening install permission settings: $e');
      return false;
    }
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  static bool _hasCheckedUpdate = false;
  List<TransactionModel> transactions = [];
  List<FirestoreFriendProfile> firestoreFriends = [];
  Map<String, String> localNicknames = {};
  Map<String, Map<String, dynamic>> cachedFriendProfiles = {};
  DateTime? _lastFriendsSyncTime;
  DateTime? _lastDashboardRefreshTime;
  bool _isSyncingFriends = false;
  String? _pendingApkPath;
  bool _isCheckingInstallPermission = false;
  String _selectedFilter = 'All';
  // True while the very first data load is in progress — shows shimmer
  bool _isInitialLoad = true;

  List<ExpenseModel> _homeExpenses = [];
  StreamSubscription<List<ExpenseModel>>? _homeExpensesSubscription;

  double get todayHomeSpending {
    final now = DateTime.now();
    return _homeExpenses
        .where((e) => e.expenseDate.year == now.year &&
                      e.expenseDate.month == now.month &&
                      e.expenseDate.day == now.day)
        .fold(0.0, (acc, e) => acc + e.amount);
  }

  double get monthHomeSpending {
    final now = DateTime.now();
    return _homeExpenses
        .where((e) => e.expenseDate.year == now.year &&
                      e.expenseDate.month == now.month)
        .fold(0.0, (acc, e) => acc + e.amount);
  }

  Future<void> loadExpenses() async {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? 'offline_user';
    final data = await ExpenseService.getExpensesOnce(uid);
    if (!mounted) return;
    debugPrint('[Home] [SQLite Load] Reloaded personal expenses: ${data.length} items');
    setState(() {
      _homeExpenses = data;
    });
  }

  Future<void> loadLocalNicknames() async {
    final nicks = await DatabaseHelper.instance.getAllNicknames();
    if (!mounted) return;
    setState(() {
      localNicknames = nicks;
    });
  }
  // Pre-load from cache for instant first render, SQLite will refine shortly after
  double bankBalance = AppPrefs.getBankBalance();
  double _oldBankBalance = AppPrefs.getBankBalance();
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
    WidgetsBinding.instance.addObserver(this);
    initializeHome();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _transactionsSubscription?.cancel();
    _bankBalanceSubscription?.cancel();
    _user1FriendsSubscription?.cancel();
    _user2FriendsSubscription?.cancel();
    _homeExpensesSubscription?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (_isCheckingInstallPermission && _pendingApkPath != null) {
        _isCheckingInstallPermission = false;
        _handleReturnFromInstallSettings();
      }
    }
  }

  Future<void> _handleReturnFromInstallSettings() async {
    final hasPermission = await InstallPermissionService.canRequestPackageInstalls();
    if (!mounted) return;

    if (hasPermission) {
      final apkPath = _pendingApkPath;
      _pendingApkPath = null;
      if (apkPath != null) {
        await _installApk(apkPath);
      }
    } else {
      _pendingApkPath = null;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Install permission was denied. Cannot install update.')),
      );
    }
  }

  Future<void> loadData() async {
    await loadLocalNicknames();
    await Future.wait([
      loadTransactions(),
      loadBankBalance(),
      loadCachedFriendProfiles(),
      loadExpenses(),
    ]);

    if (FirebaseAuth.instance.currentUser != null) {
      _loadDataFirestoreBackground();
    }
    debugPrint('[Home] total friends loaded: ${visibleFriends.length}');
  }

  Future<void> _loadDataFirestoreBackground() async {
    await FirebaseDataService.migrateSQLiteCacheToFirestoreIfNeeded();
    await loadFirestoreFriends();
  }

  Future<void> loadCachedFriendProfiles() async {
    final cached = await DatabaseHelper.instance.getAllCachedFriends();
    final map = {
      for (final row in cached)
        (row['friendUid'] as String): row
    };
    if (mounted) {
      setState(() {
        cachedFriendProfiles = map;
      });
    }
  }

  Future<void> _installApk(String apkPath) async {
    try {
      final apkFile = File(apkPath);
      final fileExists = await apkFile.exists();
      print('APK exists for install: $fileExists');
      if (!fileExists) {
        throw Exception('APK file does not exist.');
      }

      final fileSize = await apkFile.length();
      print('APK file size: $fileSize bytes');
      if (fileSize == 0) {
        throw Exception('APK file is empty.');
      }

      print('Launching installer: $apkPath');
      final result = await OpenFile.open(apkPath);
      print('OpenFile result: ${result.type}');
      print('OpenFile message: ${result.message}');

      if (result.type != ResultType.done) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Installation failed: ${result.message}')),
          );

          showDialog(
            context: context,
            builder: (errorContext) => AlertDialog(
              title: const Text('Installation Failed'),
              content: Text(
                'Could not launch APK installer.\n\n'
                'Error: ${result.type}\n'
                'Details: ${result.message}',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(errorContext),
                  child: const Text('OK'),
                ),
              ],
            ),
          );
        }
      }
    } catch (e) {
      print('APK install exception: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to install update: $e')),
        );
      }
    }
  }

  Future<void> _downloadAndInstallApk(String url) async {
    if (url.isEmpty || url.toLowerCase() == 'pending') {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Update URL is not available.')),
      );
      return;
    }

    double progress = 0.0;
    StateSetter? progressStateSetter;
    BuildContext? progressDialogContext;
    bool isProgressDialogClosed = false;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        progressDialogContext = dialogContext;
        return PopScope(
          canPop: false,
          child: StatefulBuilder(
            builder: (context, setState) {
              progressStateSetter = setState;
              return AlertDialog(
                title: const Text('Downloading Update'),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    LinearProgressIndicator(value: progress),
                    const SizedBox(height: 16),
                    Text('${(progress * 100).toStringAsFixed(0)}%'),
                    const SizedBox(height: 8),
                    const Text('Downloading APK...', style: TextStyle(color: Colors.grey, fontSize: 12)),
                  ],
                ),
              );
            },
          ),
        );
      },
    );

    String apkPath = '';
    try {
      print('APK download started');
      final tempDir = await getTemporaryDirectory();
      apkPath = '${tempDir.path}/hisab_kitab_update.apk';
      print('APK saved at: $apkPath');

      final apkFile = File(apkPath);
      if (await apkFile.exists()) {
        await apkFile.delete();
      }

      final dio = Dio();
      await dio.download(
        url,
        apkPath,
        onReceiveProgress: (received, total) {
          if (total != -1) {
            final currentProgress = received / total;
            if (progressStateSetter != null) {
              progressStateSetter!(() {
                progress = currentProgress;
              });
            }
          }
        },
      );
      print('APK download completed');

      if (progressDialogContext != null && progressDialogContext!.mounted && !isProgressDialogClosed) {
        isProgressDialogClosed = true;
        Navigator.pop(progressDialogContext!);
      }

      final fileExists = await apkFile.exists();
      print('APK exists: $fileExists');
      if (!fileExists) {
        throw Exception('Downloaded APK file does not exist.');
      }

      final fileSize = await apkFile.length();
      print('APK file size: $fileSize bytes');
      if (fileSize == 0) {
        throw Exception('Downloaded APK file is empty.');
      }

      final hasPermission = await InstallPermissionService.canRequestPackageInstalls();
      if (hasPermission) {
        await _installApk(apkPath);
      } else {
        if (mounted) {
          _pendingApkPath = apkPath;
          showDialog(
            context: context,
            barrierDismissible: false,
            builder: (dialogContext) {
              return AlertDialog(
                title: const Text('Permission Required'),
                content: const Text("Please allow 'Install unknown apps' for Hisab Kitab to continue the update."),
                actions: [
                  TextButton(
                    onPressed: () {
                      Navigator.pop(dialogContext);
                      _pendingApkPath = null;
                      _isCheckingInstallPermission = false;
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Install permission was denied. Cannot install update.')),
                      );
                    },
                    child: const Text('Cancel'),
                  ),
                  TextButton(
                    onPressed: () async {
                      Navigator.pop(dialogContext);
                      _isCheckingInstallPermission = true;
                      await InstallPermissionService.openInstallPermissionSettings();
                    },
                    child: const Text('Settings'),
                  ),
                ],
              );
            },
          );
        }
      }
    } catch (e) {
      if (progressDialogContext != null && progressDialogContext!.mounted && !isProgressDialogClosed) {
        isProgressDialogClosed = true;
        Navigator.pop(progressDialogContext!);
      }
      print('APK download/install exception: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to download or install update: $e')),
        );
      }
    }
  }

  Future<void> _checkAppUpdate() async {
    try {
      final doc = await FirebaseFirestore.instance.collection('app_config').doc('updates').get();
      if (!doc.exists || doc.data() == null) return;
      final data = doc.data() ?? {};
      final latestVersion = data['latestVersion'] as int? ?? 0;
      final versionName = data['versionName'] as String? ?? '';
      final changelog = data['changelog'] as String? ?? '';
      final forceUpdate = data['forceUpdate'] as bool? ?? false;
      final apkUrl = data['apkUrl'] as String? ?? '';

      final packageInfo = await PackageInfo.fromPlatform();
      final currentBuildNumber = int.tryParse(packageInfo.buildNumber) ?? 0;

      if (latestVersion > currentBuildNumber) {
        if (!mounted) return;
        showDialog(
          context: context,
          barrierDismissible: !forceUpdate,
          builder: (dialogContext) {
            return PopScope(
              canPop: !forceUpdate,
              child: AlertDialog(
                title: const Text('Update Available'),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Version: $versionName', style: const TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 12),
                    Text(changelog),
                  ],
                ),
                actions: [
                  if (!forceUpdate)
                    TextButton(
                      onPressed: () => Navigator.pop(dialogContext),
                      child: const Text('Later'),
                    ),
                  TextButton(
                    onPressed: () {
                      Navigator.pop(dialogContext);
                      _downloadAndInstallApk(apkUrl);
                    },
                    child: const Text('Update'),
                  ),
                ],
              ),
            );
          },
        );
      }
    } catch (e) {
      debugPrint('Error checking app update: $e');
    }
  }

  Future<void> initializeHome() async {
    await loadData();
    if (mounted) {
      setState(() => _isInitialLoad = false); // reveal real content
      startRealtimeSync();
      if (!_hasCheckedUpdate && FirebaseAuth.instance.currentUser != null) {
        _hasCheckedUpdate = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _checkAppUpdate();
        });
      }
    }
  }

  void startRealtimeSync() {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) {
      return;
    }

    _homeExpensesSubscription = ExpenseService.expensesStream(currentUser.uid).listen((data) {
      if (mounted) {
        setState(() {
          _homeExpenses = data;
        });
      }
    });

    _transactionsSubscription = FirebaseDataService.transactionsStream().listen(
      (data) {
        if (!mounted) {
          return;
        }
        bool changed = transactions.length != data.length;
        if (!changed) {
          for (int i = 0; i < transactions.length; i++) {
            if (transactions[i].id != data[i].id ||
                transactions[i].firebaseId != data[i].firebaseId ||
                transactions[i].amount != data[i].amount ||
                transactions[i].note != data[i].note ||
                transactions[i].date != data[i].date ||
                transactions[i].iGave != data[i].iGave ||
                transactions[i].receiptPath != data[i].receiptPath ||
                transactions[i].receiptUrl != data[i].receiptUrl) {
              changed = true;
              break;
            }
          }
        }
        if (changed) {
          setState(() {
            transactions = data;
          });
          debugPrint('[Home] [Firestore Stream] transactions snapshot loaded: ${data.length} items');
          debugPrint('[Home] total friends loaded: ${visibleFriends.length}');
        }
      },
    );

    _bankBalanceSubscription = FirebaseDataService.bankBalanceStream().listen((
      amount,
    ) {
      if (!mounted) {
        return;
      }
      if (bankBalance != amount) {
        setState(() {
          _oldBankBalance = bankBalance;
          bankBalance = amount;
        });
        debugPrint('[Home] [Firestore Stream] bank balance snapshot loaded: $amount');
      }
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
    final reversedData = data.reversed.toList();
    bool changed = transactions.length != reversedData.length;
    if (!changed) {
      for (int i = 0; i < transactions.length; i++) {
        if (transactions[i].id != reversedData[i].id ||
            transactions[i].amount != reversedData[i].amount ||
            transactions[i].note != reversedData[i].note ||
            transactions[i].date != reversedData[i].date ||
            transactions[i].iGave != reversedData[i].iGave ||
            transactions[i].receiptPath != reversedData[i].receiptPath) {
          changed = true;
          break;
        }
      }
    }
    if (changed) {
      debugPrint('[Home] [SQLite Load] Overwriting transactions list: ${reversedData.length} items');
      setState(() {
        transactions = reversedData;
      });
    }
  }

  Future<void> loadBankBalance() async {
    final amount = await DatabaseHelper.instance.getBankBalance();
    if (!mounted) {
      return;
    }
    if (bankBalance != amount) {
      debugPrint('[Home] [SQLite Load] Overwriting bankBalance: $amount');
      setState(() {
        _oldBankBalance = bankBalance;
        bankBalance = amount;
      });
    }
  }

  Future<void> refreshDashboard() async {
    final now = DateTime.now();
    if (_lastDashboardRefreshTime != null &&
        now.difference(_lastDashboardRefreshTime!) < const Duration(seconds: 1)) {
      debugPrint('[Home] Dashboard refreshed very recently. Skipping duplicate reload.');
      return;
    }
    _lastDashboardRefreshTime = now;

    await loadLocalNicknames();
    if (FirebaseAuth.instance.currentUser == null) {
      await Future.wait([loadTransactions(), loadBankBalance()]);
    } else {
      await loadFirestoreFriends();
    }
  }

  Future<void> loadFirestoreFriends() async {
    final cachedRows = await DatabaseHelper.instance.getAllCachedFriends();
    final cachedFriends = cachedRows.map((row) {
      return FirestoreFriendProfile(
        uid: row['friendUid'] as String,
        name: row['friendName'] as String? ?? '',
        email: row['email'] as String? ?? '',
        friendCode: row['friendCode'] as String? ?? '',
      );
    }).toList();

    if (cachedFriends.isNotEmpty && mounted) {
      setState(() {
        firestoreFriends = cachedFriends;
      });
    }

    _syncFirestoreFriendsBackground();
  }

  Future<void> _syncFirestoreFriendsBackground() async {
    if (_isSyncingFriends) {
      debugPrint('[Home] Already syncing friends. Skipping.');
      return;
    }

    final now = DateTime.now();
    if (_lastFriendsSyncTime != null &&
        now.difference(_lastFriendsSyncTime!) < const Duration(seconds: 2)) {
      debugPrint('[Home] Friends synced very recently. Skipping duplicate reload.');
      return;
    }
    _lastFriendsSyncTime = now;
    _isSyncingFriends = true;

    try {
      final currentUser = FirebaseAuth.instance.currentUser;
      if (currentUser == null) return;
      final currentUid = currentUser.uid;

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

      bool cacheChanged = false;

      final tasks = friendUids.map((friendUid) async {
        final cached = await DatabaseHelper.instance.getCachedFriendByUid(friendUid);
        try {
          final userDoc = await FirebaseFirestore.instance
              .collection('users')
              .doc(friendUid)
              .get();
          final data = userDoc.data();
          if (userDoc.exists && data != null) {
            final friendProfile = FirestoreFriendProfile(
              uid: data['uid'] as String? ?? friendUid,
              name: data['name'] as String? ?? '',
              email: data['email'] as String? ?? '',
              friendCode: data['friendCode'] as String? ?? '',
            );

            final photoUrl = data['photoUrl'] as String? ?? '';
            final upiId = data['upiId'] as String? ?? '';
            final mobileNumber = data['mobileNumber'] as String? ?? '';

            if (cached == null ||
                cached['friendName'] != friendProfile.name ||
                cached['email'] != friendProfile.email ||
                cached['friendCode'] != friendProfile.friendCode ||
                cached['photoUrl'] != photoUrl ||
                cached['upiId'] != upiId ||
                cached['mobileNumber'] != mobileNumber) {

              await DatabaseHelper.instance.saveCachedFriend(
                friendUid: friendUid,
                friendName: friendProfile.name,
                email: friendProfile.email,
                friendCode: friendProfile.friendCode,
                photoUrl: photoUrl,
                upiId: upiId,
                mobileNumber: mobileNumber,
              );
              cacheChanged = true;
            }
            return friendProfile;
          }
        } catch (e) {
          debugPrint('Error syncing friend $friendUid: $e');
        }

        if (cached != null) {
          return FirestoreFriendProfile(
            uid: friendUid,
            name: cached['friendName'] as String? ?? '',
            email: cached['email'] as String? ?? '',
            friendCode: cached['friendCode'] as String? ?? '',
          );
        }
        return null;
      }).toList();

      final results = await Future.wait(tasks);
      final syncedFriends = results.whereType<FirestoreFriendProfile>().toList();

      if (syncedFriends.isNotEmpty) {
        if (mounted) {
          bool listsDifferent = firestoreFriends.length != syncedFriends.length;
          if (!listsDifferent) {
            for (int i = 0; i < firestoreFriends.length; i++) {
              if (firestoreFriends[i].uid != syncedFriends[i].uid ||
                  firestoreFriends[i].name != syncedFriends[i].name) {
                listsDifferent = true;
                break;
              }
            }
          }
          if (listsDifferent || cacheChanged) {
            setState(() {
              firestoreFriends = syncedFriends;
            });
            if (cacheChanged) {
              await loadCachedFriendProfiles();
            }
          }
        }
      }
    } finally {
      _isSyncingFriends = false;
    }
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
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey[950],
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (bottomSheetContext) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey[700],
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 20),
                const Text(
                  "Adjust Bank Balance",
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 16),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.grey[900],
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Colors.grey[800]!),
                  ),
                  child: Column(
                    children: [
                      const Text(
                        "CURRENT BANK BALANCE",
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.1,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        "₹${formatAmount(bankBalance)}",
                        style: const TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                OlivePremiumButton(
                  icon: Icons.add_rounded,
                  title: "Add Money",
                  description: "Increase your current bank balance manually",
                  onTap: () {
                    Navigator.pop(bottomSheetContext);
                    _showAdjustmentSheet(isDeduction: false);
                  },
                ),
                const SizedBox(height: 16),
                OlivePremiumButton(
                  icon: Icons.remove_rounded,
                  title: "Deduct Money",
                  description: "Decrease your current bank balance manually",
                  onTap: () {
                    Navigator.pop(bottomSheetContext);
                    _showAdjustmentSheet(isDeduction: true);
                  },
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showAdjustmentSheet({required bool isDeduction}) {
    final controller = TextEditingController();
    final formKey = GlobalKey<FormState>();

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey[950],
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (sbContext, setSheetState) {
            final enteredText = controller.text.trim();
            final enteredAmount = double.tryParse(enteredText) ?? 0.0;
            final double previewBalance = isDeduction
                ? (bankBalance - enteredAmount)
                : (bankBalance + enteredAmount);

            return Padding(
              padding: EdgeInsets.only(
                left: 24,
                right: 24,
                top: 16,
                bottom: MediaQuery.of(sheetContext).viewInsets.bottom + 24,
              ),
              child: SafeArea(
                child: Form(
                  key: formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Center(
                        child: Container(
                          width: 40,
                          height: 4,
                          decoration: BoxDecoration(
                            color: Colors.grey[700],
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                      Text(
                        isDeduction ? "Deduct Money" : "Add Money",
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(
                            child: Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: Colors.grey[900],
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: Colors.grey[800]!),
                              ),
                              child: Column(
                                children: [
                                  const Text(
                                    "Current Balance",
                                    style: TextStyle(fontSize: 11, color: Colors.grey),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    "₹${formatAmount(bankBalance)}",
                                    style: const TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.white,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          const Icon(Icons.arrow_forward_rounded, color: Colors.grey),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: isDeduction && previewBalance < 0
                                    ? Colors.redAccent.withValues(alpha: 0.1)
                                    : const Color(0xFF9EA98F).withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: isDeduction && previewBalance < 0
                                      ? Colors.redAccent.withValues(alpha: 0.3)
                                      : const Color(0xFF9EA98F).withValues(alpha: 0.3),
                                ),
                              ),
                              child: Column(
                                children: [
                                  const Text(
                                    "New Balance Preview",
                                    style: TextStyle(fontSize: 11, color: Colors.grey),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    "₹${formatAmount(previewBalance)}",
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                      color: isDeduction && previewBalance < 0
                                          ? Colors.redAccent
                                          : const Color(0xFF9EA98F),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                      TextFormField(
                        controller: controller,
                        autofocus: true,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        style: const TextStyle(color: Colors.white, fontSize: 18),
                        decoration: InputDecoration(
                          labelText: "Amount to ${isDeduction ? 'deduct' : 'add'}",
                          labelStyle: const TextStyle(color: Colors.grey),
                          prefixText: "\u20B9 ",
                          prefixStyle: const TextStyle(color: Colors.white, fontSize: 18),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(color: Colors.grey[800]!),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: const BorderSide(color: Color(0xFF9EA98F), width: 2),
                          ),
                          errorBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: const BorderSide(color: Colors.redAccent),
                          ),
                          focusedErrorBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: const BorderSide(color: Colors.redAccent, width: 2),
                          ),
                        ),
                        onChanged: (_) {
                          setSheetState(() {});
                        },
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return "Please enter an amount";
                          }
                          final parsed = double.tryParse(value.trim());
                          if (parsed == null || parsed <= 0) {
                            return "Please enter a valid positive amount";
                          }
                          if (isDeduction && bankBalance - parsed < 0) {
                            return "Deduction amount cannot exceed current balance";
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 24),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              style: OutlinedButton.styleFrom(
                                side: BorderSide(color: Colors.grey[800]!),
                                padding: const EdgeInsets.symmetric(vertical: 16),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                              onPressed: () => Navigator.pop(sheetContext),
                              child: const Text(
                                "Cancel",
                                style: TextStyle(color: Colors.white70, fontSize: 16),
                              ),
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF9EA98F),
                                padding: const EdgeInsets.symmetric(vertical: 16),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                              onPressed: () async {
                                if (formKey.currentState?.validate() ?? false) {
                                  final amount = double.parse(controller.text.trim());
                                  final newBalance = isDeduction
                                      ? (bankBalance - amount)
                                      : (bankBalance + amount);

                                  await AppPrefs.setBankBalance(newBalance);
                                  await DatabaseHelper.instance.saveBankBalance(newBalance);
                                  await FirebaseDataService.saveBankBalance(newBalance);

                                  if (sheetContext.mounted) {
                                    Navigator.pop(sheetContext);
                                  }

                                  setState(() {
                                    _oldBankBalance = bankBalance;
                                    bankBalance = newBalance;
                                  });

                                  if (mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        backgroundColor: const Color(0xFF9EA98F),
                                        content: Text(
                                          isDeduction
                                              ? "Successfully deducted ₹${formatAmount(amount)} from Bank Balance"
                                              : "Successfully added ₹${formatAmount(amount)} to Bank Balance",
                                          style: const TextStyle(
                                            color: Colors.black,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ),
                                    );
                                  }
                                }
                              },
                              child: Text(
                                isDeduction ? "Deduct" : "Add",
                                style: const TextStyle(
                                  color: Colors.black,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> openProfilePage() async {
    await Navigator.push(context, _smoothRoute((_) => const ProfilePage()));
  }

  Future<void> openAddFriendPage() async {
    final result = await Navigator.push(
      context,
      _smoothRoute((_) => const AddFriendPage()),
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
      map.putIfAbsent(originalNames[key] ?? name, () => []).add(t);
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

  /// Shimmer skeleton shown while the first data load is in progress
  Widget _buildShimmerList() {
    return ListView.builder(
      itemCount: 4,
      physics: const NeverScrollableScrollPhysics(),
      itemBuilder: (context, _) {
        return Shimmer.fromColors(
          baseColor: Colors.grey[850] ?? const Color(0xFF212121),
          highlightColor: Colors.grey[750] ?? const Color(0xFF424242),
          child: Card(
            margin: const EdgeInsets.only(bottom: 12),
            color: Colors.grey[850],
            child: ListTile(
              leading: CircleAvatar(
                radius: 22,
                backgroundColor: Colors.grey[800],
              ),
              title: Container(
                height: 14,
                width: 120,
                decoration: BoxDecoration(
                  color: Colors.grey[800],
                  borderRadius: BorderRadius.circular(6),
                ),
              ),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 8),
                  Container(
                    height: 12,
                    width: 90,
                    decoration: BoxDecoration(
                      color: Colors.grey[800],
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Container(
                    height: 11,
                    width: 60,
                    decoration: BoxDecoration(
                      color: Colors.grey[800],
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ],
              ),
              isThreeLine: true,
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final rawFriends = visibleFriends;
    final List<FriendListItem> friends;
    if (_selectedFilter == 'Collect') {
      friends = rawFriends.where((f) => getFriendBalance(f.name) > 0).toList();
      friends.sort((a, b) => getFriendBalance(b.name).compareTo(getFriendBalance(a.name)));
    } else if (_selectedFilter == 'Pay') {
      friends = rawFriends.where((f) => getFriendBalance(f.name) < 0).toList();
      friends.sort((a, b) => getFriendBalance(a.name).compareTo(getFriendBalance(b.name)));
    } else if (_selectedFilter == 'Settled') {
      friends = rawFriends.where((f) => getFriendBalance(f.name) == 0).toList();
      friends.sort((a, b) => a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));
    } else {
      friends = rawFriends;
    }

    return Scaffold(
      resizeToAvoidBottomInset: false,
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(56),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // Drawer Menu button
                Builder(
                  builder: (context) => IconButton(
                    icon: const Icon(Icons.menu, size: 24, color: Colors.white),
                    onPressed: () => Scaffold.of(context).openDrawer(),
                  ),
                ),
                // Add Friend button
                IconButton(
                  icon: const Icon(Icons.person_add_rounded, size: 24, color: Colors.white),
                  onPressed: openAddFriendPage,
                  tooltip: 'Add Friend',
                ),
              ],
            ),
          ),
        ),
      ),
      drawer: const AppDrawer(currentRoute: 'dashboard'),
      floatingActionButton: FloatingActionButton(
        backgroundColor: Colors.green,
        onPressed: () async {
          final result = await Navigator.push(
            context,
            _smoothRoute((_) => const AddPage()),
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
                          color: Colors.green.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: Colors.green.withValues(alpha: 0.3),
                            width: 1.5,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.green.withValues(alpha: 0.08),
                              blurRadius: 8,
                              spreadRadius: 1,
                            ),
                          ],
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              "COLLECT",
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
                          color: Colors.red.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: Colors.red.withValues(alpha: 0.3),
                            width: 1.5,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.red.withValues(alpha: 0.08),
                              blurRadius: 8,
                              spreadRadius: 1,
                            ),
                          ],
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              "PAY",
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
                      GestureDetector(
                        onTap: showBankBalanceDialog,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                          decoration: BoxDecoration(
                            color: Colors.blue.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: Colors.blue.withValues(alpha: 0.3),
                              width: 1.5,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.blue.withValues(alpha: 0.08),
                                blurRadius: 8,
                                spreadRadius: 1,
                              ),
                            ],
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: const [
                                  Text(
                                    "BANK BALANCE",
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      color: Colors.white,
                                    ),
                                  ),
                                  Icon(
                                    Icons.edit_outlined,
                                    size: 14,
                                    color: Colors.white70,
                                  ),
                                ],
                              ),
                              const SizedBox(height: 2),
                              Expanded(
                                child: Align(
                                  alignment: Alignment.centerLeft,
                                  child: FittedBox(
                                    fit: BoxFit.scaleDown,
                                    alignment: Alignment.centerLeft,
                                    child: TweenAnimationBuilder<double>(
                                      tween: Tween<double>(begin: _oldBankBalance, end: bankBalance),
                                      duration: const Duration(milliseconds: 600),
                                      curve: Curves.easeOutCubic,
                                      builder: (context, value, child) {
                                        return Text(
                                          "\u20B9${formatAmount(value)}",
                                          style: const TextStyle(
                                            fontSize: 24,
                                            fontWeight: FontWeight.bold,
                                            color: Colors.white,
                                          ),
                                        );
                                      },
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 2),
                              const Text(
                                "Tap to Edit",
                                style: TextStyle(
                                  fontSize: 9,
                                  color: Colors.white70,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: Colors.amber.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: Colors.amber.withValues(alpha: 0.3),
                            width: 1.5,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.amber.withValues(alpha: 0.08),
                              blurRadius: 8,
                              spreadRadius: 1,
                            ),
                          ],
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              "NET BALANCE",
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
                                    "\u20B9${formatAmount(netWorth)}",
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
                    ],
                  ),
                );
              },
            ),
            const SizedBox(height: 10),
            // Personal Spending Card
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.grey[900],
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: Colors.grey[850] ?? const Color(0xFF212121),
                  width: 1.5,
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          "PERSONAL SPENDING",
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: Colors.amber,
                            letterSpacing: 1,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  "Today",
                                  style: TextStyle(color: Colors.grey, fontSize: 11),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  "\u20B9${todayHomeSpending.toStringAsFixed(0)}",
                                  style: const TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.white,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(width: 24),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  "This Month",
                                  style: TextStyle(color: Colors.grey, fontSize: 11),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  "\u20B9${monthHomeSpending.toStringAsFixed(0)}",
                                  style: const TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.white,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const DailyExpenditureScreen(),
                        ),
                      ).then((_) => loadExpenses());
                    },
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.amber,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          "View Details",
                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                        ),
                        Icon(Icons.chevron_right, size: 16),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: ['All', 'Collect', 'Pay', 'Settled'].map((filter) {
                final isSelected = _selectedFilter == filter;
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: GestureDetector(
                    onTap: () {
                      setState(() {
                        _selectedFilter = filter;
                      });
                    },
                    child: Container(
                      height: 32,
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      decoration: BoxDecoration(
                        color: isSelected ? Colors.amber : Colors.grey[900],
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: isSelected
                              ? Colors.amber
                              : Colors.grey[800]?.withValues(alpha: 0.5) ?? const Color(0x80424242),
                          width: 1,
                        ),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        filter,
                        style: TextStyle(
                          color: isSelected ? Colors.black : Colors.white70,
                          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: RefreshIndicator(
                onRefresh: syncBankBalance,
                color: Colors.amber,
                child: _isInitialLoad
                    ? _buildShimmerList()
                    : friends.isEmpty
                    ? ListView(
                        // Wrapping in a ListView so pull-to-refresh works even on empty state
                        children: [
                          const SizedBox(height: 80),
                          Center(
                            child: Text(
                              _selectedFilter == 'All'
                                  ? "No friends added yet. Tap '+' to add a transaction."
                                  : "No friends found under '$_selectedFilter'.",
                              style: const TextStyle(color: Colors.grey),
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
                          final String status;
                          final Color statusColor;
                          if (balance > 0) {
                            status = "Collect";
                            statusColor = Colors.green;
                          } else if (balance < 0) {
                            status = "Pay";
                            statusColor = Colors.red;
                          } else {
                            status = "Settled";
                            statusColor = Colors.grey;
                          }
                          return Card(
                            margin: const EdgeInsets.only(bottom: 12),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(12),
                              onTap: () async {
                                await Navigator.push(
                                  context,
                                  _smoothRoute((_) => PersonDetailPage(
                                    friendName: friendName,
                                    peerUserId: friend.uid,
                                  )),
                                );
                                await refreshDashboard();
                              },
                              onLongPress: () {
                                deleteEntireFriend(friend);
                              },
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                child: Row(
                                  children: [
                                    (() {
                                      final cached = cachedFriendProfiles[friend.uid];
                                      final photoUrl = cached?['photoUrl'] as String?;
                                      if (photoUrl != null && photoUrl.isNotEmpty) {
                                        return CircleAvatar(
                                          backgroundColor: Colors.transparent,
                                          child: ClipOval(
                                            child: CustomCachedImage(
                                              url: photoUrl,
                                              width: 40,
                                              height: 40,
                                              fit: BoxFit.cover,
                                            ),
                                          ),
                                        );
                                      }
                                      final Color placeholderColor;
                                      if (balance > 0) {
                                        placeholderColor = Colors.green;
                                      } else if (balance < 0) {
                                        placeholderColor = Colors.red;
                                      } else {
                                        placeholderColor = Colors.grey;
                                      }
                                      return CircleAvatar(
                                        backgroundColor: placeholderColor.withValues(alpha: 0.2),
                                        child: Text(
                                          friend.displayName.isNotEmpty
                                              ? friend.displayName[0].toUpperCase()
                                              : '?',
                                          style: TextStyle(
                                            color: placeholderColor,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      );
                                    })(),
                                    const SizedBox(width: 16),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        mainAxisSize: MainAxisSize.min,
                                        mainAxisAlignment: MainAxisAlignment.center,
                                        children: [
                                          Text(
                                            friend.displayName,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              fontWeight: FontWeight.bold,
                                              fontSize: 16,
                                            ),
                                          ),
                                          const SizedBox(height: 6),
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
                                    ),
                                    const SizedBox(width: 16),
                                    Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        GlassActionButton(
                                          icon: Icons.add,
                                          color: Colors.green,
                                          tooltip: "Give Money (+)",
                                          onPressed: () {
                                            quickAddTransaction(friendName, true);
                                          },
                                        ),
                                        const SizedBox(width: 12),
                                        GlassActionButton(
                                          icon: Icons.remove,
                                          color: Colors.red,
                                          tooltip: "Take Money (-)",
                                          onPressed: () {
                                            quickAddTransaction(friendName, false);
                                          },
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
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

  String? existingReceiptPath;
  String? existingReceiptUrl;
  bool isReceiptRemoved = false;

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
      existingReceiptPath = widget.transaction!.receiptPath;
      existingReceiptUrl = widget.transaction!.receiptUrl;
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
    _receiptLog(scope, 'Save pressed. receiptSelected=${receiptImage != null} isReceiptRemoved=$isReceiptRemoved');
    try {
      final currentUser = FirebaseAuth.instance.currentUser;
      _receiptLog(
        scope,
        'Current user=${currentUser?.uid ?? 'null'} existingFirebaseId=${widget.transaction?.firebaseId}',
      );

      String? firebaseId = widget.transaction?.firebaseId;
      String? receiptPath = widget.transaction?.receiptPath;
      String? receiptUrl = widget.transaction?.receiptUrl;

      if (isReceiptRemoved || receiptImage != null) {
        if (existingReceiptPath != null) {
          _receiptLog(scope, 'Deleting existing local receipt file: $existingReceiptPath');
          await _deleteLocalReceipt(existingReceiptPath, scope: scope);
        }
        if (existingReceiptUrl != null) {
          _receiptLog(scope, 'Deleting existing Cloudinary image: $existingReceiptUrl');
          await _deleteFromCloudinary(existingReceiptUrl!, scope: scope);
        }
        if (isReceiptRemoved && receiptImage == null) {
          receiptPath = null;
          receiptUrl = null;
        }
      }

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
                existingReceiptPath: existingReceiptPath,
                existingReceiptUrl: existingReceiptUrl,
                isReceiptRemoved: isReceiptRemoved,
                onRemoveExisting: () {
                  _receiptLog('AddPage.pickReceipt', 'Existing receipt removed.');
                  setState(() {
                    isReceiptRemoved = true;
                  });
                },
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
                    isReceiptRemoved = true;
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
                  child: FutureBuilder<File?>(
                    future: CustomCacheManager.instance.getFile(receiptUrl),
                    builder: (context, snapshot) {
                      final file = snapshot.data;
                      return PhotoView(
                        imageProvider: file != null
                            ? FileImage(file)
                            : NetworkImage(receiptUrl) as ImageProvider,
                        backgroundDecoration:
                            const BoxDecoration(color: Colors.black),
                      );
                    },
                  ),
                ),
              );
            },
          );
        },
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: CustomCachedImage(
            url: receiptUrl,
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
    final statusText = isGiven ? 'Collect' : 'Pay';
    final displayFriendName = _transactionDisplayFriendName(transaction);
    final currentUser = FirebaseAuth.instance.currentUser?.uid;
    final isCreator = transaction.createdBy == currentUser;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Transaction Details'),
        centerTitle: true,
        actions: [
          if (isCreator) ...[
            IconButton(
              icon: const Icon(Icons.edit),
              tooltip: 'Edit',
              onPressed: () async {
                final result = await Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => AddPage(transaction: transaction)),
                );
                if (result == true && context.mounted) {
                  Navigator.pop(context, true);
                }
              },
            ),
            IconButton(
              icon: const Icon(Icons.delete, color: Colors.red),
              tooltip: 'Delete',
              onPressed: () async {
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (dialogContext) => AlertDialog(
                    title: const Text('Delete Transaction?'),
                    content: const Text('Are you sure you want to permanently delete this transaction?'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(dialogContext, false),
                        child: const Text('Cancel'),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(dialogContext, true),
                        child: const Text('Delete', style: TextStyle(color: Colors.red)),
                      ),
                    ],
                  ),
                );
                if (confirmed == true && context.mounted) {
                  if (transaction.firebaseId != null) {
                    await FirebaseDataService.deleteTransaction(transaction);
                  }
                  if (transaction.id != null) {
                    await DatabaseHelper.instance.deleteTransaction(transaction.id!);
                  }
                  if (context.mounted) {
                    Navigator.pop(context, true);
                  }
                }
              },
            ),
          ],
        ],
      ),
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

class _TransactionGroup {
  final String dateLabel;
  final List<TransactionModel> transactions;
  _TransactionGroup(this.dateLabel, this.transactions);
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

class _PersonDetailPageState extends State<PersonDetailPage> {
  List<TransactionModel> personTransactions = [];
  List<DeletedEntryModel> deletedTransactions = [];
  bool isLoading = true;

  List<_TransactionGroup> _groupTransactions(List<TransactionModel> transactions) {
    final List<_TransactionGroup> groups = [];
    String? currentLabel;
    List<TransactionModel> currentGroupList = [];

    for (final t in transactions) {
      final label = _formatDateString(t.date);
      if (currentLabel == null) {
        currentLabel = label;
        currentGroupList.add(t);
      } else if (currentLabel == label) {
        currentGroupList.add(t);
      } else {
        groups.add(_TransactionGroup(currentLabel, currentGroupList));
        currentLabel = label;
        currentGroupList = [t];
      }
    }
    if (currentLabel != null) {
      groups.add(_TransactionGroup(currentLabel, currentGroupList));
    }
    return groups;
  }
  StreamSubscription<List<TransactionModel>>? _transactionsSubscription;
  StreamSubscription<List<DeletedEntryModel>>? _deletedSubscription;
  Future<Map<String, dynamic>?>? _friendProfileFuture;
  String? _cachedPhotoUrl;
  String? _cachedUpiId;
  String? _cachedMobileNumber;
  String? _localNickname;

  @override
  void initState() {
    super.initState();
    _loadNickname();
    if (FirebaseAuth.instance.currentUser == null) {
      loadPersonTransactions();
    } else {
      startRealtimeSync();
      _loadCachedProfile();
      _friendProfileFuture = _fetchFriendProfile();
    }
  }

  Future<void> _loadCachedProfile() async {
    final cached = await DatabaseHelper.instance.getCachedFriendByName(widget.friendName);
    if (cached != null && mounted) {
      setState(() {
        _cachedPhotoUrl = cached['photoUrl'] as String?;
        _cachedUpiId = cached['upiId'] as String?;
        _cachedMobileNumber = cached['mobileNumber'] as String?;
      });
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

  Future<Map<String, dynamic>?> _fetchFriendProfile() async {
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
      if (data != null) {
        final name = data['name'] as String? ?? widget.friendName;
        final email = data['email'] as String? ?? '';
        final friendCode = data['friendCode'] as String? ?? '';
        final photoUrl = data['photoUrl'] as String? ?? '';
        final upiId = data['upiId'] as String? ?? '';
        final mobileNumber = data['mobileNumber'] as String? ?? '';

        await DatabaseHelper.instance.saveCachedFriend(
          friendUid: uid,
          friendName: name,
          email: email,
          friendCode: friendCode,
          photoUrl: photoUrl,
          upiId: upiId,
          mobileNumber: mobileNumber,
        );
      }
      return data;
    } catch (e) {
      debugPrint('Error fetching friend profile: $e');
      return null;
    }
  }

  String _normalizePhoneNumber(String rawPhone) {
    String digits = rawPhone.replaceAll(RegExp(r'\D'), '');
    if (digits.length == 10) {
      return '91$digits';
    }
    return digits;
  }

  @override
  void dispose() {
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
    final double amountToSettle = netBalance.abs();
    if (FirebaseAuth.instance.currentUser != null && amountToSettle != 0) {
      try {
        await FirebaseDataService.recordSettlement(
          friendName: widget.friendName,
          amount: amountToSettle,
        );
      } catch (e) {
        debugPrint('Error recording settlement: $e');
      }
    }

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



  void _showTransactionOptions(BuildContext context, TransactionModel t) {
    final currentUid = FirebaseAuth.instance.currentUser?.uid;
    final isCreator = t.createdBy == currentUid;
    showModalBottomSheet(
      context: context,
      builder: (_) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isCreator)
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
              if (isCreator)
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

  String _formatDateString(String rawDate) {
    final regex = RegExp(r'^(\d{4})-(\d{2})-(\d{2})(.*)$');
    final match = regex.firstMatch(rawDate.trim());
    if (match == null) {
      return rawDate;
    }
    final monthStr = match.group(2)!;
    final dayStr = match.group(3)!;
    var suffix = match.group(4)!.trim();

    final monthVal = int.tryParse(monthStr);
    if (monthVal == null || monthVal < 1 || monthVal > 12) {
      return rawDate;
    }

    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    final formattedDate = "$dayStr ${months[monthVal - 1]}";

    if (suffix.isNotEmpty) {
      while (suffix.startsWith('-') || suffix.startsWith(':') || suffix.startsWith(' ')) {
        suffix = suffix.substring(1).trim();
      }
      if (suffix.startsWith('(') && suffix.endsWith(')')) {
        if (suffix.length > 2) {
          final inside = suffix.substring(1, suffix.length - 1).trim();
          if (inside.isNotEmpty) {
            final capitalized = inside[0].toUpperCase() + inside.substring(1);
            return "$formattedDate ($capitalized)";
          }
        }
        return "$formattedDate $suffix";
      } else {
        final capitalized = suffix[0].toUpperCase() + suffix.substring(1);
        return "$formattedDate ($capitalized)";
      }
    }

    return formattedDate;
  }

  Widget _buildDateHeader(String formattedDate) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          const Expanded(
            child: Divider(
              color: Colors.white24,
              thickness: 1,
              endIndent: 12,
            ),
          ),
          Text(
            formattedDate,
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              color: Colors.white70,
              fontSize: 13,
            ),
          ),
          const Expanded(
            child: Divider(
              color: Colors.white24,
              thickness: 1,
              indent: 12,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTransactionsTable(List<TransactionModel> transactions) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Table(
        columnWidths: const {
          0: FlexColumnWidth(),
          1: FixedColumnWidth(65),
          2: FixedColumnWidth(48),
        },
        defaultVerticalAlignment: TableCellVerticalAlignment.middle,
        children: transactions.map((t) {
          final isGiven = _transactionDisplayIsGiven(t);
          final rowBgColor = isGiven
              ? Colors.green.withValues(alpha: 0.15)
              : Colors.red.withValues(alpha: 0.15);
          final moneyColor = isGiven ? Colors.green : Colors.red;

          Widget buildCell(
            Widget child, {
            Alignment alignment = Alignment.centerLeft,
            EdgeInsetsGeometry padding = const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          }) {
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () async {
                final result = await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => TransactionDetailPage(transaction: t),
                  ),
                );
                if (result == true &&
                    FirebaseAuth.instance.currentUser == null &&
                    context.mounted) {
                  loadPersonTransactions();
                }
              },
              onLongPress: () => _showTransactionOptions(context, t),
              child: Container(
                alignment: alignment,
                padding: padding,
                child: child,
              ),
            );
          }

          return TableRow(
            decoration: BoxDecoration(
              color: rowBgColor,
            ),
            children: [
              buildCell(
                Text(
                  t.note,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13),
                ),
              ),
              buildCell(
                Text(
                  "\u20B9${t.amount.toStringAsFixed(0)}",
                  style: TextStyle(
                    color: moneyColor,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
                alignment: Alignment.centerRight,
              ),
              buildCell(
                (() {
                  final hasLocal = t.receiptPath != null &&
                      t.receiptPath!.isNotEmpty &&
                      File(t.receiptPath!).existsSync();
                  if (hasLocal) {
                    return ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: Image.file(
                        File(t.receiptPath!),
                        width: 32,
                        height: 32,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => const Icon(
                          Icons.broken_image,
                          size: 18,
                          color: Colors.grey,
                        ),
                      ),
                    );
                  } else if (t.receiptUrl != null && t.receiptUrl!.isNotEmpty) {
                    return ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: CustomCachedImage(
                        url: t.receiptUrl!,
                        width: 32,
                        height: 32,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => const Icon(
                          Icons.broken_image,
                          size: 18,
                          color: Colors.grey,
                        ),
                      ),
                    );
                  } else {
                    return const Icon(
                      Icons.receipt_long,
                      size: 18,
                      color: Colors.grey,
                    );
                  }
                })(),
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
              ),
            ],
          );
        }).toList(),
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
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Table(
              columnWidths: const {
                0: FixedColumnWidth(80),
                1: FlexColumnWidth(),
                2: FixedColumnWidth(65),
                3: FixedColumnWidth(80),
              },
              defaultVerticalAlignment: TableCellVerticalAlignment.middle,
              children: [
                TableRow(
                  decoration: BoxDecoration(
                    color: Colors.grey[850],
                  ),
                  children: [
                    Container(
                      alignment: Alignment.centerLeft,
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                      child: const Text(
                        'Date',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Colors.white),
                      ),
                    ),
                    Container(
                      alignment: Alignment.centerLeft,
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                      child: const Text(
                        'Note',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Colors.white),
                      ),
                    ),
                    Container(
                      alignment: Alignment.centerRight,
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                      child: const Text(
                        '₹',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Colors.white),
                      ),
                    ),
                    Container(
                      alignment: Alignment.centerRight,
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                      child: const Text(
                        'Cleared',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Colors.white),
                      ),
                    ),
                  ],
                ),
                ...deletedTransactions.map((entry) {
                  final moneyColor = entry.isGiven ? Colors.green : Colors.red;

                  Widget buildCell(
                    Widget child, {
                    Alignment alignment = Alignment.centerLeft,
                    EdgeInsetsGeometry padding = const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                  }) {
                    return GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onLongPress: () {
                        _showDeletedTransactionOptions(context, entry);
                      },
                      child: Container(
                        alignment: alignment,
                        padding: padding,
                        child: child,
                      ),
                    );
                  }

                  return TableRow(
                    decoration: BoxDecoration(
                      color: Colors.grey[900],
                    ),
                    children: [
                      buildCell(
                        Text(
                          _formatDateString(entry.date),
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                      buildCell(
                        Text(
                          entry.note,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                      buildCell(
                        Text(
                          "\u20B9${entry.amount.toStringAsFixed(0)}",
                          style: TextStyle(
                            color: moneyColor,
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                        alignment: Alignment.centerRight,
                      ),
                      buildCell(
                        Text(
                          _formatDateString(entry.clearedDate),
                          style: const TextStyle(fontSize: 13),
                        ),
                        alignment: Alignment.centerRight,
                      ),
                    ],
                  );
                }),
              ],
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
              } else if (value == 'settlement_history') {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => SettlementHistoryPage(friendName: widget.friendName),
                  ),
                );
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem<String>(
                value: 'rename_friend',
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  children: [
                    const Icon(Icons.edit_outlined, color: Colors.white70),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text(
                            'Rename Friend',
                            style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w500),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Change display name',
                            style: TextStyle(color: Colors.grey[400], fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                    const Icon(Icons.chevron_right, color: Colors.grey),
                  ],
                ),
              ),
              const PopupMenuDivider(height: 1),
              PopupMenuItem<String>(
                value: 'clear_account',
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  children: [
                    const Icon(Icons.cleaning_services_outlined, color: Colors.white70),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text(
                            'Clear Account',
                            style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w500),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Set balance to zero',
                            style: TextStyle(color: Colors.grey[400], fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                    const Icon(Icons.chevron_right, color: Colors.grey),
                  ],
                ),
              ),
              const PopupMenuDivider(height: 1),
              PopupMenuItem<String>(
                value: 'settlement_history',
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  children: [
                    const Icon(Icons.history_outlined, color: Colors.white70),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text(
                            'Settlement History',
                            style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w500),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'View past settlements',
                            style: TextStyle(color: Colors.grey[400], fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                    const Icon(Icons.chevron_right, color: Colors.grey),
                  ],
                ),
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
          : FutureBuilder<Map<String, dynamic>?>(
              future: _friendProfileFuture,
              builder: (context, snapshot) {
                final data = (snapshot.connectionState == ConnectionState.done && snapshot.hasData)
                    ? snapshot.data
                    : null;
                
                final photoUrl = data?['photoUrl'] as String? ?? _cachedPhotoUrl;
                final upiId = data?['upiId'] as String? ?? _cachedUpiId;
                final mobileNumber = data?['mobileNumber'] as String? ?? _cachedMobileNumber;

                final grouped = _groupTransactions(personTransactions);

                return CustomScrollView(
                  slivers: [
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                        child: Column(
                          children: [
                            if (photoUrl != null && photoUrl.isNotEmpty) ...[
                              Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  CircleAvatar(
                                    radius: 40,
                                    backgroundColor: Colors.grey[800],
                                    child: ClipOval(
                                      child: CustomCachedImage(
                                        url: photoUrl,
                                        width: 80,
                                        height: 80,
                                        fit: BoxFit.cover,
                                      ),
                                    ),
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
                              ),
                            ],
                            // Summary Card for this Person
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                color: Colors.grey[900],
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(color: Colors.grey[850] ?? const Color(0xFF212121)),
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
                                (() {
                                  final hasUpi = upiId != null && upiId.trim().isNotEmpty;
                                  return Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      ElevatedButton.icon(
                                        onPressed: () async {
                                          const channel = MethodChannel('hisab_kitab/upi_launcher');
                                          try {
                                            final bool? success = await channel.invokeMethod<bool>('launchUpiPayment');
                                            if (success != true) {
                                              if (context.mounted) {
                                                ScaffoldMessenger.of(context).showSnackBar(
                                                  const SnackBar(
                                                    content: Text('No UPI app available.'),
                                                  ),
                                                );
                                              }
                                            }
                                          } catch (e) {
                                            if (context.mounted) {
                                              ScaffoldMessenger.of(context).showSnackBar(
                                                SnackBar(
                                                  content: Text('Could not open UPI app: $e'),
                                                ),
                                              );
                                            }
                                          }
                                        },
                                        icon: const Icon(Icons.payment),
                                        label: const Text("Open UPI App"),
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
                                      hasUpi
                                          ? Row(
                                              mainAxisAlignment: MainAxisAlignment.center,
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Text(
                                                  "UPI ID: $upiId",
                                                  style: const TextStyle(
                                                    color: Colors.grey,
                                                    fontSize: 14,
                                                    fontWeight: FontWeight.w500,
                                                  ),
                                                ),
                                                const SizedBox(width: 4),
                                                GestureDetector(
                                                  onTap: () async {
                                                    await Clipboard.setData(
                                                      ClipboardData(text: upiId.trim()),
                                                    );
                                                    if (context.mounted) {
                                                      ScaffoldMessenger.of(context).showSnackBar(
                                                        const SnackBar(
                                                          content: Text('UPI ID copied'),
                                                          duration: Duration(seconds: 2),
                                                        ),
                                                      );
                                                    }
                                                  },
                                                  child: Padding(
                                                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                                                    child: Icon(
                                                      Icons.copy_rounded,
                                                      size: 14,
                                                      color: Colors.grey[400],
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            )
                                          : Text(
                                              _friendProfileFuture == null
                                                  ? "UPI ID: Not available offline"
                                                  : (snapshot.connectionState == ConnectionState.waiting
                                                      ? "Loading UPI ID..."
                                                      : "Friend has not added a UPI ID."),
                                              style: const TextStyle(
                                                color: Colors.grey,
                                                fontSize: 14,
                                                fontWeight: FontWeight.w500,
                                              ),
                                            ),
                                    ],
                                  );
                                })(),
                              ] else if (netBalance > 0) ...[
                                (() {
                                  if (_friendProfileFuture == null) {
                                    return ElevatedButton.icon(
                                      onPressed: () {
                                        if (context.mounted) {
                                          ScaffoldMessenger.of(context).showSnackBar(
                                            const SnackBar(
                                              content: Text("Friend has not added a mobile number."),
                                            ),
                                          );
                                        }
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
                                    );
                                  }
                                  if (snapshot.connectionState == ConnectionState.waiting &&
                                      (mobileNumber == null || mobileNumber.trim().isEmpty)) {
                                    return const Padding(
                                      padding: EdgeInsets.only(top: 8),
                                      child: SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(strokeWidth: 2),
                                      ),
                                    );
                                  }
                                  return ElevatedButton.icon(
                                    onPressed: () async {
                                      if (mobileNumber == null || mobileNumber.trim().isEmpty) {
                                        if (context.mounted) {
                                          ScaffoldMessenger.of(context).showSnackBar(
                                            const SnackBar(
                                              content: Text("Friend has not added a mobile number."),
                                            ),
                                          );
                                        }
                                        return;
                                      }

                                      final normalizedMobile = _normalizePhoneNumber(mobileNumber.trim());
                                      if (normalizedMobile.isEmpty) {
                                        if (context.mounted) {
                                          ScaffoldMessenger.of(context).showSnackBar(
                                            const SnackBar(
                                              content: Text("Friend has not added a mobile number."),
                                            ),
                                          );
                                        }
                                        return;
                                      }

                                      final amountText = netBalance.toStringAsFixed(0);
                                      final message = 'Hi $_displayName,\n\n'
                                          'According to Hisab Kitab, you currently owe ₹$amountText.\n\n'
                                          'You can settle it whenever convenient.\n\n'
                                          'Thanks 🙂';

                                      final whatsappUri = Uri.parse(
                                        'https://wa.me/$normalizedMobile?text=${Uri.encodeComponent(message)}',
                                      );

                                      try {
                                        final launched = await launchUrl(
                                          whatsappUri,
                                          mode: LaunchMode.externalApplication,
                                        );
                                        if (!launched) {
                                          if (context.mounted) {
                                            ScaffoldMessenger.of(context).showSnackBar(
                                              const SnackBar(
                                                content: Text('Could not launch WhatsApp.'),
                                              ),
                                            );
                                          }
                                        }
                                      } catch (e) {
                                        if (context.mounted) {
                                          ScaffoldMessenger.of(context).showSnackBar(
                                            SnackBar(
                                              content: Text('Could not launch WhatsApp: $e'),
                                            ),
                                          );
                                        }
                                      }
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
                                  );
                                })(),
                              ],
                            ],
                            const SizedBox(height: 20),
                            Row(
                              children: const [
                                Text(
                                  "Transaction History",
                                  style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                          ],
                        ),
                      ),
                    ),
                    if (personTransactions.isEmpty)
                      const SliverToBoxAdapter(
                        child: Padding(
                          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 20),
                          child: Center(
                            child: Text(
                              "No active transactions found.",
                              style: TextStyle(fontSize: 16, color: Colors.grey),
                            ),
                          ),
                        ),
                      )
                    else
                      SliverPadding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        sliver: SliverList(
                          delegate: SliverChildBuilderDelegate(
                            (context, index) {
                              final group = grouped[index];
                              return Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  _buildDateHeader(group.dateLabel),
                                  const SizedBox(height: 4),
                                  _buildTransactionsTable(group.transactions),
                                  const SizedBox(height: 12),
                                ],
                              );
                            },
                            childCount: grouped.length,
                          ),
                        ),
                      ),
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: _buildDeletedTransactionsSection(),
                      ),
                    ),
                  ],
                );
              },
            ),
    );
  }
}

class SettlementHistoryPage extends StatelessWidget {
  final String? friendName;

  const SettlementHistoryPage({super.key, this.friendName});

  String _formatSettlementDate(DateTime dt) {
    final months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final day = dt.day.toString().padLeft(2, '0');
    final month = months[dt.month - 1];
    final year = dt.year;
    return "$day $month $year";
  }

  String _formatSettlementTime(DateTime dt) {
    final hour24 = dt.hour;
    final minute = dt.minute.toString().padLeft(2, '0');
    final amPm = hour24 >= 12 ? 'PM' : 'AM';
    var hour12 = hour24 % 12;
    if (hour12 == 0) hour12 = 12;
    return "$hour12:$minute $amPm";
  }

  @override
  Widget build(BuildContext context) {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('Settlement History'),
          centerTitle: true,
        ),
        body: const Center(
          child: Text(
            'Please log in to view settlement history.',
            style: TextStyle(color: Colors.grey, fontSize: 16),
          ),
        ),
      );
    }

    final query = FirebaseFirestore.instance
        .collection('users')
        .doc(currentUser.uid)
        .collection('settlements')
        .orderBy('settledAt', descending: true);

    return Scaffold(
      appBar: AppBar(
        title: Text(friendName != null ? '$friendName Settlements' : 'Settlement History'),
        centerTitle: true,
      ),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: query.snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: Text(
                'Error loading settlements: ${snapshot.error}',
                style: const TextStyle(color: Colors.red),
              ),
            );
          }

          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(
              child: CircularProgressIndicator(),
            );
          }

          final docs = snapshot.data?.docs ?? [];
          var settlements = docs.map((doc) => doc.data()).toList();

          if (friendName != null) {
            final filterName = (friendName ?? '').trim().toLowerCase();
            settlements = settlements.where((item) {
              final itemFriend = (item['friendName'] as String? ?? '').trim().toLowerCase();
              return itemFriend == filterName;
            }).toList();
          }

          if (settlements.isEmpty) {
            return const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.history, size: 64, color: Colors.grey),
                  SizedBox(height: 16),
                  Text(
                    "No settlements recorded yet.",
                    style: TextStyle(color: Colors.grey, fontSize: 16),
                  ),
                ],
              ),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: settlements.length,
            itemBuilder: (context, index) {
              final item = settlements[index];
              final friend = item['friendName'] as String? ?? 'Unknown';
              final amount = (item['amount'] as num?)?.toDouble() ?? 0.0;
              final settledBy = item['settledBy'] as String? ?? '';
              final settledAtRaw = item['settledAt'];
              
              DateTime settledDateTime;
              if (settledAtRaw is Timestamp) {
                settledDateTime = settledAtRaw.toDate();
              } else if (settledAtRaw is String) {
                settledDateTime = DateTime.tryParse(settledAtRaw) ?? DateTime.now();
              } else {
                settledDateTime = DateTime.now();
              }

              final dateStr = _formatSettlementDate(settledDateTime);
              final timeStr = _formatSettlementTime(settledDateTime);

              return Card(
                color: Colors.grey[900],
                margin: const EdgeInsets.only(bottom: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: BorderSide(color: Colors.grey[850] ?? const Color(0xFF212121)),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(
                            child: Text(
                              friend,
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          Text(
                            "Settled \u20B9${amount.toStringAsFixed(0)}",
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: Colors.green,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          const Icon(Icons.calendar_today, size: 14, color: Colors.grey),
                          const SizedBox(width: 6),
                          Text(
                            dateStr,
                            style: const TextStyle(color: Colors.grey, fontSize: 14),
                          ),
                          const SizedBox(width: 16),
                          const Icon(Icons.access_time, size: 14, color: Colors.grey),
                          const SizedBox(width: 6),
                          Text(
                            timeStr,
                            style: const TextStyle(color: Colors.grey, fontSize: 14),
                          ),
                        ],
                      ),
                      if (settledBy.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.blueGrey.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            "Settled by $settledBy",
                            style: TextStyle(
                              color: Colors.blue[300],
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class GlassActionButton extends StatefulWidget {
  final IconData icon;
  final Color color;
  final String tooltip;
  final VoidCallback onPressed;

  const GlassActionButton({
    super.key,
    required this.icon,
    required this.color,
    required this.tooltip,
    required this.onPressed,
  });

  @override
  State<GlassActionButton> createState() => _GlassActionButtonState();
}

class _GlassActionButtonState extends State<GlassActionButton> {
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    final buttonColor = widget.color;
    return Tooltip(
      message: widget.tooltip,
      child: GestureDetector(
        onTapDown: (_) => setState(() => _isPressed = true),
        onTapUp: (_) => setState(() => _isPressed = false),
        onTapCancel: () => setState(() => _isPressed = false),
        onTap: widget.onPressed,
        child: AnimatedScale(
          scale: _isPressed ? 0.92 : 1.0,
          duration: const Duration(milliseconds: 100),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 100),
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: const Color(0xFF1E1E1E), // Subtle dark background matching dark theme cards
              borderRadius: BorderRadius.circular(10), // Rounded-square border radius (10-12px)
              border: Border.all(
                color: buttonColor.withValues(alpha: _isPressed ? 0.95 : 0.6),
                width: 1.0, // Thin colored border
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.35),
                  blurRadius: 3,
                  offset: const Offset(0, 1.5), // Subtle shadow/elevation for depth
                ),
              ],
            ),
            child: Center(
              child: Icon(
                widget.icon,
                color: buttonColor,
                size: 20, // Bold centered icon
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class OlivePremiumButton extends StatefulWidget {
  final IconData icon;
  final String title;
  final String description;
  final VoidCallback onTap;

  const OlivePremiumButton({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
    required this.onTap,
  });

  @override
  State<OlivePremiumButton> createState() => _OlivePremiumButtonState();
}

class _OlivePremiumButtonState extends State<OlivePremiumButton> {
  bool _isPressed = false;
  static const Color oliveColor = Color(0xFF9EA98F);

  @override
  Widget build(BuildContext context) {
    return AnimatedScale(
      scale: _isPressed ? 0.96 : 1.0,
      duration: const Duration(milliseconds: 100),
      child: Container(
        decoration: BoxDecoration(
          color: oliveColor.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: oliveColor.withValues(alpha: 0.4),
            width: 1.5,
          ),
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: widget.onTap,
            onTapDown: (_) => setState(() => _isPressed = true),
            onTapCancel: () => setState(() => _isPressed = false),
            onHighlightChanged: (highlighted) {
              if (!highlighted) {
                setState(() => _isPressed = false);
              }
            },
            borderRadius: BorderRadius.circular(16),
            splashColor: oliveColor.withValues(alpha: 0.25),
            highlightColor: oliveColor.withValues(alpha: 0.15),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: oliveColor.withValues(alpha: 0.2),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      widget.icon,
                      color: oliveColor,
                      size: 26,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.title,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: oliveColor,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          widget.description,
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.white70,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}