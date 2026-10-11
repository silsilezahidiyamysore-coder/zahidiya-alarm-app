// ============================================================
// APP CONFIGURATION
// URLs, endpoints, aur global constants
// ============================================================

// ============ SERVER URLs ============
const String websiteUrl = 'https://zahidiya-mysore.pages.dev';
const String scheduleUrlBase = '$websiteUrl/api/get-alarm-schedule';
const String saveFcmTokenUrl = '$websiteUrl/api/save-fcm-token';
const String getPrayerMessagesUrl = '$websiteUrl/api/get-prayer-messages';
const String getPrayerNamesUrl = '$websiteUrl/api/get-prayer-names';
const String getAlarmSettingsUrl = '$websiteUrl/api/get-alarm-settings';
const String getMenuItemsUrl = '$websiteUrl/api/get-menu-items';
const String transliterateUrl = '$websiteUrl/api/transliterate';

// ============ TASK NAMES ============
const String dailySyncTaskName = 'zahidiyaDailyAlarmSync';

// ============ STORAGE KEYS ============
const String kLocalAlarmRecords = 'local_alarm_records_v1';
const String kPrayerMessagesPrefs = 'prayer_messages_cache_v1';
const String kPrayerNamesPrefs = 'prayer_names_cache_v1';
const String kAlarmSettingsPrefs = 'alarm_settings_cache_v1';
const String kMenuItemsPrefs = 'menu_items_cache_v1';

// ============ GLOBAL USER STATE ============
// Ye variables app ke through shared hote hain
String currentUserRole = 'mureed';
String currentUserName = '';
String currentUserMobile = '';
