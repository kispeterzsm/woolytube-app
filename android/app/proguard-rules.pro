# youtubedl-android extracts packaged binaries through commons-compress ZIP.
# ExtraFieldUtils reflectively instantiates ZIP extra-field classes; R8 can
# otherwise rewrite them in a way that crashes YoutubeDL.init() in release.
-keep class org.apache.commons.compress.archivers.zip.** { *; }
