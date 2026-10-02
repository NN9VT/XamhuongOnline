// Dán link Firebase Realtime Database của bạn vào giữa hai dấu nháy, ví dụ:
// 'https://ten-du-an-default-rtdb.asia-southeast1.firebasedatabase.app'
const String firebaseDbUrl =
    'https://xamhuong-82e87-default-rtdb.asia-southeast1.firebasedatabase.app';

bool get onlineConfigured => firebaseDbUrl.startsWith('https://');
