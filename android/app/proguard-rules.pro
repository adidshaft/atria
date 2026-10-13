# kotlinx.serialization
-keepattributes *Annotation*, InnerClasses
-dontnote kotlinx.serialization.**
-keepclassmembers class com.adidshaft.atria.** { *** Companion; kotlinx.serialization.KSerializer serializer(...); }
-keep,includedescriptorclasses class com.adidshaft.atria.**$$serializer { *; }
# osmdroid
-dontwarn org.osmdroid.**
