// SPDX-License-Identifier: MIT
//! The genres ID3 numbers: an ID3v1 tag's genre byte, and an ID3v2 genre
//! given as `(17)` or `17`, name one of these. The first 80 are ID3v1's
//! own, the rest the extensions every tagger reads.

pub const names = [_][*:0]const u8{
    "Blues", "Classic Rock", "Country", "Dance", // 0
    "Disco", "Funk", "Grunge", "Hip-Hop", // 4
    "Jazz", "Metal", "New Age", "Oldies", // 8
    "Other", "Pop", "R&B", "Rap", // 12
    "Reggae", "Rock", "Techno", "Industrial", // 16
    "Alternative", "Ska", "Death Metal", "Pranks", // 20
    "Soundtrack", "Euro-Techno", "Ambient", "Trip-Hop", // 24
    "Vocal", "Jazz+Funk", "Fusion", "Trance", // 28
    "Classical", "Instrumental", "Acid", "House", // 32
    "Game", "Sound Clip", "Gospel", "Noise", // 36
    "AlternRock", "Bass", "Soul", "Punk", // 40
    "Space", "Meditative", "Instrumental Pop", "Instrumental Rock", // 44
    "Ethnic", "Gothic", "Darkwave", "Techno-Industrial", // 48
    "Electronic", "Pop-Folk", "Eurodance", "Dream", // 52
    "Southern Rock", "Comedy", "Cult", "Gangsta", // 56
    "Top 40", "Christian Rap", "Pop/Funk", "Jungle", // 60
    "Native American", "Cabaret", "New Wave", "Psychedelic", // 64
    "Rave", "Showtunes", "Trailer", "Lo-Fi", // 68
    "Tribal", "Acid Punk", "Acid Jazz", "Polka", // 72
    "Retro", "Musical", "Rock & Roll", "Hard Rock", // 76
    "Folk", "Folk-Rock", "National Folk", "Swing", // 80
    "Fast Fusion", "Bebop", "Latin", "Revival", // 84
    "Celtic", "Bluegrass", "Avantgarde", "Gothic Rock", // 88
    "Progressive Rock", "Psychedelic Rock", "Symphonic Rock", "Slow Rock", // 92
    "Big Band", "Chorus", "Easy Listening", "Acoustic", // 96
    "Humour", "Speech", "Chanson", "Opera", // 100
    "Chamber Music", "Sonata", "Symphony", "Booty Bass", // 104
    "Primus", "Porn Groove", "Satire", "Slow Jam", // 108
    "Club", "Tango", "Samba", "Folklore", // 112
    "Ballad", "Power Ballad", "Rhythmic Soul", "Freestyle", // 116
    "Duet", "Punk Rock", "Drum Solo", "A Cappella", // 120
    "Euro-House", "Dance Hall", "Goa", "Drum & Bass", // 124
    "Club-House", "Hardcore Techno", "Terror", "Indie", // 128
    "BritPop", "Negerpunk", "Polsk Punk", "Beat", // 132
    "Christian Gangsta Rap", "Heavy Metal", "Black Metal", "Crossover", // 136
    "Contemporary Christian", "Christian Rock", "Merengue", "Salsa", // 140
    "Thrash Metal", "Anime", "Jpop", "Synthpop", // 144
    "Abstract", "Art Rock", "Baroque", "Bhangra", // 148
    "Big Beat", "Breakbeat", "Chillout", "Downtempo", // 152
    "Dub", "EBM", "Eclectic", "Electro", // 156
    "Electroclash", "Emo", "Experimental", "Garage", // 160
    "Global", "IDM", "Illbient", "Industro-Goth", // 164
    "Jam Band", "Krautrock", "Leftfield", "Lounge", // 168
    "Math Rock", "New Romantic", "Nu-Breakz", "Post-Punk", // 172
    "Post-Rock", "Psytrance", "Shoegaze", "Space Rock", // 176
    "Trop Rock", "World Music", "Neoclassical", "Audiobook", // 180
    "Audio Theatre", "Neue Deutsche Welle", "Podcast", "Indie Rock", // 184
    "G-Funk", "Dubstep", "Garage Rock", "Psybient", // 188
};

/// The name of genre `number`, or null for one ID3 does not name.
pub fn named(number: u32) ?[*:0]const u8 {
    return if (number < names.len) names[number] else null;
}
