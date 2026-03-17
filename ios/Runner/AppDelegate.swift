import Flutter
import UIKit
import GoogleMaps
import Firebase

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Firebase: load GoogleService-Info.plist explicitly (handles bundle lookup on simulator + physical device)
    var options: FirebaseOptions?
    if let path = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") {
      options = FirebaseOptions(contentsOfFile: path)
    }
    if options == nil, let url = Bundle.main.url(forResource: "GoogleService-Info", withExtension: "plist") {
      options = FirebaseOptions(contentsOfFile: url.path)
    }
    if let opts = options {
      FirebaseApp.configure(options: opts)
    } else {
      fatalError("GoogleService-Info.plist not found in app bundle. Add it to Runner target → Build Phases → Copy Bundle Resources.")
    }
    GeneratedPluginRegistrant.register(with: self)
    // Google Maps for iOS - use same key as app_config.dart or create iOS key in Google Cloud Console
    GMSServices.provideAPIKey("AIzaSyAaTuhvB_WuJosSUXfgMyhMxAD-6sEmfVc")
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
