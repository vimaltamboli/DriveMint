import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:image_picker/image_picker.dart';
import 'package:cloud_functions/cloud_functions.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  await MobileAds.instance.initialize();

  runApp(const DriveMintApp());
}


// ================= ADS / AD EARNINGS =================
class DriveMintAdService {
  // Google test Rewarded Ad unit. Replace w
  //ith your real Rewarded Ad unit
  // before publishing the app to production.
  static const String rewardedAdUnitId =
      'ca-app-pub-3940256099942544/5224354917';

  // Driver gets this amount for one completed Rewarded Ad.
  // Change this one value when you decide the final rate.
  static const double rewardPerAd = 2.0;

  // Five ads become available after every completed ride hour.
  static const int adsPerCompletedHour = 5;

  static String dateKey(DateTime date) {
    return '${date.year.toString().padLeft(4, '0')}-'
        '${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
  }

  static CollectionReference<Map<String, dynamic>> _adsCollection(
    String uid,
    String dayKey,
  ) {
    return FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .collection('adDays')
        .doc(dayKey)
        .collection('ads');
  }

  static Future<void> unlockAdsForRide({
    required DateTime rideStartTime,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final now = DateTime.now();
    final completedHours = now.difference(rideStartTime).inHours;
    if (completedHours < 1) return;

    // Deterministic ad IDs prevent duplicate ads when the app is restarted.
    for (int hour = 1; hour <= completedHours; hour++) {
      final unlockTime = rideStartTime.add(Duration(hours: hour));
      if (unlockTime.isAfter(now)) continue;

      final dayKey = dateKey(unlockTime);
      final dayRef = FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .collection('adDays')
          .doc(dayKey);

      for (int adNumber = 1; adNumber <= adsPerCompletedHour; adNumber++) {
        final adRef = _adsCollection(user.uid, dayKey)
            .doc('hour_${hour}_ad_$adNumber');

        await FirebaseFirestore.instance.runTransaction((transaction) async {
          final adSnapshot = await transaction.get(adRef);
          if (adSnapshot.exists) return;

          final daySnapshot = await transaction.get(dayRef);
          final existingDay = daySnapshot.data() ?? <String, dynamic>{};

          final availableAds =
              (existingDay['availableAds'] ?? 0) as num;
          final pendingAds =
              (existingDay['pendingAds'] ?? 0) as num;

          transaction.set(adRef, {
            'adId': adRef.id,
            'status': 'pending',
            'reward': rewardPerAd,
            'hourNumber': hour,
            'adNumber': adNumber,
            'dateKey': dayKey,
            'unlockAt': Timestamp.fromDate(unlockTime),
            'createdAt': FieldValue.serverTimestamp(),
          });

          transaction.set(dayRef, {
            'dateKey': dayKey,
            'availableAds': availableAds.toInt() + 1,
            'pendingAds': pendingAds.toInt() + 1,
            'completedAds': existingDay['completedAds'] ?? 0,
            'totalEarned': existingDay['totalEarned'] ?? 0.0,
            'updatedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
        });
      }
    }
  }

  static Future<void> showRewardedAdAndComplete({
    required BuildContext context,
    required String dayKey,
    required String adId,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final adRef = _adsCollection(user.uid, dayKey).doc(adId);
    final adSnapshot = await adRef.get();
    if (!adSnapshot.exists) return;

    final adData = adSnapshot.data() ?? {};
    if (adData['status'] != 'pending') {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('This ad is already completed.')),
        );
      }
      return;
    }

    bool rewardGranted = false;
    bool isLoading = true;

    await RewardedAd.load(
      adUnitId: rewardedAdUnitId,
      request: const AdRequest(),
      rewardedAdLoadCallback: RewardedAdLoadCallback(
        onAdLoaded: (RewardedAd ad) {
          isLoading = false;

          ad.fullScreenContentCallback = FullScreenContentCallback(
            onAdDismissedFullScreenContent: (RewardedAd ad) {
              ad.dispose();
              if (!rewardGranted && context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Ad was not completed, so no earning was added.'),
                  ),
                );
              }
            },
            onAdFailedToShowFullScreenContent: (RewardedAd ad, AdError error) {
              ad.dispose();
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Unable to show ad: ${error.message}')),
                );
              }
            },
          );

          ad.show(
            onUserEarnedReward: (AdWithoutView ad, RewardItem reward) async {
              rewardGranted = true;
              await _completeAdAndAddEarning(
                user.uid,
                dayKey,
                adId,
              );

              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      'Ad completed! ₹${rewardPerAd.toStringAsFixed(2)} added to your wallet.',
                    ),
                  ),
                );
              }
            },
          );
        },
        onAdFailedToLoad: (LoadAdError error) {
          isLoading = false;
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Ad not available right now: ${error.message}')),
            );
          }
        },
      ),
    );

    // Keeps the variable intentionally alive through the async load callback.
    // No automatic retry is performed so a pending ad remains available.
    if (isLoading) {
      // Loading is handled by the RewardedAd callback.
    }
  }

  static Future<void> _completeAdAndAddEarning(
    String uid,
    String dayKey,
    String adId,
  ) async {
    final firestore = FirebaseFirestore.instance;
    final adRef = _adsCollection(uid, dayKey).doc(adId);
    final dayRef = firestore
        .collection('users')
        .doc(uid)
        .collection('adDays')
        .doc(dayKey);
    final userRef = firestore.collection('users').doc(uid);

    await firestore.runTransaction((transaction) async {
      final adSnapshot = await transaction.get(adRef);
      if (!adSnapshot.exists) return;

      final adData = adSnapshot.data() ?? {};
      if (adData['status'] != 'pending') return;

      final daySnapshot = await transaction.get(dayRef);
      final dayData = daySnapshot.data() ?? <String, dynamic>{};

      final pendingAds = (dayData['pendingAds'] ?? 0) as num;
      final completedAds = (dayData['completedAds'] ?? 0) as num;
      final totalEarned = (dayData['totalEarned'] ?? 0) as num;

      transaction.update(adRef, {
        'status': 'completed',
        'completedAt': FieldValue.serverTimestamp(),
        'reward': rewardPerAd,
      });

      transaction.set(dayRef, {
        'dateKey': dayKey,
        'availableAds': dayData['availableAds'] ?? 0,
        'pendingAds': pendingAds > 0 ? pendingAds.toInt() - 1 : 0,
        'completedAds': completedAds.toInt() + 1,
        'totalEarned': totalEarned.toDouble() + rewardPerAd,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      transaction.update(userRef, {
        'walletBalance': FieldValue.increment(rewardPerAd),
        'totalEarnings': FieldValue.increment(rewardPerAd),
        'adEarningsTotal': FieldValue.increment(rewardPerAd),
      });
    });
  }
}

class DriveMintApp extends StatelessWidget {
  const DriveMintApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'DriveMint',
      theme: ThemeData(
        useMaterial3: true,
        fontFamily: 'Roboto',
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0D47A1),
        ),
      ),
      home: const SplashScreen(),
    );
  }
}

// ================= SPLASH =================

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    _checkLogin();
  }

  Future<void> _checkLogin() async {
    await Future.delayed(const Duration(seconds: 2));

    if (!mounted) return;

    final user = FirebaseAuth.instance.currentUser;

    if (user != null) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => const DashboardScreen(),
        ),
      );
    } else {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => const WelcomeScreen(),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D47A1),
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 110,
                height: 110,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(28),
                ),
                child: const Icon(
                  Icons.local_taxi_rounded,
                  size: 65,
                  color: Color(0xFF0D47A1),
                ),
              ),
              const SizedBox(height: 28),
              const Text(
                'DriveMint',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 36,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Drive. Earn. Grow.',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 16,
                ),
              ),
              const SizedBox(height: 45),
              const CircularProgressIndicator(
                color: Colors.white,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ================= WELCOME =================
class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            children: [
              const Spacer(),
              Container(
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                  color: const Color(0xFF0D47A1),
                  borderRadius: BorderRadius.circular(30),
                ),
                child: const Icon(
                  Icons.sports_motorsports, // Updated Driver Logo
                  size: 70,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 30),
              const Text(
                'Welcome to DriveMint',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 30,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Track your rides, manage your earnings\nand grow with every kilometre.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 16,
                  color: Colors.grey,
                  height: 1.5,
                ),
              ),
              const Spacer(),
              SizedBox(
                width: double.infinity,
                height: 54,
                child: ElevatedButton(
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => const LoginScreen(),
                      ),
                    );
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF0D47A1),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  child: const Text(
                    'Get Started',
                    style: TextStyle(fontSize: 17),
                  ),
                ),
              ),
              const SizedBox(height: 30),
            ],
          ),
        ),
      ),
    );
  }
}

// ================= LOGIN =================
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final emailController = TextEditingController();
  final passwordController = TextEditingController();

  bool obscurePassword = true;
  bool loading = false;

  @override
  void dispose() {
    emailController.dispose();
    passwordController.dispose();
    super.dispose();
  }

  Future<void> login() async {
    final email = emailController.text.trim();
    final password = passwordController.text.trim();

    if (email.isEmpty || password.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter email and password')),
      );
      return;
    }

    setState(() => loading = true);

    try {
      await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: email,
        password: password,
      );

      if (!mounted) return;

      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (context) => const DashboardScreen(),
        ),
      );
    } on FirebaseAuthException catch (e) {
      String message = 'Login failed';
      if (e.code == 'user-not-found') {
        message = 'No account found with this email';
      } else if (e.code == 'wrong-password' || e.code == 'invalid-credential') message = 'Invalid email or password';
      else if (e.code == 'invalid-email') message = 'Invalid email address';

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Welcome Back 👋',
                style: TextStyle(fontSize: 30, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              const Text(
                'Login to continue with DriveMint',
                style: TextStyle(color: Colors.grey),
              ),
              const SizedBox(height: 40),
              TextField(
                controller: emailController,
                keyboardType: TextInputType.emailAddress,
                decoration: InputDecoration(
                  labelText: 'Email',
                  prefixIcon: const Icon(Icons.email_outlined),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
                ),
              ),
              const SizedBox(height: 18),
              TextField(
                controller: passwordController,
                obscureText: obscurePassword,
                decoration: InputDecoration(
                  labelText: 'Password',
                  prefixIcon: const Icon(Icons.lock_outline),
                  suffixIcon: IconButton(
                    onPressed: () => setState(() => obscurePassword = !obscurePassword),
                    icon: Icon(obscurePassword ? Icons.visibility_off : Icons.visibility),
                  ),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
                ),
              ),
              const SizedBox(height: 28),
              SizedBox(
                width: double.infinity,
                height: 54,
                child: ElevatedButton(
                  onPressed: loading ? null : login,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF0D47A1),
                    foregroundColor: Colors.white,
                  ),
                  child: loading
                      ? const CircularProgressIndicator(color: Colors.white)
                      : const Text('Login', style: TextStyle(fontSize: 17)),
                ),
              ),
              const SizedBox(height: 20),
              Center(
                child: TextButton(
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (context) => const SignupScreen()),
                    );
                  },
                  child: const Text("Don't have an account? Sign Up"),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ================= SIGNUP =================
class SignupScreen extends StatefulWidget {
  const SignupScreen({super.key});

  @override
  State<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends State<SignupScreen> {
  final nameController = TextEditingController();
  final emailController = TextEditingController();
  final passwordController = TextEditingController();
  DateTime? selectedDob;

  bool obscurePassword = true;
  bool loading = false;

  @override
  void dispose() {
    nameController.dispose();
    emailController.dispose();
    passwordController.dispose();
    super.dispose();
  }

  Future<void> signup() async {
    final name = nameController.text.trim();
    final email = emailController.text.trim();
    final password = passwordController.text.trim();

    if (name.isEmpty || email.isEmpty || password.isEmpty || selectedDob == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please fill all fields')));
      return;
    }

    if (password.length < 6) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Password must be at least 6 characters')));
      return;
    }

    setState(() => loading = true);

    try {
      final credential = await FirebaseAuth.instance.createUserWithEmailAndPassword(
        email: email,
        password: password,
      );

      final user = credential.user;
      if (user == null) throw Exception('User creation failed');

      await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
        'name': name,
        'email': email,
        'dob': _formatDate(selectedDob!),
        'createdAt': FieldValue.serverTimestamp(),
        'totalKm': 0.0,
        'totalEarnings': 0.0,
        'walletBalance': 0.0,
        'adEarningsTotal': 0.0,
      });

      if (!mounted) return;

      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (context) => const DashboardScreen()),
        (route) => false,
      );
    } on FirebaseAuthException catch (e) {
      String message = 'Signup failed';
      if (e.code == 'email-already-in-use') {
        message = 'This email is already registered';
      } else if (e.code == 'weak-password') message = 'Password is too weak';
      else if (e.code == 'invalid-email') message = 'Invalid email address';

      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  String _formatDate(DateTime date) {
    return '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}';
  }

  Future<void> _pickDob() async {
    final today = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: selectedDob ?? DateTime(today.year - 18, today.month, today.day),
      firstDate: DateTime(1900),
      lastDate: today,
      helpText: 'Select date of birth',
    );

    if (date != null) setState(() => selectedDob = date);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Create Account')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              const Align(
                alignment: Alignment.centerLeft,
                child: Text('Join DriveMint 🚗', style: TextStyle(fontSize: 30, fontWeight: FontWeight.bold)),
              ),
              const SizedBox(height: 30),
              TextField(
                controller: nameController,
                decoration: InputDecoration(
                  labelText: 'Full Name',
                  prefixIcon: const Icon(Icons.person_outline),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
                ),
              ),
              const SizedBox(height: 18),
              TextField(
                controller: emailController,
                keyboardType: TextInputType.emailAddress,
                decoration: InputDecoration(
                  labelText: 'Email',
                  prefixIcon: const Icon(Icons.email_outlined),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
                ),
              ),
              const SizedBox(height: 18),
              InkWell(
                onTap: _pickDob,
                borderRadius: BorderRadius.circular(14),
                child: InputDecorator(
                  decoration: InputDecoration(
                    labelText: 'Date of Birth',
                    prefixIcon: const Icon(Icons.cake_outlined),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                  child: Text(
                    selectedDob == null ? 'Select your date of birth' : _formatDate(selectedDob!),
                    style: TextStyle(color: selectedDob == null ? Colors.grey : Colors.black87),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              TextField(
                controller: passwordController,
                obscureText: obscurePassword,
                decoration: InputDecoration(
                  labelText: 'Password',
                  prefixIcon: const Icon(Icons.lock_outline),
                  suffixIcon: IconButton(
                    onPressed: () => setState(() => obscurePassword = !obscurePassword),
                    icon: Icon(obscurePassword ? Icons.visibility_off : Icons.visibility),
                  ),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
                ),
              ),
              const SizedBox(height: 28),
              SizedBox(
                width: double.infinity,
                height: 54,
                child: ElevatedButton(
                  onPressed: loading ? null : signup,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF0D47A1),
                    foregroundColor: Colors.white,
                  ),
                  child: loading
                      ? const CircularProgressIndicator(color: Colors.white)
                      : const Text('Create Account', style: TextStyle(fontSize: 17)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ================= DASHBOARD / HOME =================
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  int selectedIndex = 0;

  final List<Widget> screens = const [
    HomeScreen(),
    RideHistoryScreen(),
    WalletScreen(),
    ProfileScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: selectedIndex,
        children: screens,
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: selectedIndex,
        onDestinationSelected: (index) {
          setState(() {
            selectedIndex = index;
          });
        },
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: 'Home'),
          NavigationDestination(icon: Icon(Icons.history_outlined), selectedIcon: Icon(Icons.history), label: 'Rides'),
          NavigationDestination(icon: Icon(Icons.account_balance_wallet_outlined), selectedIcon: Icon(Icons.account_balance_wallet), label: 'Wallet'),
          NavigationDestination(icon: Icon(Icons.person_outline), selectedIcon: Icon(Icons.person), label: 'Profile'),
        ],
      ),
    );
  }
}

// ================= HOME =================
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String selectedVehicle = 'Car';

  static const Color primaryBlue = Color(0xFF1565D8);
  static const Color darkBlue = Color(0xFF0B3B91);
  static const Color accentYellow = Color(0xFFFFB800);
  static const Color pageBackground = Color(0xFFF6F9FE);

  Future<Map<String, dynamic>?> getUserData() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return null;

    final doc = await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .get();

    return doc.data();
  }

  String _todayKey() => DriveMintAdService.dateKey(DateTime.now());

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: pageBackground,
      body: FutureBuilder<Map<String, dynamic>?>(
        future: getUserData(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator(color: primaryBlue));
          }

          final data = snapshot.data ?? {};
          final name = data['name'] ?? 'Driver';
          final wallet = (data['walletBalance'] ?? 0).toDouble();
          final totalKm = (data['totalKm'] ?? 0).toDouble();
          final earnings = (data['totalEarnings'] ?? 0).toDouble();

          return SafeArea(
            child: RefreshIndicator(
              color: primaryBlue,
              onRefresh: () async => setState(() {}),
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(18, 16, 18, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildHeader(name.toString()),
                    const SizedBox(height: 20),
                    _buildWalletCard(wallet: wallet, earnings: earnings),
                    const SizedBox(height: 20),
                    _buildTodayAdCard(),
                    const SizedBox(height: 24),
                    _buildSectionHeader("Today's Summary"),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: _summaryCard(
                            title: 'Total KM',
                            value: totalKm.toStringAsFixed(1),
                            unit: 'KM',
                            icon: Icons.route_rounded,
                            iconBackground: const Color(0xFFE8F1FF),
                            iconColor: primaryBlue,
                            showGrowth: totalKm > 0,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _summaryCard(
                            title: 'Total Earnings',
                            value: '₹${earnings.toStringAsFixed(2)}',
                            unit: '',
                            icon: Icons.currency_rupee_rounded,
                            iconBackground: const Color(0xFFE9F9EF),
                            iconColor: Colors.green,
                            showGrowth: earnings > 0,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 25),
                    const Text(
                      'Choose Vehicle',
                      style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: Color(0xFF14213D)),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(child: _vehicleCard(type: 'Bike', icon: Icons.two_wheeler_rounded, subtitle: 'Fast & economical')),
                        const SizedBox(width: 12),
                        Expanded(child: _vehicleCard(type: 'Car', icon: Icons.directions_car_rounded, subtitle: 'Comfort & safe')),
                      ],
                    ),
                    const SizedBox(height: 18),
                    _buildStartRideButton(),
                    const SizedBox(height: 14),
                    _buildRateCard(),
                    const SizedBox(height: 24),
                    _buildRecentRidePlaceholder(),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildTodayAdCard() {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return const SizedBox.shrink();

    final dayRef = FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .collection('adDays')
        .doc(_todayKey());

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: dayRef.snapshots(),
      builder: (context, daySnapshot) {
        final dayData = daySnapshot.data?.data() ?? {};
        final pending = (dayData['pendingAds'] ?? 0) as num;
        final completed = (dayData['completedAds'] ?? 0) as num;
        final earned = (dayData['totalEarned'] ?? 0).toDouble();

        return Container(
          width: double.infinity,
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0xFFDDE7F7)),
            boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 14, offset: const Offset(0, 5))],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    height: 44,
                    width: 44,
                    decoration: BoxDecoration(color: const Color(0xFFE8F1FF), borderRadius: BorderRadius.circular(13)),
                    child: const Icon(Icons.ondemand_video_rounded, color: primaryBlue),
                  ),
                  const SizedBox(width: 11),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Ad Earnings', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: Color(0xFF14213D))),
                        SizedBox(height: 3),
                        Text('Ads unlock after each completed ride hour', style: TextStyle(fontSize: 11.5, color: Colors.black54)),
                      ],
                    ),
                  ),
                  Text('₹${earned.toStringAsFixed(2)}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: Colors.green)),
                ],
              ),
              const SizedBox(height: 15),
              Row(
                children: [
                  Expanded(child: _adMiniStat('Pending', pending.toString(), Icons.pending_actions_rounded, Colors.orange)),
                  const SizedBox(width: 10),
                  Expanded(child: _adMiniStat('Completed', completed.toString(), Icons.check_circle_outline_rounded, Colors.green)),
                  const SizedBox(width: 10),
                  Expanded(child: _adMiniStat('Today', '₹${earned.toStringAsFixed(2)}', Icons.currency_rupee_rounded, primaryBlue)),
                ],
              ),
              if (pending > 0) ...[
                const SizedBox(height: 14),
                const Text('Pending ads are available below. Watch them to add money to your wallet.', style: TextStyle(fontSize: 11.5, color: Colors.black54)),
                const SizedBox(height: 10),
                StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                  stream: DriveMintAdService._adsCollection(user.uid, _todayKey()).where('status', isEqualTo: 'pending').snapshots(),
                  builder: (context, adSnapshot) {
                    final ads = adSnapshot.data?.docs ?? [];
                    return Column(
                      children: ads.map((doc) {
                        final ad = doc.data();
                        return Card(
                          margin: const EdgeInsets.only(bottom: 8),
                          elevation: 0,
                          color: const Color(0xFFF7FAFF),
                          child: ListTile(
                            dense: true,
                            leading: const Icon(Icons.play_circle_fill_rounded, color: primaryBlue),
                            title: Text('Ad ${ad['adNumber'] ?? ''}', style: const TextStyle(fontWeight: FontWeight.w700)),
                            subtitle: Text('Earn ₹${DriveMintAdService.rewardPerAd.toStringAsFixed(2)}'),
                            trailing: ElevatedButton(
                              onPressed: () => DriveMintAdService.showRewardedAdAndComplete(context: context, dayKey: _todayKey(), adId: doc.id),
                              child: const Text('Watch'),
                            ),
                          ),
                        );
                      }).toList(),
                    );
                  },
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _adMiniStat(String title, String value, IconData icon, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
      decoration: BoxDecoration(color: const Color(0xFFF7F9FC), borderRadius: BorderRadius.circular(13)),
      child: Column(
        children: [
          Icon(icon, size: 19, color: color),
          const SizedBox(height: 4),
          Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800)),
          Text(title, style: const TextStyle(fontSize: 9.5, color: Colors.black54)),
        ],
      ),
    );
  }

  Widget _buildHeader(String name) {
    return Row(
      children: [
        Container(
          height: 58, width: 58,
          decoration: BoxDecoration(color: const Color(0xFFE7EEF9), shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 3), boxShadow: [BoxShadow(color: primaryBlue.withValues(alpha: 0.12), blurRadius: 12, offset: const Offset(0, 4))]),
          child: const Icon(Icons.person_rounded, size: 32, color: primaryBlue),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Good Morning 👋', style: TextStyle(fontSize: 13, color: Colors.black54, fontWeight: FontWeight.w500)),
            const SizedBox(height: 2),
            Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: Color(0xFF14213D))),
            const SizedBox(height: 2),
            const Text('Ready to drive and earn', style: TextStyle(fontSize: 12.5, color: Colors.black54)),
          ]),
        ),
        Container(
          height: 46, width: 46,
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(15), boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 12, offset: const Offset(0, 4))]),
          child: const Icon(Icons.notifications_none_rounded, color: Color(0xFF14213D), size: 25),
        ),
      ],
    );
  }

  Widget _buildWalletCard({required double wallet, required double earnings}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [primaryBlue, Color(0xFF0D5ACB), darkBlue]),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [BoxShadow(color: primaryBlue.withValues(alpha: 0.24), blurRadius: 22, offset: const Offset(0, 10))],
      ),
      child: Column(children: [
        Row(children: [
          Container(height: 48, width: 48, decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(14)), child: const Icon(Icons.account_balance_wallet_rounded, color: Colors.white, size: 26)),
          const SizedBox(width: 12),
          const Text('Wallet Balance', style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600)),
          const Spacer(),
          const Text('Available', style: TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.w600)),
        ]),
        const SizedBox(height: 14),
        Align(alignment: Alignment.centerLeft, child: Text('₹ ${wallet.toStringAsFixed(2)}', style: const TextStyle(color: Colors.white, fontSize: 34, fontWeight: FontWeight.w800))),
        const SizedBox(height: 18),
        Container(height: 1, color: Colors.white.withValues(alpha: 0.18)),
        const SizedBox(height: 14),
        Row(children: [
          const Icon(Icons.trending_up_rounded, color: Colors.white, size: 22),
          const SizedBox(width: 10),
          const Expanded(child: Text('Total Earnings', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600))),
          Text('₹ ${earnings.toStringAsFixed(2)}', style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w800)),
        ]),
      ]),
    );
  }

  Widget _buildSectionHeader(String title) => Row(children: [Text(title, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800, color: Color(0xFF14213D))), const Spacer(), const Text('View all', style: TextStyle(color: primaryBlue, fontSize: 13, fontWeight: FontWeight.w700)), const Icon(Icons.chevron_right_rounded, color: primaryBlue, size: 20)]);

  Widget _summaryCard({required String title, required String value, required String unit, required IconData icon, required Color iconBackground, required Color iconColor, required bool showGrowth}) {
    return Container(
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20), boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.045), blurRadius: 14, offset: const Offset(0, 5))]),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(height: 42, width: 42, decoration: BoxDecoration(color: iconBackground, shape: BoxShape.circle), child: Icon(icon, color: iconColor, size: 22)),
        const SizedBox(height: 12), Text(title, style: const TextStyle(color: Colors.black54, fontSize: 12, fontWeight: FontWeight.w600)),
        const SizedBox(height: 5), Row(crossAxisAlignment: CrossAxisAlignment.end, children: [Flexible(child: Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Color(0xFF14213D), fontSize: 21, fontWeight: FontWeight.w800))), if (unit.isNotEmpty) Padding(padding: const EdgeInsets.only(left: 4, bottom: 2), child: Text(unit, style: TextStyle(color: iconColor, fontSize: 12, fontWeight: FontWeight.w800)))]),
        const SizedBox(height: 8), Row(children: [Icon(showGrowth ? Icons.arrow_upward_rounded : Icons.remove_rounded, color: showGrowth ? Colors.green : Colors.grey, size: 14), const SizedBox(width: 3), Text(showGrowth ? 'Active performance' : 'No rides yet', style: TextStyle(color: showGrowth ? Colors.green : Colors.grey, fontSize: 10.5, fontWeight: FontWeight.w600))]),
      ]),
    );
  }

  Widget _vehicleCard({required String type, required IconData icon, required String subtitle}) {
    final isSelected = selectedVehicle == type;
    return GestureDetector(
      onTap: () => setState(() => selectedVehicle = type),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220), padding: const EdgeInsets.all(13),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20), border: Border.all(color: isSelected ? primaryBlue : const Color(0xFFD8DEE8), width: isSelected ? 1.8 : 1), boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.035), blurRadius: 12, offset: const Offset(0, 4))]),
        child: Row(children: [
          Container(height: 54, width: 54, decoration: BoxDecoration(color: isSelected ? const Color(0xFFE8F1FF) : const Color(0xFFF1F4F8), shape: BoxShape.circle), child: Icon(icon, size: 29, color: isSelected ? primaryBlue : const Color(0xFF67758A))),
          const SizedBox(width: 10),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(type, style: const TextStyle(color: Color(0xFF14213D), fontSize: 16, fontWeight: FontWeight.w800)), const SizedBox(height: 3), Text(subtitle, maxLines: 2, style: const TextStyle(color: Colors.black54, fontSize: 10.5, height: 1.25))])),
          Icon(isSelected ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded, color: isSelected ? primaryBlue : const Color(0xFFA7AFBC), size: 23),
        ]),
      ),
    );
  }

  Widget _buildStartRideButton() {
    final isCar = selectedVehicle == 'Car';
    return SizedBox(
      width: double.infinity, height: 62,
      child: ElevatedButton(
        onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => RideTrackingScreen(vehicleType: selectedVehicle))),
        style: ElevatedButton.styleFrom(backgroundColor: accentYellow, foregroundColor: const Color(0xFF17233C), elevation: 5, shadowColor: accentYellow.withValues(alpha: 0.30), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)), padding: const EdgeInsets.symmetric(horizontal: 18)),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [Container(height: 38, width: 38, decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle), child: Icon(isCar ? Icons.directions_car_rounded : Icons.two_wheeler_rounded, color: primaryBlue, size: 22)), const SizedBox(width: 11), Text('START ${selectedVehicle.toUpperCase()} RIDE', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900, letterSpacing: 0.2)), const SizedBox(width: 8), const Icon(Icons.arrow_forward_rounded, size: 23)]),
      ),
    );
  }

  Widget _buildRateCard() => Container(width: double.infinity, padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14), decoration: BoxDecoration(color: const Color(0xFFFFFBF0), borderRadius: BorderRadius.circular(18), border: Border.all(color: const Color(0xFFFFE7A3))), child: Row(children: [Container(height: 42, width: 42, decoration: const BoxDecoration(color: Color(0xFFFFF0C2), shape: BoxShape.circle), child: const Icon(Icons.currency_rupee_rounded, color: Color(0xFFE09B00))), const SizedBox(width: 11), const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('DriveMint Rate', style: TextStyle(color: Colors.black54, fontSize: 11.5, fontWeight: FontWeight.w600)), SizedBox(height: 2), Text('₹ 0.50 / KM', style: TextStyle(color: Color(0xFF14213D), fontSize: 18, fontWeight: FontWeight.w800))])), const Icon(Icons.info_outline_rounded, color: Color(0xFF67758A), size: 22)]));

  Widget _buildRecentRidePlaceholder() => Container(width: double.infinity, padding: const EdgeInsets.all(17), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20), boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 13, offset: const Offset(0, 5))]), child: const Row(children: [Icon(Icons.route_rounded, color: primaryBlue, size: 26), SizedBox(width: 12), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('Recent Rides', style: TextStyle(color: Color(0xFF14213D), fontSize: 15, fontWeight: FontWeight.w800)), SizedBox(height: 4), Text('Your completed rides will appear here.', style: TextStyle(color: Colors.black54, fontSize: 11.5))])), Icon(Icons.chevron_right_rounded, color: Color(0xFF67758A))]));
}

// ================= LIVE RIDE =================
class RideTrackingScreen extends StatefulWidget {
  final String vehicleType;

  const RideTrackingScreen({super.key, required this.vehicleType});

  @override
  State<RideTrackingScreen> createState() => _RideTrackingScreenState();
}

class _RideTrackingScreenState extends State<RideTrackingScreen> {
  StreamSubscription<Position>? positionSubscription;
  Position? currentPosition;
  Position? lastPosition;
  GoogleMapController? mapController;
  final List<LatLng> routePoints = <LatLng>[];

  // Auto-follow keeps the map centered on the driver's live GPS position.
  bool autoFollowMap = true;
  bool rideStarted = false;
  bool loading = false;
  bool locationPermissionGranted = false;
  Timer? rideTimer;
  Duration rideDuration = Duration.zero;
  double totalKm = 0.0;
  DateTime? rideStartTime;
  bool restoringRide = true;

  static const double ratePerKm = 0.50;
  static const LatLng defaultLocation = LatLng(26.95, 75.78);

  double get currentEarnings => totalKm * ratePerKm;

  Future<bool> _ensureLocationPermission() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();

    if (!serviceEnabled) {
      _showMessage('Please turn on GPS/Location first');
      return false;
    }

    LocationPermission permission = await Geolocator.checkPermission();

    if (permission == LocationPermission.denied) {
      // Android permission dialog appears here when permission is not granted.
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.denied) {
      _showMessage('Location permission is required to start the ride');
      return false;
    }

    if (permission == LocationPermission.deniedForever) {
      _showMessage(
        'Location permission is disabled. Open Settings and allow location for DriveMint.',
      );
      return false;
    }

    if (!mounted) return false;

    setState(() {
      locationPermissionGranted = true;
    });

    return true;
  }

  Future<void> _moveCameraTo(Position position) async {
    if (mapController == null || !autoFollowMap) return;

    await mapController!.animateCamera(
      CameraUpdate.newLatLngZoom(
        LatLng(position.latitude, position.longitude),
        17,
      ),
    );
  }

  void _onMapCameraMove() {
    // If the driver manually moves the map, stop auto-following.
    if (autoFollowMap && mounted) {
      setState(() => autoFollowMap = false);
    }
  }

  Future<void> _recenterMap() async {
    final position = currentPosition;
    if (position == null) return;

    setState(() => autoFollowMap = true);

    if (mapController != null) {
      await mapController!.animateCamera(
        CameraUpdate.newLatLngZoom(
          LatLng(position.latitude, position.longitude),
          17,
        ),
      );
    }
  }
  @override
  void initState() {
    super.initState();
    restoreActiveRide();
  }

  Future<void> _syncAdsForCurrentRide() async {
    final start = rideStartTime;
    if (start == null || !rideStarted) return;

    try {
      await DriveMintAdService.unlockAdsForRide(
        rideStartTime: start,
      );
    } catch (e) {
      debugPrint('Ad unlock sync error: $e');
    }
  }
Future<void> clearActiveRide() async {
  try {
    final prefs = await SharedPreferences.getInstance();

    await prefs.remove('driveMint_activeRide');
    await prefs.remove('driveMint_totalKm');
    await prefs.remove('driveMint_rideStartTime');
  } catch (e) {
    debugPrint('Clear active ride error: $e');
  }
}
Future<void> restoreActiveRide() async {
  try {
    final prefs = await SharedPreferences.getInstance();

    final bool activeRide =
        prefs.getBool('driveMint_activeRide') ?? false;

    if (!activeRide) {
      if (mounted) {
        setState(() {
          restoringRide = false;
        });
      }
      return;
    }

    final savedKm =
        prefs.getDouble('driveMint_totalKm') ?? 0.0;

    final savedStartTime =
        prefs.getString('driveMint_rideStartTime');

    DateTime? startTime;

    if (savedStartTime != null) {
      startTime = DateTime.tryParse(savedStartTime);
    }

    // Current GPS position
    final position = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
      ),
    );

    if (!mounted) return;

    setState(() {
      currentPosition = position;
      lastPosition = position;

      // Restore ride data
      totalKm = savedKm;
      rideStarted = true;
      rideStartTime = startTime;

      // Restore map
      routePoints
        ..clear()
        ..add(
          LatLng(
            position.latitude,
            position.longitude,
          ),
        );

      autoFollowMap = true;

      // Restore timer
      if (startTime != null) {
        rideDuration =
            DateTime.now().difference(startTime);
      } else {
        rideDuration = Duration.zero;
      }

      restoringRide = false;
    });

    await _syncAdsForCurrentRide();

    rideTimer?.cancel();
    rideTimer = Timer.periodic(const Duration(seconds: 30), (_) async {
      if (!mounted || !rideStarted || rideStartTime == null) return;
      setState(() {
        rideDuration = DateTime.now().difference(rideStartTime!);
      });
      await _syncAdsForCurrentRide();
    });

    // Resume GPS tracking
    positionSubscription =
        Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 5,
      ),
    ).listen((newPosition) {
      if (!mounted || !rideStarted) return;

      if (lastPosition != null) {
        final meters =
            Geolocator.distanceBetween(
          lastPosition!.latitude,
          lastPosition!.longitude,
          newPosition.latitude,
          newPosition.longitude,
        );

        if (meters >= 2) {
          final addedKm = meters / 1000;

          setState(() {
            totalKm += addedKm;
            currentPosition = newPosition;

            routePoints.add(
              LatLng(
                newPosition.latitude,
                newPosition.longitude,
              ),
            );
          });

          lastPosition = newPosition;

          // Save updated ride data
          saveActiveRide();

          // Auto-follow map
          if (autoFollowMap) {
            _moveCameraTo(newPosition);
          }
        }
      } else {
        lastPosition = newPosition;

        setState(() {
          currentPosition = newPosition;

          routePoints.add(
            LatLng(
              newPosition.latitude,
              newPosition.longitude,
            ),
          );
        });
      }
    });
  } catch (e) {
    if (mounted) {
      setState(() {
        restoringRide = false;
      });
    }

    debugPrint(
      'Restore active ride error: $e',
    );
  }
}
Future<void> saveActiveRide() async {
  try {
    final prefs = await SharedPreferences.getInstance();

    await prefs.setBool(
      'driveMint_activeRide',
      true,
    );

    await prefs.setDouble(
      'driveMint_totalKm',
      totalKm,
    );

    if (rideStartTime != null) {
      await prefs.setString(
        'driveMint_rideStartTime',
        rideStartTime!.toIso8601String(),
      );
    }
  } catch (e) {
    debugPrint(
      'Save active ride error: $e',
    );
  }
}

  Future<void> startRide() async {
    if (loading || rideStarted) return;

    setState(() => loading = true);

    try {
      // Ask for location permission when Start Ride is pressed.
      final permissionGranted = await _ensureLocationPermission();
      if (!permissionGranted) return;

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );

      if (!mounted) return;

    setState(() {
  currentPosition = position;
  lastPosition = position;
  routePoints
    ..clear()
    ..add(LatLng(position.latitude, position.longitude));
  totalKm = 0.0;
  rideStarted = true;
  rideStartTime = DateTime.now();
  autoFollowMap = true;
  rideDuration = Duration.zero;
});

await saveActiveRide();

      rideTimer?.cancel();
      rideTimer = Timer.periodic(const Duration(seconds: 30), (_) async {
        if (!mounted || !rideStarted || rideStartTime == null) return;
        setState(() {
          rideDuration = DateTime.now().difference(rideStartTime!);
        });
        await _syncAdsForCurrentRide();
      });

      await _syncAdsForCurrentRide();

      await positionSubscription?.cancel();
    positionSubscription = Geolocator.getPositionStream(
    locationSettings: AndroidSettings(
    accuracy: LocationAccuracy.high,
    distanceFilter: 5,
    intervalDuration: Duration(seconds: 3),
    foregroundNotificationConfig: ForegroundNotificationConfig(
      notificationTitle: 'DriveMint • Ride in progress',
      notificationText: 'GPS tracking is active for your current ride.',
      notificationChannelName: 'DriveMint Ride Tracking',
      setOngoing: true,
      enableWakeLock: true,
    ),
  ),
).listen((newPosition) async {
        if (!mounted) return;

        if (lastPosition != null) {
          final meters = Geolocator.distanceBetween(
            lastPosition!.latitude,
            lastPosition!.longitude,
            newPosition.latitude,
            newPosition.longitude,
          );

          if (meters >= 2) {
            totalKm += meters / 1000;
            lastPosition = newPosition;
            routePoints.add(
              LatLng(newPosition.latitude, newPosition.longitude),
            );
          }
        } else {
          lastPosition = newPosition;
        }

        setState(() {
          currentPosition = newPosition;
        });

        await _moveCameraTo(newPosition);
      });
    } catch (e) {
      _showMessage('GPS error: $e');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> stopRide() async {
  if (!rideStarted || loading) return;

  // Stop button press hote hi ride state off
  setState(() {
    loading = true;
    rideStarted = false;
  });

  try {
    // 1. GPS tracking immediately stop
    await positionSubscription?.cancel();
    positionSubscription = null;

    // 2. Ride timer stop
    rideTimer?.cancel();
    rideTimer = null;

    // 3. Final GPS location lene ki koshish
    try {
      final finalPosition = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
        ),
      ).timeout(
        const Duration(seconds: 5),
      );

      if (lastPosition != null) {
        final finalMeters = Geolocator.distanceBetween(
          lastPosition!.latitude,
          lastPosition!.longitude,
          finalPosition.latitude,
          finalPosition.longitude,
        );

        if (finalMeters >= 2) {
          totalKm += finalMeters / 1000;
          lastPosition = finalPosition;
        }
      }

      currentPosition = finalPosition;
    } catch (e) {
      debugPrint('Final GPS skipped: $e');
    }

    // 4. Final ride values
    final double finalKm = totalKm;
    final double finalEarning = finalKm * ratePerKm;

    // 5. Clear active ride
    try {
      await clearActiveRide().timeout(
        const Duration(seconds: 5),
      );
    } catch (e) {
      debugPrint('Clear active ride error: $e');
    }

    // 6. Save ride to Firebase
    try {
      await saveRideToFirestore(
        finalKm: finalKm,
        finalEarning: finalEarning,
      ).timeout(
        const Duration(seconds: 10),
      );
    } catch (e) {
      debugPrint('Save ride error: $e');
    }

    if (!mounted) return;

    // 7. Loading OFF
    setState(() {
      loading = false;
      rideStarted = false;
      totalKm = finalKm;
    });

    // 8. Ride completed dialog
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Ride Completed 🎉'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Vehicle: ${widget.vehicleType}',
                style: const TextStyle(
                  fontWeight: FontWeight.w500,
                ),
              ),

              const SizedBox(height: 12),

              Text(
                'Distance: ${finalKm.toStringAsFixed(2)} KM',
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.bold,
                ),
              ),

              const SizedBox(height: 8),

              Text(
                'Earning: ₹${finalEarning.toStringAsFixed(2)}',
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.bold,
                ),
              ),

              const SizedBox(height: 12),

              const Text(
                'Amount added to your wallet.',
                style: TextStyle(
                  color: Colors.green,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(dialogContext);
                Navigator.pop(context);
              },
              child: const Text('Done'),
            ),
          ],
        );
      },
    );

    // 9. Ads sync dialog ke baad
    // Ride completion ko ads sync ke wajah se block nahi karenge.
    try {
      await _syncAdsForCurrentRide();
    } catch (e) {
      debugPrint('Ads sync error: $e');
    }
  } catch (e) {
    debugPrint('STOP RIDE ERROR: $e');

    if (!mounted) return;

    setState(() {
      loading = false;
      rideStarted = false;
    });

    _showMessage(
      'Ride stopped, but some data could not be saved: $e',
    );
  }
}
  Future<void> saveRideToFirestore({
  required double finalKm,
  required double finalEarning,
}) async {
  final user = FirebaseAuth.instance.currentUser;

  if (user == null) {
    throw Exception('User is not logged in');
  }

  final firestore = FirebaseFirestore.instance;

  final userRef = firestore
      .collection('users')
      .doc(user.uid);

  final rideRef = userRef
      .collection('rides')
      .doc();

  // Ride details save
  await rideRef.set({
    'rideId': rideRef.id,
    'distanceKm': finalKm,
    'ratePerKm': ratePerKm,
    'earning': finalEarning,
    'vehicleType': widget.vehicleType,

    'startTime': rideStartTime != null
        ? Timestamp.fromDate(rideStartTime!)
        : FieldValue.serverTimestamp(),

    'endTime': FieldValue.serverTimestamp(),
    'createdAt': FieldValue.serverTimestamp(),

    'status': 'completed',
  });

  // User total + wallet update
  await userRef.update({
    'totalKm': FieldValue.increment(finalKm),
    'totalEarnings': FieldValue.increment(finalEarning),
    'walletBalance': FieldValue.increment(finalEarning),
  });
}

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  String _formatDuration(Duration duration) {
    final hours = duration.inHours.toString().padLeft(2, '0');
    final minutes = (duration.inMinutes % 60).toString().padLeft(2, '0');
    final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
    return '$hours:$minutes:$seconds';
  }

  @override
  void dispose() {
    rideTimer?.cancel();
    positionSubscription?.cancel();
    mapController = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Live ${widget.vehicleType} Ride'),
        backgroundColor: const Color(0xFF0D47A1),
        foregroundColor: Colors.white,
      ),
      body: Stack(
        children: [
          Positioned.fill(
            child: GoogleMap(
              initialCameraPosition: CameraPosition(
                target: currentPosition == null
                    ? defaultLocation
                    : LatLng(
                        currentPosition!.latitude,
                        currentPosition!.longitude,
                      ),
                zoom: 15,
              ),
              onMapCreated: (controller) {
                mapController = controller;
                final position = currentPosition;
                if (position != null) {
                  _moveCameraTo(position);
                }
              },
              onCameraMove: (_) => _onMapCameraMove(),
              mapType: MapType.normal,
              // Google's native blue live-location dot.
              myLocationEnabled: locationPermissionGranted,
              myLocationButtonEnabled: locationPermissionGranted,
              zoomControlsEnabled: false,
              compassEnabled: true,
              markers: const <Marker>{},
              polylines: {
                if (routePoints.length >= 2)
                  Polyline(
                    polylineId: const PolylineId('driveMintRoute'),
                    points: List<LatLng>.unmodifiable(routePoints),
                    color: const Color(0xFF1565D8),
                    width: 6,
                    geodesic: true,
                    startCap: Cap.roundCap,
                    endCap: Cap.roundCap,
                    jointType: JointType.round,
                  ),
              },
            ),
          ),

          if (currentPosition == null)
            Positioned(
              top: 16,
              left: 16,
              right: 16,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: const [
                    BoxShadow(
                      blurRadius: 10,
                      color: Colors.black26,
                    ),
                  ],
                ),
                child: const Text(
                  'Map ready • Tap Start Ride to connect GPS',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ),

          if (currentPosition != null)
            Positioned(
              top: 16,
              left: 16,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: const [
                    BoxShadow(
                      blurRadius: 8,
                      color: Colors.black26,
                    ),
                  ],
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.gps_fixed, color: Colors.green, size: 18),
                    SizedBox(width: 6),
                    Text(
                      'GPS Connected',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
            ),

          Positioned(
            right: 16,
            bottom: 205,
            child: Material(
              color: Colors.white,
              elevation: 5,
              shape: const CircleBorder(),
              child: InkWell(
                onTap: _recenterMap,
                customBorder: const CircleBorder(),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Icon(
                    autoFollowMap
                        ? Icons.my_location_rounded
                        : Icons.location_searching_rounded,
                    color: autoFollowMap
                        ? const Color(0xFF0D47A1)
                        : Colors.black54,
                    size: 25,
                  ),
                ),
              ),
            ),
          ),

          Positioned(
            left: 16,
            right: 16,
            bottom: 20,
            child: Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(22),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.15),
                    blurRadius: 15,
                  ),
                ],
              ),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      _rideStat(
                        'Distance',
                        '${totalKm.toStringAsFixed(2)} KM',
                        Icons.route,
                      ),
                      _rideStat(
                        'Ride Time',
                        _formatDuration(rideDuration),
                        Icons.timer_outlined,
                      ),
                      _rideStat(
                        'Earning',
                        '₹${currentEarnings.toStringAsFixed(2)}',
                        Icons.currency_rupee,
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  SizedBox(
                    width: double.infinity,
                    height: 56,
                    child: ElevatedButton.icon(
                      onPressed: loading
                          ? null
                          : (rideStarted ? stopRide : startRide),
                      icon: loading
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                color: Colors.white,
                                strokeWidth: 2,
                              ),
                            )
                          : Icon(
                              rideStarted ? Icons.stop : Icons.play_arrow,
                            ),
                      label: Text(
                        loading
                            ? 'Getting GPS...'
                            : rideStarted
                                ? 'Stop Ride'
                                : 'Start Ride',
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: rideStarted
                            ? Colors.red
                            : const Color(0xFF0D47A1),
                        foregroundColor: Colors.white,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'DriveMint rate: ₹0.50 per KM',
                    style: TextStyle(color: Colors.grey, fontSize: 13),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _rideStat(String title, String value, IconData icon) {
    return Row(
      children: [
        Icon(icon, color: const Color(0xFF0D47A1)),
        const SizedBox(width: 8),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(color: Colors.grey, fontSize: 13),
            ),
            Text(
              value,
              style: const TextStyle(
                fontSize: 19,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

// ================= RIDE HISTORY =================
class RideHistoryScreen extends StatelessWidget {
  const RideHistoryScreen({super.key});

  String formatDate(Timestamp? timestamp) {
    if (timestamp == null) return 'Date unavailable';
    final date = timestamp.toDate();
    return '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return const Scaffold(body: Center(child: Text('Please login again')));
    }

    final ridesStream = FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .collection('rides')
        .orderBy('createdAt', descending: true)
        .snapshots();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Ride History'),
        backgroundColor: const Color(0xFF0D47A1),
        foregroundColor: Colors.white,
      ),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: ridesStream,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(child: Padding(padding: const EdgeInsets.all(20), child: Text('Unable to load ride history.\n\n${snapshot.error}', textAlign: TextAlign.center)));
          }

          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          final rides = snapshot.data?.docs ?? [];
          if (rides.isEmpty) {
            return const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.history, size: 70, color: Colors.grey),
                  SizedBox(height: 12),
                  Text('No rides yet', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                  SizedBox(height: 5),
                  Text('Complete your first ride to see it here.', style: TextStyle(color: Colors.grey)),
                ],
              ),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: rides.length,
            itemBuilder: (context, index) {
              final data = rides[index].data();
              final distance = (data['distanceKm'] ?? 0).toDouble();
              final earning = (data['earning'] ?? 0).toDouble();
              final durationSeconds = (data['durationSeconds'] ?? 0).toInt();
              final durationHours = durationSeconds ~/ 3600;
              final durationMinutes = (durationSeconds % 3600) ~/ 60;
              final timestamp = data['createdAt'] as Timestamp?;
              
              // Reads vehicle type from Firestore
              final vehicleType = data['vehicleType'] ?? 'Car';
              final isBike = vehicleType == 'Bike';

              return Card(
                margin: const EdgeInsets.only(bottom: 12),
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: const Color(0xFFE8F0FE),
                    child: Icon(
                      isBike ? Icons.motorcycle : Icons.directions_car, // Dynamic Icon
                      color: const Color(0xFF0D47A1),
                    ),
                  ),
                  title: Text('${distance.toStringAsFixed(2)} KM ($vehicleType)', style: const TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: Text(
                    '${formatDate(timestamp)}\nTime: ${durationHours}h ${durationMinutes}m',
                  ),
                  trailing: Text('+₹${earning.toStringAsFixed(2)}', style: const TextStyle(color: Colors.green, fontWeight: FontWeight.bold)),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

// ================= WALLET =================
class WalletScreen extends StatelessWidget {
  const WalletScreen({super.key});

  String _formatDate(String key) {
    final parts = key.split('-');
    if (parts.length != 3) return key;
    return '${parts[2]}/${parts[1]}/${parts[0]}';
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return const Scaffold(body: Center(child: Text('Please login again')));

    final daysStream = FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .collection('adDays')
        .orderBy('dateKey', descending: true)
        .limit(30)
        .snapshots();

    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FA),
      appBar: AppBar(title: const Text('Wallet'), backgroundColor: const Color(0xFF0D47A1), foregroundColor: Colors.white),
      body: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance.collection('users').doc(user.uid).snapshots(),
        builder: (context, userSnapshot) {
          final data = userSnapshot.data?.data() ?? {};
          final wallet = (data['walletBalance'] ?? 0).toDouble();
          final earnings = (data['totalEarnings'] ?? 0).toDouble();
          final adTotal = (data['adEarningsTotal'] ?? 0).toDouble();

          return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: daysStream,
            builder: (context, daysSnapshot) {
              final days = daysSnapshot.data?.docs ?? [];
              return ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  Container(
                    width: double.infinity, padding: const EdgeInsets.all(25),
                    decoration: BoxDecoration(color: const Color(0xFF0D47A1), borderRadius: BorderRadius.circular(22)),
                    child: Column(children: [const Icon(Icons.account_balance_wallet, color: Colors.white, size: 50), const SizedBox(height: 12), const Text('Available Balance', style: TextStyle(color: Colors.white70, fontSize: 16)), const SizedBox(height: 5), Text('₹${wallet.toStringAsFixed(2)}', style: const TextStyle(color: Colors.white, fontSize: 38, fontWeight: FontWeight.bold))]),
                  ),
                  const SizedBox(height: 16),
                  Card(child: ListTile(leading: const Icon(Icons.currency_rupee, color: Color(0xFF0D47A1)), title: const Text('Total Earnings'), trailing: Text('₹${earnings.toStringAsFixed(2)}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)))),
                  Card(child: ListTile(leading: const Icon(Icons.ondemand_video, color: Colors.green), title: const Text('Total Ad Earnings'), trailing: Text('₹${adTotal.toStringAsFixed(2)}', style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.green)))),
                  const SizedBox(height: 10),
                  const Text("Ad Earnings History", style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 8),
                  if (days.isEmpty) const Card(child: Padding(padding: EdgeInsets.all(18), child: Text('No ad earnings yet. Complete a 1-hour ride to unlock ads.'))),
                  ...days.map((dayDoc) {
                    final day = dayDoc.data();
                    final completed = (day['completedAds'] ?? 0) as num;
                    final pending = (day['pendingAds'] ?? 0) as num;
                    final earned = (day['totalEarned'] ?? 0).toDouble();
                    final key = day['dateKey']?.toString() ?? dayDoc.id;
                    return Card(
                      margin: const EdgeInsets.only(bottom: 10),
                      child: ListTile(
                        leading: const CircleAvatar(backgroundColor: Color(0xFFE9F9EF), child: Icon(Icons.calendar_today, color: Colors.green, size: 20)),
                        title: Text(_formatDate(key), style: const TextStyle(fontWeight: FontWeight.w800)),
                        subtitle: Text('Completed: ${completed.toInt()}  •  Pending: ${pending.toInt()}'),
                        trailing: Text('₹${earned.toStringAsFixed(2)}', style: const TextStyle(color: Colors.green, fontWeight: FontWeight.bold)),
                      ),
                    );
                  }),
                  const SizedBox(height: 10),
                  const Card(child: ListTile(leading: Icon(Icons.info_outline), title: Text('Ride Earning Rate'), trailing: Text('₹0.50 / KM', style: TextStyle(fontWeight: FontWeight.bold)))),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

// ================= PROFESSIONAL PROFILE =================

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  static const Color primaryBlue = Color(0xFF1565D8);
  static const Color darkBlue = Color(0xFF0B3B91);
  static const Color pageBackground = Color(0xFFF6F9FE);

  final ImagePicker _imagePicker = ImagePicker();

  bool uploadingPhoto = false;

  // ================= PHOTO OPTIONS =================

  Future<void> _showPhotoOptions() async {
    if (uploadingPhoto) return;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(24),
        ),
      ),
      builder: (sheetContext) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 45,
                  height: 5,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),

                const SizedBox(height: 20),

                const Text(
                  'Profile Photo',
                  style: TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.bold,
                  ),
                ),

                const SizedBox(height: 18),

                Row(
                  children: [
                    Expanded(
                      child: _photoOption(
                        icon: Icons.camera_alt_outlined,
                        title: 'Camera',
                        onTap: () async {
                          Navigator.pop(sheetContext);
                          await _pickPhoto(ImageSource.camera);
                        },
                      ),
                    ),

                    const SizedBox(width: 14),

                    Expanded(
                      child: _photoOption(
                        icon: Icons.photo_library_outlined,
                        title: 'Gallery',
                        onTap: () async {
                          Navigator.pop(sheetContext);
                          await _pickPhoto(ImageSource.gallery);
                        },
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _photoOption({
    required IconData icon,
    required String title,
    required VoidCallback onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(
          vertical: 20,
        ),
        decoration: BoxDecoration(
          color: primaryBlue.withOpacity(0.06),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: primaryBlue.withOpacity(0.12),
          ),
        ),
        child: Column(
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: primaryBlue.withOpacity(0.10),
                shape: BoxShape.circle,
              ),
              child: Icon(
                icon,
                color: primaryBlue,
                size: 26,
              ),
            ),

            const SizedBox(height: 10),

            Text(
              title,
              style: const TextStyle(
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ================= PICK PHOTO =================

  Future<void> _pickPhoto(ImageSource source) async {
    try {
      final XFile? image =
          await _imagePicker.pickImage(
        source: source,
        imageQuality: 80,
        maxWidth: 1000,
      );

      if (image == null) return;

      if (!mounted) return;

      setState(() {
        uploadingPhoto = true;
      });

      final user =
          FirebaseAuth.instance.currentUser;

      if (user == null) return;

      await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .update({
        'profileImagePath': image.path,
      });

      if (!mounted) return;

      setState(() {
        uploadingPhoto = false;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Profile photo updated successfully',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;

      setState(() {
        uploadingPhoto = false;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Unable to select photo: $e',
          ),
        ),
      );
    }
  }

  // ================= LOGOUT =================

  Future<void> logout(BuildContext context) async {
    await FirebaseAuth.instance.signOut();

    if (!context.mounted) return;

    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(
        builder: (_) => const WelcomeScreen(),
      ),
      (route) => false,
    );
  }

  // ================= AGE =================

  int? _calculateAge(String dob) {
    final parts = dob.split('/');

    if (parts.length != 3) return null;

    final day = int.tryParse(parts[0]);
    final month = int.tryParse(parts[1]);
    final year = int.tryParse(parts[2]);

    if (day == null ||
        month == null ||
        year == null) {
      return null;
    }

    final today = DateTime.now();

    var age = today.year - year;

    if (today.month < month ||
        (today.month == month &&
            today.day < day)) {
      age--;
    }

    return age >= 0 ? age : null;
  }

  // ================= BUILD =================

  @override
  Widget build(BuildContext context) {
    final user =
        FirebaseAuth.instance.currentUser;

    if (user == null) {
      return const Scaffold(
        body: Center(
          child: Text(
            'Please login again',
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: pageBackground,

      appBar: AppBar(
        elevation: 0,
        backgroundColor: pageBackground,
        surfaceTintColor: Colors.transparent,

        title: const Text(
          'My Profile',
          style: TextStyle(
            color: Colors.black87,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),

      body: StreamBuilder<
          DocumentSnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .snapshots(),

        builder: (context, snapshot) {
          if (snapshot.connectionState ==
              ConnectionState.waiting) {
            return const Center(
              child: CircularProgressIndicator(
                color: primaryBlue,
              ),
            );
          }

          final data =
              snapshot.data?.data() ?? {};

          // ================= NAME =================

          final name =
              data['name']
                          ?.toString()
                          .trim()
                          .isNotEmpty ==
                      true
                  ? data['name'].toString()
                  : 'Driver';

          // ================= EMAIL =================

          final email =
              data['email']
                          ?.toString()
                          .trim()
                          .isNotEmpty ==
                      true
                  ? data['email'].toString()
                  : user.email ?? '';

          // ================= PHONE =================

          final phone =
              data['phone']
                          ?.toString()
                          .trim()
                          .isNotEmpty ==
                      true
                  ? data['phone'].toString()
                  : 'Not added';

          // ================= DOB =================

          final dob =
              data['dob']?.toString() ?? '';

          final age =
              _calculateAge(dob);

          // ================= PROFILE IMAGE =================

          final profileImagePath =
              data['profileImagePath']
                      ?.toString() ??
                  '';

          return SafeArea(
            child: SingleChildScrollView(
              physics:
                  const BouncingScrollPhysics(),

              padding:
                  const EdgeInsets.fromLTRB(
                18,
                8,
                18,
                30,
              ),

              child: Column(
                children: [

                  // ================= PROFILE HEADER =================

                  Container(
                    width: double.infinity,

                    padding:
                        const EdgeInsets.fromLTRB(
                      20,
                      24,
                      20,
                      24,
                    ),

                    decoration:
                        BoxDecoration(
                      gradient:
                          const LinearGradient(
                        colors: [
                          primaryBlue,
                          darkBlue,
                        ],
                        begin:
                            Alignment.topLeft,
                        end:
                            Alignment.bottomRight,
                      ),

                      borderRadius:
                          BorderRadius.circular(
                        26,
                      ),

                      boxShadow: [
                        BoxShadow(
                          color: primaryBlue
                              .withOpacity(0.20),
                          blurRadius: 20,
                          offset:
                              const Offset(0, 8),
                        ),
                      ],
                    ),

                    child: Column(
                      children: [

                        // PROFILE PHOTO

                        GestureDetector(
                          onTap:
                              _showPhotoOptions,

                          child: Stack(
                            alignment:
                                Alignment.bottomRight,

                            children: [

                              Container(
                                width: 105,
                                height: 105,

                                decoration:
                                    BoxDecoration(
                                  shape:
                                      BoxShape.circle,

                                  color:
                                      Colors.white,

                                  border:
                                      Border.all(
                                    color:
                                        Colors.white,
                                    width: 4,
                                  ),
                                ),

                                child: ClipOval(
                                  child:
                                      profileImagePath
                                              .isNotEmpty
                                          ? Image.file(
                                              File(
                                                profileImagePath,
                                              ),
                                              fit:
                                                  BoxFit.cover,

                                              errorBuilder:
                                                  (
                                                context,
                                                error,
                                                stackTrace,
                                              ) {
                                                return const Icon(
                                                  Icons.person,
                                                  size: 62,
                                                  color:
                                                      primaryBlue,
                                                );
                                              },
                                            )
                                          : const Icon(
                                              Icons.person,
                                              size: 62,
                                              color:
                                                  primaryBlue,
                                            ),
                                ),
                              ),

                              Container(
                                width: 34,
                                height: 34,

                                decoration:
                                    BoxDecoration(
                                  color:
                                      Colors.white,
                                  shape:
                                      BoxShape.circle,

                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors
                                          .black
                                          .withOpacity(
                                        0.15,
                                      ),
                                      blurRadius: 6,
                                    ),
                                  ],
                                ),

                                child:
                                    const Icon(
                                  Icons
                                      .camera_alt,
                                  size: 18,
                                  color:
                                      primaryBlue,
                                ),
                              ),
                            ],
                          ),
                        ),

                        const SizedBox(height: 12),

                        const Text(
                          'Tap photo to change',
                          style: TextStyle(
                            color:
                                Colors.white70,
                            fontSize: 12,
                          ),
                        ),

                        const SizedBox(height: 12),

                        // NAME

                        Text(
                          name,
                          textAlign:
                              TextAlign.center,

                          style:
                              const TextStyle(
                            color: Colors.white,
                            fontSize: 23,
                            fontWeight:
                                FontWeight.bold,
                          ),
                        ),

                        const SizedBox(height: 5),

                        // EMAIL

                        Text(
                          email,
                          textAlign:
                              TextAlign.center,

                          style:
                              const TextStyle(
                            color:
                                Colors.white70,
                            fontSize: 13,
                          ),
                        ),

                        const SizedBox(height: 12),

                        // DRIVER BADGE

                        Container(
                          padding:
                              const EdgeInsets
                                  .symmetric(
                            horizontal: 13,
                            vertical: 6,
                          ),

                          decoration:
                              BoxDecoration(
                            color: Colors.white
                                .withOpacity(
                              0.15,
                            ),

                            borderRadius:
                                BorderRadius
                                    .circular(
                              20,
                            ),
                          ),

                          child: const Row(
                            mainAxisSize:
                                MainAxisSize.min,

                            children: [

                              Icon(
                                Icons.verified,
                                size: 16,
                                color:
                                    Colors.white,
                              ),

                              SizedBox(width: 6),

                              Text(
                                'DriveMint Driver',
                                style: TextStyle(
                                  color:
                                      Colors.white,
                                  fontWeight:
                                      FontWeight.w600,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 26),

                  // ================= PERSONAL INFORMATION =================

                  _sectionTitle(
                    'Personal Information',
                    Icons.person_outline,
                  ),

                  const SizedBox(height: 12),

                  _informationCard(
                    icon:
                        Icons.person_outline,
                    title:
                        'Full Name',
                    value:
                        name,
                  ),

                  _informationCard(
                    icon:
                        Icons.email_outlined,
                    title:
                        'Email Address',
                    value:
                        email,
                  ),

                  _informationCard(
                    icon:
                        Icons.phone_outlined,
                    title:
                        'Mobile Number',
                    value:
                        phone,
                  ),

                  if (dob.isNotEmpty)
                    _informationCard(
                      icon: Icons
                          .calendar_today_outlined,
                      title:
                          'Date of Birth',
                      value:
                          dob,
                    ),

                  if (age != null)
                    _informationCard(
                      icon:
                          Icons.cake_outlined,
                      title:
                          'Age',
                      value:
                          '$age years',
                    ),

                  const SizedBox(height: 14),

                  // ================= HELP =================

                  _sectionTitle(
                    'Help & Support',
                    Icons.help_outline,
                  ),

                  const SizedBox(height: 12),

                  _helpCard(),

                  const SizedBox(height: 24),

                  // ================= LOGOUT =================

                  SizedBox(
                    width: double.infinity,

                    child:
                        OutlinedButton.icon(
                      onPressed: () =>
                          logout(context),

                      icon: const Icon(
                        Icons.logout,
                        color: Colors.red,
                      ),

                      label: const Text(
                        'Logout',
                        style:
                            TextStyle(
                          color: Colors.red,
                          fontWeight:
                              FontWeight.bold,
                        ),
                      ),

                      style:
                          OutlinedButton.styleFrom(
                        minimumSize:
                            const Size(
                          double.infinity,
                          52,
                        ),

                        side:
                            BorderSide(
                          color: Colors.red
                              .withOpacity(
                            0.25,
                          ),
                        ),

                        shape:
                            RoundedRectangleBorder(
                          borderRadius:
                              BorderRadius
                                  .circular(
                            16,
                          ),
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(height: 18),

                  const Text(
                    'DriveMint • Driver Dashboard',
                    style: TextStyle(
                      color: Colors.grey,
                      fontSize: 12,
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

  // ================= SECTION TITLE =================

  Widget _sectionTitle(
    String title,
    IconData icon,
  ) {
    return Row(
      children: [

        Container(
          width: 38,
          height: 38,

          decoration:
              BoxDecoration(
            color:
                primaryBlue.withOpacity(
              0.08,
            ),
            borderRadius:
                BorderRadius.circular(
              11,
            ),
          ),

          child: Icon(
            icon,
            color: primaryBlue,
            size: 20,
          ),
        ),

        const SizedBox(width: 10),

        Text(
          title,
          style: const TextStyle(
            fontSize: 19,
            fontWeight:
                FontWeight.bold,
            color:
                Colors.black87,
          ),
        ),
      ],
    );
  }

  // ================= INFORMATION CARD =================

  Widget _informationCard({
    required IconData icon,
    required String title,
    required String value,
  }) {
    return Container(
      width: double.infinity,

      margin:
          const EdgeInsets.only(
        bottom: 10,
      ),

      padding:
          const EdgeInsets.all(16),

      decoration:
          BoxDecoration(
        color: Colors.white,

        borderRadius:
            BorderRadius.circular(
          17,
        ),

        boxShadow: [
          BoxShadow(
            color: Colors.black
                .withOpacity(0.035),
            blurRadius: 10,
            offset:
                const Offset(0, 3),
          ),
        ],
      ),

      child: Row(
        children: [

          Container(
            width: 43,
            height: 43,

            decoration:
                BoxDecoration(
              color:
                  primaryBlue.withOpacity(
                0.08,
              ),
              borderRadius:
                  BorderRadius.circular(
                12,
              ),
            ),

            child: Icon(
              icon,
              color: primaryBlue,
              size: 21,
            ),
          ),

          const SizedBox(width: 14),

          Expanded(
            child: Column(
              crossAxisAlignment:
                  CrossAxisAlignment.start,

              children: [

                Text(
                  title,
                  style:
                      const TextStyle(
                    color: Colors.grey,
                    fontSize: 12,
                  ),
                ),

                const SizedBox(height: 4),

                Text(
                  value,
                  maxLines: 2,
                  overflow:
                      TextOverflow.ellipsis,

                  style:
                      const TextStyle(
                    color:
                        Colors.black87,
                    fontSize: 15,
                    fontWeight:
                        FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ================= HELP CARD =================

  Widget _helpCard() {
    return Container(
      width: double.infinity,

      padding:
          const EdgeInsets.all(18),

      decoration:
          BoxDecoration(
        color: Colors.white,

        borderRadius:
            BorderRadius.circular(
          18,
        ),

        boxShadow: [
          BoxShadow(
            color: Colors.black
                .withOpacity(0.035),
            blurRadius: 10,
            offset:
                const Offset(0, 3),
          ),
        ],
      ),

      child: InkWell(
        borderRadius:
            BorderRadius.circular(
          18,
        ),

        onTap: () {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(
            const SnackBar(
              content: Text(
                'Help & Support options will be added here.',
              ),
            ),
          );
        },

        child: Row(
          children: [

            Container(
              width: 48,
              height: 48,

              decoration:
                  BoxDecoration(
                color:
                    primaryBlue.withOpacity(
                  0.08,
                ),
                borderRadius:
                    BorderRadius.circular(
                  14,
                ),
              ),

              child: const Icon(
                Icons.support_agent,
                color: primaryBlue,
                size: 27,
              ),
            ),

            const SizedBox(width: 14),

            const Expanded(
              child: Column(
                crossAxisAlignment:
                    CrossAxisAlignment.start,

                children: [

                  Text(
                    'Help & Support',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight:
                          FontWeight.bold,
                    ),
                  ),

                  SizedBox(height: 4),

                  Text(
                    'Get help with your DriveMint account and rides.',
                    style: TextStyle(
                      color: Colors.grey,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),

            const Icon(
              Icons.chevron_right,
              color: Colors.grey,
            ),
          ],
        ),
      ),
    );
  }
}