#!/bin/sh
# SPDX-License-Identifier: MPL-2.0
# Fetch the songs and films a card's Work: volume is handed with
# (`./zig build card`, `-Dcard-work=`), and lay them out in
# toolchain/examples as the volume holds them:
#
#   Music/Musopen/        five recordings of the Musopen Kickstarter
#                         project - the Czech National Symphony Orchestra
#                         and Shelley Katz - dedicated to the public
#                         domain (CC0), MP3 with titles and covers
#   Music/Tears of Steel/ the film's soundtrack by Joram Letwory, four
#                         MP3s as released, under CC BY-ND 3.0
#   Films/Big Buck Bunny.mp4   the Blender Foundation's film, CC BY 3.0:
#                         its 1080p H.264 release in MP4, the sound mixed
#                         from 5.1 into stereo AAC, the index at the front
#   Films/Sintel.mkv      the Blender Foundation's film, CC BY 3.0: its
#                         1080p release's pictures made 720p H.264 (a
#                         key frame every two seconds), its AC-3 5.1
#                         sound and ten SubRip subtitles as they are,
#                         in Matroska
#   Films/Tears of Steel.mkv   the Blender Foundation's film, CC BY 3.0:
#                         the 1080p release's pictures encoded in H.265
#                         (Main, a key frame every two seconds), its MP3
#                         sound, and six of the project's subtitles
#   Credits.txt           who made each and under which licence
#
# H.264 and H.265 are the two codecs a Raspberry Pi 4's chip decodes, and
# MP4 and Matroska the two containers videocodec.library reads. Every
# download is held against its sha256 and kept in toolchain/examples-src,
# so a second run downloads nothing; a file already made is not made
# again - delete it to have it made afresh. ffmpeg with libx264 and
# libx265 makes the films (some minutes each for Sintel and Tears of
# Steel). Nothing of it is committed.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
src="$root/toolchain/examples-src"
out="$root/toolchain/examples"
mkdir -p "$src" "$out/Music/Musopen" "$out/Music/Tears of Steel" "$out/Films"

for tool in curl ffmpeg sha256sum unzip; do
    command -v "$tool" >/dev/null || { echo "fetch-examples: $tool is needed" >&2; exit 1; }
done
for encoder in libx264 libx265; do
    ffmpeg -hide_banner -encoders 2>/dev/null | grep -q "$encoder" ||
        { echo "fetch-examples: ffmpeg without $encoder cannot make the films" >&2; exit 1; }
done

# get <file in examples-src> <sha256> <address>: the file, downloaded
# unless it is there with that sum, and checked.
get() {
    if [ -f "$src/$1" ] && echo "$2  $src/$1" | sha256sum -c --quiet >/dev/null 2>&1; then
        return
    fi
    mkdir -p "$(dirname "$src/$1")"
    curl -sSfL --retry 3 -o "$src/$1.part" "$3"
    mv "$src/$1.part" "$src/$1"
    echo "$2  $src/$1" | sha256sum -c --quiet
}

blender=https://download.blender.org
musopen="https://archive.org/download/MusopenKickstarterRecordings/Musopen%20DVD.zip/Musopen%20DVD%2F"
tos_ost="$blender/demo/movies/ToS/Tears-Of-Steel-OST"

get musopen/bach-goldberg-aria.mp3 7ed46b53c6a7bf1e95dacecb74b6d9b5df3a0a50c696c2e6459039ffd4a982db \
    "${musopen}Goldberg%20Variations%2FGoldberg%20Variations%2C%20BWV%20988%20-%20Aria.mp3"
get musopen/beethoven-egmont.mp3 25947c9390ff028294e2cdd8bd4c4c789e165c1c5428466ad5a89c80b54e7c28 \
    "${musopen}Beethoven%20-%20Egmont%20Overture%20Op.%2084%2FEgmont%20Overture%20Op.%2084.mp3"
get musopen/grieg-morning.mp3 d14bea708905e5eef51549d7565cdcde0db552530dadfc4f43f8e0a118908ea3 \
    "${musopen}Grieg%20-%20Peer%20Gynt%2FPeer%20Gynt%20Suite%20No.%201%2C%20Op.%2046%20-%20I.%20Morning.mp3"
get musopen/grieg-mountain-king.mp3 29b8f4f8629e9abd4b16517980ce384a1e5ee18c8ff8e766fc6dc9b6520cc157 \
    "${musopen}Grieg%20-%20Peer%20Gynt%2FPeer%20Gynt%20Suite%20No.%201%2C%20Op.%2046%20-%20IV.%20In%20the%20Hall%20Of%20The%20Mountain%20King.mp3"
get musopen/mozart-40-1.mp3 68811d4bf36b5bef2eea84e596348c9cc9c7520ceee2ad7ae6ebee5fff9e3b26 \
    "${musopen}Mozart%20-%20Symphony%20No%2040%20in%20G%20Minor%20%2F1st%20Mov%20Molto%20allegro.mp3"

get "ost-01 40 years later.mp3" 06e3622e8b0627aacdc00ca25a250197a5f90d445424862a4f37425c2ce48d66 "$tos_ost/01%2040%20years%20later.mp3"
get "ost-02 The dome.mp3" ec03d47cfbfe52b4547f8bcc343b2006c438768c5c45566b91a01851f663f443 "$tos_ost/02%20The%20dome.mp3"
get "ost-03 The battle.mp3" a70b99670cb3b6a7b89632a1dc059d9d8364eaeda5b7daa65064ba6ccbf5e262 "$tos_ost/03%20The%20battle.mp3"
get "ost-04 End credits.mp3" 683956870d92a413384ea3d4e3a3376a4ebeb698c018cd3f812707ffdbb27a7a "$tos_ost/04%20End%20credits.mp3"
get ost-copyright.txt 05ca97eeac2b81eec4239b9fe82fc2ffff4f08c37731430bb14a518657341811 "$tos_ost/copyright.txt"

get big_buck_bunny_1080p_h264.mov.zip 402d6625f614631627d518b931865c9c4aefbbf3b75ed0494672e77ff510666d \
    "$blender/peach/bigbuckbunny_movies/big_buck_bunny_1080p_h264.mov.zip"
get Sintel.2010.1080p.mkv 97f1dbc66231df42ad49bd8c29aa174b8f48933058e47e7157d4ba63d93a8efa \
    "$blender/durian/movies/Sintel.2010.1080p.mkv"
get tears_of_steel_1080p.mov.zip d87a41de040d3814dbde143e9ab85ef122caf22265f660b0bebf476cd8b357a5 \
    "$blender/demo/movies/ToS/tears_of_steel_1080p.mov.zip"
get TOS-en.srt ce9578f6fe098a5821045a38884b229160f9e7ba27890448a92f5be330c6e6fe "$blender/demo/movies/ToS/subtitles/TOS-en.srt"
get TOS-de.srt 666685daa9064a5a59144e47bddd2d570bbdda199df6e4e39f3273e479ab1f4b "$blender/demo/movies/ToS/subtitles/TOS-de.srt"
get TOS-fr-orig.srt 94cc887d34c83ee909dfe141edaccc2afc1ae8c23c7929b60e2f73905968c708 "$blender/demo/movies/ToS/subtitles/TOS-fr-orig.srt"
get TOS-es.srt b1936989cf42eda28988ec9120a80b7303562ea6429e49441160ba688da39a5c "$blender/demo/movies/ToS/subtitles/TOS-es.srt"
get TOS-it.srt 6b8f6023b88b16acadea52d1664aa92ef132d7481e3e1957f1f334260477c870 "$blender/demo/movies/ToS/subtitles/TOS-it.srt"
get TOS-nl.srt 1146fe8a924306d680d9b7c82cf652e56e9f1ed28c81142fa477daee04b45b58 "$blender/demo/movies/ToS/subtitles/TOS-nl.srt"

# The songs, as they were released.
put() {
    [ -f "$out/$2" ] || cp "$src/$1" "$out/$2"
}
put musopen/bach-goldberg-aria.mp3 "Music/Musopen/Bach - Goldberg Variations, Aria.mp3"
put musopen/beethoven-egmont.mp3 "Music/Musopen/Beethoven - Egmont Overture.mp3"
put musopen/grieg-morning.mp3 "Music/Musopen/Grieg - Peer Gynt, Morning.mp3"
put musopen/grieg-mountain-king.mp3 "Music/Musopen/Grieg - Peer Gynt, In the Hall of the Mountain King.mp3"
put musopen/mozart-40-1.mp3 "Music/Musopen/Mozart - Symphony No. 40, Molto allegro.mp3"
put "ost-01 40 years later.mp3" "Music/Tears of Steel/01 40 years later.mp3"
put "ost-02 The dome.mp3" "Music/Tears of Steel/02 The dome.mp3"
put "ost-03 The battle.mp3" "Music/Tears of Steel/03 The battle.mp3"
put "ost-04 End credits.mp3" "Music/Tears of Steel/04 End credits.mp3"

# The films. Each is made under a name of its own and renamed when it is
# whole, so a run that was stopped leaves no half film behind.
work="$src/work"
mkdir -p "$work"
ff() {
    ffmpeg -nostdin -hide_banner -loglevel error -y "$@"
}

film="$out/Films/Big Buck Bunny.mp4"
if [ ! -f "$film" ]; then
    echo "fetch-examples: Big Buck Bunny"
    unzip -o -q "$src/big_buck_bunny_1080p_h264.mov.zip" -d "$work"
    ff -i "$work/big_buck_bunny_1080p_h264.mov" -map 0:v:0 -map 0:a:0 -map_metadata -1 \
        -c:v copy -c:a aac -ac 2 -b:a 192k -flags:a +bitexact \
        -metadata title="Big Buck Bunny" -metadata:s:a:0 language=eng \
        -movflags +faststart "$work/bbb.mp4"
    mv "$work/bbb.mp4" "$film"
    rm -f "$work/big_buck_bunny_1080p_h264.mov"
fi

# Sintel at 720p, so that a card with all three films packs into less than
# the 2 GiB a file handed out on GitHub may have.
film="$out/Films/Sintel.mkv"
if [ ! -f "$film" ]; then
    echo "fetch-examples: Sintel, encoding at 720p (some minutes)"
    ff -i "$src/Sintel.2010.1080p.mkv" -map 0:v:0 -map 0:a:0 -map 0:s \
        -c:v libx264 -preset slow -crf 20 -profile:v high -level:v 4.0 -pix_fmt yuv420p \
        -vf scale=1280:544,setsar=1 -g 48 -keyint_min 24 \
        -c:a copy -c:s copy "$work/sintel.mkv"
    mv "$work/sintel.mkv" "$film"
fi

film="$out/Films/Tears of Steel.mkv"
if [ ! -f "$film" ]; then
    echo "fetch-examples: Tears of Steel, encoding in H.265 (some minutes)"
    unzip -o -q "$src/tears_of_steel_1080p.mov.zip" -d "$work"
    ff -i "$work/tears_of_steel_1080p.mov" \
        -i "$src/TOS-en.srt" -i "$src/TOS-de.srt" -i "$src/TOS-fr-orig.srt" \
        -i "$src/TOS-es.srt" -i "$src/TOS-it.srt" -i "$src/TOS-nl.srt" \
        -map 0:v:0 -map 0:a:0 -map 1 -map 2 -map 3 -map 4 -map 5 -map 6 -map_metadata -1 \
        -c:v libx265 -preset medium -crf 22 -pix_fmt yuv420p -profile:v main \
        -x265-params keyint=48:min-keyint=24:log-level=error \
        -c:a copy -c:s srt \
        -metadata title="Tears of Steel" -metadata:s:a:0 language=eng \
        -metadata:s:s:0 language=eng -metadata:s:s:1 language=ger -metadata:s:s:2 language=fre \
        -metadata:s:s:3 language=spa -metadata:s:s:4 language=ita -metadata:s:s:5 language=dut \
        "$work/tos.mkv"
    mv "$work/tos.mkv" "$film"
    rm -f "$work/tears_of_steel_1080p.mov"
fi

cat >"$out/Credits.txt" <<'EOF'
The songs and films on this volume, who made them and under which
licence each may be copied.

Films/Big Buck Bunny.mp4
  (c) copyright 2008, Blender Foundation / www.bigbuckbunny.org
  Creative Commons Attribution 3.0
  https://creativecommons.org/licenses/by/3.0/
  The 1080p H.264 release, its sound mixed from 5.1 into stereo AAC.

Films/Sintel.mkv
  (c) copyright Blender Foundation | durian.blender.org
  Creative Commons Attribution 3.0
  https://creativecommons.org/licenses/by/3.0/
  The 1080p release's pictures made 720p H.264, with its AC-3 5.1
  sound and its ten subtitles.

Films/Tears of Steel.mkv
  (CC) Blender Foundation | mango.blender.org
  Creative Commons Attribution 3.0
  https://creativecommons.org/licenses/by/3.0/
  The 1080p release's pictures encoded in H.265, with its sound and the
  project's English, German, French, Spanish, Italian and Dutch
  subtitles.

Music/Tears of Steel/
  (C) Joram Letwory - www.tearsofsteel.org
  Creative Commons Attribution-NoDerivs 3.0
  https://creativecommons.org/licenses/by-nd/3.0/
  The original soundtrack's four MP3s as released.

Music/Musopen/
  Czech National Symphony Orchestra and Shelley Katz, recorded for the
  Musopen Kickstarter project (musopen.org), dedicated to the public
  domain: Creative Commons Zero 1.0
  https://creativecommons.org/publicdomain/zero/1.0/
  Bach's Aria from the Goldberg Variations, Beethoven's Egmont
  Overture, Morning and In the Hall of the Mountain King from Grieg's
  Peer Gynt Suite No. 1, and the first movement of Mozart's Symphony
  No. 40, as released.
EOF

rmdir "$work" 2>/dev/null || true
echo "fetch-examples: in $out"
