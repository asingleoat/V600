#!/bin/sh
# Assemble CerealGrain.app around a release cerealgrain-ui and zip it for sharing. Every
# library it loads from outside macOS goes into Contents/Frameworks with the
# load commands pointed there, and everything is signed ad hoc: no identity,
# so nothing in the signature names a person. Run by `zig build app-bundle`.
#
# usage: macos_app_bundle.sh <cerealgrain-ui> <cerealgrain> <output dir>
set -eu
# codesign, ditto, and plutil are macOS's own; a Nix shell may not list them.
PATH=$PATH:/usr/bin:/bin

exe=$1
cli=$2
out=$3
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/.." && pwd)
app=$out/CerealGrain.app
frameworks=$app/Contents/Frameworks
version=0.1.0
build=$(git -C "$repo" rev-list --count HEAD 2>/dev/null || echo 0)

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$frameworks" "$app/Contents/Resources"
cp "$exe" "$app/Contents/MacOS/cerealgrain-ui"
cp "$cli" "$app/Contents/MacOS/cerealgrain"
chmod 755 "$app/Contents/MacOS/cerealgrain-ui" "$app/Contents/MacOS/cerealgrain"

cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>CerealGrain</string>
  <key>CFBundleDisplayName</key><string>CerealGrain</string>
  <key>CFBundleIdentifier</key><string>io.github.asingleoat.cerealgrain</string>
  <key>CFBundleExecutable</key><string>cerealgrain-ui</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$build</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.photography</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF
plutil -lint "$app/Contents/Info.plist" > /dev/null

# install_name_tool warns that each edit invalidates the signature, and
# codesign that it replaces one; show their output only when they fail.
quiet() {
  "$@" 2> "$work/stderr" || { cat "$work/stderr" >&2; return 1; }
}

rpaths_of() {
  otool -l "$1" | awk '$1 == "cmd" && $2 == "LC_RPATH" { getline; getline; print $2 }'
}

# Prints "reference resolved-path" for each library $1 (bundled copy) loads
# from outside macOS, resolving @rpath and @loader_path against $2 (where the
# library came from). Its own install name is skipped.
bundled_deps() {
  image=$1
  origin_dir=$(dirname "$2")
  self=$(otool -D "$image" | tail -n +2)
  rpaths=$(rpaths_of "$image" | sed "s|@loader_path|$origin_dir|")
  otool -L "$image" | tail -n +2 | awk '{ print $1 }' | while read -r ref; do
    [ "$ref" = "$self" ] && continue
    case $ref in
      /usr/lib/* | /System/* | @executable_path/*) ;;
      @rpath/*)
        found=
        for dir in $rpaths; do
          if [ -f "$dir/${ref#@rpath/}" ]; then
            found=$dir/${ref#@rpath/}
            break
          fi
        done
        echo "$ref ${found:-unresolved}"
        ;;
      @loader_path/*) echo "$ref $origin_dir/${ref#@loader_path/}" ;;
      *) echo "$ref $ref" ;;
    esac
  done
}

# Breadth first from the executables: copy each library once, by the name of
# the file behind any symlinks, and point every reference at the copy. Two
# different builds of one library (Nix can carry both, e.g. libwebp for
# OpenCV and for libtiff) each keep their own copy, the second prefixed with
# its store hash.
: > "$work/copied"
printf '%s\n' "$app/Contents/MacOS/cerealgrain-ui $exe" "$app/Contents/MacOS/cerealgrain $cli" > "$work/queue"
while [ -s "$work/queue" ]; do
  mv "$work/queue" "$work/current"
  : > "$work/queue"
  while read -r image origin; do
    bundled_deps "$image" "$origin" > "$work/deps"
    while read -r ref path; do
      if [ ! -f "$path" ]; then
        echo "app-bundle: cannot find $ref, needed by $origin" >&2
        exit 1
      fi
      real=$(realpath "$path")
      name=$(awk -v real="$real" '$1 == real { print $2 }' "$work/copied")
      if [ -z "$name" ]; then
        name=$(basename "$real")
        if [ -e "$frameworks/$name" ]; then
          name=$(echo "$real" | sed -n 's|^/nix/store/\([a-z0-9]\{8\}\).*|\1|p')-$name
        fi
        if [ -e "$frameworks/$name" ]; then
          echo "app-bundle: two different libraries named $name" >&2
          exit 1
        fi
        cp "$real" "$frameworks/$name"
        chmod 644 "$frameworks/$name"
        quiet install_name_tool -id "@executable_path/../Frameworks/$name" "$frameworks/$name"
        echo "$real $name" >> "$work/copied"
        echo "$frameworks/$name $real" >> "$work/queue"
      fi
      quiet install_name_tool -change "$ref" "@executable_path/../Frameworks/$name" "$image"
    done < "$work/deps"
    # Run paths into the Nix store mean nothing on another Mac.
    for dir in $(rpaths_of "$image"); do
      quiet install_name_tool -delete_rpath "$dir" "$image"
    done
  done < "$work/current"
done

for library in "$frameworks"/* "$app/Contents/MacOS/cerealgrain"; do
  quiet codesign --force --sign - "$library"
done
quiet codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"

for image in "$app/Contents/MacOS/"* "$frameworks"/*; do
  if otool -L "$image" | grep -q "/nix/store"; then
    echo "app-bundle: $image still loads from the Nix store" >&2
    exit 1
  fi
done
# The build machine's home directory must not ship (the project is published
# under a pseudonym).
if grep -rlF "$HOME" "$app" > "$work/leaks"; then
  echo "app-bundle: these files contain $HOME:" >&2
  cat "$work/leaks" >&2
  exit 1
fi

mkdir "$work/CerealGrain"
ditto "$app" "$work/CerealGrain/CerealGrain.app"
cp "$here/macos_app_readme.txt" "$work/CerealGrain/Read Me.txt"
rm -f "$out"/CerealGrain-*-macos-arm64.zip
zip=$out/CerealGrain-$version-$build-macos-arm64.zip
ditto -c -k --sequesterRsrc --keepParent "$work/CerealGrain" "$zip"

echo "app-bundle: $app ($(ls "$frameworks" | wc -l | tr -d ' ') libraries, $(du -sh "$app" | cut -f1))"
echo "app-bundle: $zip ($(du -h "$zip" | cut -f1))"
