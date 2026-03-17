import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/push_notification_service.dart';

// Supported languages with their locale codes
class AppLanguage {
  final String code;
  final String name;
  final String nativeName;
  final Locale locale;

  const AppLanguage({
    required this.code,
    required this.name,
    required this.nativeName,
    required this.locale,
  });
}

const List<AppLanguage> supportedLanguages = [
  AppLanguage(code: 'en', name: 'English (India)', nativeName: 'English', locale: Locale('en', 'IN')),
  AppLanguage(code: 'hi', name: 'Hindi', nativeName: 'हिंदी', locale: Locale('hi', 'IN')),
  AppLanguage(code: 'ta', name: 'Tamil', nativeName: 'தமிழ்', locale: Locale('ta', 'IN')),
  AppLanguage(code: 'te', name: 'Telugu', nativeName: 'తెలుగు', locale: Locale('te', 'IN')),
  AppLanguage(code: 'kn', name: 'Kannada', nativeName: 'ಕನ್ನಡ', locale: Locale('kn', 'IN')),
  AppLanguage(code: 'ml', name: 'Malayalam', nativeName: 'മലയാളം', locale: Locale('ml', 'IN')),
  AppLanguage(code: 'bn', name: 'Bengali', nativeName: 'বাংলা', locale: Locale('bn', 'IN')),
];

// Translation strings for each language
class AppStrings {
  static Map<String, Map<String, String>> translations = {
    'en': {
      // General
      'app_name': 'Raahi',
      'continue': 'Continue',
      'cancel': 'Cancel',
      'submit': 'Submit',
      'close': 'Close',
      'save': 'Save',
      'done': 'Done',
      'ok': 'OK',
      'yes': 'Yes',
      'no': 'No',
      'loading': 'Loading...',
      'error': 'Error',
      'success': 'Success',
      
      // Settings
      'settings': 'Settings',
      'notifications': 'Notifications',
      'notifications_desc': 'Receive ride alerts and updates',
      'location_sharing': 'Location Sharing',
      'location_sharing_desc': 'Share location while online',
      'language': 'Language',
      'dark_mode': 'Dark Mode',
      'dark_mode_desc': 'Switch to dark theme',
      'about': 'About',
      'about_desc': 'App info and legal',
      'logout': 'Logout',
      
      // Help & Support
      'help_support': 'Help & Support',
      'contact_support': 'Contact Support',
      'contact_support_desc': 'Get help from our team',
      'faqs': 'FAQs',
      'faqs_desc': 'Find answers to common questions',
      'report_issue': 'Report an Issue',
      'report_issue_desc': 'Let us know about problems',
      'send_feedback': 'Send Feedback',
      'send_feedback_desc': 'Help us improve the app',
      'helpline': '24/7 Helpline',
      'call_now': 'Call Now',
      
      // Earnings
      'earnings': 'Earnings',
      'today_earnings': "Today's Earnings",
      'trips_completed': 'trips completed',
      'this_week': 'This Week',
      'total_earnings': 'Total Earnings',
      'total_trips': 'Total Trips',
      'online_hours': 'Online Hours',
      'rating': 'Rating',
      
      // Ride History
      'ride_history': 'Ride History',
      'no_rides_yet': 'No ride history yet',
      'complete_rides': 'Complete rides to see your history',
      'trip_distance': 'Trip Distance',
      'fare': 'Fare',
      
      // Driver Home
      'start_riding': 'Start Riding',
      'stop_riding': 'Stop Riding',
      'home': 'Home',
      
      // Ride booking
      'book_ride': 'Book Ride',
      'pickup': 'Pickup',
      'destination': 'Destination',
      'select_ride_type': 'Select Ride Type',
      'confirm_booking': 'Confirm Booking',
      'searching_drivers': 'Searching for drivers...',
      'driver_assigned': 'Driver Assigned',
      'arriving_in': 'Arriving in',
      'eta': 'ETA',
      
      // Profile
      'profile': 'Profile',
      'edit_profile': 'Edit Profile',
      'saved_places': 'Saved Places',
      'total_rides': 'Total Rides',
      'payment_methods': 'Payment Methods',
      
      // Home
      'where_to': 'Where to?',
      'good_morning': 'Good Morning',
      'good_afternoon': 'Good Afternoon',
      'good_evening': 'Good Evening',
      'find_ride': 'Find a Ride',
      'recent_rides': 'Recent Rides',
      'places_near_you': 'Places near you',
      'create_trip': 'Create a Trip',
      
      // Find Trip
      'find_trip': 'Find a trip',
      'enter_pickup': 'Enter pickup location',
      'enter_destination': 'Enter destination',
      'book': 'Book',
      'select_drivers': 'Select Number of Drivers',
      
      // Profile
      'logout_confirm': 'Are you sure you want to sign out?',
      
      // General
      'enter_name': "What's your name?",
      'first_name': 'First name',
      'last_name': 'Last name',
      'next': 'Next',
      'back': 'Back',
      'retry': 'Retry',
      'no_internet': 'No internet connection',
      'something_went_wrong': 'Something went wrong',
    },
    'hi': {
      // General
      'app_name': 'राही',
      'continue': 'जारी रखें',
      'cancel': 'रद्द करें',
      'submit': 'जमा करें',
      'close': 'बंद करें',
      'save': 'सहेजें',
      'done': 'हो गया',
      'ok': 'ठीक है',
      'yes': 'हां',
      'no': 'नहीं',
      'loading': 'लोड हो रहा है...',
      'error': 'त्रुटि',
      'success': 'सफलता',
      
      // Settings
      'settings': 'सेटिंग्स',
      'notifications': 'सूचनाएं',
      'notifications_desc': 'राइड अलर्ट और अपडेट प्राप्त करें',
      'location_sharing': 'लोकेशन शेयरिंग',
      'location_sharing_desc': 'ऑनलाइन होने पर लोकेशन साझा करें',
      'language': 'भाषा',
      'dark_mode': 'डार्क मोड',
      'dark_mode_desc': 'डार्क थीम पर स्विच करें',
      'about': 'एप के बारे में',
      'about_desc': 'एप जानकारी और कानूनी',
      'logout': 'लॉग आउट',
      
      // Help & Support
      'help_support': 'सहायता और समर्थन',
      'contact_support': 'सहायता से संपर्क करें',
      'contact_support_desc': 'हमारी टीम से मदद प्राप्त करें',
      'faqs': 'अक्सर पूछे जाने वाले प्रश्न',
      'faqs_desc': 'सामान्य प्रश्नों के उत्तर खोजें',
      'report_issue': 'समस्या की रिपोर्ट करें',
      'report_issue_desc': 'हमें समस्याओं के बारे में बताएं',
      'send_feedback': 'प्रतिक्रिया भेजें',
      'send_feedback_desc': 'एप को बेहतर बनाने में हमारी मदद करें',
      'helpline': '24/7 हेल्पलाइन',
      'call_now': 'अभी कॉल करें',
      
      // Earnings
      'earnings': 'कमाई',
      'today_earnings': 'आज की कमाई',
      'trips_completed': 'ट्रिप पूर्ण',
      'this_week': 'इस सप्ताह',
      'total_earnings': 'कुल कमाई',
      'total_trips': 'कुल ट्रिप',
      'online_hours': 'ऑनलाइन घंटे',
      'rating': 'रेटिंग',
      
      // Ride History
      'ride_history': 'राइड इतिहास',
      'no_rides_yet': 'अभी तक कोई राइड इतिहास नहीं',
      'complete_rides': 'इतिहास देखने के लिए राइड पूरी करें',
      'trip_distance': 'ट्रिप की दूरी',
      'fare': 'किराया',
      
      // Driver Home
      'start_riding': 'राइड शुरू करें',
      'stop_riding': 'राइड रोकें',
      'home': 'होम',
      
      // Ride booking
      'book_ride': 'राइड बुक करें',
      'pickup': 'पिकअप',
      'destination': 'गंतव्य',
      'select_ride_type': 'राइड प्रकार चुनें',
      'confirm_booking': 'बुकिंग की पुष्टि करें',
      'searching_drivers': 'ड्राइवर खोज रहे हैं...',
      'driver_assigned': 'ड्राइवर असाइन किया गया',
      'arriving_in': 'पहुंच रहे हैं',
      'eta': 'अनुमानित समय',
      
      // Profile
      'profile': 'प्रोफ़ाइल',
      'edit_profile': 'प्रोफ़ाइल संपादित करें',
      'saved_places': 'सहेजे गए स्थान',
      'total_rides': 'कुल राइड',
      'payment_methods': 'भुगतान के तरीके',
      
      // Home
      'where_to': 'कहाँ जाना है?',
      'good_morning': 'शुभ प्रभात',
      'good_afternoon': 'शुभ दोपहर',
      'good_evening': 'शुभ संध्या',
      'find_ride': 'राइड खोजें',
      'recent_rides': 'हाल की राइड',
      'places_near_you': 'आस-पास के स्थान',
      'create_trip': 'ट्रिप बनाएं',
      
      // Find Trip
      'find_trip': 'ट्रिप खोजें',
      'enter_pickup': 'पिकअप स्थान दर्ज करें',
      'enter_destination': 'गंतव्य दर्ज करें',
      'book': 'बुक करें',
      'select_drivers': 'ड्राइवरों की संख्या चुनें',
      
      // Profile
      'logout_confirm': 'क्या आप वाकई साइन आउट करना चाहते हैं?',
      
      // General
      'enter_name': 'आपका नाम क्या है?',
      'first_name': 'पहला नाम',
      'last_name': 'उपनाम',
      'next': 'अगला',
      'back': 'वापस',
      'retry': 'पुनः प्रयास करें',
      'no_internet': 'इंटरनेट कनेक्शन नहीं है',
      'something_went_wrong': 'कुछ गलत हो गया',
    },
    'ta': {
      'app_name': 'ராஹி',
      'continue': 'தொடரவும்',
      'cancel': 'ரத்து செய்',
      'submit': 'சமர்ப்பிக்கவும்',
      'close': 'மூடு',
      'settings': 'அமைப்புகள்',
      'notifications': 'அறிவிப்புகள்',
      'notifications_desc': 'சவாரி எச்சரிக்கைகள் பெறுங்கள்',
      'language': 'மொழி',
      'dark_mode': 'இருண்ட பயன்முறை',
      'dark_mode_desc': 'இருண்ட தீம் மாற்றவும்',
      'logout': 'வெளியேறு',
      'earnings': 'வருமானம்',
      'today_earnings': 'இன்றைய வருமானம்',
      'ride_history': 'பயண வரலாறு',
      'help_support': 'உதவி & ஆதரவு',
      'home': 'முகப்பு',
      'book_ride': 'சவாரி புக் செய்',
      'start_riding': 'சவாரி தொடங்கு',
      'stop_riding': 'சவாரி நிறுத்து',
      'profile': 'சுயவிவரம்',
      'saved_places': 'சேமித்த இடங்கள்',
      'about': 'பற்றி',
      'about_desc': 'ஆப் தகவல்',
      'where_to': 'எங்கே செல்ல வேண்டும்?',
      'places_near_you': 'அருகிலுள்ள இடங்கள்',
      'create_trip': 'பயணம் உருவாக்கு',
      'find_trip': 'பயணம் கண்டுபிடி',
      'enter_pickup': 'பிக்அப் இடத்தை உள்ளிடவும்',
      'enter_destination': 'இலக்கை உள்ளிடவும்',
      'book': 'புக் செய்',
      'select_drivers': 'ஓட்டுநர்களின் எண்ணிக்கையைத் தேர்ந்தெடுக்கவும்',
      'logout_confirm': 'நீங்கள் நிச்சயமாக வெளியேற விரும்புகிறீர்களா?',
    },
    'te': {
      'app_name': 'రాహి',
      'continue': 'కొనసాగించు',
      'cancel': 'రద్దు చేయి',
      'submit': 'సమర్పించు',
      'close': 'మూసివేయి',
      'settings': 'సెట్టింగ్‌లు',
      'notifications': 'నోటిఫికేషన్లు',
      'notifications_desc': 'రైడ్ అలర్ట్‌లు పొందండి',
      'language': 'భాష',
      'dark_mode': 'డార్క్ మోడ్',
      'dark_mode_desc': 'డార్క్ థీమ్‌కు మారండి',
      'logout': 'లాగ్ అవుట్',
      'earnings': 'ఆదాయం',
      'today_earnings': 'నేటి ఆదాయం',
      'ride_history': 'రైడ్ చరిత్ర',
      'help_support': 'సహాయం & మద్దతు',
      'home': 'హోమ్',
      'book_ride': 'రైడ్ బుక్ చేయండి',
      'start_riding': 'రైడింగ్ ప్రారంభించు',
      'stop_riding': 'రైడింగ్ ఆపు',
      'profile': 'ప్రొఫైల్',
      'saved_places': 'సేవ్ చేసిన ప్రదేశాలు',
      'about': 'గురించి',
      'about_desc': 'యాప్ సమాచారం',
      'where_to': 'ఎక్కడికి వెళ్ళాలి?',
      'places_near_you': 'సమీపంలోని ప్రదేశాలు',
      'create_trip': 'ట్రిప్ సృష్టించు',
      'find_trip': 'ట్రిప్ కనుగొనండి',
      'enter_pickup': 'పికప్ స్థానాన్ని నమోదు చేయండి',
      'enter_destination': 'గమ్యస్థానాన్ని నమోదు చేయండి',
      'book': 'బుక్ చేయండి',
      'select_drivers': 'డ్రైవర్ల సంఖ్యను ఎంచుకోండి',
      'logout_confirm': 'మీరు ఖచ్చితంగా సైన్ అవుట్ చేయాలనుకుంటున్నారా?',
    },
    'kn': {
      'app_name': 'ರಾಹಿ',
      'continue': 'ಮುಂದುವರಿಸಿ',
      'cancel': 'ರದ್ದುಮಾಡಿ',
      'submit': 'ಸಲ್ಲಿಸಿ',
      'close': 'ಮುಚ್ಚಿ',
      'settings': 'ಸೆಟ್ಟಿಂಗ್‌ಗಳು',
      'notifications': 'ಅಧಿಸೂಚನೆಗಳು',
      'language': 'ಭಾಷೆ',
      'dark_mode': 'ಡಾರ್ಕ್ ಮೋಡ್',
      'logout': 'ಲಾಗ್ ಔಟ್',
      'earnings': 'ಗಳಿಕೆ',
      'today_earnings': 'ಇಂದಿನ ಗಳಿಕೆ',
      'ride_history': 'ರೈಡ್ ಇತಿಹಾಸ',
      'help_support': 'ಸಹಾಯ ಮತ್ತು ಬೆಂಬಲ',
      'home': 'ಮುಖಪುಟ',
      'book_ride': 'ರೈಡ್ ಬುಕ್ ಮಾಡಿ',
      'start_riding': 'ರೈಡಿಂಗ್ ಪ್ರಾರಂಭಿಸಿ',
      'stop_riding': 'ರೈಡಿಂಗ್ ನಿಲ್ಲಿಸಿ',
      'profile': 'ಪ್ರೊಫೈಲ್',
      'saved_places': 'ಉಳಿಸಿದ ಸ್ಥಳಗಳು',
      'about': 'ಬಗ್ಗೆ',
      'about_desc': 'ಅಪ್ಲಿಕೇಶನ್ ಮಾಹಿತಿ',
      'where_to': 'ಎಲ್ಲಿಗೆ ಹೋಗಬೇಕು?',
      'places_near_you': 'ಹತ್ತಿರದ ಸ್ಥಳಗಳು',
      'create_trip': 'ಟ್ರಿಪ್ ರಚಿಸಿ',
      'find_trip': 'ಟ್ರಿಪ್ ಹುಡುಕಿ',
      'enter_pickup': 'ಪಿಕಪ್ ಸ್ಥಳವನ್ನು ನಮೂದಿಸಿ',
      'enter_destination': 'ಗಮ್ಯಸ್ಥಾನವನ್ನು ನಮೂದಿಸಿ',
      'book': 'ಬುಕ್ ಮಾಡಿ',
      'select_drivers': 'ಚಾಲಕರ ಸಂಖ್ಯೆಯನ್ನು ಆಯ್ಕೆಮಾಡಿ',
      'logout_confirm': 'ನೀವು ಖಚಿತವಾಗಿ ಸೈನ್ ಔಟ್ ಮಾಡಲು ಬಯಸುವಿರಾ?',
    },
    'ml': {
      'app_name': 'രാഹി',
      'continue': 'തുടരുക',
      'cancel': 'റദ്ദാക്കുക',
      'submit': 'സമർപ്പിക്കുക',
      'close': 'അടയ്ക്കുക',
      'settings': 'ക്രമീകരണങ്ങൾ',
      'notifications': 'അറിയിപ്പുകൾ',
      'language': 'ഭാഷ',
      'dark_mode': 'ഡാർക്ക് മോഡ്',
      'logout': 'ലോഗ് ഔട്ട്',
      'earnings': 'വരുമാനം',
      'today_earnings': 'ഇന്നത്തെ വരുമാനം',
      'ride_history': 'റൈഡ് ചരിത്രം',
      'help_support': 'സഹായവും പിന്തുണയും',
      'home': 'ഹോം',
      'book_ride': 'റൈഡ് ബുക്ക് ചെയ്യുക',
      'start_riding': 'റൈഡിംഗ് ആരംഭിക്കുക',
      'stop_riding': 'റൈഡിംഗ് നിർത്തുക',
      'profile': 'പ്രൊഫൈൽ',
      'saved_places': 'സേവ് ചെയ്ത സ്ഥലങ്ങൾ',
      'about': 'കുറിച്ച്',
      'about_desc': 'ആപ്പ് വിവരങ്ങൾ',
      'where_to': 'എവിടേക്ക് പോകണം?',
      'places_near_you': 'സമീപത്തുള്ള സ്ഥലങ്ങൾ',
      'create_trip': 'ട്രിപ്പ് സൃഷ്ടിക്കുക',
      'find_trip': 'ട്രിപ്പ് കണ്ടെത്തുക',
      'enter_pickup': 'പിക്കപ്പ് സ്ഥലം നൽകുക',
      'enter_destination': 'ലക്ഷ്യസ്ഥാനം നൽകുക',
      'book': 'ബുക്ക് ചെയ്യുക',
      'select_drivers': 'ഡ്രൈവർമാരുടെ എണ്ണം തിരഞ്ഞെടുക്കുക',
      'logout_confirm': 'നിങ്ങൾ സൈൻ ഔട്ട് ചെയ്യാൻ ആഗ്രഹിക്കുന്നുണ്ടോ?',
    },
    'bn': {
      'app_name': 'রাহি',
      'continue': 'চালিয়ে যান',
      'cancel': 'বাতিল',
      'submit': 'জমা দিন',
      'close': 'বন্ধ করুন',
      'settings': 'সেটিংস',
      'notifications': 'বিজ্ঞপ্তি',
      'language': 'ভাষা',
      'dark_mode': 'ডার্ক মোড',
      'logout': 'লগ আউট',
      'earnings': 'উপার্জন',
      'today_earnings': 'আজকের উপার্জন',
      'ride_history': 'রাইড ইতিহাস',
      'help_support': 'সাহায্য ও সহায়তা',
      'home': 'হোম',
      'book_ride': 'রাইড বুক করুন',
      'start_riding': 'রাইডিং শুরু করুন',
      'stop_riding': 'রাইডিং বন্ধ করুন',
      'profile': 'প্রোফাইল',
      'saved_places': 'সংরক্ষিত স্থান',
      'about': 'সম্পর্কে',
      'about_desc': 'অ্যাপ তথ্য',
      'where_to': 'কোথায় যেতে হবে?',
      'places_near_you': 'কাছাকাছি জায়গা',
      'create_trip': 'ট্রিপ তৈরি করুন',
      'find_trip': 'ট্রিপ খুঁজুন',
      'enter_pickup': 'পিকআপ অবস্থান লিখুন',
      'enter_destination': 'গন্তব্য লিখুন',
      'book': 'বুক করুন',
      'select_drivers': 'ড্রাইভারের সংখ্যা নির্বাচন করুন',
      'logout_confirm': 'আপনি কি সাইন আউট করতে চান?',
    },
  };

  static String get(String key, String languageCode) {
    return translations[languageCode]?[key] ?? translations['en']?[key] ?? key;
  }
}

// Settings State
class SettingsState {
  final bool isDarkMode;
  final String languageCode;
  final String languageName;
  final bool notificationsEnabled;
  final bool locationSharing;

  const SettingsState({
    this.isDarkMode = false,
    this.languageCode = 'en',
    this.languageName = 'English (India)',
    this.notificationsEnabled = true,
    this.locationSharing = true,
  });

  SettingsState copyWith({
    bool? isDarkMode,
    String? languageCode,
    String? languageName,
    bool? notificationsEnabled,
    bool? locationSharing,
  }) {
    return SettingsState(
      isDarkMode: isDarkMode ?? this.isDarkMode,
      languageCode: languageCode ?? this.languageCode,
      languageName: languageName ?? this.languageName,
      notificationsEnabled: notificationsEnabled ?? this.notificationsEnabled,
      locationSharing: locationSharing ?? this.locationSharing,
    );
  }
}

// Settings Notifier
class SettingsNotifier extends StateNotifier<SettingsState> {
  SettingsNotifier() : super(const SettingsState()) {
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    state = SettingsState(
      isDarkMode: prefs.getBool('isDarkMode') ?? false,
      languageCode: prefs.getString('languageCode') ?? 'en',
      languageName: prefs.getString('languageName') ?? 'English (India)',
      notificationsEnabled: prefs.getBool('notificationsEnabled') ?? true,
      locationSharing: prefs.getBool('locationSharing') ?? true,
    );
  }

  Future<void> setDarkMode(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('isDarkMode', value);
    state = state.copyWith(isDarkMode: value);
  }

  Future<void> setLanguage(String code, String name) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('languageCode', code);
    await prefs.setString('languageName', name);
    state = state.copyWith(languageCode: code, languageName: name);
  }

  Future<void> setNotifications(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('notificationsEnabled', value);
    // Keep both settings keys in sync (profile/settings screens share push controls).
    await prefs.setBool('pref_push_notifications', value);
    state = state.copyWith(notificationsEnabled: value);
    if (value) {
      unawaited(pushNotificationService.registerToken());
    } else {
      unawaited(pushNotificationService.unregisterToken());
    }
  }

  Future<void> setLocationSharing(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('locationSharing', value);
    state = state.copyWith(locationSharing: value);
  }

  // Get translated string
  String tr(String key) {
    return AppStrings.get(key, state.languageCode);
  }
}

// Provider
final settingsProvider = StateNotifierProvider<SettingsNotifier, SettingsState>((ref) {
  return SettingsNotifier();
});

// Extension for easy translation access in widgets
extension TranslationExtension on WidgetRef {
  String tr(String key) {
    final langCode = watch(settingsProvider).languageCode;
    return AppStrings.get(key, langCode);
  }
}

// For use outside of widgets (e.g., in providers)
String trWithCode(String key, String languageCode) {
  return AppStrings.get(key, languageCode);
}
