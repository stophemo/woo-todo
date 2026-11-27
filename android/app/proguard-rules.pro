# ZXing Android Embedded 4.3.0 未附带 consumer rules；
# 保留扫描 Activity 与二维码编解码，避免 release 混淆后扫码/生成二维码失败。
-keep class com.journeyapps.barcodescanner.** { *; }
-keep class com.google.zxing.** { *; }
-dontwarn com.google.zxing.**
