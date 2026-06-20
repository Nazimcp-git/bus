import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AuthProvider extends ChangeNotifier {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseDatabase _db = FirebaseDatabase.instance;

  User? _user;
  bool _isLoading = false;
  bool _hasMissingAssignments = false;
  
  String? _schoolId;
  String? _busId;
  String? _routeName;
  String? _schoolName;
  String? _role;
  String? _errorMessage;
  String? _name;

  User? get currentUser => _user;
  bool get isLoading => _isLoading;
  bool get hasMissingAssignments => _hasMissingAssignments;
  
  String? get schoolId => _schoolId;
  String? get busId => _busId;
  String? get routeName => _routeName;
  String? get schoolName => _schoolName;
  String? get role => _role;
  String? get errorMessage => _errorMessage;
  String? get name => _name;

  AuthProvider() {
    _auth.authStateChanges().listen((User? user) {
      _user = user;
      if (user != null) {
        if (_schoolId == null && !_isLoading) {
          _loadDriverProfile(user.uid);
        }
      } else {
        _clearState(keepError: true);
      }
      notifyListeners();
    });
  }

  void clearError() {
    _errorMessage = null;
    notifyListeners();
  }

  void _clearState({bool keepError = false}) {
    _schoolId = null;
    _busId = null;
    _routeName = null;
    _schoolName = null;
    _role = null;
    _name = null;
    _hasMissingAssignments = false;
    if (!keepError) {
      _errorMessage = null;
    }
    _isLoading = false;
  }

  Future<bool> signIn(String email, String password) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      final credential = await _auth.signInWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );
      
      if (credential.user != null) {
        // Load and verify profile immediately
        final success = await _loadDriverProfile(credential.user!.uid, password: password);
        if (!success) {
          final tempError = _errorMessage;
          final prefs = await SharedPreferences.getInstance();
          await prefs.clear();
          await _auth.signOut();
          _clearState(keepError: true);
          _errorMessage = tempError;
          notifyListeners();
          return false;
        }
        return true;
      }
      return false;
    } on FirebaseAuthException catch (e) {
      _errorMessage = _getAuthErrorMessage(e);
      _isLoading = false;
      notifyListeners();
      return false;
    } catch (e) {
      _errorMessage = "An unexpected error occurred: ${e.toString()}";
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  Future<void> signOut() async {
    _isLoading = true;
    notifyListeners();
    try {
      // Clear preferences used by background service
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();
      
      await _auth.signOut();
    } catch (e) {
      _errorMessage = "Error signing out: ${e.toString()}";
    } finally {
      _clearState();
      notifyListeners();
    }
  }

  Future<void> retryLoadingProfile() async {
    if (_user != null) {
      await _loadDriverProfile(_user!.uid);
    }
  }

  Future<bool> _loadDriverProfile(String uid, {String? password}) async {
    _isLoading = true;
    _errorMessage = null;
    Future.microtask(() => notifyListeners());

    try {
      final userSnapshot = await _db.ref('users/$uid').get();
      if (!userSnapshot.exists) {
        _errorMessage = "User profile not found in database.";
        _isLoading = false;
        notifyListeners();
        return false;
      }

      final userData = Map<String, dynamic>.from(userSnapshot.value as Map);
      
      // 1. Guardrail: Role check
      final role = userData['role']?.toString();
      if (role != 'driver' && role != 'parent') {
        _errorMessage = "Access Denied: Account role must be 'driver' or 'parent'.";
        _isLoading = false;
        notifyListeners();
        return false;
      }
      _role = role;
      _name = userData['name']?.toString() ?? 'Driver';

      // Extract details
      _schoolId = userData['schoolId']?.toString();
      _busId = userData['busId']?.toString();
      _routeName = userData['routeName']?.toString();

      // 3. Guardrail: Missing Assignments check
      if (_schoolId == null || _schoolId!.isEmpty || _busId == null || _busId!.isEmpty) {
        _hasMissingAssignments = true;
        _errorMessage = "No bus or school assigned. Contact Admin.";
      } else {
        _hasMissingAssignments = false;
        
        // Fetch School Name and Bus Route Name from database
        await _fetchSchoolName(_schoolId!);
        await _fetchBusRouteName(_schoolId!, _busId!);

        // Save to Shared Preferences so Background Service isolate can access it
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('schoolId', _schoolId!);
        await prefs.setString('busId', _busId!);
        await prefs.setString('routeName', _routeName ?? '');
        await prefs.setString('uid', uid);
        await prefs.setString('role', _role!);

        if (_role == 'parent' && password != null) {
          await prefs.setString('parent_email', _user?.email ?? '');
          await prefs.setString('parent_password', password);
        }
      }

      _isLoading = false;
      notifyListeners();
      return true;
    } catch (e) {
      // Handle db config/network errors gracefully
      _errorMessage = "Configuration Error: Ensure your Firebase database is reachable.\nDetail: ${e.toString()}";
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  Future<void> _fetchSchoolName(String schoolId) async {
    try {
      final schoolNameSnapshot = await _db.ref('schools/$schoolId/name').get();
      if (schoolNameSnapshot.exists) {
        _schoolName = schoolNameSnapshot.value?.toString();
      } else {
        _schoolName = "Unknown School";
      }
    } catch (e) {
      _schoolName = "School Network Err";
    }
  }

  Future<void> _fetchBusRouteName(String schoolId, String busId) async {
    try {
      final routeSnapshot = await _db.ref('schools/$schoolId/buses/$busId/routeName').get();
      if (routeSnapshot.exists) {
        _routeName = routeSnapshot.value?.toString();
      } else {
        _routeName = "No Route Assigned";
      }
    } catch (e) {
      _routeName = "Route Network Err";
    }
  }

  String _getAuthErrorMessage(FirebaseAuthException e) {
    switch (e.code) {
      case 'invalid-email':
        return 'The email address is badly formatted.';
      case 'user-disabled':
        return 'This driver account has been disabled.';
      case 'user-not-found':
        return 'No driver found with this email.';
      case 'wrong-password':
        return 'Incorrect password. Please try again.';
      case 'invalid-credential':
        return 'Invalid email or password.';
      case 'network-request-failed':
        return 'Network connection failed. Please check your internet.';
      default:
        return e.message ?? 'An unknown authentication error occurred.';
    }
  }
}
