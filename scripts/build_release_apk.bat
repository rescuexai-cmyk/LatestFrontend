@echo off
REM Build a release APK for testing (uses debug signing from android/app/build.gradle.kts).
cd /d "%~dp0.."
where flutter >nul 2>nul
if errorlevel 1 (
  echo ERROR: Flutter is not in PATH.
  echo Install Flutter and add its bin folder to PATH, then run this script again.
  echo https://docs.flutter.dev/get-started/install/windows
  exit /b 1
)
call flutter pub get
call flutter build apk --release
if errorlevel 1 exit /b 1
echo.
echo APK output:
echo   build\app\outputs\flutter-apk\app-release.apk
exit /b 0
